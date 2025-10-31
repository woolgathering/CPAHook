// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";

import { CurrencyDecimals } from "../utils/CurrencyDecimals.sol";
import { PriceUtils } from "../utils/PriceUtils.sol";

/**
 * @title CPAComputationLibrary
 * @notice Shared computation library for CPA system - single source of truth for all calculation functions
 * @dev This library consolidates computation logic used by both phase libraries and integrator utils.
 *      All functions are internal to be callable from external libraries via DELEGATECALL.
 *      Uses optimized implementations with caching for gas efficiency.
 * @author Clock-Proxy Auction Team
 */
library CPAComputationLibrary {
	using PriceUtils for IPoolManager;

	/**
	 * @notice Calculate bid value (accepts calldata demands array)
	 * @param demands Array of demands in calldata
	 * @param numeraire The numeraire currency address
	 * @param poolManager The pool manager instance
	 * @param poolKeys Array of pool keys for the auction
	 * @return totalValue Total value of the bid in numeraire terms
	 * @dev EVM automatically converts calldata to memory when delegating to internal function
	 */
	function calculateBidValue(
		uint256[] calldata demands,
		address numeraire,
		IPoolManager poolManager,
		PoolKey[] memory poolKeys
	) internal view returns (uint256 totalValue) {
		// Delegate to internal implementation (calldata automatically converted to memory)
		return _calculateBidValueInternal(demands, numeraire, poolManager, poolKeys);
	}

	/**
	 * @notice Calculate bid value using memory demands array
	 * @param demands Array of demands in memory
	 * @param numeraire The numeraire currency address
	 * @param poolManager The pool manager instance
	 * @param poolKeys Array of pool keys for the auction
	 * @return totalValue Total value of the bid in numeraire terms
	 * @dev Used when demands are already loaded into memory (e.g., from totalDemands array)
	 */
	function calculateBidValueWithMemoryDemands(
		uint256[] memory demands,
		address numeraire,
		IPoolManager poolManager,
		PoolKey[] memory poolKeys
	) internal view returns (uint256 totalValue) {
		// Delegate to internal implementation
		return _calculateBidValueInternal(demands, numeraire, poolManager, poolKeys);
	}

	/**
	 * @notice Internal implementation for calculating bid value
	 * @param demands Array of demands (works with both calldata and memory)
	 * @param numeraire The numeraire currency address
	 * @param poolManager The pool manager instance
	 * @param poolKeys Array of pool keys for the auction
	 * @return totalValue Total value of the bid in numeraire terms
	 * @dev Consolidated implementation to avoid code duplication. Accepts both calldata and memory arrays.
	 *      Uses optimized caching of numeraire decimals and factor outside loop for gas efficiency.
	 */
	function _calculateBidValueInternal(
		uint256[] memory demands,
		address numeraire,
		IPoolManager poolManager,
		PoolKey[] memory poolKeys
	) private view returns (uint256 totalValue) {
		// Cache numeraire decimals and factor outside loop (gas optimization)
		uint8 numeraireDecimals = CurrencyDecimals.getDecimals(numeraire);
		uint256 numeraireFactor = 10**numeraireDecimals;
		
		// Calculate inner product: sum(demands[i] * prices[i])
		for (uint256 i = 0; i < demands.length && i < poolKeys.length; ) {
			uint256 itemValue;
			{
				(uint256 price, address assetCurrency) = _getPriceAndAssetCurrency(
					poolKeys[i],
					numeraire,
					poolManager
				);
				uint8 assetDecimals = CurrencyDecimals.getDecimals(assetCurrency);
				uint256 divisor = 10**(18 + assetDecimals);
				itemValue = (demands[i] * price * numeraireFactor) / divisor;
			}
			totalValue += itemValue;
			unchecked { ++i; }
		}
	}

	/**
	 * @notice Get price and asset currency for a pool key given common numeraire
	 * @param poolKey The pool key containing both currencies
	 * @param commonNumeraire The address of the common numeraire
	 * @param poolManager The pool manager instance
	 * @return price The current price in 18-decimal precision
	 * @return assetCurrency The currency that is the asset (non-numeraire)
	 * @dev Helper function to determine which currency is asset vs numeraire and get the correct price
	 */
	function _getPriceAndAssetCurrency(
		PoolKey memory poolKey,
		address commonNumeraire,
		IPoolManager poolManager
	) private view returns (uint256 price, address assetCurrency) {
		bool numeraireIsCurrency0 = (Currency.unwrap(poolKey.currency0) == commonNumeraire);
		if (numeraireIsCurrency0) {
			price = poolManager.getPriceOfCurrency1(poolKey);
			assetCurrency = Currency.unwrap(poolKey.currency1);
		} else {
			price = poolManager.getPriceOfCurrency0(poolKey);
			assetCurrency = Currency.unwrap(poolKey.currency0);
		}
	}

	/**
	 * @notice Convert stake amount to bid points
	 * @param stakeAmount The stake amount in numeraire terms
	 * @param numeraire The numeraire currency address
	 * @return bidPoints The equivalent bid points (always in 18 decimals)
	 * @dev Bid points are always in 18 decimals for consistency across different numeraires
	 */
	function computeBidPoints(uint256 stakeAmount, address numeraire) internal view returns (uint256 bidPoints) {
		bidPoints = stakeAmount * 10**18 / (10**CurrencyDecimals.getDecimals(numeraire));
	}

	/**
	 * @notice Get current price of an asset in terms of numeraire
	 * @param poolKey The pool key for the asset/numeraire pair
	 * @param numeraire The numeraire currency address
	 * @param poolManager The pool manager instance
	 * @return price The current price in 18-decimal precision
	 * @dev Prices are always returned in 18-decimal precision for consistency
	 *      Useful for integrators who need to query prices
	 */
	function getCurrentPrice(
		PoolKey memory poolKey,
		address numeraire,
		IPoolManager poolManager
	) internal view returns (uint256 price) {
		(price, ) = _getPriceAndAssetCurrency(poolKey, numeraire, poolManager);
	}
}

