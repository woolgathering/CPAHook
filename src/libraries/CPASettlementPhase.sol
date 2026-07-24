// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { NumeraireLib } from "./NumeraireLib.sol";

import { ClockPhaseState, ProxyPhaseState, SettlementPhaseState } from "../base/CPAStorage.sol";
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
        ProxyPhaseState storage proxyState,
        SettlementPhaseState storage settlementState
    ) internal {
        bytes32 computedCommitHash = CommitReveal.generateCommitHash(bidder, proxy, saltA, saltB);

        if (proxyState.commitProxy[computedCommitHash] == address(0))
            revert IErrorsAndEvents.NoSuchCommitHash(auctionId, computedCommitHash);
        if (settlementState.revealedMappings[computedCommitHash] != address(0))
            revert IErrorsAndEvents.DuplicateReveal(auctionId, computedCommitHash);

        settlementState.revealedMappings[computedCommitHash] = bidder;

        emit IErrorsAndEvents.RevealProcessed(auctionId, bidder, proxy, computedCommitHash);
    }

    // ---- Claim ----

    /**
     * @notice Claim all allocated tokens for a bidder.
     */
    function claimAllTokens(
        address bidder,
        AuctionId auctionId,
        bytes32 commitHash,
        uint256 protocolFeeBps,
        AuctionTypes.AuctionInfo storage auctionInfo,
        mapping(AssetId => AuctionTypes.AssetInfo) storage assetInfo,
        mapping(bytes32 => BundleId) storage winningBundleIds,
        ClockPhaseState storage clockState,
        ProxyPhaseState storage proxyState,
        SettlementPhaseState storage settlementState
    ) internal {
        // Validate bidder
        {
            address revealedBidder = settlementState.revealedMappings[commitHash];
            if (revealedBidder == address(0))
                revert IErrorsAndEvents.CommitHashNotYetRevealed(auctionId, commitHash);
            if (revealedBidder != bidder) revert IErrorsAndEvents.Unauthorized();
        }

        BundleId bundleId = winningBundleIds[commitHash];

        // Non-winner: full stake refund, no fee
        if (BundleId.unwrap(bundleId) == 0) {
            uint256 stake_ = clockState.bidderStake[bidder];
            if (stake_ > 0) {
                clockState.bidderStake[bidder] = 0;
                NumeraireLib.transfer(auctionInfo.commonNumeraire, bidder, stake_);
                emit IErrorsAndEvents.StakeRefunded(auctionId, bidder, stake_);
            }
            return;
        }

        // Load bundle into memory before delegating so _settleWinner doesn't need proxyState
        AuctionTypes.Bundle memory bundle = proxyState.bundles[bundleId];
        _settleWinner(
            bidder, auctionId, bundle, protocolFeeBps,
            auctionInfo, assetInfo, clockState, settlementState
        );
    }

    // ---- Phase check ----

    function shouldSettlementPhaseEnd(
        AuctionId auctionId,
        SettlementPhaseState storage settlementState,
        mapping(AuctionId => AuctionTypes.AuctionInfo) storage auctionInfo
    ) internal view returns (bool) {
        uint256 startTime = settlementState.settlementPhaseStartTime;
        if (startTime == 0) return false;
        return block.timestamp >= startTime + auctionInfo[auctionId].config.phaseDurations[2];
    }

    // ========================================
    // INTERNAL HELPERS
    // ========================================

    function _settleWinner(
        address bidder,
        AuctionId auctionId,
        AuctionTypes.Bundle memory bundle,
        uint256 protocolFeeBps,
        AuctionTypes.AuctionInfo storage auctionInfo,
        mapping(AssetId => AuctionTypes.AssetInfo) storage assetInfo,
        ClockPhaseState storage clockState,
        SettlementPhaseState storage settlementState
    ) private {
        uint256 stake = clockState.bidderStake[bidder];
        clockState.bidderStake[bidder] = 0;

        uint256 totalDebt;
        {
            uint256 totalCost = _computeTotalCost(bundle.quantities, auctionInfo.assets, auctionId, assetInfo);
            uint256 protocolFee = (totalCost * protocolFeeBps) / 10000;
            uint256 violation = _computeViolation(auctionId, bidder, totalCost, stake, auctionInfo.config.minSpendRatio, settlementState);
            settlementState.protocolAccrued += protocolFee;
            totalDebt = totalCost + protocolFee + violation;
        }

        if (totalDebt > stake) {
            uint256 shortfall = totalDebt - stake;
            NumeraireLib.transferFrom(auctionInfo.commonNumeraire, bidder, shortfall, 0);
            stake += shortfall;
        }

        _transferAssets(bidder, auctionId, bundle.quantities, auctionInfo.assets, settlementState);

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
        SettlementPhaseState storage settlementState
    ) private returns (uint256 violation) {
        uint256 minSpend = (minSpendRatio * stake) / 10000;
        if (totalCost < minSpend) {
            violation = minSpend - totalCost;
            settlementState.protocolAccrued += violation;
            emit IErrorsAndEvents.PenaltyApplied(auctionId, bidder, violation);
        }
    }

    function _transferAssets(
        address bidder,
        AuctionId auctionId,
        uint256[] memory quantities,
        AssetConfig[] memory assets,
        SettlementPhaseState storage settlementState
    ) private {
        for (uint256 i = 0; i < quantities.length; ) {
            uint256 qty = quantities[i];
            if (qty > 0) {
                address assetToken = assets[i].assetToken;
                settlementState.assetBalance[assetToken] -= qty;
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
