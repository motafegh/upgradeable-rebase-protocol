// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title RebaseToken
 * @author Ali
 * @notice ERC20 token where each user has their own interest rate
 *
 * Key Features:
 * - Linear interest calculation for gas efficiency
 * - Per-user interest rates that persist across transfers and bridges
 * - Lazy minting: interest calculated on-demand, minted on interaction
 * - Security: Rate downgrade protection prevents griefing attacks
 */
contract RebaseToken is ERC20, Ownable, AccessControl {
    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error RebaseToken__InterestRateCanOnlyDecrease(uint256 currentRate, uint256 proposedRate);

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    uint256 private constant PRECISION_FACTOR = 1e18;
    bytes32 private constant MINT_AND_BURN_ROLE = keccak256("MINT_AND_BURN_ROLE");

    mapping(address => uint256) private s_userInterestRate;
    mapping(address => uint256) private s_userLastUpdatedTimestamp;
    uint256 private s_interestRate = 5e10;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event InterestRateSet(uint256 newInterestRate);
    event InterestMinted(address indexed user, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor() Ownable(msg.sender) ERC20("RebaseToken", "RBT") {}

    /*//////////////////////////////////////////////////////////////
                          EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Grant mint and burn role to an address (typically Vault and Pool)
     * @param _address Address to grant the role to
     */
    function grantMintAndBurnRole(address _address) external onlyOwner {
        _grantRole(MINT_AND_BURN_ROLE, _address);
    }

    /**
     * @notice Set the global interest rate (can only decrease)
     * @param _newInterestRate The new interest rate
     * @dev Ensures rate can only go down to prevent unfair advantage to late depositors
     */
    function setInterestRate(uint256 _newInterestRate) external onlyOwner {
        if (_newInterestRate >= s_interestRate) {
            revert RebaseToken__InterestRateCanOnlyDecrease(s_interestRate, _newInterestRate);
        }
        s_interestRate = _newInterestRate;
        emit InterestRateSet(_newInterestRate);
    }

    /**
     * @notice Mint tokens to a user with a specific interest rate
     * @param _to Recipient address
     * @param _value Amount to mint
     * @param _userInterestRate Interest rate for this user
     * @dev Includes rate downgrade protection: only updates rate if higher or user has zero balance
     */
    function mint(address _to, uint256 _value, uint256 _userInterestRate) public onlyRole(MINT_AND_BURN_ROLE) {
        _mintAccruedInterest(_to);

        // Security fix: prevent rate downgrade attacks
        // Only update rate if user has no tokens OR new rate is higher
        if (super.balanceOf(_to) == 0 || _userInterestRate > s_userInterestRate[_to]) {
            s_userInterestRate[_to] = _userInterestRate;
        }

        _mint(_to, _value);
    }

    /**
     * @notice Burn tokens from a user
     * @param _from Address to burn from
     * @param _value Amount to burn
     * @dev Mints any pending interest before burning
     */
    function burn(address _from, uint256 _value) public onlyRole(MINT_AND_BURN_ROLE) {
        _mintAccruedInterest(_from);
        _burn(_from, _value);
    }

    /**
     * @notice Get user's balance including unminted interest
     * @param _user User address
     * @return Total balance (principal + interest)
     * @dev This is a view function so it's free to call, but interest isn't actually minted until interaction
     */
    function balanceOf(address _user) public view override returns (uint256) {
        uint256 currentPrincipalBalance = super.balanceOf(_user);
        if (currentPrincipalBalance == 0) {
            return 0;
        }

        // Calculate balance with interest: principal × accumulated multiplier
        return (currentPrincipalBalance * _calculateUserAccumulatedInterestSinceLastUpdate(_user)) / PRECISION_FACTOR;
    }

    /**
     * @notice Transfer tokens to another address
     * @param _recipient Recipient address
     * @param _amount Amount to transfer (use type(uint256).max for full balance)
     * @return success Whether transfer succeeded
     * @dev Mints interest for both parties and may update recipient's rate
     */

    //Optimize gas cost
    function transfer(address _recipient, uint256 _amount) public override returns (bool) {
        // Mint interest FIRST
        _mintAccruedInterest(msg.sender);
        _mintAccruedInterest(_recipient);

        // Then use super.balanceOf (no calculation needed)
        if (_amount == type(uint256).max) {
            _amount = super.balanceOf(msg.sender);
        }

        if (super.balanceOf(_recipient) == 0) {
            s_userInterestRate[_recipient] = s_userInterestRate[msg.sender];
        }

        return super.transfer(_recipient, _amount);
    }

    /**
     * @notice Transfer tokens from one address to another
     * @param _sender Sender address
     * @param _recipient Recipient address
     * @param _amount Amount to transfer (use type(uint256).max for full balance)
     * @return success Whether transfer succeeded
     * @dev Same logic as transfer but with approval mechanism
     */
    function transferFrom(address _sender, address _recipient, uint256 _amount) public override returns (bool) {
        _mintAccruedInterest(_sender);
        _mintAccruedInterest(_recipient);

        uint256 requestedAmount = _amount; // keep original value
        if (_amount == type(uint256).max) {
            _amount = super.balanceOf(_sender); // actual tokens to move
        }

        if (super.balanceOf(_recipient) == 0) {
            s_userInterestRate[_recipient] = s_userInterestRate[_sender];
        }

        // super.transferFrom will transfer `_amount` but decrement allowance by `requestedAmount`
        return super.transferFrom(_sender, _recipient, requestedAmount);
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Calculate accumulated interest multiplier since last update
     * @param _user User address
     * @return linearInterest Multiplier in 1e18 precision (1e18 = 1x, 2e18 = 2x)
     *
     * Formula: 1 + (rate × time)
     * Example: rate=5e10, time=3600s → 1e18 + (5e10 × 3600) = 1.00018e18 (0.018% gain)
     *
     * Why linear not compound?
     * - Gas efficient: ~30k vs ~200k for exponential
     * - Accurate enough for short timeframes (weekly/monthly interactions)
     * - Simple to audit
     */
    function _calculateUserAccumulatedInterestSinceLastUpdate(address _user)
        internal
        view
        returns (uint256 linearInterest)
    {
        uint256 timeDifference = block.timestamp - s_userLastUpdatedTimestamp[_user];

        // Linear interest formula: 1 + (rate × time)
        // Note: Must multiply before adding to maintain precision
        linearInterest = (s_userInterestRate[_user] * timeDifference) + PRECISION_FACTOR;
    }

    /**
     * @dev Mint accumulated interest to user's balance
     * @param _user User address
     *
     * CRITICAL: Must be called before any balance-changing operation
     * Why? Because we need to capture interest before the balance changes
     *
     * Process:
     * 1. Calculate what user's balance SHOULD be (with interest)
     * 2. See difference between that and what they actually have
     * 3. Mint that difference
     * 4. Update timestamp so next calculation starts from now
     */
    function _mintAccruedInterest(address _user) internal {
        // Get current stored balance (without interest)
        uint256 previousPrincipalBalance = super.balanceOf(_user);

        // Calculate balance with accumulated interest
        uint256 currentBalance = balanceOf(_user);

        // Calculate interest amount
        uint256 balanceIncrease = currentBalance - previousPrincipalBalance;

        // Mint the interest (making it "real")
        _mint(_user, balanceIncrease);
        // Emit an event for the minted interest
        emit InterestMinted(_user, balanceIncrease);

        // Reset the clock for next interest calculation
        s_userLastUpdatedTimestamp[_user] = block.timestamp;
    }

    /*//////////////////////////////////////////////////////////////
                              VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Get the global interest rate for new deposits
     * @return Current global interest rate
     */
    function getInterestRate() external view returns (uint256) {
        return s_interestRate;
    }

    /**
     * @notice Get a user's personal interest rate
     * @param _user User address
     * @return User's interest rate (locked in at their deposit/bridge time)
     */
    function getUserInterestRate(address _user) external view returns (uint256) {
        return s_userInterestRate[_user];
    }

    /**
     * @notice Get a user's principal balance (without unminted interest)
     * @param _user User address
     * @return Principal balance (last minted amount)
     */
    function principalBalanceOf(address _user) external view returns (uint256) {
        return super.balanceOf(_user);
    }
}
