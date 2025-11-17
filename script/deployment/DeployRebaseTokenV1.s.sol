// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {RebaseTokenV1} from "../../src/upgradable/RebaseTokenV1.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @title DeployRebaseTokenV1
 * @author Ali (motafegh)
 * @notice Deploys upgradeable RebaseToken with UUPS proxy pattern
 * @dev First version deployment - establishes proxy infrastructure
 * 
 * ARCHITECTURE:
 * - Implementation: Contains all business logic (stateless)
 * - Proxy: Holds all state, delegates calls to implementation
 * - Users interact ONLY with proxy address
 * 
 * DEPLOYMENT FLOW:
 * 1. Deploy implementation contract
 * 2. Encode initialize() call as bytes
 * 3. Deploy proxy with implementation + init data
 * 4. Proxy atomically calls initialize() during construction
 * 
 * USAGE:
 * Local simulation:
 *   forge script script/DeployRebaseTokenV1.s.sol:DeployRebaseTokenV1
 * 
 * Testnet deployment:
 *   forge script script/DeployRebaseTokenV1.s.sol:DeployRebaseTokenV1 \
 *     --rpc-url $SEPOLIA_RPC_URL \
 *     --broadcast \
 *     --verify
 * 
 * SECURITY NOTES:
 * - Implementation is deployed with _disableInitializers() to prevent direct init
 * - Initialization happens atomically (prevents front-running)
 * - Only proxy address should be shared with users
 */
contract DeployRebaseTokenV1 is Script {
    
    /*//////////////////////////////////////////////////////////////
                            DEPLOYMENT
    //////////////////////////////////////////////////////////////*/
    
    /**
     * @notice Main deployment function
     * @return proxy Address users should interact with (holds state)
     * @return implementation Address of logic contract (stateless)
     * 
     * @dev Returns proxy first because that's the important address!
     */
    function run() external returns (address proxy, address implementation) {
        _logDeploymentStart();
        
        vm.startBroadcast();
        
        // Step 1: Deploy implementation
        RebaseTokenV1 implementationContract = new RebaseTokenV1();
        implementation = address(implementationContract);
        console.log("\n[1/3] Implementation deployed:", implementation);
        
        // Step 2: Encode initialize() call
        // Why: Proxy will delegatecall this during construction
        // Result: Initialization happens atomically (no front-running window)
        bytes memory initData = abi.encodeCall(
            implementationContract.initialize,
            (msg.sender) // Pass the deployer as the owner
        );
        
        // Step 3: Deploy proxy with atomic initialization
        // Constructor flow:
        //   1. Proxy stores implementation address in ERC-1967 slot
        //   2. Proxy delegatecalls initialize() with initData
        //   3. Initialize code runs in PROXY's storage context
        //   4. Result: Proxy is initialized and ready to use
        ERC1967Proxy proxyContract = new ERC1967Proxy(
            implementation,
            initData
        );
        proxy = address(proxyContract);
        console.log("[2/3] Proxy deployed:", proxy);
        
        // Step 4: Verify deployment
        // Cast proxy address as RebaseTokenV1 to interact with it
        // When we call token.name(), the proxy's fallback function
        // delegates to implementation.name() using the proxy's storage
        RebaseTokenV1 token = RebaseTokenV1(proxy);
        _verifyDeployment(token, implementation);
        
        vm.stopBroadcast();
        
        _logDeploymentSummary(proxy, implementation);
        
        return (proxy, implementation);
    }
    
    /*//////////////////////////////////////////////////////////////
                          HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    
    /**
     * @dev Log deployment environment info
     */
    function _logDeploymentStart() internal view {
        console.log("=== Deploying Upgradeable RebaseToken ===");
        console.log("Deployer:", msg.sender);
        console.log("Chain ID:", block.chainid);
        console.log("Block number:", block.number);
        
        // Network detection
        if (block.chainid == 1) {
            console.log("Network: Ethereum Mainnet");
        } else if (block.chainid == 11155111) {
            console.log("Network: Sepolia Testnet");
        } else if (block.chainid == 31337) {
            console.log("Network: Local Anvil");
        }
    }
    
    /**
     * @dev Verify deployment by calling view functions
     * @param token Deployed token (proxy address cast as RebaseTokenV1)
     * @param implementation Implementation address for logging
     */
    function _verifyDeployment(
        RebaseTokenV1 token,
        address implementation
    ) internal view {
        console.log("=== [3/3] Verification ===");
        console.log("  Token name:", token.name());
        console.log("  Token symbol:", token.symbol());
        console.log("  Owner:", token.owner());
        console.log("  Interest rate:", token.getInterestRate());
        console.log("  Version:", token.version());
        
        // Verify owner is deployer
        require(
            token.owner() == msg.sender,
            "Deployment failed: Owner mismatch"
        );
        
        // Verify version is 1
        require(
            token.version() == 1,
            "Deployment failed: Version mismatch"
        );
        
        console.log(" All checks passed!");
    }
    
    /**
     * @dev Log deployment summary with important addresses
     */
    function _logDeploymentSummary(
        address proxy,
        address implementation
    ) internal pure {
        console.log("=== Deployment Summary ===");
        console.log("Proxy (USER-FACING):", proxy);
        console.log("  = Share this address with users");
        console.log("  = Holds all state (balances, rates, etc.)");
        console.log("Implementation (LOGIC ONLY):", implementation);
        console.log("  = Do NOT interact with this directly");
        console.log("  = Stateless (contains only code)");
        console.log("===========================");
    }
}
