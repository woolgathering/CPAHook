// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { BaseHook, ModifyLiquidityParams, SwapParams, BeforeSwapDelta } from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { Hooks } from "@uniswap/v4-core/src/libraries/Hooks.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";

/**
 * @title PoolHook
 * @notice Simple hook that blocks all operations when controlled by auction
 * @author Clock-Proxy Auction Team
 */
contract PoolHook is BaseHook {
	/// @notice Address of the auction that controls this pool hook
	address public immutable auction;
	
	/// @notice Whether operations are blocked
	bool public blocked;

	/// @notice Error when caller is not the auction
	error OnlyAuction();
	error OperationsBlocked();

	/// @notice Events
	event BlockedStateChanged(bool blocked);

	/**
	 * @notice Constructor
	 * @param _poolManager The V4 pool manager
	 * @param _auction The auction that controls this pool hook
	 */
	constructor(
		IPoolManager _poolManager,
		address _auction
	) BaseHook(_poolManager) {
		auction = _auction;
	}

	/**
	 * @notice Set blocked state (only callable by auction)
	 * @param _blocked Whether operations should be blocked
	 */
	function setBlocked(bool _blocked) external {
		if (msg.sender != auction) {
			revert OnlyAuction();
		}
		
		blocked = _blocked;
		emit BlockedStateChanged(_blocked);
	}

	/**
	 * @notice Hook that runs before pool initialization
	 */
	function _beforeInitialize(
		address sender,
		PoolKey calldata key,
		uint160 sqrtPriceX96
	) internal view override returns (bytes4) {
		if (blocked) {
			revert OperationsBlocked();
		}
		
		return BaseHook.beforeInitialize.selector;
	}

	/**
	 * @notice Hook that runs before swaps
	 */
	function _beforeSwap(
		address sender,
		PoolKey calldata key,
		SwapParams calldata params,
		bytes calldata hookData
	) internal view override returns (bytes4, BeforeSwapDelta, uint24) {
		if (blocked) {
			revert OperationsBlocked();
		}
		
		return (BaseHook.beforeSwap.selector, BeforeSwapDelta.wrap(0), 0);
	}

	/**
	 * @notice Hook that runs before adding liquidity
	 */
	function _beforeAddLiquidity(
		address sender,
		PoolKey calldata key,
		ModifyLiquidityParams calldata params,
		bytes calldata hookData
	) internal view override returns (bytes4) {
		if (blocked) {
			revert OperationsBlocked();
		}
		
		return BaseHook.beforeAddLiquidity.selector;
	}

	/**
	 * @notice Hook that runs before removing liquidity
	 */
	function _beforeRemoveLiquidity(
		address sender,
		PoolKey calldata key,
		ModifyLiquidityParams calldata params,
		bytes calldata hookData
	) internal view override returns (bytes4) {
		if (blocked) {
			revert OperationsBlocked();
		}
		
		return BaseHook.beforeRemoveLiquidity.selector;
	}

	/**
	 * @notice Hook that runs before donations
	 */
	function _beforeDonate(
		address sender,
		PoolKey calldata key,
		uint256 amount0,
		uint256 amount1,
		bytes calldata hookData
	) internal view override returns (bytes4) {
		if (blocked) {
			revert OperationsBlocked();
		}
		
		return BaseHook.beforeDonate.selector;
	}

	/**
	 * @notice Returns the hook permissions configuration
	 * @return permissions The hook permissions configuration
	 */
	function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
		return Hooks.Permissions({
			beforeInitialize: true,
			afterInitialize: false,
			beforeAddLiquidity: true,
			beforeRemoveLiquidity: true,
			afterAddLiquidity: false,
			afterRemoveLiquidity: false,
			beforeSwap: true,
			afterSwap: false,
			beforeDonate: true,
			afterDonate: false,
			beforeSwapReturnDelta: false,
			afterSwapReturnDelta: false,
			afterAddLiquidityReturnDelta: false,
			afterRemoveLiquidityReturnDelta: false
		});
	}
}
