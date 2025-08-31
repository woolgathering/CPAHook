// SPDX-License-Identifier: MIT
// OpenZeppelin Uniswap Hooks (last updated v0.1.0) (src/base/BaseCustomAccounting.sol)

pragma solidity ^0.8.24;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {CurrencySettler} from "@openzeppelin/uniswap-hooks/src/utils/CurrencySettler.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHookEvents} from "@openzeppelin/uniswap-hooks/src/interfaces/IHookEvents.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/**
 * @dev Base implementation for custom accounting and hook-owned liquidity.
 *
 * To enable hook-owned liquidity, tokens must be deposited via the hook to allow control and flexibility
 * over the liquidity. The implementation inheriting this hook must implement the respective functions
 * to calculate the liquidity modification parameters and the amount of liquidity shares to mint or burn.
 *
 * Additionally, the implementer must consider that the hook is the sole owner of the liquidity and
 * manage fees over liquidity shares accordingly.
 *
 * NOTE: This base hook is designed to work with a single pool key. If you want to use the same custom
 * accounting hook for multiple pools, you must have multiple storage instances of this contract and
 * initialize them via the `PoolManager` with their respective pool keys.
 *
 * WARNING: This is experimental software and is provided on an "as is" and "as available" basis. We do
 * not give any warranties and will not be liable for any losses incurred through any use of this code
 * base.
 *
 * _Available since v0.1.0_
 */
abstract contract CPABaseCustomAccounting is BaseHook, IHookEvents, IUnlockCallback {
    using CurrencySettler for Currency;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    /**
     * @dev A liquidity modification order was attempted to be executed after the deadline.
     */
    error ExpiredPastDeadline();

    /**
     * @dev Pool was not initialized.
     */
    error PoolNotInitialized();

    /**
     * @dev Principal delta of liquidity modification resulted in too much slippage.
     */
    error TooMuchSlippage();

    /**
     * @dev Liquidity was attempted to be added or removed via the `PoolManager` instead of the hook.
     */
    error AuctionNotFinished();

    /**
     * @dev Native currency was not sent with the correct amount.
     */
    error InvalidNativeValue();

    /**
     * @dev Hook was already initialized.
     */
    error AlreadyInitialized();

    struct AddLiquidityAsBidParams {
        uint256 amountStake;
        uint256 deadline;
        bytes32 demands;
        bytes32 userInputSalt;
    }

    struct RemoveLiquidityAsBidParams {
        uint256 liquidity;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
        int24 tickLower;
        int24 tickUpper;
        bytes32 userInputSalt;
    }

    struct CallbackData {
        address sender;
        ModifyLiquidityParams params;
    }

    // are the non-auction hooks allowed to trade yet?
    mapping(PoolId => bool) public allowedPools;

    /**
     * @dev Ensure the deadline of a liquidity modification request is not expired.
     *
     * @param deadline Deadline of the request, passed in by the caller.
     */
    modifier ensure(uint256 deadline) {
        if (deadline < block.timestamp) revert ExpiredPastDeadline();
        _;
    }

    /**
     * @dev Set the pool `PoolManager` address.
     */
    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {
    }

    /**
     * @notice Adds liquidity to the hook's pool.
     *
     * @dev To cover all possible scenarios, `msg.sender` should have already given the hook an allowance
     * of at least amount0Desired/amount1Desired on token0/token1. Always adds assets at the ideal ratio,
     * according to the price when the transaction is executed.
     *
     * NOTE: The `amount0Min` and `amount1Min` parameters are relative to the principal delta, which excludes
     * fees accrued from the liquidity modification delta.
     *
     * @param params The parameters for the liquidity addition.
     * @return delta The principal delta of the liquidity addition.
     */
    function addLiquidityAsBid(AddLiquidityAsBidParams calldata params)
        external
        payable
        virtual
        ensure(params.deadline)
        returns (BalanceDelta delta)
    {
        // This function is not used in the auction hook context
        revert("Not yet implemented");

        // Get the liquidity modification parameters and the amount of liquidity shares to mint
        // (bytes memory modifyParams, uint256 shares) = _getAddLiquidity(sqrtPriceX96, params);

        // Apply the liquidity modification
        // (BalanceDelta callerDelta, BalanceDelta feesAccrued) = _modifyLiquidity(modifyParams);

        // Mint the liquidity shares to sender
        // _mint(params, callerDelta, feesAccrued, shares);

        // Get the principal delta by subtracting the fee delta from the caller delta (-= is not supported)
        // delta = callerDelta - feesAccrued;

        // // Check for slippage on principal delta
        // uint128 amount0 = uint128(-delta.amount0());
        // if (amount0 < params.amount0Min || uint128(-delta.amount1()) < params.amount1Min) {
        //     revert TooMuchSlippage();
        // }

        // // If the currency0 is native, refund any remaining msg.value that wasn't used based on the principal delta
        // if (isNative) {
        //     // Check that delta amount was covered by msg.value given that settle would be valid if hook can pay for difference
        //     // It also allows users to provide more native value than the desired amount
        //     if (msg.value < amount0) revert InvalidNativeValue();

        //     // Previous check prevents underflow revert
        //     poolKey.currency0.transfer(msg.sender, msg.value - amount0);
        // }
        return (BalanceDeltaLibrary.ZERO_DELTA);
    }

    /**
     * @notice Removes liquidity from the hook's pool.
     *
     * NOTE: The `amount0Min` and `amount1Min` parameters are relative to the principal delta, which
     * excludes fees accrued from the liquidity modification delta.
     *
     * @param params The parameters for the liquidity removal.
     * @return delta The principal delta of the liquidity removal.
     */
    function removeLiquidityAsBid(RemoveLiquidityAsBidParams calldata params)
        external
        virtual
        ensure(params.deadline)
        returns (BalanceDelta delta)
    {
        // This function is not used in the auction hook context
        revert("Not yet implemented");

        // Get the liquidity modification parameters and the amount of liquidity shares to burn
        (bytes memory modifyParams, uint256 shares) = _getRemoveLiquidity(params);

        // Apply the liquidity modification
        (BalanceDelta callerDelta, BalanceDelta feesAccrued) = _modifyLiquidity(modifyParams);

        // Burn the liquidity shares from the sender
        _burn(params, callerDelta, feesAccrued, shares);

        // Get the principal delta by subtracting the fee delta from the caller delta (-= is not supported)
        delta = callerDelta - feesAccrued;

        // Check for slippage
        if (uint128(delta.amount0()) < params.amount0Min || uint128(delta.amount1()) < params.amount1Min) {
            revert TooMuchSlippage();
        }
    }

    /**
     * @dev Calls the `PoolManager` to unlock and call back the hook's `unlockCallback` function.
     *
     * @param params The encoded parameters for the liquidity modification based on the `ModifyLiquidityParams` struct.
     * @return callerDelta The balance delta from the liquidity modification. This is the total of both principal and fee deltas.
     * @return feesAccrued The balance delta of the fees generated in the liquidity range.
     */
    // slither-disable-next-line dead-code
    function _modifyLiquidity(bytes memory params)
        internal
        virtual
        returns (BalanceDelta callerDelta, BalanceDelta feesAccrued)
    {
        (callerDelta, feesAccrued) = abi.decode(
            poolManager.unlock(abi.encode(CallbackData(msg.sender, abi.decode(params, (ModifyLiquidityParams))))),
            (BalanceDelta, BalanceDelta)
        );
    }

    /**
     * @dev Callback from the `PoolManager` when liquidity is modified, either adding or removing.
     *
     * @param rawData The encoded `CallbackData` struct.
     * @return returnData The encoded caller and fees accrued deltas.
     */
    function unlockCallback(bytes calldata rawData)
        external
        virtual
        override
        onlyPoolManager
        returns (bytes memory returnData)
    {
        // This will be overridden in ClockProxyAuctionHook
        revert("Not yet implemented");
    }

    /**
     * @dev Handle bid as liquidity add operation
     * @param operationData The encoded operation data
     * @return returnData The encoded balance deltas
     */
    function _handleBidAsLiquidity(bytes memory operationData) internal virtual returns (bytes memory returnData) {
        // This will be implemented in the derived contract
        revert("Not yet implemented");
    }



    /**
     * @dev Handle any fees accrued in a liquidity position. This function is now virtual and should be overridden
     * in derived contracts to handle fees according to the specific operation type.
     *
     * @param poolKey The pool key for the operation
     * @param sender The sender of the operation
     * @param feesAccrued The balance delta of the fees generated in the liquidity range.
     */
    function _handleAccruedFees(PoolKey memory poolKey, address sender, BalanceDelta feesAccrued)
        internal
        virtual
    {
        // Send any accrued fees to the sender
        poolKey.currency0.take(poolManager, sender, uint256(int256(feesAccrued.amount0())), false);
        poolKey.currency1.take(poolManager, sender, uint256(int256(feesAccrued.amount1())), false);
    }

    /**
     * @dev Get the liquidity modification to apply for a given liquidity addition,
     * and the amount of liquidity shares would be minted to the sender.
     *
     * @param sqrtPriceX96 The current square root price of the pool.
     * @param params The parameters for the liquidity addition.
     * @return modify The encoded parameters for the liquidity addition, which must follow the
     * same encoding structure as in `_getRemoveLiquidity` and `_modifyLiquidity`.
     * @return shares The liquidity shares to mint.
     *
     * IMPORTANT: The salt returned in `modify` indicates which position of the sender the liquidity
     * modification is applied given that the `unlockCallback` function uses the keccak256 hash of
     * the sender and the salt returned here to determine the liquidity position. By default, we
     * recommend using the `userInputSalt` parameter from the `AddLiquidityAsBidParams` struct as the salt
     * here.
     */
    function _getAddLiquidity(uint160 sqrtPriceX96, AddLiquidityAsBidParams memory params)
        internal
        virtual
        returns (bytes memory modify, uint256 shares);

    /**
     * @dev Get the liquidity modification to apply for a given liquidity removal,
     * and the amount of liquidity shares would be burned from the sender.
     *
     * @param params The parameters for the liquidity removal.
     * @return modify The encoded parameters for the liquidity removal, which must follow the
     * same encoding structure as in `_getAddLiquidity` and `_modifyLiquidity`.
     * @return shares The liquidity shares to burn.
     *
     * IMPORTANT: The salt returned in `modify` indicates which position of the sender the liquidity
     * modification is applied given that the `unlockCallback` function uses the keccak256 hash of
     * the sender and the salt returned here to determine the liquidity position. By default, we
     * recommend using the `userInputSalt` parameter from the `AddLiquidityAsBidParams` struct as the salt
     * here.
     */
    function _getRemoveLiquidity(RemoveLiquidityAsBidParams memory params)
        internal
        virtual
        returns (bytes memory modify, uint256 shares);

    /**
     * @dev Mint liquidity shares to the sender.
     *
     * @param params The parameters for the liquidity addition.
     * @param callerDelta The balance delta from the liquidity addition. This is the total of both principal and fee delta.
     * @param feesAccrued The balance delta of the fees generated in the liquidity range.
     * @param shares The liquidity shares to mint.
     */
    function _mint(AddLiquidityAsBidParams memory params, BalanceDelta callerDelta, BalanceDelta feesAccrued, uint256 shares)
        internal
        virtual;

    /**
     * @dev Burn liquidity shares from the sender.
     *
     * @param params The parameters for the liquidity removal.
     * @param callerDelta The balance delta from the liquidity removal. This is the total of both principal and fee delta.
     * @param feesAccrued The balance delta of the fees generated in the liquidity range.
     * @param shares The liquidity shares to burn.
     */
    function _burn(
        RemoveLiquidityAsBidParams memory params,
        BalanceDelta callerDelta,
        BalanceDelta feesAccrued,
        uint256 shares
    ) internal virtual;

    /**
     * @dev Set the hook permissions, specifically `beforeInitialize`, `beforeAddLiquidity` and `beforeRemoveLiquidity`.
     *
     * @return permissions The hook permissions.
     */
    function getHookPermissions() public pure virtual override returns (Hooks.Permissions memory permissions) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: true,
            beforeRemoveLiquidity: true,
            afterAddLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }
}
