// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {Vault} from "../../src/upgradable/Vault.sol";
import {RebaseToken} from "../../src/archived/RebaseToken.sol";
import {IRebaseToken} from "src/interfaces/IRebaseToken.sol";

/**
 * @title VaultTest
 * @notice Comprehensive test suite for Vault contract
 * @dev Tests cover:
 *      - Deposit functionality (ETH → tokens)
 *      - Redeem functionality (tokens → ETH)
 *      - Interest accrual during vault operations
 *      - Multi-user scenarios
 *      - Vault solvency edge cases
 *      - CEI pattern reentrancy protection
 */
contract VaultTest is Test {
    Vault public vault;
    RebaseToken public token;

    // Test addresses
    address public owner = makeAddr("owner");
    address public user = makeAddr("user");
    address public userTwo = makeAddr("userTwo");

    // Constants
    uint256 constant DEPOSIT_AMOUNT = 1 ether;
    uint256 constant VAULT_FUNDING = 100 ether; // Extra ETH for interest payouts

    function setUp() public {
        // Deploy token as owner
        vm.prank(owner);
        token = new RebaseToken();

        // Deploy vault
        vault = new Vault(IRebaseToken(address(token)));

        // Grant vault mint/burn privileges
        vm.prank(owner);
        token.grantMintAndBurnRole(address(vault));

        // Fund users with ETH for deposits
        vm.deal(user, 10 ether);
        vm.deal(userTwo, 10 ether);

        // Fund vault with extra ETH to cover interest payouts
        // This simulates protocol revenue funding the vault
        vm.deal(address(vault), VAULT_FUNDING);
    }

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Verify vault initializes with correct token reference
     */
    function test_Constructor() public view {
        assertEq(address(vault.i_rebaseToken()), address(token));
    }

    /**
     * @notice Test immutable token cannot be changed after deployment
     */
    function test_ConstructorSetsImmutableToken() public {
        // Deploy new token
        vm.prank(owner);
        RebaseToken newToken = new RebaseToken();

        // Deploy vault with new token
        Vault newVault = new Vault(IRebaseToken(address(newToken)));

        // Token should be set correctly
        assertEq(address(newVault.i_rebaseToken()), address(newToken));
    }

    /*//////////////////////////////////////////////////////////////
                            DEPOSIT TESTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Test basic deposit functionality
     * @dev User sends ETH, receives RebaseTokens at current rate
     */
    function test_Deposit() public {
        vm.prank(user);
        vault.deposit{value: DEPOSIT_AMOUNT}();

        // User should receive tokens equal to ETH deposited
        assertEq(token.balanceOf(user), DEPOSIT_AMOUNT, "Should receive 1:1 tokens for ETH");

        // Vault should hold the ETH (in addition to initial funding)
        assertEq(address(vault).balance, VAULT_FUNDING + DEPOSIT_AMOUNT, "Vault should hold deposited ETH");
    }

    /**
     * @notice Verify deposit reverts with zero amount
     */
    function test_DepositRevertsWithZeroAmount() public {
        vm.prank(user);
        vm.expectRevert(Vault.Vault__DepositAmountZero.selector);
        vault.deposit{value: 0}();
    }

    /**
     * @notice Verify deposit emits correct event
     */
    function test_DepositEmitsEvent() public {
        vm.prank(user);
        vm.expectEmit(true, true, false, true);
        emit Vault.Deposit(user, DEPOSIT_AMOUNT);
        vault.deposit{value: DEPOSIT_AMOUNT}();
    }

    /**
     * @notice Verify user receives tokens at current global rate
     */
    function test_DepositSetsUserRate() public {
        uint256 currentRate = token.getInterestRate();

        vm.prank(user);
        vault.deposit{value: DEPOSIT_AMOUNT}();

        assertEq(token.getUserInterestRate(user), currentRate, "User should receive current global rate");
    }

    /**
     * @notice Test multiple deposits from same user
     * @dev Balances should accumulate correctly
     */
    function test_MultipleDeposits() public {
        // First deposit
        vm.prank(user);
        vault.deposit{value: DEPOSIT_AMOUNT}();

        // Second deposit
        vm.prank(user);
        vault.deposit{value: DEPOSIT_AMOUNT}();

        assertEq(token.balanceOf(user), DEPOSIT_AMOUNT * 2, "Multiple deposits should accumulate");
    }

    /**
     * @notice Test deposits from multiple users
     * @dev Each user should have independent balances and rates
     */
    function test_DepositFromMultipleUsers() public {
        // User deposits
        vm.prank(user);
        vault.deposit{value: DEPOSIT_AMOUNT}();

        // UserTwo deposits
        vm.prank(userTwo);
        vault.deposit{value: DEPOSIT_AMOUNT * 2}();

        assertEq(token.balanceOf(user), DEPOSIT_AMOUNT);
        assertEq(token.balanceOf(userTwo), DEPOSIT_AMOUNT * 2);
    }

    /**
     * @notice Verify vault mints tokens at current rate (not user's existing rate)
     */
    function test_DepositMintsTokensAtCurrentRate() public {
        // First deposit at initial rate
        vm.prank(user);
        vault.deposit{value: DEPOSIT_AMOUNT}();
        uint256 initialRate = token.getUserInterestRate(user);

        // Owner decreases global rate
        vm.prank(owner);
        token.setInterestRate(2e10);

        // User deposits again - should NOT change their existing rate
        vm.prank(user);
        vault.deposit{value: DEPOSIT_AMOUNT}();

        // User keeps their original high rate (rate downgrade protection)
        assertEq(token.getUserInterestRate(user), initialRate, "User should keep original rate");
    }

    /*//////////////////////////////////////////////////////////////
                            REDEEM TESTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Test basic redeem functionality
     * @dev User burns tokens, receives ETH back
     */
    function test_Redeem() public {
        // Deposit first
        vm.prank(user);
        vault.deposit{value: DEPOSIT_AMOUNT}();

        uint256 userEthBefore = user.balance;

        // Redeem all tokens
        vm.prank(user);
        vault.redeem(DEPOSIT_AMOUNT);

        // User should have tokens burned
        assertEq(token.balanceOf(user), 0, "All tokens should be burned");

        // User should receive ETH back
        assertEq(user.balance, userEthBefore + DEPOSIT_AMOUNT, "User should receive ETH back");
    }

    /**
     * @notice Test redeeming with type(uint256).max (full balance)
     */
    function test_RedeemMaxUint() public {
        vm.prank(user);
        vault.deposit{value: DEPOSIT_AMOUNT}();

        uint256 userEthBefore = user.balance;

        // Redeem using max uint (should redeem full balance)
        vm.prank(user);
        vault.redeem(type(uint256).max);

        assertEq(token.balanceOf(user), 0, "All tokens should be redeemed");
        assertEq(user.balance, userEthBefore + DEPOSIT_AMOUNT, "Should redeem full balance");
    }

    /**
     * @notice Verify redeem includes accrued interest
     * @dev Tests the full cycle: deposit → wait → redeem (with interest)
     */
    function test_RedeemWithInterest() public {
        // Deposit
        vm.prank(user);
        vault.deposit{value: DEPOSIT_AMOUNT}();

        // Accrue interest
        vm.warp(block.timestamp + 365 days);

        uint256 balanceWithInterest = token.balanceOf(user);
        assertGt(balanceWithInterest, DEPOSIT_AMOUNT, "Interest should accrue");

        uint256 userEthBefore = user.balance;

        // Redeem all (including interest)
        vm.prank(user);
        vault.redeem(type(uint256).max);

        // User should receive ETH = deposit + interest
        assertEq(user.balance, userEthBefore + balanceWithInterest, "Should receive deposit + interest");
    }

    /**
     * @notice Test partial redemption
     */
    function test_RedeemPartialAmount() public {
        vm.prank(user);
        vault.deposit{value: DEPOSIT_AMOUNT}();

        // Redeem half
        vm.prank(user);
        vault.redeem(DEPOSIT_AMOUNT / 2);

        assertEq(token.balanceOf(user), DEPOSIT_AMOUNT / 2, "Half should remain");
    }

    /**
     * @notice Verify redeem emits correct event
     */
    function test_RedeemEmitsEvent() public {
        vm.prank(user);
        vault.deposit{value: DEPOSIT_AMOUNT}();

        vm.prank(user);
        vm.expectEmit(true, true, false, true);
        emit Vault.Redeem(user, DEPOSIT_AMOUNT);
        vault.redeem(DEPOSIT_AMOUNT);
    }

    /**
     * @notice Test multiple redemptions
     */
    function test_RedeemMultipleTimes() public {
        vm.prank(user);
        vault.deposit{value: DEPOSIT_AMOUNT}();

        // Redeem 1/4
        vm.prank(user);
        vault.redeem(DEPOSIT_AMOUNT / 4);

        // Redeem another 1/4
        vm.prank(user);
        vault.redeem(DEPOSIT_AMOUNT / 4);

        assertEq(token.balanceOf(user), DEPOSIT_AMOUNT / 2, "Should have half remaining");
    }

    /**
     * @notice Verify redeem reverts if user has insufficient tokens
     */
    function test_RedeemRevertsIfInsufficientTokenBalance() public {
        vm.prank(user);
        vault.deposit{value: DEPOSIT_AMOUNT}();

        // Try to redeem more than balance
        vm.prank(user);
        vm.expectRevert();
        vault.redeem(DEPOSIT_AMOUNT + 1);
    }

    /**
     * @notice ECONOMIC RISK TEST: Verify redeem reverts if vault lacks ETH
     * @dev This tests vault solvency - a real economic risk in production
     */
    function test_RedeemRevertsIfInsufficientVaultBalance() public {
        vm.prank(user);
        vault.deposit{value: DEPOSIT_AMOUNT}();

        // Drain vault ETH (simulate insolvency)
        vm.prank(address(vault));
        payable(owner).transfer(address(vault).balance);

        // Redeem should fail (vault has no ETH)
        vm.prank(user);
        vm.expectRevert(Vault.Vault__RedeemFailed.selector);
        vault.redeem(DEPOSIT_AMOUNT);
    }

    function test_RedeemFollowsCEIPattern() public {
        ReentrancyAttacker attacker = new ReentrancyAttacker(vault, token);
        /*  CEI + re-entrancy test in one shot
        1. Attacker deposits 1 ETH → gets 1 token
        2. Attacker calls redeem() → Vault burns token FIRST, then sends 1 ETH
        3. Attacker's receive() tries to re-enter redeem(), but balance is now 0 → revert
        4. We assert vault lost exactly 1 ETH → no double-spend happened
         */
        vm.deal(address(attacker), 1 ether);

        // deposit & redeem
        attacker.deposit{value: 1 ether}();

        // record balances before redeem
        uint256 vaultBefore = address(vault).balance;
        uint256 attackerBefore = address(attacker).balance;

        attacker.attack();

        // vault must lose exactly 1 ETH (no extra)
        assertEq(address(vault).balance, vaultBefore - 1 ether);
        // attacker must gain exactly 1 ETH (no extra)
        assertEq(address(attacker).balance, attackerBefore + 1 ether);
    }

    /*//////////////////////////////////////////////////////////////
                            RECEIVE FUNCTION
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Test vault can receive ETH directly
     * @dev This allows funding vault for interest payouts
     */
    function test_ReceiveETH() public {
        uint256 vaultBalanceBefore = address(vault).balance;

        // Send ETH to vault
        (bool success,) = address(vault).call{value: 1 ether}("");
        assertTrue(success, "ETH transfer should succeed");

        assertEq(address(vault).balance, vaultBalanceBefore + 1 ether, "Vault should receive ETH");
    }

    /*//////////////////////////////////////////////////////////////
                        INTEGRATION TESTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Test full cycle: deposit → redeem → deposit again
     */
    function test_FullCycle_DepositRedeemDeposit() public {
        // First deposit
        vm.prank(user);
        vault.deposit{value: DEPOSIT_AMOUNT}();

        // Redeem all
        vm.prank(user);
        vault.redeem(type(uint256).max);

        // Second deposit (user should still work normally)
        vm.prank(user);
        vault.deposit{value: DEPOSIT_AMOUNT}();

        assertEq(token.balanceOf(user), DEPOSIT_AMOUNT);
    }

    /**
     * @notice ECONOMIC TEST: Verify vault solvency after interest payouts
     * @dev Tests that vault can handle interest liability over time
     */
    function test_VaultSolvencyAfterInterestPayouts() public {
        // User deposits
        vm.prank(user);
        vault.deposit{value: 10 ether}();

        // Accrue significant interest
        vm.warp(block.timestamp + 365 days);

        uint256 balanceWithInterest = token.balanceOf(user);
        console.log("Balance with interest:", balanceWithInterest);
        console.log("Vault ETH balance:", address(vault).balance);

        // Check if vault has enough ETH
        if (address(vault).balance >= balanceWithInterest) {
            // Vault is solvent - redemption should work
            vm.prank(user);
            vault.redeem(type(uint256).max);
            assertEq(token.balanceOf(user), 0);
        } else {
            // Vault is insolvent - redemption should fail
            vm.prank(user);
            vm.expectRevert(Vault.Vault__RedeemFailed.selector);
            vault.redeem(type(uint256).max);
        }
    }

    /*//////////////////////////////////////////////////////////////
                            FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Fuzz test: deposit and immediately redeem
     * @dev Should get same ETH back (no loss)
     */
    function testFuzz_DepositAndRedeem(uint256 amount) public {
        amount = bound(amount, 0.01 ether, 100 ether);
        vm.deal(user, amount);

        uint256 userEthBefore = user.balance;

        // Deposit
        vm.prank(user);
        vault.deposit{value: amount}();

        // Immediately redeem
        vm.prank(user);
        vault.redeem(type(uint256).max);

        // Should get same ETH back
        assertEq(user.balance, userEthBefore, "Should get same ETH back");
    }

    /**
     * @notice Fuzz test: partial redemption
     */
    function testFuzz_PartialRedeem(uint256 depositAmt, uint256 redeemAmt) public {
        depositAmt = bound(depositAmt, 0.1 ether, 10 ether);
        redeemAmt = bound(redeemAmt, 0.1 ether, depositAmt);
        vm.deal(user, depositAmt);

        // Deposit
        vm.prank(user);
        vault.deposit{value: depositAmt}();

        // Partial redeem
        vm.prank(user);
        vault.redeem(redeemAmt);

        assertEq(token.balanceOf(user), depositAmt - redeemAmt, "Remaining balance should be correct");
    }

    /**
     * @notice Fuzz test: multiple users depositing
     */
    function testFuzz_MultipleUsers(uint256 amount1, uint256 amount2) public {
        amount1 = bound(amount1, 0.01 ether, 50 ether);
        amount2 = bound(amount2, 0.01 ether, 50 ether);

        vm.deal(user, amount1);
        vm.deal(userTwo, amount2);

        // User deposits
        vm.prank(user);
        vault.deposit{value: amount1}();

        // UserTwo deposits
        vm.prank(userTwo);
        vault.deposit{value: amount2}();

        assertEq(token.balanceOf(user), amount1);
        assertEq(token.balanceOf(userTwo), amount2);
    }

    /**
     * @notice Fuzz test: receive function
     */
    function testFuzz_ReceiveETH(uint256 amount) public {
        amount = bound(amount, 0, 100 ether);
        vm.deal(user, amount);

        uint256 vaultBefore = address(vault).balance;

        vm.prank(user);
        (bool success,) = address(vault).call{value: amount}("");
        assertTrue(success);

        assertEq(address(vault).balance, vaultBefore + amount);
    }
}

/**
 * @notice Mock contract for testing reentrancy protection
 * @dev Attempts to call redeem() again during receive()
 */
contract ReentrancyAttacker {
    Vault public vault;
    RebaseToken public token;
    uint256 public attackCount;

    constructor(Vault _vault, RebaseToken _token) {
        vault = _vault;
        token = _token;
    }

    function deposit() external payable {
        vault.deposit{value: msg.value}();
    }

    function attack() external {
        vault.redeem(type(uint256).max);
    }

    receive() external payable {
        // Try to reenter (should fail due to CEI pattern)
        if (attackCount < 2 && token.balanceOf(address(this)) > 0) {
            attackCount++;
            try vault.redeem(type(uint256).max) {} catch {}
        }
    }
}
