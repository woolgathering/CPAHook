// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { CurrencyDecimals } from "../utils/CurrencyDecimals.sol";

library CPALibraryUtils {

    function getCachedDecimals(
        address numeraireAddress,
        address assetAddress
    ) internal view returns (uint8 numeraireDecimals, uint8 assetDecimals) {
        numeraireDecimals = CurrencyDecimals.getDecimals(numeraireAddress);
        assetDecimals = CurrencyDecimals.getDecimals(assetAddress);
    }

    /**
     * @notice Compute value in numeraire from quantity and linear price.
     *         price is in numeraire decimals per asset token.
     *         value = quantity * price / 10^assetDecimals
     */
    function calculateValue(
        uint256 quantity,
        uint256 price,
        uint8 assetDecimals
    ) internal pure returns (uint256) {
        return (quantity * price) / (10 ** assetDecimals);
    }
}
