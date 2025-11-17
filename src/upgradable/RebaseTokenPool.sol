// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Pool} from "@ccip/contracts/src/v0.8/ccip/libraries/Pool.sol";
import {TokenPool} from "@ccip/contracts/src/v0.8/ccip/pools/TokenPool.sol";
import {IERC20} from "@ccip/contracts/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/token/ERC20/IERC20.sol";
import {IRebaseToken} from "src/interfaces/IRebaseToken.sol";

/**
 * @title RebaseTokenPool
 * @author Ali
 * @notice Custom CCIP pool for cross-chain rebase token with rate preservation
 *
 * Design:
 * - Burn & Mint pattern (tokens destroyed on source, created on dest)
 * - Encodes user's interest rate in CCIP message
 * - Preserves rate even if global rate changed
 *
 * CCIP Flow:
 * Source: User → Router (transfer) → Pool.lockOrBurn() → Burn + Encode rate
 * Dest: Router → Pool.releaseOrMint() → Decode rate + Mint
 */
contract RebaseTokenPool is TokenPool {
    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Initialize the token pool
     * @param token The rebase token this pool manages
     * @param allowlist Addresses allowed to bridge (empty = public)
     * @param rmnProxy Risk Management Network proxy
     * @param router CCIP router address
     */
    constructor(IERC20 token, address[] memory allowlist, address rmnProxy, address router)
        TokenPool(token, allowlist, rmnProxy, router)
    {}

    /*//////////////////////////////////////////////////////////////
                          EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Burns tokens on source chain, encodes user rate for CCIP
     * @param lockOrBurnIn CCIP data: sender, amount, destination chain
     * @return lockOrBurnOut Destination token address + encoded rate
     *
     * CCIP Flow Context:
     * 1. User approves Router for tokens
     * 2. User calls router.ccipSend()
     * 3. Router transfers tokens from user to THIS pool
     * 4. Router calls THIS function
     * 5. Pool burns from its own balance (tokens it just received)
     *
     * Why burn from address(this) not originalSender:
     * - Router already did transferFrom(user, pool, amount)
     * - Pool now holds the tokens
     * - Burning from pool is CCIP standard
     * - Alternative (direct burn from user) doesn't work with CCIP Router
     *
     * Why capture rate BEFORE burn:
     * - Need sender's rate at bridge time
     * - Balance will be 0 after burn (but rate mapping persists)
     * - Ensures correct rate travels cross-chain
     */
    function lockOrBurn(Pool.LockOrBurnInV1 calldata lockOrBurnIn)
        external
        virtual
        override
        returns (Pool.LockOrBurnOutV1 memory)
    {
        _validateLockOrBurn(lockOrBurnIn);

        // STEP 1: Capture user's rate (before burn affects balance)
        uint256 userRate = IRebaseToken(address(i_token)).getUserInterestRate(lockOrBurnIn.originalSender);

        // STEP 2: Burn tokens from pool's balance
        // Router already transferred tokens to pool via:
        // IERC20(token).safeTransferFrom(msg.sender, pool, amount)
        IRebaseToken(address(i_token)).burn(
            address(this), // Pool burns from itself, NOT from originalSender
            lockOrBurnIn.amount
        );

        // STEP 3: Return destination info + encoded rate
        return Pool.LockOrBurnOutV1({
            destTokenAddress: getRemoteToken(lockOrBurnIn.remoteChainSelector),
            destPoolData: abi.encode(userRate) // Custom data field for rate preservation
        });
    }

    /**
     * @notice Mints tokens on destination chain with preserved rate
     * @param releaseOrMintIn CCIP data: receiver, amount, source data
     * @return releaseOrMintOut Amount minted
     *
     * CCIP Flow Context:
     * 1. CCIP relayers deliver message from source chain
     * 2. Router on destination receives message
     * 3. Router calls THIS function
     * 4. Pool decodes rate and mints tokens
     *
     * Rate Preservation Logic:
     * The mint() function in RebaseToken handles rate assignment:
     * - Receiver has 0 balance → set rate = decoded rate
     * - Receiver has balance + decoded rate > current → upgrade rate
     * - Receiver has balance + decoded rate < current → keep current (no downgrade)
     *
     * No Interest During Transit:
     * User earns no interest while tokens are bridging (~15 min)
     * - Source: tokens burned (balance = 0)
     * - Destination: tokens not yet minted
     * This is expected behavior for cross-chain transfers
     */
    function releaseOrMint(Pool.ReleaseOrMintInV1 calldata releaseOrMintIn)
        external
        virtual
        override
        returns (Pool.ReleaseOrMintOutV1 memory)
    {
        // STEP 0: Validate input (standard CCIP checks)
        _validateReleaseOrMint(releaseOrMintIn);
        // STEP 1: Extract receiver address
        address receiver = releaseOrMintIn.receiver;

        // STEP 2: Decode user's rate from source chain
        (uint256 userRate) = abi.decode(releaseOrMintIn.sourcePoolData, (uint256));

        // STEP 3: Mint with preserved rate
        // RebaseToken.mint() will handle rate logic internally
        IRebaseToken(address(i_token)).mint(
            receiver,
            releaseOrMintIn.amount,
            userRate // User's rate from source chain
        );
        // STEP 4: Return minted amount
        return Pool.ReleaseOrMintOutV1({destinationAmount: releaseOrMintIn.amount});
    }
}
