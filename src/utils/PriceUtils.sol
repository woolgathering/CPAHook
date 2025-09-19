// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import { FullMath } from "@uniswap/v4-core/src/libraries/FullMath.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";

    // for use on a pool manager instance
library PriceUtils {
    using StateLibrary for IPoolManager;

    function getPriceOfCurrency(
        IPoolManager manager,
        PoolKey memory poolKey,
        address currency
    ) internal view returns (uint256) {
        // Get sqrtPriceX96 from pool
        (uint160 sqrtPriceX96, , , ) = manager.getSlot0(poolKey.toId());

        // Compute price = (sqrtPriceX96 / 2^96)^2
        // This gives us currency1/currency0
        // Use double WAD (36 decimals) for precision, then convert to 18 decimals
        uint256 priceX192 = uint256(sqrtPriceX96) * uint256(sqrtPriceX96);
        uint256 priceDoubleWad = FullMath.mulDiv(priceX192, 1e36, 1 << 192);
        uint256 price = priceDoubleWad / 1e18; // Convert back to 18 decimals

        if (currency == Currency.unwrap(poolKey.currency0)) {
            // We want currency1 in terms of currency0
            // price = currency1/currency0, so return price directly
            if (price == 0) {
                revert("PriceUtils: price too small to compute accurately");
            }
            return price;
        } else {
            // We want currency0 in terms of currency1
            // price = currency1/currency0, so currency0/currency1 = 1/price
            // Use double WAD precision for inversion, then convert back to 18 decimals
            uint256 invertedPriceDoubleWad = FullMath.mulDiv(1e36, 1e36, priceDoubleWad);
            uint256 invertedPrice = invertedPriceDoubleWad / 1e18; // Convert back to 18 decimals
            if (invertedPrice == 0) {
                revert("PriceUtils: inverted price too small to compute accurately");
            }
            return invertedPrice;
        }
    }

    function getPriceOfCurrency0(
        IPoolManager manager,
        PoolKey memory poolKey
    ) internal view returns (uint256) {
        return getPriceOfCurrency(manager, poolKey, Currency.unwrap(poolKey.currency0));
    }

    function getPriceOfCurrency1(
        IPoolManager manager,
        PoolKey memory poolKey
    ) internal view returns (uint256) {
        return getPriceOfCurrency(manager, poolKey, Currency.unwrap(poolKey.currency1));
    }

    
}