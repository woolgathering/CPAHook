// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { CPAStorage } from "../base/CPAStorage.sol";
import { IErrorsAndEvents } from "../utils/IErrorsAndEvents.sol";
import { AuctionTypes } from "../types/AuctionTypes.sol";
import { AuctionId } from "../types/AuctionId.sol";
import { AssetConfig, AssetId, AssetIdLibrary } from "../types/AssetConfig.sol";
import { CPAComputationLibrary } from "./CPAComputationLibrary.sol";
import { CurrencyDecimals } from "../utils/CurrencyDecimals.sol";

library CPAClockPhase {
    using SafeERC20 for IERC20;

    /**
     * @notice Process a bid during the clock phase.
     *         Transfers any additional stake required from the bidder.
     */
    function processBid(
        CPAStorage self,
        AuctionId auctionId,
        uint256[] calldata demands,
        uint256 maxStakeAmount,
        AuctionTypes.AuctionInfo storage auctionInfo,
        mapping(address => uint256) storage bidderStake,
        mapping(address => uint256) storage bidderBidPoints,
        mapping(address => uint256[]) storage bids,
        address[] storage activeBidders
    ) internal {
        address bidder = msg.sender;

        if (auctionInfo.clockOpen == 1) revert IErrorsAndEvents.ClockNotOpen();
        if (demands.length != auctionInfo.assets.length) revert IErrorsAndEvents.InvalidBidsLength();

        _validateActivityRule(demands, bids[bidder], auctionInfo.changedPrices);

        uint256 requiredAdditionalStake;
        uint256 allocatorRewardAmount;
        {
            (requiredAdditionalStake, allocatorRewardAmount) = _calculateRequiredStake(
                demands,
                auctionInfo,
                bidderStake[bidder],
                bidderBidPoints[bidder],
                maxStakeAmount,
                auctionId,
                self
            );

            if (requiredAdditionalStake > 0) {
                bidderStake[bidder] += requiredAdditionalStake;
                bidderBidPoints[bidder] = CPAComputationLibrary.computeBidPoints(
                    bidderStake[bidder], auctionInfo.commonNumeraire
                );
                auctionInfo.allocatorReward += allocatorRewardAmount;

                uint256 total = requiredAdditionalStake + allocatorRewardAmount;
                IERC20(auctionInfo.commonNumeraire).safeTransferFrom(bidder, address(this), total);
            }
        }

        bids[bidder] = demands;
        activeBidders.push(bidder);

        emit IErrorsAndEvents.BidSubmitted(auctionId, bidder, requiredAdditionalStake, auctionInfo.currentRound);
    }

    /**
     * @notice Process end-of-round demand aggregation and price updates.
     *         Returns total demand per asset.
     */
    function processClockRound(
        CPAStorage self,
        AuctionId auctionId,
        AuctionTypes.AuctionInfo storage auctionInfo,
        mapping(AssetId => AuctionTypes.AssetInfo) storage assetInfo,
        mapping(address => uint256[]) storage bids,
        mapping(AuctionId => address[]) storage activeBidders
    ) internal returns (uint256[] memory) {
        uint256 numAssets = auctionInfo.assets.length;
        uint256[] memory totalDemands = new uint256[](numAssets);
        address[] storage currentActiveBidders = activeBidders[auctionId];

        for (uint256 i = 0; i < numAssets; ) {
            AssetId assetId = AssetIdLibrary.createId(auctionId, auctionInfo.assets[i].assetToken);

            for (uint256 j = 0; j < currentActiveBidders.length; ) {
                address bidder = currentActiveBidders[j];
                if (bidder != address(0)) {
                    totalDemands[i] += bids[bidder][i];
                }
                unchecked { ++j; }
            }

            AuctionTypes.AssetInfo storage asset = assetInfo[assetId];
            asset.excessDemand = int256(totalDemands[i]) - int256(asset.depositAmount);

            if (asset.excessDemand > 0) {
                asset.lastOversoldPrice = asset.currentPrice;
                asset.currentPrice += asset.config.priceIncrement;
                auctionInfo.changedPrices[i] = true;
            } else {
                auctionInfo.changedPrices[i] = false;
            }

            unchecked { ++i; }
        }

        delete activeBidders[auctionId];
        return totalDemands;
    }

    /**
     * @notice Check if clock phase should end (no excess demand, max rounds, or stale revenue).
     */
    function shouldEndClockPhase(
        AuctionId auctionId,
        AuctionTypes.AuctionInfo storage auctionInfo,
        mapping(AssetId => AuctionTypes.AssetInfo) storage assetInfo,
        uint256[] memory totalDemands,
        CPAStorage self
    ) internal returns (bool) {
        // 1. No excess demand on any asset
        bool hasExcessDemand = false;
        for (uint256 i = 0; i < auctionInfo.assets.length; ) {
            AssetId assetId = AssetIdLibrary.createId(auctionId, auctionInfo.assets[i].assetToken);
            if (assetInfo[assetId].excessDemand > 0) {
                hasExcessDemand = true;
                break;
            }
            unchecked { ++i; }
        }
        if (!hasExcessDemand) return true;

        // 2. Max rounds exceeded
        if (auctionInfo.currentRound >= auctionInfo.config.maxRounds) return true;

        // 3. Revenue EMA improvement < 0.5%
        uint256 alpha = 5e17;
        uint256 revenue = CPAComputationLibrary.calculateBidValueWithMemoryDemands(
            totalDemands, auctionInfo.commonNumeraire, auctionInfo.assets, auctionId, assetInfo
        );
        if (revenue == 0) return false;
        uint256 rT = _computeEma(revenue, auctionInfo.lastRevenue, alpha);
        if ((rT * 1e18) / revenue <= 5e15) {
            return true;
        }
        auctionInfo.lastRevenue = revenue;

        return false;
    }

    /**
     * @notice Revert prices to lastOversoldPrice for any currently undersold assets.
     */
    function revertUndersoldPrices(
        AuctionTypes.AuctionInfo storage auctionInfo,
        mapping(AssetId => AuctionTypes.AssetInfo) storage assetInfo
    ) internal {
        for (uint256 i = 0; i < auctionInfo.assets.length; ) {
            AssetId assetId = AssetIdLibrary.createId(
                auctionInfo.assets[i].assetToken == auctionInfo.assets[i].assetToken // always true, just using struct
                    ? AuctionId.wrap(keccak256(abi.encode(auctionInfo.assets))) // can't easily get auctionId here
                    : AuctionId.wrap(0),
                auctionInfo.assets[i].assetToken
            );
            // NOTE: revertUndersoldPrices must be called with the auctionId available;
            // see revertUndersoldPricesForAuction below for the correct entry point.
            unchecked { ++i; }
        }
    }

    function revertUndersoldPricesForAuction(
        AuctionId auctionId,
        AuctionTypes.AuctionInfo storage auctionInfo,
        mapping(AssetId => AuctionTypes.AssetInfo) storage assetInfo
    ) internal {
        for (uint256 i = 0; i < auctionInfo.assets.length; ) {
            AssetId assetId = AssetIdLibrary.createId(auctionId, auctionInfo.assets[i].assetToken);
            AuctionTypes.AssetInfo storage asset = assetInfo[assetId];

            if (asset.excessDemand < 0 && asset.lastOversoldPrice != 0) {
                asset.currentPrice = asset.lastOversoldPrice;
            }
            unchecked { ++i; }
        }
    }

    function setClockOpen(
        AuctionId auctionId,
        uint256 _clockOpen,
        mapping(AuctionId => AuctionTypes.AuctionInfo) storage auctionInfo
    ) internal {
        auctionInfo[auctionId].clockOpen = _clockOpen;
    }

    function openClockRound(
        AuctionId auctionId,
        mapping(AuctionId => AuctionTypes.AuctionInfo) storage auctionInfo
    ) internal {
        AuctionTypes.AuctionInfo storage info = auctionInfo[auctionId];

        if (info.currentStatus != AuctionTypes.AuctionStatus.Active)
            revert IErrorsAndEvents.AuctionNotActive(auctionId, info.currentStatus);
        if (info.clockOpen == 2) revert IErrorsAndEvents.ClockAlreadyOpen();
        if (info.currentPhase != AuctionTypes.AuctionPhase.Clock)
            revert IErrorsAndEvents.InvalidPhase(AuctionTypes.AuctionPhase.Clock, info.currentPhase);

        unchecked {
            info.clockOpen = 2;
            info.currentRound++;
        }

        emit IErrorsAndEvents.ClockRoundOpened(auctionId, info.currentRound);
    }

    // ========================================
    // INTERNAL HELPERS
    // ========================================

    function _computeEma(uint256 rT, uint256 rT1, uint256 alpha) internal pure returns (uint256) {
        return (alpha * rT + (1e18 - alpha) * rT1) / 1e18;
    }

    function _validateActivityRule(
        uint256[] calldata demands,
        uint256[] memory previousDemands,
        bool[] memory changedPrices
    ) private pure {
        if (previousDemands.length == 0) return;
        for (uint256 i = 0; i < changedPrices.length; i++) {
            if (changedPrices[i] && demands[i] > previousDemands[i]) {
                revert IErrorsAndEvents.ActivityRuleViolation();
            }
        }
    }

    function _calculateRequiredStake(
        uint256[] calldata demands,
        AuctionTypes.AuctionInfo storage auctionInfo,
        uint256 currentStake,
        uint256 currentBidPoints,
        uint256 maxStakeAmount,
        AuctionId auctionId,
        CPAStorage self
    ) private view returns (uint256 requiredAdditionalStake, uint256 allocatorReward) {
        uint256 totalValueInNumeraire = CPAComputationLibrary.calculateBidValue(
            demands, auctionInfo.commonNumeraire, auctionInfo.assets, auctionId, self.assetInfo
        );
        uint256 requiredBidPoints = CPAComputationLibrary.computeBidPoints(
            totalValueInNumeraire, auctionInfo.commonNumeraire
        );
        if (requiredBidPoints <= currentBidPoints) return (0, 0);

        requiredAdditionalStake = totalValueInNumeraire - currentStake;
        allocatorReward = (requiredAdditionalStake * auctionInfo.config.allocatorRewardPct) / 10000;
        if (maxStakeAmount < requiredAdditionalStake + allocatorReward)
            revert IErrorsAndEvents.MaxStakeTooLow(auctionId);
    }
}
