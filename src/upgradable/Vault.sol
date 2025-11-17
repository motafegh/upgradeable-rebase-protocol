// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IRebaseToken} from "../interfaces/IRebaseToken.sol";

/**
 * @title Vault
 * @author Ali
 * @notice Entry point for users on L1 to deposit ETH and receive RebaseTokens
 *
 * Design decisions:
 * - Only deployed on L1 (Sepolia) where ETH liquidity exists
 * - Users deposit ETH and receive tokens at current global interest rate
 * - Users can redeem tokens 1:1 for ETH
 * - Vault must be funded with extra ETH to cover interest payouts
 *
 * Why only L1?
 * - Interest payments require ETH reserves
 * - Simpler to manage liquidity in one place
 * - Users can bridge tokens to L2 for cheap transactions, redeem back on L1
 */
contract Vault {
    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    IRebaseToken public immutable i_rebaseToken;

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error Vault__DepositAmountZero();
    error Vault__RedeemFailed();
    error Vault__RedeemAmountZero();

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event Deposit(address indexed user, uint256 amount);
    event Redeem(address indexed user, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(IRebaseToken _rebaseToken) {
        i_rebaseToken = _rebaseToken;
    }

    /*//////////////////////////////////////////////////////////////
                          EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Accept ETH for funding interest payments
     * @dev Anyone can add ETH to vault to keep it solvent
     */
    receive() external payable {}

    /**
     * @notice Deposit ETH and receive RebaseTokens at current global rate
     * @dev Mints tokens to msg.sender with current interest rate
     */
    function deposit() external payable {
        if (msg.value == 0) {
            revert Vault__DepositAmountZero();
        }

        // Get current global rate for new deposits
        uint256 currentRate = i_rebaseToken.getInterestRate();

        // Mint tokens to depositor at current rate
        i_rebaseToken.mint(msg.sender, msg.value, currentRate);

        emit Deposit(msg.sender, msg.value);
    }

    /**
     * @notice Redeem RebaseTokens for ETH
     * @param _amount Amount to redeem (use type(uint256).max for full balance)
     * @dev Burns tokens and sends ETH 1:1
     *      Uses CEI pattern: burn before external call to prevent reentrancy
     */
    function redeem(uint256 _amount) external {
        // Allow redeeming full balance
        if (_amount == type(uint256).max) {
            _amount = i_rebaseToken.balanceOf(msg.sender);
        }
        // to prevent accidentally call `redeem(0)` which would execute CEI
        if (_amount == 0) {
            revert Vault__RedeemAmountZero();
        }

        // Burn tokens first (CEI pattern - Effects before Interactions)
        i_rebaseToken.burn(msg.sender, _amount);

        // Send ETH to user
        (bool success,) = payable(msg.sender).call{value: _amount}("");
        if (!success) {
            revert Vault__RedeemFailed();
        }

        emit Redeem(msg.sender, _amount);
    }
}
