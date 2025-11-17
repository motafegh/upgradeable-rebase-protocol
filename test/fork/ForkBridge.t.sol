// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {CCIPLocalSimulatorFork, Register} from "@chainlink-local/src/ccip/CCIPLocalSimulatorFork.sol";
import {IRouterClient} from "@ccip/contracts/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {Client} from "@ccip/contracts/src/v0.8/ccip/libraries/Client.sol";
import {IERC20} from "@ccip/contracts/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/token/ERC20/IERC20.sol";
import {RebaseToken} from "../../src/archived/RebaseToken.sol";
import {RebaseTokenPool} from "../../src/upgradable/RebaseTokenPool.sol";

/**
 * @title ForkBridge
 * @notice Test full bridge flow: Sepolia → Arbitrum with rate preservation
 * @dev Uses CCIPLocalSimulatorFork to route messages between forks
 */
contract ForkBridgeTest is Test {
    CCIPLocalSimulatorFork public ccipSimulator;

    // Forks
    uint256 public sepoliaFork;
    uint256 public arbFork;

    // Deployed addresses (from your actual deployment)
    address public constant SEPOLIA_TOKEN = 0x16C632BafA9b3ce39bdCDdB00c3D486741685425;
    address public constant SEPOLIA_POOL = 0x197baBc40fC361e9c324e9e690c016A609ac09D4;

    address public arbToken;
    address public arbPool;

    address public alice = makeAddr("alice");

    function setUp() public {
        // Create forks
        sepoliaFork = vm.createSelectFork(vm.envString("SEPOLIA_RPC"));
        arbFork = vm.createFork(vm.envString("ARB_SEPOLIA_RPC"));

        // Deploy simulator (persists across fork switches)
        ccipSimulator = new CCIPLocalSimulatorFork();
        vm.makePersistent(address(ccipSimulator));

        // Deploy on Arbitrum fork
        vm.selectFork(arbFork);
        Register.NetworkDetails memory arbDetails = ccipSimulator.getNetworkDetails(block.chainid);

        arbToken = address(new RebaseToken());
        arbPool = address(
            new RebaseTokenPool(
                IERC20(arbToken), new address[](0), arbDetails.rmnProxyAddress, arbDetails.routerAddress
            )
        );

        RebaseToken(arbToken).grantMintAndBurnRole(arbPool);
        // TODO: Register pool with token admin registry
    }

    function test_BridgeWithRatePreservation() public {
        vm.selectFork(sepoliaFork);

        // 1. Alice deposits on Sepolia (gets high rate)
        vm.deal(alice, 1 ether);
        // ... deposit logic

        // 2. Wait for interest to accrue
        vm.warp(block.timestamp + 1 days);
        uint256 balanceWithInterest = RebaseToken(SEPOLIA_TOKEN).balanceOf(alice);
        uint256 userRate = RebaseToken(SEPOLIA_TOKEN).getUserInterestRate(alice);

        // 3. Bridge to Arbitrum
        Register.NetworkDetails memory sepoliaDetails = ccipSimulator.getNetworkDetails(block.chainid);

        vm.startPrank(alice);

        Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](1);
        tokenAmounts[0] = Client.EVMTokenAmount({
            token: SEPOLIA_TOKEN,
            amount: balanceWithInterest / 2 // Bridge half
        });

        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(alice),
            data: "",
            tokenAmounts: tokenAmounts,
            feeToken: sepoliaDetails.linkAddress,
            extraArgs: Client._argsToBytes(Client.EVMExtraArgsV2({gasLimit: 200_000, allowOutOfOrderExecution: true}))
        });

        // Get LINK from faucet
        ccipSimulator.requestLinkFromFaucet(
            alice,
            IRouterClient(sepoliaDetails.routerAddress).getFee(
                ccipSimulator.getNetworkDetails(421614).chainSelector, message
            )
        );

        // Approve and send
        IERC20(sepoliaDetails.linkAddress).approve(sepoliaDetails.routerAddress, type(uint256).max);
        IERC20(SEPOLIA_TOKEN).approve(sepoliaDetails.routerAddress, type(uint256).max);

        IRouterClient(sepoliaDetails.routerAddress).ccipSend(
            ccipSimulator.getNetworkDetails(421614).chainSelector, message
        );

        vm.stopPrank();

        // 4. Route message to Arbitrum
        ccipSimulator.switchChainAndRouteMessage(arbFork);

        // 5. Verify on Arbitrum
        vm.selectFork(arbFork);
        uint256 arbBalance = RebaseToken(arbToken).balanceOf(alice);
        uint256 arbRate = RebaseToken(arbToken).getUserInterestRate(alice);

        assertEq(arbRate, userRate, "Rate should be preserved");
        assertGt(arbBalance, 0, "Tokens should arrive");

        console.log("Bridge successful");
        console.log("Original rate:", userRate);
        console.log("Destination rate:", arbRate);
    }
}
