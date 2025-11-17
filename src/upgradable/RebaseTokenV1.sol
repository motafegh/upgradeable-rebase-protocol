// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// TODO 1: Import upgradeable versions instead of standard
// HINT: Change from @openzeppelin/contracts/ to @openzeppelin/contracts-upgradeable/
// 
// You need these upgradeable imports:
// - ERC20Upgradeable (replaces ERC20)
// - OwnableUpgradeable (replaces Ownable)  
// - AccessControlUpgradeable (replaces AccessControl)
// - Initializable (NEW - needed for initialize function)
// - UUPSUpgradeable (NEW - upgrade mechanism)
//
// Start here: ↓

import {ERC20Upgradeable} from "@openzeppelin-contracts-upgradeable/contracts/token/ERC20/ERC20Upgradeable.sol";
// TODO: Add remaining 4 imports
import {OwnableUpgradeable} from "@openzeppelin-contracts-upgradeable/contracts/access/OwnableUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin-contracts-upgradeable/contracts/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";


/**
 * @title RebaseTokenV1
 * @author Ali (motafegh)
 * @notice Upgradeable version of RebaseToken using UUPS pattern
 * 
 * ARCHITECTURE DECISION: Why UUPS over Transparent Proxy?
 * 
 * UUPS (Universal Upgradeable Proxy Standard):
 * ✅ Gas efficient: ~800 gas cheaper per call (no admin checks in proxy)
 * ✅ Simpler proxy: Easier to audit (~50 LOC vs ~200 LOC)
 * ✅ Upgrade logic in implementation: Better encapsulation
 * ❌ Risk: If _authorizeUpgrade breaks, contract is bricked
 * 
 * Transparent Proxy:
 * ✅ Safer: Admin cannot brick upgrade mechanism
 * ✅ Clear separation: Admin vs user calls
 * ❌ More expensive: Extra checks on every call
 * ❌ More complex: Harder to reason about
 * 
 * CHOICE: UUPS for this project because:
 * 1. High-frequency token (gas matters)
 * 2. We'll have comprehensive tests (mitigates brick risk)
 * 3. Demonstrates understanding of both patterns
 * 
 * KEY DIFFERENCES FROM IMMUTABLE VERSION:
 * - No constructor logic (uses initialize() instead)
 * - Must inherit from Initializable + UUPSUpgradeable
 * - Storage layout MUST be preserved in all future versions
 * - Can be upgraded by owner via upgradeToAndCall()
 */
contract RebaseTokenV1 is 
    Initializable,           // Prevents double-initialization
    ERC20Upgradeable,        // Upgradeable ERC20 base
    OwnableUpgradeable,      // Upgradeable ownership
    AccessControlUpgradeable,// Upgradeable roles
    UUPSUpgradeable          // UUPS upgrade mechanism
{
    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error RebaseToken__InterestRateCanOnlyDecrease(uint256 currentRate, uint256 proposedRate);

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/
    
    // CRITICAL: Storage Layout Documentation
    // 
    // Slots 0-50:   ERC20Upgradeable (inherited)
    // Slots 51-100: OwnableUpgradeable (inherited)
    // Slots 101-150: AccessControlUpgradeable (inherited)
    // Slots 151-200: UUPSUpgradeable (inherited)
    // Slots 201+:   OUR custom storage (below)
    //
    // RULE: These MUST stay in EXACT same order in ALL future versions
    // - Never reorder
    // - Never delete  
    // - Never change types
    // - Only APPEND new variables in V2, V3, etc.

    uint256 internal constant PRECISION_FACTOR = 1e18;
    bytes32 internal constant MINT_AND_BURN_ROLE = keccak256("MINT_AND_BURN_ROLE");

    // TODO 2: Copy these state variables from your RebaseToken.sol
    // HINT: They should be IDENTICAL to the immutable version
    // 
    // You need:
    // - s_userInterestRate (mapping)
    // - s_userLastUpdatedTimestamp (mapping)
    // - s_interestRate (uint256)
    //
    // Copy them here: ↓
    mapping(address => uint256) internal s_userInterestRate;
    mapping(address => uint256) internal s_userLastUpdatedTimestamp;
    uint256 internal s_interestRate = 5e10;


    // TODO 3: Add storage gap for future versions
    // 
    // WHAT: Array of empty slots reserved for V2, V3, etc.
    // WHY: Without this, adding variables in V2 could corrupt V1 data
    // HOW MANY: 50 slots is standard (can adjust based on needs)
    //
    // Format: uint256[X] private __gap;
    // where X = number of slots to reserve
    //
    // Add it here: ↓
    uint256[50] private __gap;


    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    // TODO 4: Copy events from RebaseToken.sol
    // HINT: Events don't affect storage, so these stay the same
    event InterestRateSet(uint256 newInterestRate);
    event InterestMinted(address indexed user, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @custom:oz-upgrades-unsafe-allow constructor
     * @notice Constructor is empty and locks implementation
     * 
     * CRITICAL SECURITY PATTERN:
     * 
     * Q: Why do we need a constructor if we use initialize()?
     * A: To prevent anyone from initializing the IMPLEMENTATION contract
     * 
     * Q: What happens if we don't lock the implementation?
     * A: Attacker could call initialize() on implementation, become owner,
     *    and potentially selfdestruct it (bricking all proxies!)
     * 
     * Q: How does _disableInitializers() work?
     * A: Sets an internal flag that prevents initialize() from ever running
     *    on THIS contract (the implementation). Proxies are unaffected.
     * 
     * The @custom:oz-upgrades-unsafe-allow comment tells OpenZeppelin's
     * upgrade validator that we intentionally have a constructor.
     */
    
    // TODO 5: Implement constructor
    // HINT: Just call _disableInitializers() - nothing else!
    //
    constructor() {
        _disableInitializers();
    }


    /*//////////////////////////////////////////////////////////////
                              INITIALIZER
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Initialize the token (replaces constructor)
     * @dev Called ONCE per proxy via the Initializable modifier
     * 
     * EXECUTION FLOW:
     * 
     * 1. Deploy Implementation:
     *    new RebaseTokenV1() ← constructor runs, locks itself
     * 
     * 2. Deploy Proxy:
     *    new ERC1967Proxy(implementation, initData)
     *    └─ Proxy delegatecalls initialize() on implementation
     *       └─ Code runs from implementation
     *       └─ Storage writes go to PROXY
     *       └─ msg.sender = proxy deployer
     * 
     * 3. Result:
     *    - Implementation: Locked, cannot be initialized
     *    - Proxy: Initialized, owner = deployer
     * 
     * STORAGE CONTEXT:
     * When proxy delegatecalls initialize():
     * - All state variables live in PROXY storage
     * - s_interestRate = 5e10 writes to PROXY slot 203
     * - owner = msg.sender writes to PROXY slot (OwnableUpgradeable)
     * 
     * TODO 6: Implement initialize function
     * HINTS:
     * - Needs `initializer` modifier (from Initializable)
     * - Must initialize ALL parent contracts:
     *   • __ERC20_init(name, symbol)
     *   • __Ownable_init(initialOwner)
     *   • __AccessControl_init()
     *   • __UUPSUpgradeable_init()
     * - Then set our custom state (s_interestRate)
     */
    
    function initialize(address initialOwner) public initializer {
        // TODO: Initialize parents
        __ERC20_init("RebaseToken", "RBT");
        __Ownable_init(initialOwner);
        __AccessControl_init();

        // TODO: Set initial state
        s_interestRate = 5e10;
    }


    /*//////////////////////////////////////////////////////////////
                          EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * TODO 7: Copy ALL functions from your RebaseToken.sol
     * 
     * IMPORTANT: Function logic stays IDENTICAL
     * - grantMintAndBurnRole()
     * - setInterestRate()
     * - mint()
     * - burn()
     * - balanceOf() override
     * - transfer() override
     * - transferFrom() override
     * 
     * NO CHANGES needed except:
     * - They're now calling upgradeable parent functions
     * - Storage variables are same slots (just in proxy now)
     * 
     * Copy them here: ↓
     */
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
    function mint(address _to, uint256 _value, uint256 _userInterestRate) public virtual onlyRole(MINT_AND_BURN_ROLE) {
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
    function burn(address _from, uint256 _value) public virtual onlyRole(MINT_AND_BURN_ROLE) {
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
    function transfer(address _recipient, uint256 _amount) public override virtual returns (bool) {
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
    function transferFrom(address _sender, address _recipient, uint256 _amount) public override virtual returns (bool) {
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
    function _mintAccruedInterest(address _user) internal virtual {
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
                          UPGRADE AUTHORIZATION
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Authorize upgrade to new implementation
     * @dev This is the UUPS upgrade mechanism - CRITICAL function!
     * 
     * SECURITY MODEL:
     * - Only owner can authorize upgrades (centralized but clear)
     * - Future: Could change to multisig or DAO governance
     * - This function MUST exist in ALL versions or contract is bricked
     * 
     * WHY EMPTY BODY?
     * - We just need the onlyOwner check
     * - Actual upgrade logic is in UUPSUpgradeable parent
     * - upgradeToAndCall() in parent calls this for authorization
     * 
     * TODO 9: Implement upgrade authorization
     * HINT: Function needs:
     * - `internal` visibility
     * - `override` keyword (overriding UUPSUpgradeable)
     * - `onlyOwner` modifier
     * - Empty body (or validation logic)
     * - Parameter: address newImplementation
     */
    
    function _authorizeUpgrade(address newImplementation) 
        internal 
        override 
        onlyOwner 
    {}


    /*//////////////////////////////////////////////////////////////
                              VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Get contract version
     * @dev Useful for verifying upgrades succeeded
     * 
     * TODO 10: Implement version function
     * HINT: Returns 1 for V1, 2 for V2, etc.
     */
    
    function version() external pure virtual returns (uint256) {
        return 1;
    }

    /**
     * TODO 11: Copy view functions from RebaseToken.sol
     * 
     * - getInterestRate()
     * - getUserInterestRate()
     * - principalBalanceOf()
     */
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


    function getAccruedInterest(address _account) public view returns (uint256) {
        uint256 currentPrincipalBalance = super.balanceOf(_account);
        if (currentPrincipalBalance == 0) {
            return 0;
        }
        uint256 currentBalance = balanceOf(_account);
        uint256 balanceIncrease = currentBalance - currentPrincipalBalance;
        return balanceIncrease;
    }

    /**
    * @notice Get the keccak256 hash of the MINT_AND_BURN_ROLE.
    * @return The bytes32 role identifier.
    */
    function show_MINT_AND_BURN_ROLE() external pure returns (bytes32) {
        return MINT_AND_BURN_ROLE;
    }
}