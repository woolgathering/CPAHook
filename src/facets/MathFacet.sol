// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { LiquidityAmounts } from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import { FullMath } from "@uniswap/v4-core/src/libraries/FullMath.sol";
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { PoolId } from "@uniswap/v4-core/src/types/PoolId.sol";
import { IERC20 } from "forge-std/interfaces/IERC20.sol";

contract MathFacet {
    using StateLibrary for IPoolManager;

    function getTickAtSqrtPrice(uint160 sqrtPriceX96) external pure returns (int24) {
        return TickMath.getTickAtSqrtPrice(sqrtPriceX96);
    }

    function getSqrtPriceAtTick(int24 tick) external pure returns (uint160) {
        return TickMath.getSqrtPriceAtTick(tick);
    }

    function getLiquidityForAmount0(uint160 sqrtRatioAx96, uint160 sqrtRatioBx96, uint256 amount0) external pure returns (uint128) {
        return LiquidityAmounts.getLiquidityForAmount0(sqrtRatioAx96, sqrtRatioBx96, amount0);
    }

    function getLiquidityForAmount1(uint160 sqrtRatioAx96, uint160 sqrtRatioBx96, uint256 amount1) external pure returns (uint128) {
        return LiquidityAmounts.getLiquidityForAmount1(sqrtRatioAx96, sqrtRatioBx96, amount1);
    }

    function mulDiv(uint256 a, uint256 b, uint256 denominator) external pure returns (uint256) {
        return FullMath.mulDiv(a, b, denominator);
    }

    function mulDivRoundingUp(uint256 a, uint256 b, uint256 denominator) external pure returns (uint256) {
        return FullMath.mulDivRoundingUp(a, b, denominator);
    }

    /**
     * @notice Calculate total bid value from demands and on-chain pool prices
     * @dev Offloads the price-fetching loop from facets to avoid inlining PriceUtils + FullMath.
     * @param demands Array of demand quantities per pool
     * @param numeraire The numeraire currency address (address(0) for ETH)
     * @param poolManagerAddr Address of the IPoolManager
     * @param poolIds Array of PoolId bytes32 values
     * @param currency0s Array of currency0 addresses per pool
     * @param currency1s Array of currency1 addresses per pool
     * @return totalValue Total value in numeraire units
     */
    function calculateBidValueFromPools(
        uint256[] calldata demands,
        address numeraire,
        address poolManagerAddr,
        bytes32[] calldata poolIds,
        address[] calldata currency0s,
        address[] calldata currency1s
    ) external view returns (uint256 totalValue) {
        uint8 numeraireDecimals = _getDecimals(numeraire);
        uint256 numeraireFactor = 10 ** numeraireDecimals;
        IPoolManager poolManager = IPoolManager(poolManagerAddr);

        for (uint256 i = 0; i < demands.length && i < poolIds.length; ) {
            bool numeraireIsCurrency0 = (currency0s[i] == numeraire);
            address assetCurrency = numeraireIsCurrency0 ? currency1s[i] : currency0s[i];
            uint8 assetDecimals = _getDecimals(assetCurrency);

            (uint160 sqrtPriceX96, , , ) = poolManager.getSlot0(PoolId.wrap(poolIds[i]));
            uint256 priceX192 = uint256(sqrtPriceX96) * uint256(sqrtPriceX96);
            uint256 priceDoubleWad = FullMath.mulDiv(priceX192, 1e36, 1 << 192);

            uint256 price18;
            if (numeraireIsCurrency0) {
                uint256 invertedPriceDoubleWad = FullMath.mulDiv(1e36, 1e36, priceDoubleWad);
                price18 = invertedPriceDoubleWad / 1e18;
            } else {
                price18 = priceDoubleWad / 1e18;
            }

            totalValue += (demands[i] * price18 * numeraireFactor) / 10 ** (18 + assetDecimals);
            unchecked { ++i; }
        }
    }

    function _getDecimals(address currency) internal view returns (uint8) {
        if (currency == address(0)) return 18;
        return IERC20(currency).decimals();
    }
}
