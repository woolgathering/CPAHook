// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "@v4-core/types/PoolId.sol";
import { AuctionTypes } from "./AuctionTypes.sol";
import { ClockProxyAuctionHook } from "./ClockProxyAuctionHook.sol";
import { PoolHook } from "./PoolHook.sol";

/**
 * @title ClockProxyFactory
 * @notice Factory for deploying complete clock-proxy auction systems
 * @author Clock-Proxy Auction Team
 */
contract ClockProxyFactory {
	using PoolIdLibrary for PoolKey;

	/// @notice V4 Pool Manager
	IPoolManager public immutable poolManager;
	
	/// @notice Deployed auctions
	AuctionInfo[] public deployedAuctions;
	
	/// @notice Mapping from auction address to auction info
	mapping(address => uint256) public auctionIndex;

	/// @notice Auction information structure
	struct AuctionInfo {
		address auctionHook;
		address owner;
		address commonNumeraire;
		address[] poolHooks;
		address[] pools;
		uint256 deploymentTime;
		bool active;
	}

	/// @notice Events
	event AuctionDeployed(
		address indexed auctionHook,
		address indexed owner,
		address commonNumeraire,
		uint256 poolCount,
		uint256 auctionIndex
	);
	event PoolHookDeployed(address indexed poolHook, address indexed auctionHook);
	event PoolDeployed(address indexed pool, address indexed poolHook);

	/// @notice Errors
	error InvalidConfiguration();
	error PoolDeploymentFailed();
	error HookDeploymentFailed();
	error InvalidNumeraire();

	/**
	 * @notice Constructor
	 * @param _poolManager The V4 pool manager
	 */
	constructor(IPoolManager _poolManager) {
		poolManager = _poolManager;
	}

	/**
	 * @notice Deploy a complete clock-proxy auction system
	 * @param owner The auction owner
	 * @param commonNumeraire The common numeraire token (Y token)
	 * @param config The auction configuration
	 * @param poolConfigs Array of pool configurations
	 * @return auctionHook The deployed auction hook address
	 * @return poolHooks Array of deployed pool hook addresses
	 * @return pools Array of deployed pool addresses
	 */
	function deployAuction(
		address owner,
		address commonNumeraire,
		AuctionTypes.AuctionConfig calldata config,
		PoolConfig[] calldata poolConfigs
	) external returns (
		address auctionHook,
		address[] memory poolHooks,
		address[] memory pools
	) {
		// Validate configuration
		if (owner == address(0) || commonNumeraire == address(0)) {
			revert InvalidConfiguration();
		}
		
		if (poolConfigs.length == 0) {
			revert InvalidConfiguration();
		}

		// Deploy auction hook
		auctionHook = _deployAuctionHook(owner, commonNumeraire, config);
		
		// Deploy pool hooks and pools
		poolHooks = new address[](poolConfigs.length);
		pools = new address[](poolConfigs.length);
		
		for (uint256 i = 0; i < poolConfigs.length; i++) {
			// Deploy pool hook
			poolHooks[i] = _deployPoolHook(auctionHook);
			
			// Deploy pool
			pools[i] = _deployPool(poolConfigs[i], poolHooks[i]);
			
			// Add pool to auction hook
			ClockProxyAuctionHook(auctionHook).addPool(
				pools[i],
				poolHooks[i],
				poolConfigs[i].token0,
				poolConfigs[i].token1,
				poolConfigs[i].depositAmount
			);
		}
		
		// Add initial liquidity to pools
		_addInitialLiquidity(pools, poolConfigs, auctionHook);
		
		// Record auction deployment
		_recordAuctionDeployment(auctionHook, owner, commonNumeraire, poolHooks, pools);
		
		emit AuctionDeployed(auctionHook, owner, commonNumeraire, poolConfigs.length, deployedAuctions.length - 1);
	}

	/**
	 * @notice Get all deployed auctions
	 * @return auctions Array of auction information
	 */
	function getDeployedAuctions() external view returns (AuctionInfo[] memory auctions) {
		return deployedAuctions;
	}

	/**
	 * @notice Get auction information by index
	 * @param index The auction index
	 * @return auctionInfo The auction information
	 */
	function getAuctionInfo(uint256 index) external view returns (AuctionInfo memory auctionInfo) {
		if (index >= deployedAuctions.length) {
			revert("Auction not found");
		}
		return deployedAuctions[index];
	}

	/**
	 * @notice Get auction information by address
	 * @param auctionHook The auction hook address
	 * @return auctionInfo The auction information
	 */
	function getAuctionInfoByAddress(address auctionHook) external view returns (AuctionInfo memory auctionInfo) {
		uint256 index = auctionIndex[auctionHook];
		if (index == 0 && deployedAuctions.length == 0) {
			revert("Auction not found");
		}
		return deployedAuctions[index];
	}

	// Internal functions

	/**
	 * @notice Deploy auction hook
	 * @param owner The auction owner
	 * @param commonNumeraire The common numeraire token
	 * @param config The auction configuration
	 * @return auctionHook The deployed auction hook address
	 */
	function _deployAuctionHook(
		address owner,
		address commonNumeraire,
		AuctionTypes.AuctionConfig memory config
	) internal returns (address auctionHook) {
		auctionHook = address(new ClockProxyAuctionHook(
			poolManager,
			owner,
			commonNumeraire,
			config
		));
		
		if (auctionHook == address(0)) {
			revert HookDeploymentFailed();
		}
	}

	/**
	 * @notice Deploy pool hook
	 * @param auctionHook The auction hook address
	 * @return poolHook The deployed pool hook address
	 */
	function _deployPoolHook(address auctionHook) internal returns (address poolHook) {
		poolHook = address(new PoolHook(poolManager, auctionHook));
		
		if (poolHook == address(0)) {
			revert HookDeploymentFailed();
		}
		
		emit PoolHookDeployed(poolHook, auctionHook);
	}

	/**
	 * @notice Deploy V4 pool
	 * @param poolConfig The pool configuration
	 * @param poolHook The pool hook address
	 * @return pool The deployed pool address
	 */
	function _deployPool(
		PoolConfig memory poolConfig,
		address poolHook
	) internal returns (address pool) {
		// Create pool key
		PoolKey memory key = PoolKey({
			currency0: poolConfig.token0 < poolConfig.token1 ? 
				Currency.wrap(poolConfig.token0) : Currency.wrap(poolConfig.token1),
			currency1: poolConfig.token0 < poolConfig.token1 ? 
				Currency.wrap(poolConfig.token1) : Currency.wrap(poolConfig.token0),
			fee: poolConfig.fee,
			tickSpacing: poolConfig.tickSpacing,
			hooks: IHooks(poolHook)
		});
		
		// Initialize pool
		poolManager.initialize(key, poolConfig.sqrtPriceX96);
		
		// Get pool address (in V4, pools are identified by their key)
		pool = address(uint160(uint256(key.toId())));
		
		emit PoolDeployed(pool, poolHook);
	}

	/**
	 * @notice Add initial liquidity to pools
	 * @param pools Array of pool addresses
	 * @param poolConfigs Array of pool configurations
	 * @param auctionHook The auction hook address
	 */
	function _addInitialLiquidity(
		address[] memory pools,
		PoolConfig[] memory poolConfigs,
		address auctionHook
	) internal {
		// This would add initial liquidity to each pool
		// Implementation depends on the specific liquidity management strategy
		// For now, this is a placeholder
	}

	/**
	 * @notice Record auction deployment
	 * @param auctionHook The auction hook address
	 * @param owner The auction owner
	 * @param commonNumeraire The common numeraire token
	 * @param poolHooks Array of pool hook addresses
	 * @param pools Array of pool addresses
	 */
	function _recordAuctionDeployment(
		address auctionHook,
		address owner,
		address commonNumeraire,
		address[] memory poolHooks,
		address[] memory pools
	) internal {
		AuctionInfo memory auctionInfo = AuctionInfo({
			auctionHook: auctionHook,
			owner: owner,
			commonNumeraire: commonNumeraire,
			poolHooks: poolHooks,
			pools: pools,
			deploymentTime: block.timestamp,
			active: true
		});
		
		deployedAuctions.push(auctionInfo);
		auctionIndex[auctionHook] = deployedAuctions.length - 1;
	}
}

/**
 * @title PoolConfig
 * @notice Configuration for pool deployment
 */
struct PoolConfig {
	address token0;
	address token1;
	uint24 fee;
	int24 tickSpacing;
	uint160 sqrtPriceX96;
	uint256 depositAmount;
}
