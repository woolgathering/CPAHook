// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { NumeraireLib } from "./NumeraireLib.sol";

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

    // ---- Reveal ----

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

    // ---- Claim ----

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
            uint256 stake_ = bidderStake[bidder];
            if (stake_ > 0) {
                bidderStake[bidder] = 0;
                NumeraireLib.transfer(auctionInfo.commonNumeraire, bidder, stake_);
                emit IErrorsAndEvents.StakeRefunded(auctionId, bidder, stake_);
            }
            return;
        }

        // Winner: delegate to helper to keep this frame's stack shallow
        _settleWinner(
            bidder, auctionId, bundleId, protocolFeeBps,
            auctionInfo, assetInfo, bidderStake, bundles,
            protocolAccrued, assetBalance
        );
    }

    // ---- Phase check ----

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

    function _settleWinner(
        address bidder,
        AuctionId auctionId,
        BundleId bundleId,
        uint256 protocolFeeBps,
        AuctionTypes.AuctionInfo storage auctionInfo,
        mapping(AssetId => AuctionTypes.AssetInfo) storage assetInfo,
        mapping(address => uint256) storage bidderStake,
        mapping(BundleId => AuctionTypes.Bundle) storage bundles,
        mapping(AuctionId => uint256) storage protocolAccrued,
        mapping(AuctionId => mapping(address => uint256)) storage assetBalance
    ) private {
        AuctionTypes.Bundle memory bundle = bundles[bundleId];
        uint256 stake = bidderStake[bidder];
        bidderStake[bidder] = 0;

        uint256 totalCost = _computeTotalCost(bundle.quantities, auctionInfo.assets, auctionId, assetInfo);
        uint256 protocolFee = (totalCost * protocolFeeBps) / 10000;

        // Spending violation check
        uint256 violation = _computeViolation(auctionId, bidder, totalCost, stake, auctionInfo.config.minSpendRatio, protocolAccrued);

        protocolAccrued[auctionId] += protocolFee;

        uint256 totalDebt = totalCost + protocolFee + violation;

        // Pull shortfall from bidder if stake is insufficient
        if (totalDebt > stake) {
            uint256 shortfall = totalDebt - stake;
            NumeraireLib.transferFrom(auctionInfo.commonNumeraire, bidder, shortfall, 0);
            stake += shortfall;
        }

        // Transfer allocated assets to bidder
        _transferAssets(bidder, auctionId, bundle.quantities, auctionInfo.assets, assetBalance);

        // Refund remaining stake
        uint256 refund = stake - totalDebt;
        if (refund > 0) {
            NumeraireLib.transfer(auctionInfo.commonNumeraire, bidder, refund);
            emit IErrorsAndEvents.StakeRefunded(auctionId, bidder, refund);
        }
    }

    function _computeViolation(
        AuctionId auctionId,
        address bidder,
        uint256 totalCost,
        uint256 stake,
        uint256 minSpendRatio,
        mapping(AuctionId => uint256) storage protocolAccrued
    ) private returns (uint256 violation) {
        uint256 minSpend = (minSpendRatio * stake) / 10000;
        if (totalCost < minSpend) {
            violation = minSpend - totalCost;
            protocolAccrued[auctionId] += violation;
            emit IErrorsAndEvents.PenaltyApplied(auctionId, bidder, violation);
        }
    }

    function _transferAssets(
        address bidder,
        AuctionId auctionId,
        uint256[] memory quantities,
        AssetConfig[] memory assets,
        mapping(AuctionId => mapping(address => uint256)) storage assetBalance
    ) private {
        for (uint256 i = 0; i < quantities.length; ) {
            uint256 qty = quantities[i];
            if (qty > 0) {
                address assetToken = assets[i].assetToken;
                assetBalance[auctionId][assetToken] -= qty;
                IERC20(assetToken).safeTransfer(bidder, qty);
            }
            unchecked { ++i; }
        }
    }

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
