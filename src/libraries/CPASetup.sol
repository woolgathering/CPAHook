// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { SettlementPhaseState } from "../base/CPAStorage.sol";
import { IErrorsAndEvents } from "../utils/IErrorsAndEvents.sol";
import { AuctionTypes } from "../types/AuctionTypes.sol";
import { AuctionId, AuctionIdLibrary } from "../types/AuctionId.sol";
import { AssetConfig, AssetId, AssetIdLibrary } from "../types/AssetConfig.sol";

library CPASetup {
    using SafeERC20 for IERC20;

    /**
     * @notice Register assets for a new auction (step 1 of 2-step creation).
     *         Validates config, writes assetInfo and assetToAuctionId.
     *         Call finalizeAuctionCreation as step 2.
     */
    function registerAssetsForAuction(
        AuctionTypes.AuctionConfig memory config,
        mapping(AssetId => AuctionId) storage assetToAuctionId,
        mapping(AssetId => AuctionTypes.AssetInfo) storage assetInfo
    ) internal returns (AuctionId auctionId) {
        if (config.assets.length == 0) revert IErrorsAndEvents.InvalidBidsLength();

        auctionId = AuctionIdLibrary.createId(config.assets);

        for (uint256 i = 0; i < config.assets.length; ) {
            AssetConfig memory asset = config.assets[i];

            if (asset.assetToken == address(0)) revert IErrorsAndEvents.InvalidNumeraire();
            if (asset.assetToken == config.commonNumeraire) revert IErrorsAndEvents.MismatchedNumeraires();
            if (asset.supply == 0) revert IErrorsAndEvents.InvalidStakeAmount();
            if (asset.startingPrice == 0) revert IErrorsAndEvents.InvalidStakeAmount();

            AssetId assetId = AssetIdLibrary.createId(auctionId, asset.assetToken);
            assetToAuctionId[assetId] = auctionId;

            assetInfo[assetId] = AuctionTypes.AssetInfo({
                config: asset,
                depositAmount: 0,
                excessDemand: 0,
                lastOversoldPrice: 0,
                currentPrice: asset.startingPrice,
                auctionId: auctionId
            });

            unchecked { ++i; }
        }
    }

    /**
     * @notice Write AuctionInfo and emit AuctionCreated (step 2 of creation).
     */
    function finalizeAuctionCreation(
        AuctionTypes.AuctionConfig memory config,
        AuctionId auctionId,
        address auctionOwner,
        mapping(AuctionId => AuctionTypes.AuctionInfo) storage auctionInfo
    ) internal {
        auctionInfo[auctionId] = AuctionTypes.AuctionInfo({
            auctionOwner: auctionOwner,
            commonNumeraire: config.commonNumeraire,
            config: config,
            currentPhase: AuctionTypes.AuctionPhase.Setup,
            currentStatus: AuctionTypes.AuctionStatus.Active,
            clockOpen: 1,
            currentRound: 0,
            assets: config.assets,
            allocatorReward: 0,
            changedPrices: new bool[](config.assets.length),
            lastRevenue: 0,
            totalPauseDuration: 0
        });
        emit IErrorsAndEvents.AuctionCreated(auctionId, auctionOwner);
    }

    /**
     * @notice Deposit a single asset from the auctioneer into the contract.
     */
    function moveDeposit(
        AuctionTypes.AuctionInfo storage info,
        mapping(AssetId => AuctionTypes.AssetInfo) storage assetInfo,
        SettlementPhaseState storage settlementState,
        AuctionId auctionId,
        address assetToken,
        uint256 depositAmount
    ) internal {
        if (info.currentPhase != AuctionTypes.AuctionPhase.Setup)
            revert IErrorsAndEvents.InvalidPhase(AuctionTypes.AuctionPhase.Setup, info.currentPhase);

        AssetId assetId = AssetIdLibrary.createId(auctionId, assetToken);
        assetInfo[assetId].depositAmount = depositAmount;
        settlementState.assetBalance[assetToken] = depositAmount;

        IERC20(assetToken).safeTransferFrom(info.auctionOwner, address(this), depositAmount);

        emit IErrorsAndEvents.AssetsDeposited(auctionId, assetId, assetToken, depositAmount);
    }

    /**
     * @notice Confirm all assets have been deposited.
     */
    function confirmSetupComplete(
        AuctionId auctionId,
        AuctionTypes.AuctionInfo storage info,
        mapping(AssetId => AuctionTypes.AssetInfo) storage assetInfo
    ) internal view returns (bool) {
        if (info.currentPhase != AuctionTypes.AuctionPhase.Setup) return false;
        for (uint256 i = 0; i < info.assets.length; ) {
            AssetId assetId = AssetIdLibrary.createId(auctionId, info.assets[i].assetToken);
            if (assetInfo[assetId].depositAmount == 0) return false;
            unchecked { ++i; }
        }
        return true;
    }

    /**
     * @notice Deposit all assets and transition to Clock phase in one transaction.
     */
    function depositAllAndStartClock(
        AuctionTypes.AuctionInfo storage info,
        mapping(AssetId => AuctionTypes.AssetInfo) storage assetInfo,
        SettlementPhaseState storage settlementState,
        uint256[] memory amounts,
        AuctionId auctionId
    ) internal {
        if (info.assets.length != amounts.length) revert IErrorsAndEvents.InvalidBidsLength();

        for (uint256 i = 0; i < info.assets.length; ) {
            _depositSingleAsset(auctionId, assetInfo, settlementState, info.assets[i].assetToken, amounts[i]);
            unchecked { ++i; }
        }

        info.currentPhase = AuctionTypes.AuctionPhase.Clock;
        info.clockOpen = 2;
        info.currentRound = 1;

        emit IErrorsAndEvents.AuctionPhaseChanged(auctionId, AuctionTypes.AuctionPhase.Clock);
        emit IErrorsAndEvents.ClockRoundOpened(auctionId, 1);
    }

    function _depositSingleAsset(
        AuctionId auctionId,
        mapping(AssetId => AuctionTypes.AssetInfo) storage assetInfo,
        SettlementPhaseState storage settlementState,
        address assetToken,
        uint256 amount
    ) private {
        AssetId assetId = AssetIdLibrary.createId(auctionId, assetToken);
        assetInfo[assetId].depositAmount = amount;
        settlementState.assetBalance[assetToken] = amount;
        IERC20(assetToken).safeTransferFrom(msg.sender, address(this), amount);
        emit IErrorsAndEvents.AssetsDeposited(auctionId, assetId, assetToken, amount);
    }
}
