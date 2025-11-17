// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {RebaseTokenV1} from "../../src/upgradable/RebaseTokenV1.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @title DeployHelper
 * @author Ali (motafegh)
 * @notice Helper contract for deploying RebaseTokenV1 in tests
 * @dev Does NOT use vm.startBroadcast() - designed for test environment
 * 
 * WHY THIS EXISTS:
 * - Scripts use startBroadcast() for real deployments
 * - Tests use vm.prank() to control msg.sender
 * - These are incompatible! So we need separate deployment logic
 * 
 * PATTERN:
 * - Scripts use DeployRebaseTokenV1.sol (with broadcast)
 * - Tests use DeployHelper.sol (without broadcast, prank-friendly)
 */
contract DeployHelper {
    
    /**
     * @notice Deploy RebaseTokenV1 with proxy (test-friendly)
     * @param initialOwner Address that will own the token
     * @return proxy User-facing address
     * @return implementation Logic contract address
     * 
     * @dev This function does NOT use startBroadcast
     * It's designed to work with vm.prank() in tests
     */
    function deployRebaseToken(address initialOwner) 
        external 
        returns (address proxy, address implementation) 
    {
        // Step 1: Deploy implementation
        RebaseTokenV1 implementationContract = new RebaseTokenV1();
        implementation = address(implementationContract);
        
        // Step 2: Encode initialize() call with the provided owner
        bytes memory initData = abi.encodeCall(
            implementationContract.initialize,
            (initialOwner)
        );
        
        // Step 3: Deploy proxy with initialization
        ERC1967Proxy proxyContract = new ERC1967Proxy(
            implementation,
            initData
        );
        proxy = address(proxyContract);
        
        return (proxy, implementation);
    }
}
