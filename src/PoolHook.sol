// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { BaseHook, ModifyLiquidityParams, SwapParams, BeforeSwapDelta } from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { Hooks } from "@uniswap/v4-core/src/libraries/Hooks.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { AuctionTypes } from "./AuctionTypes.sol";

/**
 * @title PoolHook
 * @notice Simple hook that blocks all operations when controlled by auction
 * @author Clock-Proxy Auction Team
 */
contract PoolHook is BaseHook {
	using PoolIdLibrary for PoolKey;
	
	/// @notice Address of the auction that controls this pool hook
	address public immutable auctionManager;

	/// @notice Auction phase per pool
	mapping(PoolId => AuctionTypes.AuctionPhase) public poolStates;
	
	/// @notice Whether operations are blocked per pool
	mapping(PoolId => bool) public allowedPools;

	/// @notice Error when caller is not the auction
	error OnlyAuction();
	error AuctionOngoing();

	/// @notice Events
	event BlockedStateChanged(bool blocked);

	/**
	 * @notice Constructor
	 * @param _poolManager The V4 pool manager
	 */
	constructor(
		IPoolManager _poolManager,
		address _auctionManager
	) BaseHook(_poolManager) {
		auctionManager = _auctionManager;
	}

	/**
	 * @notice Set whether a pool is allowed to be used
	 * @param key The pool key
	 * @param allowed Whether the pool is allowed to be used
	 */
	function setPoolAllowed(PoolKey calldata key, bool allowed) external {
		if (msg.sender != auctionManager) {
			revert OnlyAuction();
		}
		
		allowedPools[key.toId()] = allowed;
	}

	/**
	 * @notice Hook that runs before pool initialization
	 */
	function _beforeInitialize(
		address sender,
		PoolKey calldata key,
		uint160 sqrtPriceX96
	) internal override returns (bytes4) {
		allowedPools[key.toId()] = false; // make sure it's set to false (not necessary??)
		
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
		if (!allowedPools[key.toId()]) {
			revert AuctionOngoing();
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
		if (!allowedPools[key.toId()]) {
			revert AuctionOngoing();
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
		if (!allowedPools[key.toId()]) {
			revert AuctionOngoing();
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
		if (!allowedPools[key.toId()]) {
			revert AuctionOngoing();
		}
		
		return BaseHook.beforeDonate.selector;
	}

	/**
	 * @notice Set the auction state for a specific pool
	 * @param poolKey The pool key
	 * @param phase The auction phase
	 * @param paused Whether the auction is paused
	 * @param cancelled Whether the auction is cancelled
	 */
	function setAuctionState(
		PoolKey calldata poolKey, 
		AuctionTypes.AuctionPhase phase, 
		bool paused, 
		bool cancelled
	) external {
		if (msg.sender != auctionManager) {
			revert OnlyAuction();
		}
		
		PoolId poolId = poolKey.toId();
		poolStates[poolId] = phase;
		// Update allowed state based on phase and pause/cancel status
		allowedPools[poolId] = (phase == AuctionTypes.AuctionPhase.Settlement) && !paused && !cancelled;
	}

	/**
	 * @notice Set the pool state (only allows ClockProxyAuctionHook to call)
	 * @param poolKey The pool key
	 * @param state The auction phase state
	 */
	function setPoolState(PoolKey calldata poolKey, AuctionTypes.AuctionPhase state) external {
		if (msg.sender != auctionManager) {
			revert OnlyAuction();
		}
		
		PoolId poolId = poolKey.toId();
		poolStates[poolId] = state;
		// Only allow trading when auction is in Settlement phase
		allowedPools[poolId] = (state == AuctionTypes.AuctionPhase.Settlement);
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
