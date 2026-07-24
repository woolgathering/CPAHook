// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { CurrencyDecimals } from "../utils/CurrencyDecimals.sol";

import { AllocationPhaseState, ProxyPhaseState } from "../base/CPAStorage.sol";
import { IErrorsAndEvents } from "../utils/IErrorsAndEvents.sol";
import { AuctionTypes } from "../types/AuctionTypes.sol";
import { AuctionId } from "../types/AuctionId.sol";
import { AssetConfig, AssetId, AssetIdLibrary } from "../types/AssetConfig.sol";
import { BundleId } from "../types/BundleId.sol";

library CPAAllocationPhase {

    function submitAllocation(
        AuctionTypes.Allocation calldata allocationData,
        AllocationPhaseState storage allocState,
        AuctionTypes.AuctionInfo storage auctionInfo,
        mapping(AssetId => AuctionTypes.AssetInfo) storage assetInfo,
        ProxyPhaseState storage proxyState
    ) internal {
        AuctionId auctionId = allocationData.auctionId;

        (uint256 score, uint256 totalValue) = _scoreAllocation(
            auctionId, allocationData, auctionInfo, assetInfo, proxyState.bundles
        );
        if (score > allocState.topAllocation.score) {
            allocState.topAllocation.allocation = allocationData;
            allocState.topAllocation.score = score;
            allocState.topAllocation.totalValue = totalValue;
        }

        allocState.hasAllocations = true;

        emit IErrorsAndEvents.AllocationSubmitted(auctionId, allocationData.allocator, score);
    }

    function _scoreAllocation(
        AuctionId auctionId,
        AuctionTypes.Allocation calldata allocationData,
        AuctionTypes.AuctionInfo storage auctionInfo,
        mapping(AssetId => AuctionTypes.AssetInfo) storage assetInfo,
        mapping(BundleId => AuctionTypes.Bundle) storage auctionBundles
    ) internal view returns (uint256, uint256) {
        if (allocationData.bundleIds.length == 0) revert IErrorsAndEvents.EmptyAllocation(auctionId);

        AssetConfig[] memory assets = auctionInfo.assets;
        uint256[] memory quantities = new uint256[](assets.length);
        bytes32[] memory existingCommitHashes = new bytes32[](allocationData.bundleIds.length);

        for (uint256 i = 0; i < allocationData.bundleIds.length; ) {
            BundleId bundleId = allocationData.bundleIds[i];

            if (auctionBundles[bundleId].commitHash == bytes32(0))
                revert IErrorsAndEvents.InvalidBundle(auctionId, bundleId);
            if (_checkIfDuplicateAllocation(auctionBundles[bundleId].commitHash, existingCommitHashes, i))
                revert IErrorsAndEvents.DuplicateAllocation(auctionId, auctionBundles[bundleId].commitHash);

            AuctionTypes.Bundle memory bundle = auctionBundles[bundleId];
            for (uint256 j = 0; j < bundle.quantities.length; ) {
                quantities[j] += bundle.quantities[j];
                unchecked { ++j; }
            }

            existingCommitHashes[i] = auctionBundles[bundleId].commitHash;
            unchecked { ++i; }
        }

        uint256 totalValue = 0;
        for (uint256 i = 0; i < assets.length; ) {
            AssetId assetId = AssetIdLibrary.createId(auctionId, assets[i].assetToken);

            if (quantities[i] > assetInfo[assetId].depositAmount)
                revert IErrorsAndEvents.InvalidQuantities(auctionId, quantities[i]);

            uint256 price = assetInfo[assetId].currentPrice;
            uint8 assetDecimals = CurrencyDecimals.getDecimals(assets[i].assetToken);
            totalValue += (quantities[i] * price) / (10 ** assetDecimals);

            unchecked { ++i; }
        }

        return (totalValue, totalValue);
    }

    function _checkIfDuplicateAllocation(
        bytes32 commitHash,
        bytes32[] memory existingCommitHashes,
        uint256 index
    ) internal pure returns (bool) {
        for (uint256 i = 0; i < index; i++) {
            if (existingCommitHashes[i] == commitHash) return true;
        }
        return false;
    }

    function selectWinner(
        AuctionId auctionId,
        AllocationPhaseState storage allocState,
        ProxyPhaseState storage proxyState,
        mapping(bytes32 => BundleId) storage winningBundleIds
    ) internal {
        AuctionTypes.Allocation memory winner = allocState.topAllocation.allocation;
        for (uint256 i = 0; i < winner.bundleIds.length; ) {
            winningBundleIds[proxyState.bundles[winner.bundleIds[i]].commitHash] = winner.bundleIds[i];
            unchecked { ++i; }
        }
    }

    function shouldAllocationPhaseEnd(
        AuctionId auctionId,
        AllocationPhaseState storage allocState,
        mapping(AuctionId => AuctionTypes.AuctionInfo) storage auctionInfo
    ) internal view returns (bool) {
        uint256 startTime = allocState.allocationPhaseStartTime;
        if (startTime == 0) return false;
        return block.timestamp >= startTime + auctionInfo[auctionId].config.phaseDurations[1];
    }
}
