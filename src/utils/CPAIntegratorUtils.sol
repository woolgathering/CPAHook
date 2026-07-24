// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { CPAComputationLibrary } from "../libraries/CPAComputationLibrary.sol";
import { AuctionTypes } from "../types/AuctionTypes.sol";
import { AuctionId } from "../types/AuctionId.sol";
import { AssetId, AssetConfig } from "../types/AssetConfig.sol";

library CPAIntegratorUtils {

    /// @notice Compute stake required for a bid at current prices.
    function computeRequiredStake(
        uint256[] calldata demands,
        address numeraire,
        uint256 allocatorRewardPct,
        uint256 existingStake,
        AssetConfig[] memory assets,
        AuctionId auctionId,
        mapping(AssetId => AuctionTypes.AssetInfo) storage assetInfo
    ) internal view returns (
        uint256 additionalRequired,
        uint256 totalRequired,
        uint256 bidValue,
        uint256 allocatorFee
    ) {
        bidValue = CPAComputationLibrary.calculateBidValue(demands, numeraire, assets, auctionId, assetInfo);
        allocatorFee = (bidValue * allocatorRewardPct) / 10000;
        totalRequired = bidValue + allocatorFee;
        additionalRequired = totalRequired > existingStake ? totalRequired - existingStake : 0;
    }

    /// @notice Check whether existing stake covers the bid.
    function checkStakeSufficiency(
        uint256[] calldata demands,
        address numeraire,
        uint256 allocatorRewardPct,
        uint256 existingStake,
        AssetConfig[] memory assets,
        AuctionId auctionId,
        mapping(AssetId => AuctionTypes.AssetInfo) storage assetInfo
    ) internal view returns (
        bool hasSufficientStake,
        uint256 requiredStake,
        uint256 additionalNeeded
    ) {
        (additionalNeeded, requiredStake, , ) = computeRequiredStake(
            demands, numeraire, allocatorRewardPct, existingStake, assets, auctionId, assetInfo
        );
        hasSufficientStake = (additionalNeeded == 0);
    }
}
