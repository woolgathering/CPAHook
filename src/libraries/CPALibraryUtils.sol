// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { CurrencyDecimals } from "../utils/CurrencyDecimals.sol";

/**
 * @title CPALibraryUtils
 * @notice Shared utility functions used across CPA phase libraries
 * @dev Consolidates common patterns to reduce code duplication and improve gas efficiency
 */
library CPALibraryUtils {
    
    /**
     * @notice Determine which currency is the asset vs numeraire
     * @param poolKey The pool key containing both currencies
     * @param commonNumeraire The address of the common numeraire
     * @return assetCurrency The currency that is the asset (non-numeraire)
     * @return numeraireIsCurrency0 True if numeraire is currency0, false if currency1
     */
    function getAssetCurrency(
        PoolKey memory poolKey,
        address commonNumeraire
    ) internal pure returns (Currency assetCurrency, bool numeraireIsCurrency0) {
        if (address(Currency.unwrap(poolKey.currency0)) == commonNumeraire) {
            // Numeraire is currency0, asset is currency1
            assetCurrency = poolKey.currency1;
            numeraireIsCurrency0 = true;
        } else {
            // Numeraire is currency1, asset is currency0
            assetCurrency = poolKey.currency0;
            numeraireIsCurrency0 = false;
        }
    }
    
    /**
     * @notice Get decimals for both numeraire and asset currencies
     * @param numeraireAddress The address of the numeraire currency
     * @param assetAddress The address of the asset currency
     * @return numeraireDecimals The number of decimals for numeraire
     * @return assetDecimals The number of decimals for asset
     */
    function getCachedDecimals(
        address numeraireAddress,
        address assetAddress
    ) internal view returns (uint8 numeraireDecimals, uint8 assetDecimals) {
        numeraireDecimals = CurrencyDecimals.getDecimals(numeraireAddress);
        assetDecimals = CurrencyDecimals.getDecimals(assetAddress);
    }
    
    /**
     * @notice Calculate value in numeraire from quantity and price
     * @param quantity The quantity in asset decimals
     * @param price The price in 18 decimals
     * @param numeraireDecimals The number of decimals for numeraire
     * @param assetDecimals The number of decimals for asset
     * @return value The value in numeraire decimals
     * @dev Formula: (quantity * price * 10^numeraireDecimals) / (10^(18 + assetDecimals))
     */
    function calculateValue(
        uint256 quantity,
        uint256 price,
        uint8 numeraireDecimals,
        uint8 assetDecimals
    ) internal pure returns (uint256 value) {
        value = (quantity * price * (10**numeraireDecimals)) / (10**(18 + assetDecimals));
    }
}

