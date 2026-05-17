// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";

import { CurrencyDecimals } from "../utils/CurrencyDecimals.sol";
import { PriceUtils } from "../utils/PriceUtils.sol";

library CPAComputationLibrary {
	using PriceUtils for IPoolManager;

	function calculateBidValue(
		uint256[] calldata demands,
		address numeraire,
		IPoolManager poolManager,
		PoolKey[] memory poolKeys,
		address mathFacetAddr
	) internal view returns (uint256 totalValue) {
		return _calculateBidValueInternal(demands, numeraire, poolManager, poolKeys, mathFacetAddr);
	}

	function calculateBidValueWithMemoryDemands(
		uint256[] memory demands,
		address numeraire,
		IPoolManager poolManager,
		PoolKey[] memory poolKeys,
		address mathFacetAddr
	) internal view returns (uint256 totalValue) {
		return _calculateBidValueInternal(demands, numeraire, poolManager, poolKeys, mathFacetAddr);
	}

	function _calculateBidValueInternal(
		uint256[] memory demands,
		address numeraire,
		IPoolManager poolManager,
		PoolKey[] memory poolKeys,
		address mathFacetAddr
	) private view returns (uint256 totalValue) {
		uint8 numeraireDecimals = CurrencyDecimals.getDecimals(numeraire);
		uint256 numeraireFactor = 10**numeraireDecimals;

		for (uint256 i = 0; i < demands.length && i < poolKeys.length; ) {
			uint256 itemValue;
			{
				(uint256 price, address assetCurrency) = _getPriceAndAssetCurrency(
					poolKeys[i],
					numeraire,
					poolManager,
					mathFacetAddr
				);
				uint8 assetDecimals = CurrencyDecimals.getDecimals(assetCurrency);
				uint256 divisor = 10**(18 + assetDecimals);
				itemValue = (demands[i] * price * numeraireFactor) / divisor;
			}
			totalValue += itemValue;
			unchecked { ++i; }
		}
	}

	function _getPriceAndAssetCurrency(
		PoolKey memory poolKey,
		address commonNumeraire,
		IPoolManager poolManager,
		address mathFacetAddr
	) private view returns (uint256 price, address assetCurrency) {
		bool numeraireIsCurrency0 = (Currency.unwrap(poolKey.currency0) == commonNumeraire);
		if (numeraireIsCurrency0) {
			price = poolManager.getPriceOfCurrency1(poolKey, mathFacetAddr);
			assetCurrency = Currency.unwrap(poolKey.currency1);
		} else {
			price = poolManager.getPriceOfCurrency0(poolKey, mathFacetAddr);
			assetCurrency = Currency.unwrap(poolKey.currency0);
		}
	}

	function computeBidPoints(uint256 stakeAmount, address numeraire) internal view returns (uint256 bidPoints) {
		bidPoints = stakeAmount * 10**18 / (10**CurrencyDecimals.getDecimals(numeraire));
	}

	function getCurrentPrice(
		PoolKey memory poolKey,
		address numeraire,
		IPoolManager poolManager,
		address mathFacetAddr
	) internal view returns (uint256 price) {
		(price, ) = _getPriceAndAssetCurrency(poolKey, numeraire, poolManager, mathFacetAddr);
	}
}
