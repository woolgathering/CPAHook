// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import { FullMath } from "@uniswap/v4-core/src/libraries/FullMath.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";

/**
 * @title PriceUtils
 * @notice Utility library for retrieving token prices from Uniswap V4 pools
 * @dev IMPORTANT: All prices returned by this library are in 18-decimal precision,
 *      regardless of the numeraire token's actual decimals. This provides consistent
 *      high-precision arithmetic. Calling code must convert to numeraire decimals.
 *      
 *      Formula for value calculation:
 *      value_in_numeraire_decimals = (quantity * price_18decimals * 10^numeraireDecimals) / (10^(18 + assetDecimals))
 *      
 *      Example with 6-decimal numeraire (USDC) and 18-decimal asset:
 *      - quantity = 1000e18 (1000 tokens)
 *      - price = 2e18 (2 units in 18 decimals)
 *      - value = (1000e18 * 2e18 * 1e6) / (1e18 * 1e18) = 2000e6 USDC
 * @author notthatintodefi.eth
 */
library PriceUtils {
    using StateLibrary for IPoolManager;

    /**
     * @notice Get the price of a currency in terms of its pair
     * @dev Returns price in 18-decimal precision for consistent high-precision calculations.
     *      This is NOT in the numeraire's native decimals - calling code must convert.
     * @param manager The pool manager instance
     * @param poolKey The pool key
     * @param currency The currency to get the price for
     * @return price The price in 18-decimal precision (NOT in numeraire decimals)
     */
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

    /**
     * @notice Get the price of currency0 in terms of currency1
     * @dev Returns price in 18-decimal precision. See library documentation for usage.
     * @param manager The pool manager instance
     * @param poolKey The pool key
     * @return price The price in 18-decimal precision
     */
    function getPriceOfCurrency0(
        IPoolManager manager,
        PoolKey memory poolKey
    ) internal view returns (uint256) {
        return getPriceOfCurrency(manager, poolKey, Currency.unwrap(poolKey.currency0));
    }

    /**
     * @notice Get the price of currency1 in terms of currency0
     * @dev Returns price in 18-decimal precision. See library documentation for usage.
     * @param manager The pool manager instance
     * @param poolKey The pool key
     * @return price The price in 18-decimal precision
     */
    function getPriceOfCurrency1(
        IPoolManager manager,
        PoolKey memory poolKey
    ) internal view returns (uint256) {
        return getPriceOfCurrency(manager, poolKey, Currency.unwrap(poolKey.currency1));
    }

    
}