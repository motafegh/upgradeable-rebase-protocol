// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {RebaseTokenV2} from "../../src/upgradable/RebaseTokenV2.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IRebaseToken} from "../../src/interfaces/IRebaseToken.sol";

/**
 * @title UpgradeToV2
 * @author Ali (motafegh)
 * @notice Upgrades RebaseToken from V1 to V2 using UUPS proxy pattern
 * @dev This script takes an existing proxy and upgrades it to V2 implementation
 * 
 * ARCHITECTURE:
 * - Existing Proxy: Holds all state (balances, rates, etc.)
 * - New Implementation: Contains V2 logic (fees, pause, supply cap)
 * - Users continue interacting with same proxy address
 * 
 * UPGRADE FLOW:
 * 1. Deploy V2 implementation
 * 2. Encode initializeV2() call as bytes
 * 3. Call upgradeToAndCall() on proxy
 * 4. Verify upgrade was successful
 * 
 * USAGE:
 * Local simulation:
 *   forge script script/UpgradeToV2.s.sol:UpgradeToV2 --sig "run(address)" <PROXY_ADDRESS>
 * 
 * Testnet deployment:
 *   forge script script/UpgradeToV2.s.sol:UpgradeToV2 --sig "run(address)" <PROXY_ADDRESS> \
 *     --rpc-url $SEPOLIA_RPC_URL \
 *     --broadcast \
 *     --verify
 * 
 * SECURITY NOTES:
 * - Only owner can upgrade (enforced by _authorizeUpgrade)
 * - Upgrade is atomic (all or nothing)
 * - State is preserved (no data loss)
 * - New features are initialized safely
 */
contract UpgradeToV2 is Script {
    
    /*//////////////////////////////////////////////////////////////
                            UPGRADE
    //////////////////////////////////////////////////////////////*/
    
    /**
     * @notice Main upgrade function
     * @param proxyAddress Address of existing proxy to upgrade
     * @return newImplementation Address of new V2 implementation
     * 
     * @dev Takes existing proxy and upgrades it to V2
     */
    function run(address proxyAddress) external returns (address newImplementation) {
        _logUpgradeStart(proxyAddress);
        
        vm.startBroadcast();
        
        // Step 1: Deploy V2 implementation
        RebaseTokenV2 implementationContract = new RebaseTokenV2();
        newImplementation = address(implementationContract);
        console.log("\n[1/3] V2 Implementation deployed:", newImplementation);
        
        // Step 2: Encode initializeV2() call
        // Why: Proxy will delegatecall this during upgrade
        // Result: V2's new state is initialized in proxy's storage
        bytes memory initData = abi.encodeCall(
            implementationContract.initializeV2,
            () // initializeV2 takes no arguments
        );
        
        // Step 3: Perform upgrade
        // Flow:
        //   1. Proxy updates implementation pointer to V2
        //   2. Proxy delegatecalls initializeV2() with initData
        //   3. V2's new state is set in proxy's storage
        //   4. Result: Proxy now runs V2 code with all V1 state preserved
        IRebaseToken proxy = IRebaseToken(proxyAddress);
        proxy.upgradeToAndCall(newImplementation, initData);
        console.log("[2/3] Proxy upgraded to V2");
        
        vm.stopBroadcast();
        
        // Step 4: Verify upgrade
        _verifyUpgrade(proxy, newImplementation);
        
        _logUpgradeSummary(proxyAddress, newImplementation);
        
        return newImplementation;
    }
    
    /*//////////////////////////////////////////////////////////////
                          HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    
    /**
     * @dev Log upgrade environment info
     */
    function _logUpgradeStart(address proxyAddress) internal view {
        console.log("=== Upgrading RebaseToken to V2 ===");
        console.log("Proxy address:", proxyAddress);
        console.log("Deployer:", msg.sender);
        console.log("Chain ID:", block.chainid);
        
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
     * @dev Verify upgrade by calling view functions
     * @param proxy Upgraded proxy
     * @param implementation V2 implementation address
     */
    function _verifyUpgrade(
        IRebaseToken proxy,
        address implementation
    ) internal view {
        console.log("\n=== [3/3] Verification ===");
        console.log("  Token name:", proxy.name());
        console.log("  Token symbol:", proxy.symbol());
        console.log("  Owner:", proxy.owner());
        console.log("  Version:", proxy.version());
        
        // Verify version is 2
        require(
            proxy.version() == 2,
            "Upgrade failed: Version mismatch"
        );
        
        // Verify V2 features are available
        console.log("  Transfer fee rate:", proxy.getTransferFeeRate());
        console.log("  Fee recipient:", proxy.getFeeRecipient());
        console.log("  Max supply:", proxy.getMaxSupply());
        console.log("  Paused:", proxy.paused());
        
        console.log(" All checks passed!");
    }
    
    /**
     * @dev Log upgrade summary with important addresses
     */
    function _logUpgradeSummary(
        address proxy,
        address implementation
    ) internal pure {
        console.log("\n=== Upgrade Summary ===");
        console.log("Proxy (USER-FACING):", proxy);
        console.log("  = Users continue interacting with this address");
        console.log("  = All state preserved (balances, rates, etc.)");
        console.log("V2 Implementation (LOGIC ONLY):", implementation);
        console.log("  = New logic for fees, pause, and supply cap");
        console.log("  = Do NOT interact with this directly");
        console.log("===========================");
    }
}