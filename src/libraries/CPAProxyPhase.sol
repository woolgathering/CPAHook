// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { CPAStorage } from "../base/CPAStorage.sol";
import { IErrorsAndEvents } from "../utils/IErrorsAndEvents.sol";
import { AuctionTypes } from "../types/AuctionTypes.sol";
import { AuctionId } from "../types/AuctionId.sol";
import { BundleId, BundleIdLibrary } from "../types/BundleId.sol";

library CPAProxyPhase {

    function startProxyPhase(
        CPAStorage,
        mapping(AuctionId => uint256) storage proxyPhaseStartTime,
        AuctionId auctionId
    ) internal {
        proxyPhaseStartTime[auctionId] = block.timestamp;
    }

    function shouldProxyPhaseEnd(
        CPAStorage self,
        AuctionId auctionId,
        mapping(AuctionId => AuctionTypes.AuctionInfo) storage auctionInfo
    ) internal view returns (bool) {
        uint256 startTime = self.proxyPhaseStartTime(auctionId);
        if (startTime == 0) return true;

        if (self.hasBundles(auctionId)) {
            return block.timestamp < (startTime + auctionInfo[auctionId].config.phaseDurations[0]);
        } else {
            return true;
        }
    }

    function submitBundle(
        CPAStorage self,
        bytes32 commitHash,
        mapping(BundleId => AuctionTypes.Bundle) storage auctionBundles,
        mapping(bytes32 => address) storage auctionCommitProxy,
        AuctionTypes.Bundle calldata bundleData,
        mapping(AuctionId => bool) storage hasBundles
    ) internal returns (BundleId bundleId) {
        bundleId = BundleIdLibrary.createId(bundleData.commitHash, keccak256(abi.encode(bundleData.quantities)));

        bytes memory err = _isValidBundle(self, msg.sender, commitHash, bundleId, auctionBundles, auctionCommitProxy, bundleData);
        if (err.length > 0) {
            assembly {
                revert(add(err, 0x20), mload(err))
            }
        }

        auctionBundles[bundleId] = bundleData;
        hasBundles[bundleData.auctionId] = true;

        emit IErrorsAndEvents.BundleSubmitted(
            bundleData.auctionId, bundleData.commitHash, bundleId, bundleData.quantities, bundleData.value
        );
    }

    function _isValidBundle(
        CPAStorage self,
        address sender,
        bytes32 commitHash,
        BundleId bundleId,
        mapping(BundleId => AuctionTypes.Bundle) storage auctionBundles,
        mapping(bytes32 => address) storage auctionCommitProxy,
        AuctionTypes.Bundle calldata bundleData
    ) internal view returns (bytes memory) {
        if (commitHash != bundleData.commitHash)
            return abi.encodeWithSelector(IErrorsAndEvents.SenderIsNotProxy.selector, bundleData.auctionId, bundleData.commitHash);

        if (auctionCommitProxy[bundleData.commitHash] != sender)
            return abi.encodeWithSelector(IErrorsAndEvents.SenderIsNotProxy.selector, bundleData.auctionId, bundleData.commitHash);

        if (bundleData.quantities.length != self.getNumItems(bundleData.auctionId))
            return abi.encodeWithSelector(IErrorsAndEvents.InvalidBundleQuantities.selector, bundleData.auctionId, bundleData.commitHash);

        bool hasNonZeroDemand = false;
        for (uint256 i = 0; i < bundleData.quantities.length; i++) {
            if (bundleData.quantities[i] > 0) { hasNonZeroDemand = true; break; }
        }
        if (!hasNonZeroDemand)
            return abi.encodeWithSelector(IErrorsAndEvents.InvalidBundleQuantities.selector, bundleData.auctionId, bundleData.commitHash);

        if (auctionBundles[bundleId].commitHash != bytes32(0))
            return abi.encodeWithSelector(IErrorsAndEvents.DuplicateBundle.selector, bundleData.auctionId, bundleData.commitHash);

        return "";
    }

    function bundleExists(
        mapping(BundleId => AuctionTypes.Bundle) storage auctionBundles,
        BundleId bundleId
    ) internal view returns (bool) {
        return auctionBundles[bundleId].commitHash != bytes32(0);
    }
}
