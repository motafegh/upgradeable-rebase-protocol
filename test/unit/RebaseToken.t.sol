// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {RebaseToken} from "../../src/archived/RebaseToken.sol";

/**
 * @title RebaseTokenTest
 * @notice Comprehensive test suite for RebaseToken contract
 * @dev Tests cover:
 *      - Access control and role management
 *      - Mint/burn functionality with rate preservation
 *      - Interest accrual calculations (linear formula)
 *      - Transfer mechanics with rate inheritance
 *      - Owner-controlled interest rate adjustments
 *      - Fuzz testing for edge cases
 */
contract RebaseTokenTest is Test {
    RebaseToken public token;

    // Test addresses
    address public owner = makeAddr("owner");
    address public user = makeAddr("user");
    address public vault = makeAddr("vault");
    address public userTwo = makeAddr("userTwo");

    // Constants
    uint256 constant AMOUNT = 1000e18;
    uint256 constant INITIAL_RATE = 5e10; // 5% APY represented as per-second rate

    function setUp() public {
        // Deploy token as owner
        vm.prank(owner);
        token = new RebaseToken();

        // Grant vault the MINT_AND_BURN_ROLE
        vm.prank(owner);
        token.grantMintAndBurnRole(vault);

        // Verify role was granted correctly
        assertTrue(
            token.hasRole(keccak256("MINT_AND_BURN_ROLE"), vault), "Vault should have MINT_AND_BURN_ROLE after setUp"
        );
    }

    /*//////////////////////////////////////////////////////////////    
                            INITIAL STATE
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Verify contract initializes with correct state
     * @dev Checks initial rate (5e10) and owner address
     */
    function test_InitialState() public view {
        assertEq(token.getInterestRate(), INITIAL_RATE, "Initial rate should be 5e10");
        assertEq(token.owner(), owner, "Owner should be deployer address");
    }

    /*//////////////////////////////////////////////////////////////
                            ACCESS CONTROL
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Test granting MINT_AND_BURN_ROLE to new address
     * @dev Verifies granted address can successfully mint tokens
     */
    function test_GrantMintAndBurnRole() public {
        // Owner grants role to user
        vm.prank(owner);
        token.grantMintAndBurnRole(user);

        // User should now be able to mint
        vm.prank(user);
        token.mint(user, AMOUNT, INITIAL_RATE);

        assertEq(token.balanceOf(user), AMOUNT, "User should receive minted tokens");
    }

    /**
     * @notice Verify only owner can grant roles
     * @dev Non-owner attempt should revert
     */
    function test_GrantMintAndBurnRole_NotOwner() public {
        vm.prank(user);
        vm.expectRevert();
        token.grantMintAndBurnRole(userTwo);
    }

    /**
     * @notice Verify only addresses with MINT_AND_BURN_ROLE can mint
     * @dev Unauthorized mint attempt should revert
     */
    function test_OnlyRoleCanMint() public {
        vm.prank(user); // user doesn't have role
        vm.expectRevert();
        token.mint(userTwo, AMOUNT, INITIAL_RATE);
    }

    /*//////////////////////////////////////////////////////////////
                            MINT FUNCTION
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Test basic mint functionality
     * @dev Verifies tokens are minted and user rate is set
     */
    function test_Mint() public {
        vm.prank(vault);
        token.mint(user, AMOUNT, INITIAL_RATE);

        assertEq(token.principalBalanceOf(user), AMOUNT, "Principal should equal minted amount");
        assertEq(token.getUserInterestRate(user), INITIAL_RATE, "User rate should be set");
    }

    /**
     * @notice Verify mint sets user's interest rate correctly
     * @dev Tests that user receives current global rate when minting
     */
    function test_MintSetsUserRate() public {
        // Owner decreases global rate
        vm.prank(owner);
        token.setInterestRate(2e10);

        uint256 currentRate = token.getInterestRate();

        // Mint to user at new rate
        vm.prank(vault);
        token.mint(user, AMOUNT, currentRate);

        assertEq(token.getUserInterestRate(user), 2e10, "User should have new rate");
    }

    /**
     * @notice SECURITY TEST: Verify rate downgrade protection
     * @dev This is the key security fix - users cannot have their rate downgraded
     *      by receiving tokens at a lower rate
     */
    function test_MintDoesNotDowngradeRate() public {
        // User gets high rate (5e10)
        vm.prank(vault);
        token.mint(user, AMOUNT, INITIAL_RATE);

        // Global rate drops to 2e10
        vm.prank(owner);
        token.setInterestRate(2e10);

        // Mint more tokens to user at lower rate
        uint256 currentRate = token.getInterestRate();
        vm.prank(vault);
        token.mint(user, 100e18, currentRate);

        // User should KEEP their original high rate (not downgrade to 2e10)
        assertEq(token.getUserInterestRate(user), INITIAL_RATE, "Rate should not downgrade from 5e10 to 2e10");
    }

    /**
     * @notice Verify users CAN receive higher rates
     * @dev Rate can upgrade but not downgrade
     */
    function test_MintAcceptsHigherRate() public {
        // User starts with 5e10 rate
        vm.prank(vault);
        token.mint(user, AMOUNT, 5e10);

        // Mint at higher 10e10 rate
        vm.prank(vault);
        token.mint(user, 100e18, 10e10);

        // Rate should upgrade
        assertEq(token.getUserInterestRate(user), 10e10, "Rate should upgrade to higher rate");
    }

    /**
     * @notice Verify that minting triggers interest minting for existing balance
     * @dev When user mints new tokens, any accrued interest on existing balance
     *      should be minted first (lazy minting pattern)
     */
    function test_MintMintsAccruedInterest() public {
        // Initial mint
        vm.prank(vault);
        token.mint(user, AMOUNT, INITIAL_RATE);
        uint256 userOriginalBalance = token.principalBalanceOf(user);

        // Advance time to accrue interest
        vm.warp(block.timestamp + 3600); // 1 hour

        // Check balance includes interest
        uint256 newBalance = token.balanceOf(user);
        console.log("User balance after 1 hour:", newBalance);

        assertGt(newBalance, userOriginalBalance, "Balance should include accrued interest");
    }

    /*//////////////////////////////////////////////////////////////
                            BURN FUNCTION
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Test basic burn functionality
     * @dev Verifies tokens are burned and balance updates
     */
    function test_Burn() public {
        // Mint tokens
        vm.prank(vault);
        token.mint(user, AMOUNT, INITIAL_RATE);

        // Burn all tokens
        vm.prank(vault);
        token.burn(user, AMOUNT);

        assertEq(token.principalBalanceOf(user), 0, "All tokens should be burned");
    }

    /**
     * @notice Verify burn mints accrued interest before burning
     * @dev Tests the lazy minting pattern: interest is minted before balance change
     */
    function test_BurnMintsAccruedInterestFirst() public {
        // Mint tokens
        vm.prank(vault);
        token.mint(user, AMOUNT, INITIAL_RATE);

        // Accrue interest
        vm.warp(block.timestamp + 3600); // 1 hour
        uint256 balanceWithInterest = token.balanceOf(user);
        console.log("Balance with interest before burn:", balanceWithInterest);

        // Burn only the original principal
        vm.prank(vault);
        token.burn(user, AMOUNT);

        // Remaining balance should be the accrued interest
        uint256 remainingBalance = token.balanceOf(user);
        console.log("Remaining balance after burn:", remainingBalance);

        assertLt(remainingBalance, balanceWithInterest, "Balance should decrease after burn");
        assertGt(remainingBalance, 0, "Interest should remain after burning principal");
    }

    /**
     * @notice Verify burn reverts with insufficient balance
     * @dev Attempting to burn more than balance should fail
     */
    function test_BurnRevertsIfInsufficientBalance() public {
        vm.prank(vault);
        token.mint(user, AMOUNT, INITIAL_RATE);

        // Try to burn more than balance
        vm.expectRevert();
        vm.prank(vault);
        token.burn(user, AMOUNT + 1);
    }

    /*//////////////////////////////////////////////////////////////
                        BALANCE CALCULATIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Verify balanceOf includes accrued interest
     * @dev balanceOf is a view function that calculates interest on-demand
     *      without actually minting (lazy evaluation)
     */
    function test_BalanceOfIncludesInterest() public {
        vm.prank(vault);
        token.mint(user, AMOUNT, INITIAL_RATE);

        // Advance time
        vm.warp(block.timestamp + 3600); // 1 hour

        uint256 balanceWithInterest = token.balanceOf(user);
        console.log("Balance with interest after 1 hour:", balanceWithInterest);

        assertGt(balanceWithInterest, AMOUNT, "Balance should include accrued interest");
    }

    /**
     * @notice Verify balanceOf equals principal immediately after mint
     * @dev When no time has passed, balanceOf should equal principalBalanceOf
     */
    function test_BalanceOfWithZeroTime() public {
        vm.prank(vault);
        token.mint(user, AMOUNT, INITIAL_RATE);

        uint256 balance = token.balanceOf(user);
        uint256 principal = token.principalBalanceOf(user);

        assertEq(balance, principal, "Balance should equal principal with no time elapsed");
        assertEq(balance, AMOUNT, "Balance should equal minted amount immediately");
    }

    /**
     * @notice Verify interest accrues linearly over time
     * @dev Tests that equal time periods produce equal interest (linear formula)
     *      Formula: interest = principal × rate × time
     *      NOT compound: principal × (1 + rate)^time
     */
    function test_InterestAccrualIsLinear() public {
        vm.prank(vault);
        token.mint(user, AMOUNT, INITIAL_RATE);

        uint256 startTime = block.timestamp;

        // First 30 minutes
        vm.warp(startTime + 1800);
        uint256 balanceAfter30Min = token.balanceOf(user);
        uint256 interest30Min = balanceAfter30Min - AMOUNT;

        // Second 30 minutes
        vm.warp(startTime + 3600);
        uint256 balanceAfter60Min = token.balanceOf(user);
        uint256 interest60Min = balanceAfter60Min - balanceAfter30Min;

        console.log("Interest after first 30 min:", interest30Min);
        console.log("Interest after second 30 min:", interest60Min);

        // Both periods should yield approximately equal interest (linear growth)
        // Small tolerance for integer rounding
        assertApproxEqAbs(interest30Min, interest60Min, 1e10, "Interest should accrue linearly");
    }

    /*//////////////////////////////////////////////////////////////
                        TRANSFER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Test basic transfer functionality
     * @dev Verifies tokens move between users and rates are inherited
     */
    function test_Transfer() public {
        vm.prank(vault);
        token.mint(user, AMOUNT, INITIAL_RATE);

        // Transfer half to userTwo
        vm.prank(user);
        token.transfer(userTwo, AMOUNT / 2);

        assertEq(token.balanceOf(userTwo), AMOUNT / 2, "UserTwo should receive tokens");
        assertEq(token.balanceOf(user), AMOUNT / 2, "User should have remaining tokens");

        // UserTwo should inherit sender's rate (since userTwo had 0 balance)
        assertEq(token.getUserInterestRate(userTwo), INITIAL_RATE, "UserTwo should inherit sender's rate");
    }

    /**
     * @notice Verify transferFrom works with approval
     * @dev Tests ERC20 approval mechanism with our custom logic
     */
    function test_TransferFrom() public {
        vm.prank(vault);
        token.mint(user, AMOUNT, INITIAL_RATE);

        // User approves userTwo
        vm.prank(user);
        token.approve(userTwo, AMOUNT / 2);

        // UserTwo transfers from user
        vm.prank(userTwo);
        token.transferFrom(user, userTwo, AMOUNT / 2);

        assertEq(token.balanceOf(userTwo), AMOUNT / 2, "UserTwo should receive tokens");
        assertEq(token.balanceOf(user), AMOUNT / 2, "User should have remaining tokens");
        assertEq(token.getUserInterestRate(userTwo), INITIAL_RATE, "UserTwo should inherit rate");
    }

    /**
     * @notice SECURITY TEST: Verify transfer doesn't overwrite existing rates
     * @dev If recipient already has tokens with a rate, transfer should NOT change it
     *      This prevents griefing where someone sends you low-rate tokens to downgrade you
     */
    function test_TransferDoesNotOverwriteExistingRate() public {
        // User has 5e10 rate
        vm.prank(vault);
        token.mint(user, AMOUNT, INITIAL_RATE);

        // UserTwo has higher 6e10 rate
        vm.prank(vault);
        token.mint(userTwo, AMOUNT, INITIAL_RATE + 1e10);

        // User transfers to userTwo
        vm.prank(user);
        token.transfer(userTwo, AMOUNT / 2);

        // UserTwo should KEEP their higher rate (not downgrade to user's rate)
        assertEq(
            token.getUserInterestRate(userTwo),
            INITIAL_RATE + 1e10,
            "Recipient's existing rate should not be overwritten"
        );
        assertEq(token.getUserInterestRate(user), INITIAL_RATE, "Sender's rate should remain unchanged");
    }

    /*//////////////////////////////////////////////////////////////
                        SET INTEREST RATE
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Test setting global interest rate
     * @dev Only owner can decrease rate
     */
    function test_SetInterestRate() public {
        vm.prank(owner);
        token.setInterestRate(2e10); // Lower than initial 5e10

        assertEq(token.getInterestRate(), 2e10, "Global rate should update");
    }

    /**
     * @notice Verify only owner can set rate
     * @dev Non-owner attempt should revert
     */
    function test_SetInterestRate_NotOwner() public {
        vm.prank(user);
        vm.expectRevert();
        token.setInterestRate(10e10);
    }

    /**
     * @notice SECURITY TEST: Verify rate can only decrease
     * @dev Attempting to increase rate should revert with custom error
     *      This prevents protocol from giving unfair advantages to late depositors
     */
    function test_SetInterestRateRevertsIfHigher() public {
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(RebaseToken.RebaseToken__InterestRateCanOnlyDecrease.selector, INITIAL_RATE, 6e10)
        );
        token.setInterestRate(6e10); // Higher than current 5e10
    }

    /**
     * @notice Verify new deposits get new rate while old users keep old rate
     * @dev This is the core mechanic: early users lock in higher rates
     */
    function test_NewDepositsGetNewRate() public {
        // User deposits at initial rate (5e10)
        vm.prank(vault);
        token.mint(user, AMOUNT, INITIAL_RATE);

        // Owner decreases global rate
        vm.prank(owner);
        token.setInterestRate(2e10);

        uint256 currentRate = token.getInterestRate();

        // UserTwo deposits at new lower rate
        vm.prank(vault);
        token.mint(userTwo, AMOUNT, currentRate);

        // User keeps old high rate, userTwo gets new low rate
        assertEq(token.getUserInterestRate(user), INITIAL_RATE, "Old user keeps original high rate");
        assertEq(token.getUserInterestRate(userTwo), 2e10, "New user gets current lower rate");
    }

    /*//////////////////////////////////////////////////////////////
                            FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Fuzz test: mint and burn random amounts
     * @dev Tests that mint + burn leaves correct remaining balance
     * @param mintAmount Random amount to mint (bounded)
     * @param burnAmount Random amount to burn (bounded to <= mintAmount)
     */
    function testFuzz_MintAndBurn(uint256 mintAmount, uint256 burnAmount) public {
        // Bound inputs to reasonable ranges
        mintAmount = bound(mintAmount, 1e18, 1e24); // 1 to 1 million tokens
        burnAmount = bound(burnAmount, 0, mintAmount); // Can't burn more than minted

        // Mint
        vm.prank(vault);
        token.mint(user, mintAmount, INITIAL_RATE);
        assertEq(token.principalBalanceOf(user), mintAmount);

        // Burn
        vm.prank(vault);
        token.burn(user, burnAmount);
        assertEq(token.principalBalanceOf(user), mintAmount - burnAmount);
    }

    /**
     * @notice Fuzz test: verify interest formula with random inputs
     * @dev Tests the linear interest calculation: balance = principal × (1 + rate × time)
     * @param amount Random principal amount
     * @param timeElapsed Random time period
     */
    function testFuzz_InterestAccrual(uint256 amount, uint256 timeElapsed) public {
        // Bound amount: 1 token to 1 billion tokens
        amount = bound(amount, 1e18, 1e27);

        // Bound time: 1 second to 365 days
        timeElapsed = bound(timeElapsed, 1, 365 days);

        // Mint at initial rate
        vm.prank(vault);
        token.mint(user, amount, INITIAL_RATE);

        uint256 balanceBefore = token.balanceOf(user);
        assertEq(balanceBefore, amount, "Initial balance should equal mint amount");

        // Advance time
        vm.warp(block.timestamp + timeElapsed);

        uint256 balanceAfter = token.balanceOf(user);
        assertGt(balanceAfter, amount, "Balance should increase after time passes");

        // Calculate expected interest using linear formula
        // interest = (principal × rate × time) / PRECISION_FACTOR
        uint256 expectedInterest = (amount * INITIAL_RATE * timeElapsed) / 1e18;
        uint256 expectedBalance = amount + expectedInterest;

        // Allow 1 wei tolerance for rounding errors
        assertApproxEqAbs(balanceAfter, expectedBalance, 1, "Balance should match linear interest formula");
    }
}
