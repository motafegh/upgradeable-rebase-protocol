// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {CCIPLocalSimulatorFork, Register} from "@chainlink-local/src/ccip/CCIPLocalSimulatorFork.sol";
import {BurnMintERC677Helper, IERC20} from "@chainlink-local/src/ccip/CCIPLocalSimulator.sol";
import {IRouterClient} from "@ccip/contracts/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {Client} from "@ccip/contracts/src/v0.8/ccip/libraries/Client.sol";

import {DeployLocal} from "../../script/archived/DeployLocal.s.sol";
import {ConfigurePool} from "../../script/configuration/ConfigurePool.s.sol";
import {RebaseToken} from "../../src/archived/RebaseToken.sol";
import {RebaseTokenPool} from "../../src/upgradable/RebaseTokenPool.sol";
import {Vault} from "../../src/upgradable/Vault.sol";
/**
 * @title CrossChainTest
 * @notice Fork tests for cross-chain rate preservation via CCIP
 * @dev Uses CCIPLocalSimulatorFork for instant message delivery
 */
contract CrossChainTest is Test {
    CCIPLocalSimulatorFork ccipSimulator;

    uint256 sepoliaFork;
    uint256 arbFork;

    // Sepolia contracts
    RebaseToken sepoliaToken;
    RebaseTokenPool sepoliaPool;
    Vault vault;
    address sepoliaRouter;
    uint64 sepoliaSelector;

    // Arbitrum contracts
    RebaseToken arbToken;
    RebaseTokenPool arbPool;
    address arbRouter;
    uint64 arbSelector;

    // Test accounts
    address owner;
    address alice = makeAddr("alice");

    uint256 constant DEPOSIT_AMOUNT = 1 ether;

    function setUp() public {
        // TODO: Get RPC URLs from environment
        string memory SEPOLIA_RPC = vm.envString("SEPOLIA_RPC_URL");
        string memory ARB_RPC = vm.envString("ARBITRUM_SEPOLIA_RPC_URL");

        // TODO: Create forks
        sepoliaFork = vm.createFork(SEPOLIA_RPC);
        arbFork = vm.createFork(ARB_RPC);

        // TODO: Deploy CCIP simulator
        ccipSimulator = new CCIPLocalSimulatorFork();
        vm.makePersistent(address(ccipSimulator));

        // TODO: Deploy on Sepolia
        vm.selectFork(sepoliaFork);
        _deployOnSepolia();

        // TODO: Deploy on Arbitrum
        vm.selectFork(arbFork);
        _deployOnArbitrum();

        // TODO: Configure pools bidirectionally
        _configurePools();

        // TODO: Fund Alice with ETH on both chains
        vm.deal(alice, 10 ether);
    }

    function _deployOnSepolia() internal {
        // TODO: Use DeployLocal to deploy
        // TODO: Capture addresses
        // TODO: Register in CCIP simulator
        // TODO: Fund vault
    }

    function _deployOnArbitrum() internal {
        // TODO: Same as Sepolia (no vault)
    }

    function _configurePools() internal {
        // TODO: Sepolia → Arbitrum via ConfigurePool
        // TODO: Arbitrum → Sepolia via ConfigurePool
    }

    /*//////////////////////////////////////////////////////////////
                            BRIDGE TESTS
    //////////////////////////////////////////////////////////////*/

    /**
     * TODO: Bridge Sepolia → Arbitrum, verify rate preserved
     *
     * Steps:
     * 1. Alice deposits 1 ETH on Sepolia
     * 2. Capture Alice's rate (5e10 initial)
     * 3. Build CCIP message
     * 4. Bridge tokens to Arbitrum
     * 5. ccipSimulator.switchChainAndRouteMessage()
     * 6. Switch to Arbitrum fork
     * 7. Assert Alice has tokens on Arbitrum
     * 8. Assert rate = 5e10 (preserved)
     */
    function test_BridgeSepoliaToArbitrum() public {
        // TODO: Implement
    }

    /**
     * TODO: Reverse direction bridge
     */
    function test_BridgeArbitrumToSepolia() public {
        // TODO: Implement (similar logic, reverse direction)
    }

    /**
     * TODO: Multi-hop preserves rate
     *
     * Steps:
     * 1. Deposit on Sepolia (rate 5e10)
     * 2. Bridge to Arbitrum
     * 3. Bridge back to Sepolia
     * 4. Assert rate still 5e10
     */
    function test_MultiHopPreservesRate() public {
        // TODO: Implement
    }

    /**
     * TODO: Interest accrues independently on both chains
     *
     * Steps:
     * 1. Alice deposits 1 ETH on Sepolia
     * 2. vm.warp(+180 days) on Sepolia fork
     * 3. Check balance increased (interest accrued)
     * 4. Bridge to Arbitrum
     * 5. vm.warp(+180 days) on Arbitrum fork
     * 6. Check balance increased again (6mo more interest)
     */
    function test_InterestAccruesBothChains() public {
        // TODO: Implement
    }

    /**
     * TODO: Multiple users with different rates
     *
     * Steps:
     * 1. Alice deposits at 5e10 rate
     * 2. Owner drops rate to 3e10
     * 3. Bob deposits at 3e10 rate
     * 4. Both bridge to Arbitrum
     * 5. Assert Alice keeps 5e10, Bob keeps 3e10
     */
    function test_MultiUserDifferentRates() public {
        // TODO: Implement
    }

    /*//////////////////////////////////////////////////////////////
                            HELPERS
    //////////////////////////////////////////////////////////////*/

    function _bridgeTokens(
        uint256 sourceFork,
        address router,
        address token,
        uint64 destSelector,
        address receiver,
        uint256 amount
    ) internal returns (bytes32 messageId) {
        // TODO: Build CCIP message
        // TODO: Approve router
        // TODO: Call router.ccipSend()
        // TODO: Return messageId
    }
}
