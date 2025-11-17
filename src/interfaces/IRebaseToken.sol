// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * @title IRebaseToken
 * @author Ali (motafegh)
 * @notice Interface for upgradeable RebaseToken (works with V1, V2, V3...)
 * @dev Minimal interface with only functions external contracts need
 *
 * DESIGN DECISION: Minimal Interface
 * ═══════════════════════════════════════════════════════════════
 * We DON'T inherit from IERC20, IAccessControl, etc. because:
 * 1. Vault only needs: mint(), burn(), balanceOf(), getInterestRate()
 * 2. Pool only needs: mint(), burn(), getUserInterestRate()
 * 3. Interactions only needs: balanceOf(), principalBalanceOf(), transfer()
 * 
 * Including unused functions bloats the interface unnecessarily.
 * External contracts can cast to IERC20 if they need ERC20 functions.
 */
interface IRebaseToken {
    /*//////////////////////////////////////////////////////////////
                        CORE REBASE FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    
    /**
     * @notice Mint tokens with specific interest rate
     * @dev Used by Vault and Pool to mint tokens
     */
    function mint(address _to, uint256 _amount, uint256 _interestRate) external;
    
    /**
     * @notice Burn tokens from address
     * @dev Used by Vault and Pool to burn tokens
     */
    function burn(address _from, uint256 _amount) external;
    
    /**
     * @notice Get user's personal interest rate
     * @dev Used by Pool to preserve rate cross-chain
     */
    function getUserInterestRate(address _account) external view returns (uint256);
    
    /**
     * @notice Get global interest rate for new deposits
     * @dev Used by Vault to mint at current rate
     */
    function getInterestRate() external view returns (uint256);
    
    /**
     * @notice Get balance including unminted interest
     * @dev Standard ERC20 balanceOf with interest calculation
     */
    function balanceOf(address _account) external view returns (uint256);
    
    /**
     * @notice Get principal balance (without unminted interest)
     * @dev Useful for calculating accrued interest
     */
    function principalBalanceOf(address _account) external view returns (uint256);
    
    /*//////////////////////////////////////////////////////////////
                        ROLE MANAGEMENT
    //////////////////////////////////////////////////////////////*/
    
    /**
     * @notice Grant mint and burn role to address
     * @dev Used by deployment scripts to authorize Vault and Pool
     */
    function grantMintAndBurnRole(address _account) external;
    
    /*//////////////////////////////////////////////////////////////
                        ERC20 FUNCTIONS (Minimal)
    //////////////////////////////////////////////////////////////*/
    
    /**
     * @notice Transfer tokens
     * @dev Standard ERC20 transfer
     */
    function transfer(address _to, uint256 _amount) external returns (bool);
    
    /**
     * @notice Approve spender
     * @dev Standard ERC20 approve
     */
    function approve(address _spender, uint256 _amount) external returns (bool);
    
    /**
     * @notice Transfer from
     * @dev Standard ERC20 transferFrom
     */
    function transferFrom(address _from, address _to, uint256 _amount) external returns (bool);
    
    /**
     * @notice Get token name
     */
    function name() external view returns (string memory);
    
    /**
     * @notice Get token symbol
     */
    function symbol() external view returns (string memory);
    
    /**
     * @notice Get token decimals
     */
    function decimals() external view returns (uint8);
    
    /**
     * @notice Get total supply
     */
    function totalSupply() external view returns (uint256);
    
    /**
     * @notice Get allowance
     */
    function allowance(address _owner, address _spender) external view returns (uint256);
    
    /*//////////////////////////////////////////////////////////////
                        V2+ OPTIONAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    
    /**
     * @notice Get transfer fee rate (V2+)
     * @dev Returns 0 if not implemented (V1)
     */
    function getTransferFeeRate() external view returns (uint256);
    
    /**
     * @notice Get fee recipient (V2+)
     * @dev Returns zero address if not implemented (V1)
     */
    function getFeeRecipient() external view returns (address);
    
    /**
     * @notice Get maximum supply (V2+)
     * @dev Returns max uint256 if not implemented (V1)
     */
    function getMaxSupply() external view returns (uint256);
    
    /**
     * @notice Check if paused (V2+)
     * @dev Returns false if not implemented (V1)
     */
    function paused() external view returns (bool);
      // UUPS upgrade function
    function upgradeToAndCall(address newImplementation, bytes memory data) external payable;
    
    function owner() external view returns (address);
    function version() external view returns (uint256);
}
