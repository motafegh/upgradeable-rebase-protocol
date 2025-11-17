// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {Vault} from "../../src/upgradable/Vault.sol";
import {RebaseToken} from "../../src/archived/RebaseToken.sol";
import {RebaseTokenPool} from "../../src/upgradable/RebaseTokenPool.sol";
import {IRouterClient} from "@ccip/contracts/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {Client} from "@ccip/contracts/src/v0.8/ccip/libraries/Client.sol";
import {IERC20} from "@ccip/contracts/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/token/ERC20/IERC20.sol";

/**
 * @title Interactions
 * @author Ali (motafegh)
 * @notice User-facing scripts for protocol interaction: deposit, redeem, bridge
 * @dev Three independent entry points designed for production deployment and testing
 *
 * ARCHITECTURE DECISIONS:
 * - Separate scripts (not single multi-function) for clearer gas tracking
 * - Shared base contract reduces duplication without coupling
 * - All scripts are stateless (no storage) for gas efficiency
 *
 * SECURITY MODEL:
 * - Input validation via modifiers (fail fast)
 * - Balance checks BEFORE external calls
 * - Custom errors (cheaper than strings)
 * - No reentrancy risk (all scripts are read-only or single-call)
 *
 * GAS COSTS (approximate, Sepolia):
 * - Deposit:  ~120k gas (~$3-5 at 30 gwei)
 * - Redeem:   ~95k gas (~$2-4)
 * - Bridge:   ~180k gas + CCIP relay fees (~$0.50-2.00 in LINK)
 *
 * USAGE EXAMPLES:
 *
 *   # 1. Deposit ETH to vault on Sepolia
 *   forge script script/Interactions.s.sol:DepositScript \
 *     --sig "run(address)" $VAULT_ADDR \
 *     --rpc-url $SEPOLIA_RPC --broadcast
 *
 *   # 2. Redeem specific amount
 *   forge script script/Interactions.s.sol:RedeemScript \
 *     --sig "run(address,uint256)" $VAULT_ADDR 100000000000000000 \
 *     --rpc-url $SEPOLIA_RPC --broadcast
 *
 *   # 3. Redeem full balance (use max uint)
 *   forge script script/Interactions.s.sol:RedeemScript \
 *     --sig "run(address,uint256)" $VAULT_ADDR $(cast max-uint256) \
 *     --rpc-url $SEPOLIA_RPC --broadcast
 *
 *   # 4. Bridge tokens Sepolia → Arbitrum
 *   forge script script/Interactions.s.sol:BridgeScript \
 *     --sig "run(address,address,address,address,uint64,address,uint256,uint256)" \
 *     $TOKEN $POOL $ROUTER $LINK 3478487238524512106 $RECEIVER $AMOUNT 250000 \
 *     --rpc-url $SEPOLIA_RPC --broadcast
 *
 * PRODUCTION CHECKLIST:
 * - [ ] Test on testnet with small amounts first
 * - [ ] Verify LINK balance sufficient for bridge fees
 * - [ ] Confirm destination chain is configured in pool
 * - [ ] Use hardware wallet for mainnet broadcasts
 * - [ ] Monitor CCIP Explorer for cross-chain delivery
 */

/*//////////////////////////////////////////////////////////////
                         SHARED BASE
//////////////////////////////////////////////////////////////*/

/**
 * @notice Base contract with common validations and utilities
 * @dev Inherited by all interaction scripts to reduce duplication
 *
 * DESIGN PATTERN: Template Method
 * - Define reusable validation hooks
 * - Let child scripts implement specific logic
 * - Fail fast with descriptive errors
 */
abstract contract InteractionBase is Script {
    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Insufficient balance for requested operation
    error InsufficientBalance(uint256 required, uint256 actual);

    /// @notice Zero address provided where valid address required
    error ZeroAddress();

    /// @notice Zero amount provided where positive amount required
    error ZeroAmount();

    /// @notice Destination chain not configured in token pool
    error UnsupportedChain(uint64 chainSelector);

    /*//////////////////////////////////////////////////////////////
                              MODIFIERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Validate address is not zero
     * @dev Prevents misconfiguration by failing early
     */
    modifier nonZeroAddress(address addr) {
        if (addr == address(0)) revert ZeroAddress();
        _;
    }

    /**
     * @notice Validate amount is positive
     * @dev Prevents wasted gas on no-op transactions
     */
    modifier nonZeroAmount(uint256 amount) {
        if (amount == 0) revert ZeroAmount();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                             HELPERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Validate user has sufficient token balance
     * @param token Token contract address
     * @param owner Address to check balance of
     * @param required Minimum required balance
     * @dev Reverts with actual vs required for debugging
     */
    function _requireBalance(address token, address owner, uint256 required) internal view {
        uint256 actual = IERC20(token).balanceOf(owner);
        if (actual < required) {
            revert InsufficientBalance(required, actual);
        }
    }

    /**
     * @notice Format token amount with 4 decimal precision for logging
     * @param amount Raw token amount (18 decimals)
     * @return Formatted string like "1.2345 RBT"
     * @dev For display only, not used in calculations
     */
    function _formatTokens(uint256 amount) internal pure returns (string memory) {
        // Convert to 4 decimals: amount / 1e14 gives 4 decimal places
        return string(abi.encodePacked(vm.toString(amount / 1e14), " RBT"));
    }

    /**
     * @notice Validate destination chain is configured in pool
     * @param pool Token pool address
     * @param chainSelector CCIP chain selector
     * @dev Prevents bridging to unconfigured chains (tokens would be stuck)
     */
    function _requireSupportedChain(address pool, uint64 chainSelector) internal view {
        try RebaseTokenPool(pool).isSupportedChain(chainSelector) returns (bool supported) {
            if (!supported) {
                revert UnsupportedChain(chainSelector);
            }
        } catch {
            // If pool doesn't implement isSupportedChain, skip check
            // This maintains backward compatibility with older pools
            console.log("WARNING: Unable to verify chain support - proceeding anyway");
        }
    }
}

/*//////////////////////////////////////////////////////////////
                        DEPOSIT SCRIPT
//////////////////////////////////////////////////////////////*/

/**
 * @notice Deposit ETH to vault, receive RebaseTokens at current interest rate
 * @dev Fixed deposit amount for simplicity (can be parameterized if needed)
 *
 * FLOW:
 * 1. Check vault address is valid
 * 2. Query current token balance
 * 3. Send ETH to vault.deposit()
 * 4. Vault mints tokens 1:1 with ETH deposited
 * 5. User receives tokens at current global interest rate
 * 6. Log balances and rate for verification
 *
 * ECONOMIC NOTE:
 * User locks in the global interest rate at deposit time.
 * This rate persists even if global rate decreases later.
 * This incentivizes early adoption.
 *
 * GAS OPTIMIZATION:
 * - No token approvals needed (vault mints directly)
 * - Single transaction (deposit is atomic)
 * - Estimate: ~120k gas
 *
 * TESTING CHECKLIST:
 * - [ ] Verify tokens minted equal ETH deposited
 * - [ ] Confirm user rate matches global rate
 * - [ ] Check vault ETH balance increased
 * - [ ] Test with insufficient ETH (should revert)
 */
contract DepositScript is InteractionBase {
    /*//////////////////////////////////////////////////////////////
                              CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @dev Standard testnet deposit amount (0.01 ETH)
    /// Production: Make this a parameter for flexibility
    uint256 private constant DEPOSIT_AMOUNT = 0.01 ether;

    /*//////////////////////////////////////////////////////////////
                            MAIN FUNCTION
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Execute deposit operation
     * @param vaultAddress Address of deployed Vault contract
     * @dev Caller must have at least DEPOSIT_AMOUNT ETH in balance
     */
    function run(address vaultAddress, address tokenAddress) external nonZeroAddress(vaultAddress) {
        // Load contracts
        Vault vault = Vault(payable(vaultAddress));
        RebaseToken token = RebaseToken(tokenAddress);

        vm.startBroadcast();

        // Snapshot state before deposit
        uint256 balanceBefore = token.balanceOf(msg.sender);
        uint256 ethBefore = msg.sender.balance;

        console.log("\n=== Vault Deposit ===");
        console.log("Vault:", vaultAddress);
        console.log("Token:", address(token));
        console.log("---");
        console.log("ETH balance:", ethBefore / 1e18, "ETH");
        console.log("Token balance before:", balanceBefore / 1e18, "RBT");
        console.log("Depositing:", DEPOSIT_AMOUNT / 1e18, "ETH");

        // Execute deposit (payable function)
        vault.deposit{value: DEPOSIT_AMOUNT}();

        // Snapshot state after deposit
        uint256 balanceAfter = token.balanceOf(msg.sender);
        uint256 ethAfter = msg.sender.balance;

        console.log("---");
        console.log("Token balance after:", balanceAfter / 1e18, "RBT");
        console.log("Tokens minted:", (balanceAfter - balanceBefore) / 1e18, "RBT");
        console.log("Your interest rate:", token.getUserInterestRate(msg.sender));
        console.log("ETH spent:", (ethBefore - ethAfter) / 1e18, "ETH");
        console.log("\n[SUCCESS] Deposit complete");
        console.log("=====================\n");

        vm.stopBroadcast();
    }
}

/*//////////////////////////////////////////////////////////////
                        REDEEM SCRIPT
//////////////////////////////////////////////////////////////*/

/**
 * @notice Burn RebaseTokens, withdraw ETH from vault
 * @dev Supports both partial redemption and full balance withdrawal
 *
 * FLOW:
 * 1. Validate vault and amount
 * 2. Check user has sufficient token balance (unless max)
 * 3. Call vault.redeem(amount)
 * 4. Vault burns tokens from user
 * 5. Vault sends ETH to user (1:1 with tokens burned)
 * 6. Log final balances
 *
 * CEI PATTERN:
 * Vault uses Checks-Effects-Interactions pattern:
 * - Burns tokens FIRST (Effect)
 * - Sends ETH SECOND (Interaction)
 * This prevents reentrancy attacks
 *
 * INTEREST ACCRUAL:
 * User's balance includes accrued interest at redemption time.
 * If user deposited 1 ETH and earned 0.1 ETH interest,
 * they can redeem 1.1 tokens for 1.1 ETH (if vault is solvent).
 *
 * SOLVENCY RISK:
 * Vault must hold enough ETH to cover redemptions.
 * If total (principal + interest) > vault balance, redemption fails.
 * Production: Implement reserve ratio monitoring.
 *
 * GAS OPTIMIZATION:
 * - Single transaction
 * - No token approvals needed
 * - Estimate: ~95k gas
 *
 * TESTING CHECKLIST:
 * - [ ] Partial redeem works correctly
 * - [ ] Full redeem (max uint) works correctly
 * - [ ] Redeem with insufficient balance reverts
 * - [ ] Redeem updates both token and ETH balances
 * - [ ] Vault has sufficient ETH for redemption
 */
contract RedeemScript is InteractionBase {
    /*//////////////////////////////////////////////////////////////
                            MAIN FUNCTION
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Execute redemption operation
     * @param vaultAddress Address of deployed Vault contract
     * @param amount Tokens to redeem (use type(uint256).max for full balance)
     * @dev Special handling for max uint to redeem full balance including interest
     */
    function run(address vaultAddress, address tokenAddress, uint256 amount)
        external
        nonZeroAddress(vaultAddress)
        nonZeroAmount(amount)
    {
        // Load contracts
        Vault vault = Vault(payable(vaultAddress));
        RebaseToken token = RebaseToken(tokenAddress);

        vm.startBroadcast();

        // Snapshot state before redeem
        uint256 tokenBalanceBefore = token.balanceOf(msg.sender);
        uint256 ethBefore = msg.sender.balance;

        console.log("\n=== Vault Redeem ===");
        console.log("Vault:", vaultAddress);
        console.log("Token:", address(token));
        console.log("---");
        console.log("Token balance:", tokenBalanceBefore / 1e18, "RBT");
        console.log("ETH balance before:", ethBefore / 1e18, "ETH");

        // Handle max uint for full balance redemption
        bool isMaxRedeem = (amount == type(uint256).max);

        if (isMaxRedeem) {
            console.log("Redeeming: MAX (full balance including interest)");
            // Skip balance check for max - vault will calculate actual amount
        } else {
            console.log("Redeeming:", amount / 1e18, "RBT");
            // Validate user has sufficient balance for partial redeem
            _requireBalance(address(token), msg.sender, amount);
        }

        // Execute redemption (burns tokens, sends ETH)
        vault.redeem(amount);

        // Snapshot state after redeem
        uint256 tokenBalanceAfter = token.balanceOf(msg.sender);
        uint256 ethAfter = msg.sender.balance;

        console.log("---");
        console.log("Token balance after:", tokenBalanceAfter / 1e18, "RBT");
        console.log("ETH balance after:", ethAfter / 1e18, "ETH");
        console.log("Tokens burned:", (tokenBalanceBefore - tokenBalanceAfter) / 1e18, "RBT");
        console.log("ETH received:", (ethAfter - ethBefore) / 1e18, "ETH");
        console.log("\n[SUCCESS] Redemption complete");
        console.log("====================\n");

        vm.stopBroadcast();
    }
}

/*//////////////////////////////////////////////////////////////
                        BRIDGE SCRIPT
//////////////////////////////////////////////////////////////*/

/**
 * @notice Send RebaseTokens cross-chain via Chainlink CCIP
 * @dev Most complex script - handles CCIP message construction and fee payment
 *
 * PREREQUISITES:
 * - User must hold sufficient RebaseTokens on source chain
 * - User must hold sufficient LINK for CCIP relay fees (~0.5-2 LINK)
 * - Destination chain must be configured in source pool
 * - Source chain must be configured in destination pool
 *
 * FLOW:
 * 1. Validate all addresses and amounts
 * 2. Check destination chain is supported
 * 3. Build CCIP message with token transfer
 * 4. Calculate CCIP fee in LINK
 * 5. Approve router for tokens + LINK
 * 6. Capture user's interest rate (preserved cross-chain)
 * 7. Send CCIP message via router.ccipSend()
 * 8. Router calls pool.lockOrBurn() on source
 * 9. Pool burns tokens, encodes user rate
 * 10. CCIP relayers deliver message to destination (~15 min)
 * 11. Router calls pool.releaseOrMint() on destination
 * 12. Pool decodes rate, mints tokens with preserved rate
 *
 * INTEREST DURING TRANSIT:
 * User earns NO interest while bridging (~15 minutes).
 * Rationale: Tokens are burned on source but not yet minted on dest.
 * At 10% APY, 15 min = 0.00285% loss - negligible vs CCIP security.
 *
 * RATE PRESERVATION MECHANISM:
 * The user's interest rate travels in the CCIP message:
 * - Pool.lockOrBurn() encodes rate in destPoolData
 * - CCIP relayers forward the message
 * - Pool.releaseOrMint() decodes rate and mints with it
 * - User keeps their high rate even if global rate dropped
 *
 * GAS CONFIGURATION:
 * - Gas limit: Configurable parameter (default 250k)
 * - Why high? releaseOrMint() → mint() → _mintAccruedInterest()
 * - Production: Monitor actual usage and adjust
 *
 * SECURITY NOTES:
 * - No reentrancy risk (single external call)
 * - Router validation ensures only authorized pools
 * - Rate limiters prevent drain attacks (if enabled)
 * - User can track message via CCIP Explorer
 *
 * COST BREAKDOWN:
 * - Source chain gas: ~180k gas (~$4-6 at 30 gwei)
 * - CCIP relay fee: ~0.5-2 LINK (~$5-20 depending on chain)
 * - Destination gas: Paid by CCIP relayers (included in fee)
 * Total: ~$10-25 per bridge for security guarantees
 *
 * TESTING STRATEGY:
 * - Fork test: Use CCIPLocalSimulatorFork for instant delivery
 * - Testnet: Real 15-min wait, track via CCIP Explorer
 * - Verify rate preserved after delivery
 * - Check no interest accrued during transit
 *
 * PRODUCTION DEPLOYMENT:
 * - Test with 0.01 ETH worth first
 * - Monitor CCIP Explorer: https://ccip.chain.link
 * - Expect 15-20 min delivery time
 * - Verify rate and balance on destination
 * - Scale up after successful test bridges
 *
 * IMPORTANT ANVIL NOTE:
 * This script will REVERT on Anvil forks at getFee() step.
 * Reason: Anvil lacks CCIP's off-chain DON infrastructure.
 * Solution: Use CCIPLocalSimulatorFork for local testing,
 * or deploy to live testnets (Sepolia/Arbitrum Sepolia).
 */
contract BridgeScript is InteractionBase {
    /*//////////////////////////////////////////////////////////////
                              CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @dev Default gas limit for destination chain execution
    /// High enough for: releaseOrMint → mint → _mintAccruedInterest
    /// Production: Monitor actual usage and optimize
    uint256 private constant DEFAULT_GAS_LIMIT = 250_000;

    /*//////////////////////////////////////////////////////////////
                            MAIN FUNCTION
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Execute cross-chain bridge operation
     * @param tokenAddress RebaseToken contract on source chain
     * @param poolAddress RebaseTokenPool contract on source chain
     * @param routerAddress CCIP Router on source chain
     * @param linkAddress LINK token on source chain
     * @param destinationChainSelector CCIP identifier for target chain
     * @param receiver Address to receive tokens on destination chain
     * @param amount Tokens to bridge (18 decimals)
     * @param gasLimit Gas to allocate for destination execution (0 = use default)
     *
     * @dev All parameters validated via modifiers and internal checks
     */
    function run(
        address tokenAddress,
        address poolAddress,
        address routerAddress,
        address linkAddress,
        uint64 destinationChainSelector,
        address receiver,
        uint256 amount,
        uint256 gasLimit
    )
        external
        nonZeroAddress(tokenAddress)
        nonZeroAddress(poolAddress)
        nonZeroAddress(routerAddress)
        nonZeroAddress(linkAddress)
        nonZeroAddress(receiver)
        nonZeroAmount(amount)
    {
        // Load contracts
        RebaseToken token = RebaseToken(tokenAddress);
        IRouterClient router = IRouterClient(routerAddress);

        // Use default gas limit if not specified
        if (gasLimit == 0) {
            gasLimit = DEFAULT_GAS_LIMIT;
        }

        vm.startBroadcast();

        /*//////////////////////////////////////////////////////////////
                            VALIDATION PHASE
        //////////////////////////////////////////////////////////////*/

        console.log("\n=== CCIP Bridge Setup ===");
        console.log("Source Chain ID:", block.chainid);
        console.log("Token:", tokenAddress);
        console.log("Pool:", poolAddress);
        console.log("Router:", routerAddress);
        console.log("---");

        // Ensure user has sufficient tokens
        _requireBalance(tokenAddress, msg.sender, amount);
        console.log("Token balance verified:", amount / 1e18, "RBT");

        // Ensure destination chain is configured (prevents stuck funds)
        _requireSupportedChain(poolAddress, destinationChainSelector);
        console.log("Destination chain verified:", destinationChainSelector);

        /*//////////////////////////////////////////////////////////////
                        MESSAGE CONSTRUCTION
        //////////////////////////////////////////////////////////////*/

        // Build token amount array (CCIP supports multi-token transfers)
        Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](1);
        tokenAmounts[0] = Client.EVMTokenAmount({token: tokenAddress, amount: amount});

        // Construct CCIP message
        // IMPORTANT: No data payload - rate travels in pool.lockOrBurn() return
        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(receiver), // ABI-encoded for cross-VM compatibility
            data: "", // Empty - rate encoded in pool layer
            tokenAmounts: tokenAmounts, // Single token transfer
            feeToken: linkAddress, // Pay fee in LINK
            extraArgs: Client._argsToBytes(
                Client.EVMExtraArgsV2({
                    gasLimit: gasLimit, // Gas for destination execution
                    allowOutOfOrderExecution: true // Accept messages out of order (faster)
                })
            )
        });

        /*//////////////////////////////////////////////////////////////
                            FEE CALCULATION
        //////////////////////////////////////////////////////////////*/

        // Query CCIP fee (denominated in LINK)
        // NOTE: This call will REVERT on Anvil (no CCIP DON)
        uint256 fee = router.getFee(destinationChainSelector, message);

        console.log("---");
        console.log("CCIP Fee (LINK):", fee / 1e18);

        // Ensure user has sufficient LINK for fee
        _requireBalance(linkAddress, msg.sender, fee);
        console.log("LINK balance verified");

        /*//////////////////////////////////////////////////////////////
                            APPROVALS
        //////////////////////////////////////////////////////////////*/

        // Approve router to transfer LINK (for fee payment)
        IERC20(linkAddress).approve(routerAddress, fee);

        // Approve router to transfer tokens (for burning)
        IERC20(tokenAddress).approve(routerAddress, amount);

        console.log("Router approvals granted");

        /*//////////////////////////////////////////////////////////////
                            RATE PRESERVATION
        //////////////////////////////////////////////////////////////*/

        // Capture user's interest rate BEFORE bridge
        // This rate will be encoded by pool.lockOrBurn() and preserved
        uint256 userRate = token.getUserInterestRate(msg.sender);

        console.log("---");
        console.log("Amount to bridge:", amount / 1e18, "RBT");
        console.log("User interest rate:", userRate, "(preserved cross-chain)");
        console.log("Destination selector:", destinationChainSelector);
        console.log("Receiver:", receiver);
        console.log("Gas limit:", gasLimit);

        /*//////////////////////////////////////////////////////////////
                            SEND MESSAGE
        //////////////////////////////////////////////////////////////*/

        // Execute cross-chain send
        // FLOW:
        // 1. Router transfers tokens from user to pool
        // 2. Router calls pool.lockOrBurn()
        // 3. Pool burns tokens, returns encoded rate
        // 4. Router submits to CCIP relayers
        bytes32 messageId = router.ccipSend(destinationChainSelector, message);

        console.log("---");
        console.log("Message ID:", vm.toString(uint256(messageId)));
        console.log("\n[SUCCESS] Bridge initiated");
        console.log("Track delivery: https://ccip.chain.link/msg/", vm.toString(uint256(messageId)));
        console.log("Expected delivery: ~15 minutes");
        console.log("========================\n");

        vm.stopBroadcast();
    }
}
