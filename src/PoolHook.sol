// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { BaseHook, ModifyLiquidityParams, SwapParams } from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { Hooks } from "@uniswap/v4-core/src/libraries/Hooks.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";

// import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";


/**
 * @title PoolHook
 * @notice Simple hook that blocks trading and liquidity operations during auction
 * @author Clock-Proxy Auction Team
 */
contract PoolHook is BaseHook {
	/// @notice Address of the auction hook that controls this pool hook
	address public immutable auctionHook;
	
	/// @notice Whether the auction is currently active
	bool public auctionActive;
	
	/// @notice Whether the auction is paused
	bool public auctionPaused;
	
	/// @notice Whether the auction is cancelled
	bool public auctionCancelled;

	/// @notice Error when caller is not the auction hook
	error OnlyAuctionHook();
	error AuctionActive();
	error AuctionPaused();
	error AuctionCancelled();

	/// @notice Events
	event AuctionStateChanged(bool active, bool paused, bool cancelled);
	event PoolHookInitialized(address auctionHook);

	/**
	 * @notice Constructor
	 * @param _poolManager The V4 pool manager
	 * @param _auctionHook The auction hook that controls this pool hook
	 */
	constructor(
		IPoolManager _poolManager,
		address _auctionHook
	) BaseHook(_poolManager) {
		auctionHook = _auctionHook;
		emit PoolHookInitialized(_auctionHook);
	}

	/**
	 * @notice Set auction state (only callable by auction hook)
	 * @param _active Whether auction is active
	 * @param _paused Whether auction is paused
	 * @param _cancelled Whether auction is cancelled
	 */
	function setAuctionState(
		bool _active,
		bool _paused,
		bool _cancelled
	) external {
		if (msg.sender != auctionHook) {
			revert OnlyAuctionHook();
		}
		
		auctionActive = _active;
		auctionPaused = _paused;
		auctionCancelled = _cancelled;
		
		emit AuctionStateChanged(_active, _paused, _cancelled);
	}

	/**
	 * @notice Check if operations should be blocked
	 * @return blocked True if operations should be blocked
	 */
	function _isBlocked() internal view returns (bool blocked) {
		return auctionActive || auctionPaused || auctionCancelled;
	}

	/**
	 * @notice Hook that runs before pool initialization
	 * @param sender Address of the caller
	 * @param key Pool key containing pool parameters
	 * @param sqrtPriceX96 Initial sqrt price of the pool
	 * @return selector The hook selector
	 */
	function _beforeInitialize(
		address sender,
		PoolKey calldata key,
		uint160 sqrtPriceX96
	) internal view override returns (bytes4) {
		// Allow initialization only if auction is not active
		if (_isBlocked()) {
			revert AuctionActive();
		}
		
		return BaseHook.beforeInitialize.selector;
	}

	/**
	 * @notice Hook that runs before swa
	 */
	// function _beforeSwap(
	// 	address sender,
	// 	PoolKey calldata key,
	// 	SwapParams calldata params,
	// 	bytes calldata hookData
	// ) internal view override returns (bytes4) {
	// 	if (_isBlocked()) {
	// 		if (auctionActive) revert AuctionActive();
	// 		if (auctionPaused) revert AuctionPaused();
	// 		if (auctionCancelled) revert AuctionCancelled();
	// 	}
		
	// 	return BaseHook.beforeSwap.selector;
	// }

	/**
	 * @notice Hook that runs before adding liquidity
	 */
	function _beforeAddLiquidity(
		address sender,
		PoolKey calldata key,
		ModifyLiquidityParams calldata params,
		bytes calldata hookData
	) internal view override returns (bytes4) {
		if (_isBlocked()) {
			if (auctionActive) revert AuctionActive();
			if (auctionPaused) revert AuctionPaused();
			if (auctionCancelled) revert AuctionCancelled();
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
		if (_isBlocked()) {
			if (auctionActive) revert AuctionActive();
			if (auctionPaused) revert AuctionPaused();
			if (auctionCancelled) revert AuctionCancelled();
		}
		
		return BaseHook.beforeRemoveLiquidity.selector;
	}

	/**
	 * @notice Hook that runs before donations
	 * @param sender Address of the caller
	 * @param key Pool key containing pool parameters
	 * @param amount0 The amount of token0 to donate
	 * @param amount1 The amount of token1 to donate
	 * @param hookData Additional data for the hook
	 * @return selector The hook selector
	 */
	function _beforeDonate(
		address sender,
		PoolKey calldata key,
		uint256 amount0,
		uint256 amount1,
		bytes calldata hookData
	) internal view override returns (bytes4) {
		if (_isBlocked()) {
			if (auctionActive) revert AuctionActive();
			if (auctionPaused) revert AuctionPaused();
			if (auctionCancelled) revert AuctionCancelled();
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
