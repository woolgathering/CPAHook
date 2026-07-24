// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { CurrencyDecimals } from "../utils/CurrencyDecimals.sol";
import { AuctionTypes } from "../types/AuctionTypes.sol";
import { AuctionId } from "../types/AuctionId.sol";
import { AssetConfig, AssetId, AssetIdLibrary } from "../types/AssetConfig.sol";

library CPAComputationLibrary {

    /**
     * @notice Compute total bid value in numeraire from calldata demands.
     *         price is read directly from assetInfo[assetId].currentPrice.
     *         Formula: sum( quantity[i] * price[i] / 10^assetDecimals[i] )
     */
    function calculateBidValue(
        uint256[] calldata demands,
        address numeraire,
        AssetConfig[] memory assets,
        AuctionId auctionId,
        mapping(AssetId => AuctionTypes.AssetInfo) storage assetInfo
    ) internal view returns (uint256 totalValue) {
        return _calculateBidValueInternal(demands, numeraire, assets, auctionId, assetInfo);
    }

    function calculateBidValueWithMemoryDemands(
        uint256[] memory demands,
        address numeraire,
        AssetConfig[] memory assets,
        AuctionId auctionId,
        mapping(AssetId => AuctionTypes.AssetInfo) storage assetInfo
    ) internal view returns (uint256 totalValue) {
        return _calculateBidValueInternal(demands, numeraire, assets, auctionId, assetInfo);
    }

    function _calculateBidValueInternal(
        uint256[] memory demands,
        address numeraire,
        AssetConfig[] memory assets,
        AuctionId auctionId,
        mapping(AssetId => AuctionTypes.AssetInfo) storage assetInfo
    ) private view returns (uint256 totalValue) {
        for (uint256 i = 0; i < demands.length && i < assets.length; ) {
            if (demands[i] == 0) { unchecked { ++i; } continue; }

            AssetId assetId = AssetIdLibrary.createId(auctionId, assets[i].assetToken);
            uint256 price = assetInfo[assetId].currentPrice; // numeraire decimals per asset token

            uint8 assetDecimals = CurrencyDecimals.getDecimals(assets[i].assetToken);
            // cost = quantity * price / 10^assetDecimals
            totalValue += (demands[i] * price) / (10 ** assetDecimals);

            unchecked { ++i; }
        }
    }

    /**
     * @notice Normalise stake to 18-decimal bid points for activity-rule comparisons.
     */
    function computeBidPoints(uint256 stakeAmount, address numeraire) internal view returns (uint256) {
        return stakeAmount * 10**18 / (10**CurrencyDecimals.getDecimals(numeraire));
    }

    /**
     * @notice Get the current price for a single asset.
     */
    function getCurrentPrice(
        AssetId assetId,
        mapping(AssetId => AuctionTypes.AssetInfo) storage assetInfo
    ) internal view returns (uint256) {
        return assetInfo[assetId].currentPrice;
    }
}
