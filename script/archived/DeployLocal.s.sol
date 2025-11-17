// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {RebaseToken} from "../../src/archived/RebaseToken.sol";
import {RebaseTokenPool} from "../../src/upgradable/RebaseTokenPool.sol";
import {Vault} from "../../src/upgradable/Vault.sol";
import {IRebaseToken} from "../../src/interfaces/IRebaseToken.sol";
import {IERC20} from "@ccip/contracts/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/token/ERC20/IERC20.sol";
import {HelperConfig} from "../helpers/HelperConfig.s.sol";

// Registry imports
import {RegistryModuleOwnerCustom} from "@ccip/contracts/src/v0.8/ccip/tokenAdminRegistry/RegistryModuleOwnerCustom.sol";
import {TokenAdminRegistry} from "@ccip/contracts/src/v0.8/ccip/tokenAdminRegistry/TokenAdminRegistry.sol";

/**
 * @title DeployLocal
 * @author Ali (motafegh)
 * @notice Production-grade single-chain deployment with Registry integration
 * @dev Deploys Token + Pool + Vault, registers with CCIP TokenAdminRegistry
 *
 */
contract DeployLocal is Script {
    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error DeployLocal__InvalidRouterAddress();
    error DeployLocal__InvalidRmnProxyAddress();
    error DeployLocal__InvalidRegistryAddress();
    error DeployLocal__InvalidRegistryModuleAddress();
    error DeployLocal__VaultFundingFailed();

    /*//////////////////////////////////////////////////////////////
                              CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @dev Sepolia chain ID (only chain with vault)
    uint256 private constant SEPOLIA_CHAIN_ID = 11_155_111;

    /// @dev Testnet vault seed funding
    /// Production: Funded by protocol revenue (trading fees, yields)
    uint256 private constant VAULT_SEED_FUNDING = 1 ether;

    /*//////////////////////////////////////////////////////////////
                            MAIN FUNCTION
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Deploy complete single-chain stack
     * @return token RebaseToken contract address
     * @return pool RebaseTokenPool contract address
     * @return vault Vault contract address (0x0 if not Sepolia)
     * @return router CCIP Router address from HelperConfig
     * @return rmnProxy RMN Proxy address from HelperConfig
     * @return linkToken LINK token address from HelperConfig
     *
     * @dev Return values enable script chaining (e.g., for ConfigurePool)
     *
     * EXECUTION FLOW:
     * 1. Load network config from HelperConfig
     * 2. Validate all addresses (fail-fast)
     * 3. Deploy RebaseToken
     * 4. Deploy RebaseTokenPool
     * 5. Grant pool mint/burn role
     * 6. Register with TokenAdminRegistry (3 steps)
     * 7. Deploy Vault (Sepolia only)
     * 8. Grant vault mint/burn role
     * 9. Fund vault with seed ETH
     * 10. Log deployment summary
     */
    function run()
        external
        returns (address token, address pool, address vault, address router, address rmnProxy, address linkToken)
    {
        /*//////////////////////////////////////////////////////////////
                        STEP 0: LOAD & VALIDATE CONFIG
        //////////////////////////////////////////////////////////////*/

        HelperConfig helper = new HelperConfig();
        HelperConfig.NetworkConfig memory cfg = helper.getConfig();

        // Defensive validation (fail-fast pattern)
        if (cfg.router == address(0)) revert DeployLocal__InvalidRouterAddress();
        if (cfg.rmnProxy == address(0)) revert DeployLocal__InvalidRmnProxyAddress();
        if (cfg.tokenAdminRegistry == address(0)) revert DeployLocal__InvalidRegistryAddress();
        if (cfg.registryModule == address(0)) revert DeployLocal__InvalidRegistryModuleAddress();

        console.log("\n========================================");
        console.log("     DEPLOYMENT CONFIGURATION");
        console.log("========================================");
        console.log("Chain ID:", block.chainid);
        console.log("Deployer:", msg.sender);
        console.log("Timestamp:", block.timestamp);
        console.log("----------------------------------------");
        console.log("CCIP Infrastructure:");
        console.log("  Router:", cfg.router);
        console.log("  RMN Proxy:", cfg.rmnProxy);
        console.log("  LINK Token:", cfg.linkToken);
        console.log("  Chain Selector:", cfg.chainSelector);
        console.log("----------------------------------------");
        console.log("Token Admin Registry:");
        console.log("  Registry:", cfg.tokenAdminRegistry);
        console.log("  Module:", cfg.registryModule);
        console.log("----------------------------------------\n");

        /*//////////////////////////////////////////////////////////////
                        STEP 1: DEPLOY REBASE TOKEN
        //////////////////////////////////////////////////////////////*/

        vm.startBroadcast();

        RebaseToken tokenContract = new RebaseToken();

        console.log("========================================");
        console.log("  [1/7] REBASE TOKEN DEPLOYED");
        console.log("========================================");
        console.log("Address:", address(tokenContract));
        console.log("Owner:", tokenContract.owner());
        console.log("Initial Rate:", tokenContract.getInterestRate());
        console.log("Symbol:", tokenContract.symbol());
        console.log("Name:", tokenContract.name());
        console.log("");

        /*//////////////////////////////////////////////////////////////
                        STEP 2: DEPLOY TOKEN POOL
        //////////////////////////////////////////////////////////////*/

        // Empty allowlist = public bridging (testnet)
        // Production: Populate with KYC'd addresses
        address[] memory allowlist = new address[](0);

        RebaseTokenPool poolContract = new RebaseTokenPool(
            IERC20(address(tokenContract)), // Token to manage
            allowlist, // Who can bridge
            cfg.rmnProxy, // Security layer
            cfg.router // Message router
        );

        console.log("========================================");
        console.log("  [2/7] REBASE TOKEN POOL DEPLOYED");
        console.log("========================================");
        console.log("Address:", address(poolContract));
        console.log("Token:", address(poolContract.getToken()));
        console.log("Router:", address(poolContract.getRouter()));
        console.log("Allowlist: PUBLIC (empty array)");
        console.log("");

        /*//////////////////////////////////////////////////////////////
                        STEP 3: GRANT POOL PERMISSIONS
        //////////////////////////////////////////////////////////////*/

        tokenContract.grantMintAndBurnRole(address(poolContract));

        console.log("========================================");
        console.log("  [3/7] POOL GRANTED MINT/BURN ROLE");
        console.log("========================================");
        console.log("Role: MINT_AND_BURN_ROLE");
        console.log("Granted to:", address(poolContract));
        console.log("Verified:", tokenContract.hasRole(keccak256("MINT_AND_BURN_ROLE"), address(poolContract)));
        console.log("");

        /*//////////////////////////////////////////////////////////////
                    STEPS 4-6: REGISTRY INTEGRATION
        //////////////////////////////////////////////////////////////*/

        /*//////////////////////////////////////////////////////////////
            STEP 4-6: TOKEN ADMIN REGISTRY (TESTNET ONLY)
//////////////////////////////////////////////////////////////*/

        // Skip registry on Anvil (no real CCIP infrastructure)
        if (block.chainid != 31337) {
            // STEP 4: Propose admin
            RegistryModuleOwnerCustom(cfg.registryModule).registerAdminViaOwner(address(tokenContract));

            console.log("========================================");
            console.log("  [4/7] ADMIN REGISTRATION PROPOSED");
            console.log("========================================");
            console.log("Token:", address(tokenContract));
            console.log("Proposed Admin:", msg.sender);
            console.log("Status: PENDING");
            console.log("");

            // STEP 5: Accept admin role
            TokenAdminRegistry(cfg.tokenAdminRegistry).acceptAdminRole(address(tokenContract));

            console.log("========================================");
            console.log("  [5/7] ADMIN ROLE ACCEPTED");
            console.log("========================================");
            console.log("Token:", address(tokenContract));
            console.log("Active Admin:", msg.sender);
            console.log("Status: ACTIVE");
            console.log("");

            // STEP 6: Set pool in registry
            TokenAdminRegistry(cfg.tokenAdminRegistry).setPool(address(tokenContract), address(poolContract));

            console.log("========================================");
            console.log("  [6/7] POOL REGISTERED IN REGISTRY");
            console.log("========================================");
            console.log("Token:", address(tokenContract));
            console.log("Pool:", address(poolContract));
            console.log("Registry:", cfg.tokenAdminRegistry);
            console.log("----------------------------------------");
            console.log("Router Discovery: ENABLED");
            console.log("CCIP Standard: COMPLIANT");
            console.log("Pool Upgradeable: YES");
            console.log("");
        } else {
            // Anvil: Skip registry (mock infrastructure)
            console.log("========================================");
            console.log("  [4-6/7] REGISTRY STEPS SKIPPED (ANVIL)");
            console.log("========================================");
            console.log("Reason: No CCIP registry on local Anvil");
            console.log("Note: Registry only needed for testnet/mainnet");
            console.log("Pool can still burn/mint without registry");
            console.log("");
        }

        /*//////////////////////////////////////////////////////////////
                        STEP 7: VAULT (SEPOLIA ONLY)
        //////////////////////////////////////////////////////////////*/

        Vault vaultContract;

        if (block.chainid == SEPOLIA_CHAIN_ID || block.chainid == 1 || block.chainid == 31337) {
            vaultContract = new Vault(IRebaseToken(address(tokenContract)));

            console.log("========================================");
            console.log("  [7/7] VAULT DEPLOYED (SEPOLIA)");
            console.log("========================================");
            console.log("Address:", address(vaultContract));
            console.log("Token:", address(vaultContract.i_rebaseToken()));

            tokenContract.grantMintAndBurnRole(address(vaultContract));
            console.log("Mint/Burn Role: GRANTED");

            // Fund vault
            if (msg.sender.balance >= VAULT_SEED_FUNDING) {
                (bool success,) = payable(address(vaultContract)).call{value: VAULT_SEED_FUNDING}("");
                if (!success) revert DeployLocal__VaultFundingFailed();

                console.log("----------------------------------------");
                console.log("Initial Funding:", VAULT_SEED_FUNDING / 1e18, "ETH");
                console.log("Purpose: Interest payout reserves");
            } else {
                console.log("----------------------------------------");
                console.log("WARNING: Vault unfunded");
                console.log("  Users can deposit but NOT redeem");
                console.log("  Fund with: cast send", address(vaultContract), "--value 1ether");
            }
            console.log("");
        } else {
            console.log("========================================");
            console.log("  [7/7] VAULT SKIPPED (NOT SEPOLIA)");
            console.log("========================================");
            console.log("Chain:", block.chainid);
            console.log("Rationale: Vault only on L1");
            console.log("");
            vaultContract = Vault(payable(address(0)));
        }

        vm.stopBroadcast();

        /*//////////////////////////////////////////////////////////////
                            DEPLOYMENT SUMMARY
        //////////////////////////////////////////////////////////////*/

        console.log("========================================");
        console.log("       DEPLOYMENT COMPLETE");
        console.log("========================================");
        console.log("CONTRACT ADDRESSES:");
        console.log("----------------------------------------");
        console.log("RebaseToken:", address(tokenContract));
        console.log("RebaseTokenPool:", address(poolContract));
        console.log("Vault:", address(vaultContract));
        console.log("");
        console.log("CCIP INFRASTRUCTURE:");
        console.log("----------------------------------------");
        console.log("Router:", cfg.router);
        console.log("Chain Selector:", cfg.chainSelector);
        console.log("");
        console.log("REGISTRY INTEGRATION:");
        console.log("----------------------------------------");
        console.log("Token Admin:", msg.sender);
        console.log("Registry:", cfg.tokenAdminRegistry);
        console.log("Status: ACTIVE");
        console.log("");

        if (block.chainid == SEPOLIA_CHAIN_ID) {
            console.log("NEXT STEPS:");
            console.log("========================================");
            console.log("1. Deploy on Arbitrum Sepolia");
            console.log("2. Configure pools bidirectionally");
            console.log("3. Test deposit -> bridge -> redeem");
            console.log("");
        }

        console.log("    ALL SYSTEMS OPERATIONAL");
        console.log("========================================\n");

        return (
            address(tokenContract),
            address(poolContract),
            address(vaultContract),
            cfg.router,
            cfg.rmnProxy,
            cfg.linkToken
        );
    }
}