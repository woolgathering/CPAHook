// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { BaseHook, ModifyLiquidityParams, SwapParams, BeforeSwapDelta } from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { Hooks } from "@uniswap/v4-core/src/libraries/Hooks.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { AuctionTypes } from "./AuctionTypes.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title PoolHook
 * @notice Simple hook that blocks all operations when controlled by auction
 * @author Clock-Proxy Auction Team
 */
contract PoolHook is BaseHook, Ownable {
	using PoolIdLibrary for PoolKey;
	
	/// @notice Address of the auction that controls this pool hook
	address public auctionManager;

	/// @notice Auction phase per pool
	mapping(PoolId => AuctionTypes.AuctionPhase) public poolStates;
	
	/// @notice Whether operations are blocked per pool
	mapping(PoolId => bool) public allowedPools;

	/// @notice Error when caller is not the auction
	error OnlyAuction();
	error AuctionOngoing();
	error OnlyOwner();

	/// @notice Events
	event BlockedStateChanged(bool blocked);

	/**
	 * @notice Constructor
	 * @param _poolManager The V4 pool manager
	 */
	constructor(
		IPoolManager _poolManager
	) BaseHook(_poolManager) Ownable(msg.sender) {
	}

	function getAuctionManager() external view returns (address) {
		return auctionManager;
	}

	function setAuctionManager(address _auctionManager) external {
		if (msg.sender != owner()) {
			revert OnlyOwner();
		}
		
		auctionManager = _auctionManager;
	}

	// Removed setPoolAllowed function - consolidated into setPoolState

	/**
	 * @notice Hook that runs before pool initialization
	 */
	function _beforeInitialize(
		address sender,
		PoolKey calldata key,
		uint160 sqrtPriceX96
	) internal override returns (bytes4) {
		// New pools start blocked by default
		allowedPools[key.toId()] = false;
		
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

	// Removed setAuctionState function - consolidated into setPoolState

	/**
	 * @notice Set the pool state (only allows auction manager to call)
	 * @param poolKey The pool key
	 * @param state The auction phase state
	 */
	function setPoolState(PoolKey calldata poolKey, AuctionTypes.AuctionPhase state) external {
		if (msg.sender != auctionManager) {
			revert OnlyAuction();
		}
		
		PoolId poolId = poolKey.toId();
		poolStates[poolId] = state;
		// Only allow trading when auction is in Settlement or Finished phase
		allowedPools[poolId] = (state == AuctionTypes.AuctionPhase.Settlement || state == AuctionTypes.AuctionPhase.Finished);
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
