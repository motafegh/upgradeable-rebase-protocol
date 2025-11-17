// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {RebaseTokenV1} from "./RebaseTokenV1.sol";
import {PausableUpgradeable} from "@openzeppelin-contracts-upgradeable/contracts/utils/PausableUpgradeable.sol";

/**
 * @title RebaseTokenV2
 * @author Ali (motafegh)
 * @notice Version 2 of the upgradeable rebase token with enhanced features
 * @dev Adds transfer fees, pause mechanism, and supply cap to V1
 *
 * ═══════════════════════════════════════════════════════════════════════════════
 * UPGRADE STRATEGY & NEW FEATURES:
 * ═══════════════════════════════════════════════════════════════════════════════
 *
 * V2 adds THREE major features while preserving ALL V1 state:
 *
 * 1. TRANSFER FEE SYSTEM:
 *    - Protocol takes a percentage fee on transfers (e.g., 0.1%)
 *    - Fee goes to treasury (owner can set address)
 *    - Can be set to 0 (disabled by default)
 *    - Real-world use: Protocol revenue, similar to Uniswap V2 0.3% fee
 *
 * 2. PAUSE MECHANISM:
 *    - Emergency stop functionality (circuit breaker)
 *    - When paused: No transfers, mints, or burns allowed
 *    - Only owner can pause/unpause
 *    - Real-world use: Response to discovered vulnerabilities
 *
 * 3. MAXIMUM SUPPLY CAP:
 *    - Hard limit on total token supply
 *    - Prevents runaway inflation from interest accrual
 *    - Can be set by owner (but not decreased below current supply)
 *    - Real-world use: Economic policy, like Bitcoin's 21M cap
 *
 * ═══════════════════════════════════════════════════════════════════════════════
 * STORAGE LAYOUT MANAGEMENT:
 * ═══════════════════════════════════════════════════════════════════════════════
 *
 * V1 Storage (from RebaseTokenV1.sol):
 * - Slot 0-50: ERC20Upgradeable (name, symbol, balances, allowances)
 * - Slot 51-100: OwnableUpgradeable (owner)
 * - Slot 101-150: AccessControlUpgradeable (roles)
 * - Slot 151-200: UUPSUpgradeable (implementation slot via ERC1967)
 * - Slot 201: s_interestRate (uint256)
 * - Slot 202: s_userInterestRate (mapping)
 * - Slot 203: s_lastUpdateTime (mapping)
 * - Slots 204-253: __gap (50 slots reserved in V1)
 *
 * V2 Storage (what we're adding):
 * - Slot 204: s_transferFeeRate (uint256) ← Uses first gap slot
 * - Slot 205: s_feeRecipient (address)    ← Uses second gap slot
 * - Slot 206: s_maxSupply (uint256)        ← Uses third gap slot
 * - Slot 207-256: PausableUpgradeable      ← Inherits new contract (uses more slots)
 * - Slots XXX-253: __gap (47 slots)        ← ADJUSTED: 50 - 3 = 47
 *
 * CRITICAL RULE:
 * We CANNOT reorder or change V1 variables!
 * We can ONLY add new variables AFTER V1's storage.
 * Storage gaps allow us to add variables without shifting V1's layout.
 *
 * ═══════════════════════════════════════════════════════════════════════════════
 * INHERITANCE CHANGE:
 * ═══════════════════════════════════════════════════════════════════════════════
 *
 * V1: RebaseTokenV1 is ERC20Upgradeable, OwnableUpgradeable, AccessControlUpgradeable, UUPSUpgradeable
 * V2: RebaseTokenV2 is RebaseTokenV1, PausableUpgradeable
 *
 * WHY ADD PausableUpgradeable?
 * - Adds pause/unpause functionality
 * - Provides whenNotPaused modifier
 * - Handles paused state in separate storage
 * - Standard OpenZeppelin pattern for circuit breakers
 * ═══════════════════════════════════════════════════════════════════════════════
 */
contract RebaseTokenV2 is RebaseTokenV1, PausableUpgradeable {
    /*//////////////////////////////////////////////////////////////
                            TYPE DECLARATIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Fee precision constant for transfer fee calculations
     * We use basis points (10000 = 100%)
     * Example: 50 = 0.5%, 100 = 1%, 1000 = 10%
     */
    uint256 private constant FEE_PRECISION = 10000;

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES (NEW IN V2)
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Transfer fee rate in basis points (e.g., 50 = 0.5%)
     * @dev Stored in first available gap slot from V1
     *
     * We use basis points:
     * Allows precise percentages without decimals:
     * - 1 = 0.01% (1/10000)
     * - 50 = 0.5% (typical DeFi fee)
     * - 100 = 1%
     * - 10000 = 100% (maximum, would take everything!)
     */
    uint256 private s_transferFeeRate;

    /**
     * @notice Address that receives transfer fees
     * @dev Stored in second available gap slot from V1
     *
     * FEE RECIPIENT PATTERNS:
     * Common patterns in production:
     * - Treasury multi-sig (governance controlled)
     * - Staking contract (fees distributed to stakers)
     * - Burn address (deflationary tokenomics)
     * - Split between multiple addresses
     *
     * DEFAULT: Set to owner address in initialize
     */
    address private s_feeRecipient;

    /**
     * @notice Maximum total supply cap (0 = no cap)
     * @dev Stored in third available gap slot from V1
     *
     * IMPLEMENTATION:
     * - 0 means no cap (unlimited supply)
     * - Non-zero enforces maximum total supply
     * - Checked in mint() and _mintAccruedInterest()
     *
     * EXAMPLE:
     * If maxSupply = 1,000,000 tokens:
     * - Current supply: 950,000
     * - User tries to mint 100,000 → REVERT (would exceed cap)
     * - User can only mint up to 50,000
     */
    uint256 private s_maxSupply;

    /**
     * @dev Storage gap for future upgrades
     *
     * CRITICAL CALCULATION:
     * V1 had: 50 slots reserved
     * V2 uses: 3 slots (s_transferFeeRate, s_feeRecipient, s_maxSupply)
     * V2 has: 50 - 3 = 47 slots remaining
     *
     * FUTURE UPGRADES (V3):
     * If V3 adds 2 variables, this becomes uint256[45] private __gap;
     */
    uint256[47] private __gap;

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @dev Thrown when transfer fee exceeds maximum allowed (100%)
    error RebaseTokenV2__InvalidFeeRate();

    /// @dev Thrown when minting would exceed maximum supply cap
    error RebaseTokenV2__MaxSupplyExceeded();

    /// @dev Thrown when trying to set max supply below current supply
    error RebaseTokenV2__MaxSupplyBelowCurrent();

    /// @dev Thrown when fee recipient is zero address
    error RebaseTokenV2__InvalidFeeRecipient();

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when transfer fee rate is updated
    event TransferFeeRateUpdated(uint256 oldRate, uint256 newRate);

    /// @notice Emitted when fee recipient address is updated
    event FeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);

    /// @notice Emitted when maximum supply cap is updated
    event MaxSupplyUpdated(uint256 oldMaxSupply, uint256 newMaxSupply);

    /// @notice Emitted when transfer fees are collected
    event FeeCollected(address indexed from, address indexed to, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                              INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Initialize V2 features (called during upgrade)
     * @dev This is called ONCE when upgrading from V1 to V2
     *
     * REINITIALIZER PATTERN:
     * - V1 used reinitializer(1)
     * - V2 uses reinitializer(2)
     * - Each version increments the number
     * - Prevents re-initialization attacks
     *
     * WHY NEEDED:
     * When proxy upgrades to V2, it needs to initialize V2's new state!
     * - Set default fee rate (0 = disabled)
     * - Set fee recipient (owner)
     * - Set max supply (0 = unlimited)
     * - Initialize PausableUpgradeable
     *
     * CALL SEQUENCE DURING UPGRADE:
     * 1. Deploy V2 implementation
     * 2. Call upgradeToAndCall(v2Address, initializeV2())
     * 3. Proxy upgrades implementation pointer
     * 4. Proxy delegatecalls initializeV2()
     * 5. V2 state initialized in proxy's storage
     */
    function initializeV2() external reinitializer(2) {
        // Initialize PausableUpgradeable (sets paused = false)
        __Pausable_init();

        // Set default values for V2 features
        s_transferFeeRate = 0; // No fees by default (can be enabled later)
        s_feeRecipient = owner(); // Owner receives fees initially
        s_maxSupply = 0; // No supply cap by default (unlimited)

    }

    /*//////////////////////////////////////////////////////////////
                          FEE MANAGEMENT (NEW IN V2)
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Set the transfer fee rate
     * @param _feeRate Fee rate in basis points (max 10000 = 100%)
     * @dev Only owner can set fees
     *
     * EDUCATIONAL - FEE RATE VALIDATION:
     * We check feeRate <= 10000 to prevent fees > 100%
     * Otherwise, transfers would fail due to underflow!
     *
     * Example: If fee = 15000 (150%):
     * Transfer 1000 tokens → fee = 1000 * 15000 / 10000 = 1500 tokens
     * But alice only has 1000 tokens → UNDERFLOW → REVERT
     */
    function setTransferFeeRate(uint256 _feeRate) external onlyOwner {
        if (_feeRate > FEE_PRECISION) {
            revert RebaseTokenV2__InvalidFeeRate();
        }

        uint256 oldRate = s_transferFeeRate;
        s_transferFeeRate = _feeRate;

        emit TransferFeeRateUpdated(oldRate, _feeRate);
    }

    /**
     * @notice Set the address that receives transfer fees
     * @param _recipient Address to receive fees
     * @dev Only owner can set recipient, cannot be zero address
     */
    function setFeeRecipient(address _recipient) external onlyOwner {
        if (_recipient == address(0)) {
            revert RebaseTokenV2__InvalidFeeRecipient();
        }

        address oldRecipient = s_feeRecipient;
        s_feeRecipient = _recipient;

        emit FeeRecipientUpdated(oldRecipient, _recipient);
    }

    /**
     * @notice Get current transfer fee rate
     * @return Current fee rate in basis points
     */
    function getTransferFeeRate() external view returns (uint256) {
        return s_transferFeeRate;
    }

    /**
     * @notice Get current fee recipient address
     * @return Address that receives transfer fees
     */
    function getFeeRecipient() external view returns (address) {
        return s_feeRecipient;
    }

    /*//////////////////////////////////////////////////////////////
                        SUPPLY CAP MANAGEMENT (NEW IN V2)
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Set maximum total supply cap
     * @param _maxSupply Maximum supply (0 = unlimited)
     * @dev Only owner can set, cannot set below current supply
     *
     *  - SUPPLY CAP ECONOMICS:
     * Setting a supply cap is an economic policy decision:
     *
     * WITHOUT CAP:
     * - Interest accrues forever
     * - Supply grows infinitely
     * - Potential hyperinflation
     *
     * WITH CAP:
     * - Hard limit on supply
     * - Sustainable tokenomics
     * - Predictable inflation
     *
     * SAFETY CHECK:
     * We prevent setting cap BELOW current supply because:
     * - Would brick the contract (no more mints possible)
     * - Could trap users (can't mint accrued interest)
     * - Economic chaos (unexpected supply freeze)

     */
    function setMaxSupply(uint256 _maxSupply) external onlyOwner {
        // If setting a non-zero cap, ensure it's above current supply
        if (_maxSupply != 0 && _maxSupply < totalSupply()) {
            revert RebaseTokenV2__MaxSupplyBelowCurrent();
        }

        uint256 oldMaxSupply = s_maxSupply;
        s_maxSupply = _maxSupply;

        emit MaxSupplyUpdated(oldMaxSupply, _maxSupply);
    }

    /**
     * @notice Get maximum supply cap
     * @return Maximum supply (0 = unlimited)
     */
    function getMaxSupply() external view returns (uint256) {
        return s_maxSupply;
    }

    /**
     * @notice Check if a mint would exceed max supply
     * @param _amount Amount to potentially mint
     * @return bool True if mint would exceed cap
     */
    function wouldExceedMaxSupply(uint256 _amount) public view returns (bool) {
        // No cap = never exceeds
        if (s_maxSupply == 0) return false;

        // Check if current + new would exceed cap
        return totalSupply() + _amount > s_maxSupply;
    }

    /*//////////////////////////////////////////////////////////////
                        PAUSE MECHANISM (NEW IN V2)
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Pause all token operations
     * @dev Only owner can pause
     *
     * PAUSE USE CASES:
     * When to pause:
     * - Security vulnerability discovered
     * - Oracle price manipulation detected
     * - Bridge exploit in progress
     * - Emergency governance decision
     *
     * What gets paused:
     * - Transfers (including transferFrom)
     * - Mints (all new token creation)
     * - Burns (all token destruction)
     *
     * What DOESN'T pause:
     * - View functions (balanceOf, etc.)
     * - Owner functions (pause/unpause, setFees)
     * - Interest accrual (time keeps ticking)
     
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpause token operations
     * @dev Only owner can unpause
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    /*//////////////////////////////////////////////////////////////
                    OVERRIDDEN FUNCTIONS (MODIFIED IN V2)
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Transfer tokens with fee
     * @dev Overrides V1 transfer to add fee mechanism and pause check
     *
     * THE FLOW:
     * 1. User calls transfer(recipient, 1000)
     * 2. Check if paused (revert if true)
     * 3. Calculate fee: 1000 * feeRate / 10000
     * 4. Transfer to recipient: 1000 - fee
     * 5. Transfer fee to feeRecipient
     * 6. Both transfers trigger interest minting (V1 behavior preserved)
     *
     * BACKWARD COMPATIBILITY:
     * If feeRate = 0, this behaves exactly like V1 (no fee)!
     * This means V1 users experience no breaking changes.
     */
    function transfer(
        address _to,
        uint256 _amount
    ) public virtual override whenNotPaused returns (bool) {
        // If no fee, use V1 logic directly
        if (s_transferFeeRate == 0) {
            return super.transfer(_to, _amount);
        }

        // Calculate fee
        uint256 fee = (_amount * s_transferFeeRate) / FEE_PRECISION;
        uint256 amountAfterFee = _amount - fee;

        // Transfer amount minus fee to recipient
        super.transfer(_to, amountAfterFee);

        // Transfer fee to fee recipient (if fee > 0)
        if (fee > 0) {
            super.transfer(s_feeRecipient, fee);
            emit FeeCollected(msg.sender, s_feeRecipient, fee);
        }

        return true;
    }

    /**
     * @notice TransferFrom with fee
     * @dev Overrides V1 transferFrom to add fee mechanism and pause check
     *
     * EXAMPLE:
     * Alice approves bob: 1000 tokens
     * Fee rate: 1% (100 basis points)
     * Bob calls transferFrom(alice, carol, 1000):
     * - Fee: 10 tokens
     * - Carol gets: 990 tokens
     * - Fee recipient gets: 10 tokens
     * - Alice's balance decreases: 1000 tokens
     * - Bob's allowance decreases: 1000 tokens
     */
    function transferFrom(
        address _from,
        address _to,
        uint256 _amount
    ) public virtual override whenNotPaused returns (bool) {
        // If no fee, use V1 logic directly
        if (s_transferFeeRate == 0) {
            return super.transferFrom(_from, _to, _amount);
        }

        // Calculate fee
        uint256 fee = (_amount * s_transferFeeRate) / FEE_PRECISION;
        uint256 amountAfterFee = _amount - fee;

        // Transfer amount minus fee to recipient
        super.transferFrom(_from, _to, amountAfterFee);

        // Transfer fee to fee recipient (if fee > 0)
        if (fee > 0) {
            // Note: This uses the same allowance
            super.transferFrom(_from, s_feeRecipient, fee);
            emit FeeCollected(_from, s_feeRecipient, fee);
        }

        return true;
    }

    /**
     * @notice Mint tokens with supply cap check
     * @dev Overrides V1 mint to add supply cap enforcement and pause check
     *
     * EDUCATIONAL - SUPPLY CAP ENFORCEMENT:
     * Before minting, we check: currentSupply + amount <= maxSupply
     * If it would exceed, we REVERT the entire transaction.
     *
     * WHY REVERT (not mint partial)?
     * - Clearer error handling
     * - User knows exactly what happened
     * - Prevents unexpected partial mints
     *
     * ALTERNATIVE DESIGNS:
     * Some protocols mint up to cap, ignore excess
     * We chose revert for safety and clarity
     */
    function mint(
        address _to,
        uint256 _amount,
        uint256 _userInterestRate
    ) public virtual override whenNotPaused onlyRole(MINT_AND_BURN_ROLE) {
        // Check supply cap
        if (wouldExceedMaxSupply(_amount)) {
            revert RebaseTokenV2__MaxSupplyExceeded();
        }

        // Call V1 mint logic
        super.mint(_to, _amount, _userInterestRate);
    }

    /**
     * @notice Burn tokens with pause check
     * @dev Overrides V1 burn to add pause check
     */
    function burn(
        address _from,
        uint256 _amount
    ) public virtual override whenNotPaused onlyRole(MINT_AND_BURN_ROLE) {
        super.burn(_from, _amount);
    }

    /**
     * @notice Override _mintAccruedInterest to check supply cap
     * @dev CRITICAL: Interest minting must also respect supply cap!
     *
     * WHY THIS IS NECESSARY:
     * Without this check, interest could push supply over the cap!
     *
     * SCENARIO:
     * - Max supply: 1,000,000
     * - Current supply: 999,000
     * - User has 10,000 tokens with 10% APY for 1 year
     * - Interest accrued: 1,000 tokens
     * - Transfer triggers interest minting
     * - Without check: Supply becomes 1,000,000 (at cap) ✓
     * - With more interest: Would exceed cap → need to handle!
     *
     * OUR STRATEGY:
     * Mint up to cap, ignore excess interest
     * Alternative: Revert entire transaction (more restrictive)
     */
    function _mintAccruedInterest(address _account) internal virtual override {
        uint256 interest = getAccruedInterest(_account);
        if (interest == 0) return;

        // Check if minting interest would exceed cap
        if (s_maxSupply != 0) {
            uint256 currentSupply = totalSupply();
            uint256 availableSpace = s_maxSupply > currentSupply ? s_maxSupply - currentSupply : 0;

            // If no space, don't mint any interest
            if (availableSpace == 0) return;

            // If interest exceeds available space, mint only available space
            if (interest > availableSpace) {
                interest = availableSpace;
            }
        }

        // Mint the interest (capped amount)
        _mint(_account, interest);
        s_userLastUpdatedTimestamp[_account] = block.timestamp;

        emit InterestMinted(_account, interest);
    }

    /*//////////////////////////////////////////////////////////////
                            VERSION TRACKING
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Returns the version of this contract
     * @dev Overrides V1's version() function
     * @return Version number (2)
     *
     *  - VERSION TRACKING:
     * Each upgrade increments the version number.
     * This helps:
     * - Debugging (which version is deployed?)
     * - Frontend integration (handle V1 vs V2 differently)
     * - Monitoring (track upgrade adoption)
     *
     * IMPLEMENTATION:
     * - V1 returns 1
     * - V2 returns 2
     * - V3 would return 3, etc
     */
    function version() external pure virtual override returns (uint256) {
        return 2;
    }
}

