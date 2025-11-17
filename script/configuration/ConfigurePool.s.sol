// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {TokenPool} from "@ccip/contracts/src/v0.8/ccip/pools/TokenPool.sol";
import {RateLimiter} from "@ccip/contracts/src/v0.8/ccip/libraries/RateLimiter.sol";

/**
 * @title ConfigurePool
 * @author Ali (motafegh)
 * @notice Bidirectional CCIP pool configuration for cross-chain token bridging
 * @dev Establishes trust relationship between local and remote token pools
 *
 * CRITICAL CONTEXT:
 * This script must be run on BOTH chains to enable bidirectional transfers:
 * 1. Run on Sepolia    → allows Sepolia → Arbitrum bridging
 * 2. Run on Arbitrum   → allows Arbitrum → Sepolia bridging
 *
 * ARCHITECTURE DECISIONS:
 * - Rate limiters DISABLED for testnet (set to 0/0)
 *   Rationale: Simplifies testing; production would enforce limits
 *   Trade-off: No protection against drain attacks in current setup
 *
 * - Single remotePool per chain (array of 1)
 *   Rationale: One canonical pool per token per chain
 *   Alternative: Multi-pool support for complex routing (not needed here)
 *
 * SECURITY CONSIDERATIONS:
 * - Pool ownership: Only pool owner can call applyChainUpdates
 * - Immutable after config: Changing pools requires new deployment
 * - Trust model: We trust both pools to preserve user rates correctly
 */
contract ConfigurePool is Script {
    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error ConfigurePool__InvalidLocalPool();
    error ConfigurePool__InvalidRemotePool();
    error ConfigurePool__InvalidRemoteToken();
    error ConfigurePool__InvalidChainSelector();

    /*//////////////////////////////////////////////////////////////
                            MAIN FUNCTION
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Configure local pool to recognize and trust remote pool
     * @param localPool Address of pool contract on this chain
     * @param remoteChainSelector CCIP identifier for destination chain
     * @param remotePool Address of pool contract on destination chain
     * @param remoteToken Address of token contract on destination chain
     *
     * @dev Call flow:
     *      1. Validate inputs (fail fast on misconfiguration)
     *      2. Encode remote pool address to bytes (CCIP requirement)
     *      3. Build ChainUpdate struct with rate limiter config
     *      4. Submit single applyChainUpdates transaction
     *
     * EXAMPLE USAGE:
     *   # On Sepolia (configuring for Arbitrum)
     *   forge script script/ConfigurePool.s.sol --rpc-url $SEPOLIA_RPC --broadcast \
     *     --sig "run(address,uint64,address,address)" \
     *     0xSepoliaPool 3478487238524512106 0xArbPool 0xArbToken
     *
     *   # On Arbitrum (configuring for Sepolia)
     *   forge script script/ConfigurePool.s.sol --rpc-url $ARB_RPC --broadcast \
     *     --sig "run(address,uint64,address,address)" \
     *     0xArbPool 16015286601757825753 0xSepoliaPool 0xSepoliaToken
     */
    function run(address localPool, uint64 remoteChainSelector, address remotePool, address remoteToken) external {
        /*//////////////////////////////////////////////////////////////
                            INPUT VALIDATION
        //////////////////////////////////////////////////////////////*/

        // Fail fast if misconfigured (prevents wasted gas + confusion)
        if (localPool == address(0)) revert ConfigurePool__InvalidLocalPool();
        if (remotePool == address(0)) revert ConfigurePool__InvalidRemotePool();
        if (remoteToken == address(0)) revert ConfigurePool__InvalidRemoteToken();
        if (remoteChainSelector == 0) revert ConfigurePool__InvalidChainSelector();

        /*//////////////////////////////////////////////////////////////
                            DEPLOYMENT INFO
        //////////////////////////////////////////////////////////////*/

        console.log("\n=== Configuring CCIP Pool ===");
        console.log("Current Chain ID:", block.chainid);
        console.log("Local Pool:", localPool);
        console.log("---");
        console.log("Target Chain Selector:", remoteChainSelector);
        console.log("Remote Pool:", remotePool);
        console.log("Remote Token:", remoteToken);

        vm.startBroadcast();

        /*//////////////////////////////////////////////////////////////
                        BUILD CHAIN CONFIGURATION
        //////////////////////////////////////////////////////////////*/

        // CCIP requires pool addresses as bytes (supports non-EVM chains)
        bytes[] memory remotePoolAddresses = new bytes[](1);
        remotePoolAddresses[0] = abi.encode(remotePool);

        // Construct the chain update with DISABLED rate limiters
        // WHY DISABLED?
        // - Testnet: Simplifies testing, no real economic risk
        // - Production: Should enable with appropriate capacity/rate
        //   Example production values:
        //   • capacity: 1_000_000e18 (1M tokens)
        //   • rate: 100_000e18 per 15 min (refill rate)
        TokenPool.ChainUpdate[] memory chainsToAdd = new TokenPool.ChainUpdate[](1);
        chainsToAdd[0] = TokenPool.ChainUpdate({
            remoteChainSelector: remoteChainSelector,
            allowed: true, // Enable bidirectional transfers
            remotePoolAddress: remotePoolAddresses[0], // Encoded bytes for cross-chain compat
            remoteTokenAddress: abi.encode(remoteToken), // Encoded bytes for cross-chain compat
            // RATE LIMITER: Outbound (L1 → L2 or L2 → L1)
            outboundRateLimiterConfig: RateLimiter.Config({
                isEnabled: false, // TODO: Enable for production
                capacity: 0, // Max tokens in bucket
                rate: 0 // Refill rate per second
            }),
            // RATE LIMITER: Inbound (receiving from remote chain)
            inboundRateLimiterConfig: RateLimiter.Config({
                isEnabled: false, // TODO: Enable for production
                capacity: 0,
                rate: 0
            })
        });

        /*//////////////////////////////////////////////////////////////
                        EXECUTE CONFIGURATION
        //////////////////////////////////////////////////////////////*/

        // Single atomic call to configure cross-chain trust
        // SECURITY NOTE: Only pool owner can call this
        TokenPool(localPool).applyChainUpdates(chainsToAdd);

        console.log("\n[SUCCESS] Pool configured for chain", remoteChainSelector);
        console.log("Next step: Run this script on chain", remoteChainSelector, "to complete bidirectional setup");
        console.log("===========================\n");

        vm.stopBroadcast();
    }
}
