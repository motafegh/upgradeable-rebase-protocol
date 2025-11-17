// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {RebaseTokenV1} from "../../src/upgradable/RebaseTokenV1.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {DeployHelper} from "../helpers/DeployHelper.sol";

/**
 * @title DeploymentTest
 * @author Ali (motafegh)
 * @notice Tests the deployment for RebaseTokenV1
 * @dev Verifies proxy setup, initialization, and proper delegation
 * 
 * WHAT WE'RE TESTING:
 * 1. Deployment completes without errors
 * 2. Proxy and implementation deployed correctly
 * 3. Initialization happened atomically
 * 4. Proxy delegates to implementation
 * 5. Storage lives in proxy, not implementation
 * 6. Implementation cannot be initialized directly
 * 
 * WHY THIS MATTERS:
 * - Deployment is ONE-TIME operation (can't redo on mainnet!)
 * - Wrong initialization = lost funds
 * - Storage in wrong place = data loss on upgrade
 */
contract DeploymentTest is Test {
    
    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/
    
    DeployHelper public deployHelper;
    address public proxy;
    address public implementation;
    RebaseTokenV1 public token;
    
    address public owner = makeAddr("owner");
    address public user1 = makeAddr("user1");
    
    /*//////////////////////////////////////////////////////////////
                                SETUP
    //////////////////////////////////////////////////////////////*/
    
    function setUp() public {
        // Create the deploy helper
        deployHelper = new DeployHelper();
        
        // Deploy as 'owner' using prank
        // This works because deployHelper.deployRebaseToken() doesn't use broadcast!
        vm.prank(owner);
        (proxy, implementation) = deployHelper.deployRebaseToken(owner);
        
        // Cast proxy for easy interaction
        token = RebaseTokenV1(proxy);
    }
    
    /*//////////////////////////////////////////////////////////////
                        DEPLOYMENT VALIDATION
    //////////////////////////////////////////////////////////////*/
    
    /**
     * @notice Test that deployment returns valid addresses
     * CONCEPT: Deployed addresses should not be zero address
     */
    function test_DeploymentReturnsValidAddresses() public view {
        assertTrue(proxy != address(0), "Proxy is zero address");
        assertTrue(implementation != address(0), "Implementation is zero address");
        assertNotEq(proxy, implementation, "Proxy and implementation are the same");
    }
    
    /**
     * @notice Test that proxy has bytecode (is actually deployed)
     * CONCEPT: address.code.length > 0 means contract exists
     */
    function test_ProxyIsDeployed() public view {
        uint256 proxyCodeSize = address(proxy).code.length;
        assertTrue(proxyCodeSize > 0, "Proxy has no bytecode");
        console.log("Proxy bytecode size:", proxyCodeSize);
    }
    
    /**
     * @notice Test that implementation is deployed
     */
    function test_ImplementationIsDeployed() public view {
        uint256 implementationCodeSize = address(implementation).code.length;
        assertTrue(implementationCodeSize > 0, "Implementation has no bytecode");
        console.log("Implementation bytecode size:", implementationCodeSize);
    }
    
    /*//////////////////////////////////////////////////////////////
                      INITIALIZATION VALIDATION
    //////////////////////////////////////////////////////////////*/
    
    /**
     * @notice Test that token was initialized with correct values
     * CONCEPT: initialize() should set name, symbol, owner, interest rate
     */
    function test_TokenInitializedCorrectly() public view {
        assertEq(token.name(), "RebaseToken", "Wrong token name");
        assertEq(token.symbol(), "RBT", "Wrong token symbol");
        assertEq(token.owner(), owner, "Wrong owner");
        assertEq(token.getInterestRate(), 5e10, "Wrong interest rate");
        assertEq(token.version(), 1, "Wrong version");
    }
    
    /**
     * @notice Test that proxy holds state, not implementation
     * CONCEPT: When we call token.owner(), storage should be in proxy
     * 
     * CRITICAL TEST! This proves delegatecall works correctly.
     */
    function test_StateStoredInProxy() public view {
        // Read owner from proxy
        address proxyOwner = token.owner();
        
        // Read owner from implementation directly
        RebaseTokenV1 implContract = RebaseTokenV1(implementation);
        address implOwner = implContract.owner();
        
        // Verify: proxy has state, implementation doesn't
        assertEq(proxyOwner, owner, "Proxy owner incorrect");
        assertEq(implOwner, address(0), "Implementation should have no owner");
        
        console.log("Proxy owner:", proxyOwner);
        console.log("Implementation owner:", implOwner);
    }
    
    /*//////////////////////////////////////////////////////////////
                      SECURITY VALIDATION
    //////////////////////////////////////////////////////////////*/
    
    /**
     * @notice Test that implementation cannot be initialized directly
     * CONCEPT: _disableInitializers() should prevent this
     * 
     * WHY THIS MATTERS:
     * If attacker can initialize implementation, they could:
     * 1. Become "owner" of implementation
     * 2. Call selfdestruct (if it existed)
     * 3. Confuse access control
     */
    function test_CannotInitializeImplementation() public {
        RebaseTokenV1 implContract = RebaseTokenV1(implementation);
        
        vm.expectRevert();
        implContract.initialize(owner);
    }
    
    /**
     * @notice Test that proxy cannot be initialized twice
     * CONCEPT: Initializer modifier prevents re-initialization
     */
    function test_CannotReinitializeProxy() public {
        vm.expectRevert();
        token.initialize(owner);
    }
    
    /*//////////////////////////////////////////////////////////////
                      DELEGATION VALIDATION
    //////////////////////////////////////////////////////////////*/
    
    /**
     * @notice Test that proxy correctly delegates calls
     * CONCEPT: Call view functions through proxy, verify responses
     */
    function test_ProxyDelegatesCorrectly() public view {
        string memory name = token.name();
        string memory symbol = token.symbol();
        uint256 version = token.version();
        uint256 rate = token.getInterestRate();
        
        // Assert all values match initialization
        assertEq(name, "RebaseToken", "Delegation failed: wrong name");
        assertEq(symbol, "RBT", "Delegation failed: wrong symbol");
        assertEq(version, 1, "Delegation failed: wrong version");
        assertEq(rate, 5e10, "Delegation failed: wrong rate");
        
        console.log("Delegation test passed:");
        console.log("  Name:", name);
        console.log("  Symbol:", symbol);
        console.log("  Version:", version);
        console.log("  Rate:", rate);
    }
    
    /*//////////////////////////////////////////////////////////////
                      ROLE VALIDATION
    //////////////////////////////////////////////////////////////*/
    
    /**
     * @notice Test that deployer can grant mint/burn role
     * CONCEPT: Owner should have admin capabilities
     */
    function test_OwnerCanGrantMintBurnRole() public {
        vm.prank(owner);
        token.grantMintAndBurnRole(user1);
        
        bool hasRole = token.hasRole(keccak256("MINT_AND_BURN_ROLE"), user1);
        assertTrue(hasRole, "User1 should have MINT_AND_BURN_ROLE");
    }
    
    /**
     * @notice Test that non-owner cannot grant roles
     * CONCEPT: Access control should prevent unauthorized role grants
     */
    function test_NonOwnerCannotGrantRoles() public {
        vm.prank(user1);
        vm.expectRevert();
        token.grantMintAndBurnRole(user1);
    }
}
