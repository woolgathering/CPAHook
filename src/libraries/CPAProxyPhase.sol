// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { ProxyPhaseState } from "../base/CPAStorage.sol";
import { IErrorsAndEvents } from "../utils/IErrorsAndEvents.sol";
import { AuctionTypes } from "../types/AuctionTypes.sol";
import { AuctionId } from "../types/AuctionId.sol";
import { BundleId, BundleIdLibrary } from "../types/BundleId.sol";

library CPAProxyPhase {

    function startProxyPhase(
        ProxyPhaseState storage proxyState
    ) internal {
        proxyState.proxyPhaseStartTime = block.timestamp;
    }

    function shouldProxyPhaseEnd(
        ProxyPhaseState storage proxyState,
        uint256 phaseDuration0
    ) internal view returns (bool) {
        uint256 startTime = proxyState.proxyPhaseStartTime;
        if (startTime == 0) return true;

        if (proxyState.hasBundles) {
            return block.timestamp < (startTime + phaseDuration0);
        } else {
            return true;
        }
    }

    function submitBundle(
        AuctionId auctionId,
        bytes32 commitHash,
        uint256 numItems,
        ProxyPhaseState storage proxyState,
        AuctionTypes.Bundle calldata bundleData
    ) internal returns (BundleId bundleId) {
        bundleId = BundleIdLibrary.createId(bundleData.commitHash, keccak256(abi.encode(bundleData.quantities)));

        bytes memory err = _isValidBundle(auctionId, msg.sender, commitHash, bundleId, proxyState, bundleData, numItems);
        if (err.length > 0) {
            assembly {
                revert(add(err, 0x20), mload(err))
            }
        }

        proxyState.bundles[bundleId] = bundleData;
        proxyState.hasBundles = true;

        emit IErrorsAndEvents.BundleSubmitted(
            bundleData.auctionId, bundleData.commitHash, bundleId, bundleData.quantities, bundleData.value
        );
    }

    function _isValidBundle(
        AuctionId auctionId,
        address sender,
        bytes32 commitHash,
        BundleId bundleId,
        ProxyPhaseState storage proxyState,
        AuctionTypes.Bundle calldata bundleData,
        uint256 numItems
    ) internal view returns (bytes memory) {
        if (AuctionId.unwrap(auctionId) != AuctionId.unwrap(bundleData.auctionId))
            return abi.encodeWithSelector(IErrorsAndEvents.SenderIsNotProxy.selector, bundleData.auctionId, bundleData.commitHash);

        if (commitHash != bundleData.commitHash)
            return abi.encodeWithSelector(IErrorsAndEvents.SenderIsNotProxy.selector, bundleData.auctionId, bundleData.commitHash);

        if (proxyState.commitProxy[bundleData.commitHash] != sender)
            return abi.encodeWithSelector(IErrorsAndEvents.SenderIsNotProxy.selector, bundleData.auctionId, bundleData.commitHash);

        if (bundleData.quantities.length != numItems)
            return abi.encodeWithSelector(IErrorsAndEvents.InvalidBundleQuantities.selector, bundleData.auctionId, bundleData.commitHash);

        bool hasNonZeroDemand = false;
        for (uint256 i = 0; i < bundleData.quantities.length; i++) {
            if (bundleData.quantities[i] > 0) { hasNonZeroDemand = true; break; }
        }
        if (!hasNonZeroDemand)
            return abi.encodeWithSelector(IErrorsAndEvents.InvalidBundleQuantities.selector, bundleData.auctionId, bundleData.commitHash);

        if (proxyState.bundles[bundleId].commitHash != bytes32(0))
            return abi.encodeWithSelector(IErrorsAndEvents.DuplicateBundle.selector, bundleData.auctionId, bundleData.commitHash);

        return "";
    }

    function bundleExists(
        ProxyPhaseState storage proxyState,
        BundleId bundleId
    ) internal view returns (bool) {
        return proxyState.bundles[bundleId].commitHash != bytes32(0);
    }
}
