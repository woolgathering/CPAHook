// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { CPAStorage } from "../base/CPAStorage.sol";
import { CommitReveal } from "../utils/CommitReveal.sol";
import { CurrencyDecimals } from "../utils/CurrencyDecimals.sol";
import { IErrorsAndEvents } from "../utils/IErrorsAndEvents.sol";
import { AuctionTypes } from "../types/AuctionTypes.sol";
import { AuctionId } from "../types/AuctionId.sol";
import { AssetConfig, AssetId, AssetIdLibrary } from "../types/AssetConfig.sol";
import { BundleId } from "../types/BundleId.sol";

library CPASettlementPhase {
    using SafeERC20 for IERC20;

    function reveal(
        AuctionId auctionId,
        address bidder,
        address proxy,
        bytes32 saltA,
        bytes32 saltB,
        mapping(AuctionId => mapping(bytes32 => address)) storage commitProxy,
        mapping(AuctionId => mapping(bytes32 => address)) storage revealedMappings
    ) internal {
        bytes32 computedCommitHash = CommitReveal.generateCommitHash(bidder, proxy, saltA, saltB);

        if (commitProxy[auctionId][computedCommitHash] == address(0))
            revert IErrorsAndEvents.NoSuchCommitHash(auctionId, computedCommitHash);
        if (revealedMappings[auctionId][computedCommitHash] != address(0))
            revert IErrorsAndEvents.DuplicateReveal(auctionId, computedCommitHash);

        revealedMappings[auctionId][computedCommitHash] = bidder;

        emit IErrorsAndEvents.RevealProcessed(auctionId, bidder, proxy, computedCommitHash);
    }

    /**
     * @notice Claim all allocated tokens for a bidder.
     *
     *  Flow:
     *   1. Validate reveal and allocation
     *   2. Non-winner: full stake refund
     *   3. Winner:
     *      a. Compute totalCost = sum(quantity[i] * clearingPrice[i] / 10^assetDecimals[i])
     *      b. Compute protocolFee = totalCost * protocolFeeBps / 10000
     *      c. Spending violation: if totalCost < minSpendRatio * stake, add shortfall to protocolAccrued
     *      d. If totalCost + protocolFee + violations > stake: pull shortfall from bidder
     *      e. Transfer allocated assets to bidder; decrement assetBalance
     *      f. Refund remainder of stake to bidder
     */
    function claimAllTokens(
        address bidder,
        AuctionId auctionId,
        bytes32 commitHash,
        uint256 protocolFeeBps,
        AuctionTypes.AuctionInfo storage auctionInfo,
        mapping(AssetId => AuctionTypes.AssetInfo) storage assetInfo,
        mapping(bytes32 => address) storage revealedMappings,
        mapping(address => uint256) storage bidderStake,
        mapping(BundleId => AuctionTypes.Bundle) storage bundles,
        mapping(bytes32 => BundleId) storage winningBundleIds,
        mapping(AuctionId => uint256) storage protocolAccrued,
        mapping(AuctionId => mapping(address => uint256)) storage assetBalance
    ) internal {
        // Validate bidder
        {
            address revealedBidder = revealedMappings[commitHash];
            if (revealedBidder == address(0))
                revert IErrorsAndEvents.CommitHashNotYetRevealed(auctionId, commitHash);
            if (revealedBidder != bidder) revert IErrorsAndEvents.Unauthorized();
        }

        BundleId bundleId = winningBundleIds[commitHash];

        // Non-winner: full stake refund, no fee
        if (BundleId.unwrap(bundleId) == 0) {
            uint256 stake = bidderStake[bidder];
            if (stake > 0) {
                bidderStake[bidder] = 0;
                IERC20(auctionInfo.commonNumeraire).safeTransfer(bidder, stake);
                emit IErrorsAndEvents.StakeRefunded(auctionId, bidder, stake);
            }
            return;
        }

        // Winner: compute costs and transfer
        AuctionTypes.Bundle memory bundle = bundles[bundleId];
        uint256 stake = bidderStake[bidder];
        bidderStake[bidder] = 0;

        uint256 totalCost = _computeTotalCost(bundle.quantities, auctionInfo.assets, auctionId, assetInfo);
        uint256 protocolFee = (totalCost * protocolFeeBps) / 10000;

        // Spending violation check
        uint256 minSpend = (auctionInfo.config.minSpendRatio * stake) / 10000;
        uint256 violation = 0;
        if (totalCost < minSpend) {
            violation = minSpend - totalCost;
            protocolAccrued[auctionId] += violation;
            emit IErrorsAndEvents.PenaltyApplied(auctionId, bidder, violation);
        }

        protocolAccrued[auctionId] += protocolFee;

        uint256 totalDebt = totalCost + protocolFee + violation;

        // Pull shortfall from bidder if stake is insufficient
        if (totalDebt > stake) {
            uint256 shortfall = totalDebt - stake;
            IERC20(auctionInfo.commonNumeraire).safeTransferFrom(bidder, address(this), shortfall);
            stake += shortfall;
        }

        // Transfer allocated assets to bidder
        for (uint256 i = 0; i < auctionInfo.assets.length; ) {
            uint256 qty = bundle.quantities[i];
            if (qty > 0) {
                address assetToken = auctionInfo.assets[i].assetToken;
                AssetId assetId = AssetIdLibrary.createId(auctionId, assetToken);
                assetBalance[auctionId][assetToken] -= qty;
                assetInfo[assetId]; // storage touch (no-op, keeps reference)
                IERC20(assetToken).safeTransfer(bidder, qty);
            }
            unchecked { ++i; }
        }

        // Refund remaining stake
        uint256 refund = stake - totalDebt;
        if (refund > 0) {
            IERC20(auctionInfo.commonNumeraire).safeTransfer(bidder, refund);
            emit IErrorsAndEvents.StakeRefunded(auctionId, bidder, refund);
        }
    }

    /**
     * @notice Check if settlement phase duration has expired.
     */
    function shouldSettlementPhaseEnd(
        AuctionId auctionId,
        mapping(AuctionId => uint256) storage settlementPhaseStartTime,
        mapping(AuctionId => AuctionTypes.AuctionInfo) storage auctionInfo
    ) internal view returns (bool) {
        uint256 startTime = settlementPhaseStartTime[auctionId];
        if (startTime == 0) return false;
        return block.timestamp >= startTime + auctionInfo[auctionId].config.phaseDurations[2];
    }

    // ========================================
    // INTERNAL HELPERS
    // ========================================

    function _computeTotalCost(
        uint256[] memory quantities,
        AssetConfig[] memory assets,
        AuctionId auctionId,
        mapping(AssetId => AuctionTypes.AssetInfo) storage assetInfo
    ) private view returns (uint256 totalCost) {
        for (uint256 i = 0; i < quantities.length; ) {
            if (quantities[i] > 0) {
                AssetId assetId = AssetIdLibrary.createId(auctionId, assets[i].assetToken);
                uint256 price = assetInfo[assetId].currentPrice;
                uint8 assetDecimals = CurrencyDecimals.getDecimals(assets[i].assetToken);
                totalCost += (quantities[i] * price) / (10 ** assetDecimals);
            }
            unchecked { ++i; }
        }
    }
}
