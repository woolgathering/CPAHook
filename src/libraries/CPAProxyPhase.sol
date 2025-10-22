// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";

import { CPAStorage } from "../base/CPAStorage.sol";
import { IErrorsAndEvents } from "../utils/IErrorsAndEvents.sol";
import { AuctionTypes } from "../types/AuctionTypes.sol";
import { AuctionId } from "../types/AuctionId.sol";
import { BundleId, BundleIdLibrary } from "../types/BundleId.sol";

library CPAProxyPhase {

	

	function startProxyPhase(CPAStorage, mapping(AuctionId => uint256) storage proxyPhaseStartTime, AuctionId auctionId) internal {
		// we need to confirm that the clock phase is over
		// and that the auction is ready to start the proxy phase
		// self.setPhase(AuctionTypes.AuctionPhase.Proxy);
		proxyPhaseStartTime[auctionId] = block.timestamp;
	}

	function shouldProxyPhaseEnd(
		CPAStorage self, 
		AuctionId auctionId,
		mapping(AuctionId => AuctionTypes.AuctionInfo) storage auctionInfo
	) internal view returns (bool) {
		// Check if proxy phase duration has expired
		uint256 startTime = self.proxyPhaseStartTime(auctionId);
		if (startTime == 0) return true; // Phase not started yet

	if (self.hasBundles(auctionId)) {
		// Get phase duration from auction config
		return block.timestamp < (startTime + auctionInfo[auctionId].config.phaseDurations[0]);
	} else {
		return true;
	}
	}

    /**
	 * @notice Submit bundle during proxy phase. This does not do any auction-level checks but updates the state of the auction.
	 * @param self The contract instance
	 * @param commitHash The commit hash
	 * @param auctionBundles The auction-specific bundles mapping (bundles[auctionId])
	 * @param auctionCommitProxy The auction-specific commit proxy mapping (commitProxy[auctionId])
	 * @param bundleData The bundle data
	 * @param hasBundles The hasBundles mapping
	 */
	function submitBundle(
		CPAStorage self,
		bytes32 commitHash,
		mapping(BundleId => AuctionTypes.Bundle) storage auctionBundles,
		mapping(bytes32 => address) storage auctionCommitProxy,
		AuctionTypes.Bundle calldata bundleData,
		mapping(AuctionId => bool) storage hasBundles
	) internal returns (BundleId bundleId) {
		bundleId = BundleIdLibrary.createId(bundleData.commitHash, keccak256(abi.encode(bundleData.quantities)));

		// check that the bundle is valid
		bytes memory err = _isValidBundle(self, msg.sender, commitHash, bundleId, auctionBundles, auctionCommitProxy, bundleData);
		if (err.length > 0) {
            assembly {
                revert(add(err, 0x20), mload(err))
            }
        }

		// add the bundle to the bundles mapping
		auctionBundles[bundleId] = bundleData;

		// mark that bundles have been submitted for this auction
		hasBundles[bundleData.auctionId] = true;

		// emit a bundle submitted event
		emit IErrorsAndEvents.BundleSubmitted(bundleData.auctionId, bundleData.commitHash, bundleId, bundleData.quantities, bundleData.value);
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
		// check that the commit hash matches the one in bundle data
		if (commitHash != bundleData.commitHash) return abi.encodeWithSelector(IErrorsAndEvents.SenderIsNotProxy.selector, bundleData.auctionId, bundleData.commitHash);
		
		// check that the msg.sender is the proxy for the commit hash
		if (auctionCommitProxy[bundleData.commitHash] != sender) return abi.encodeWithSelector(IErrorsAndEvents.SenderIsNotProxy.selector, bundleData.auctionId, bundleData.commitHash);

		// check that the length of the allocation in the bundle is equal to the length of the items in the auction
		if (bundleData.quantities.length != self.getNumItems(bundleData.auctionId)) return abi.encodeWithSelector(IErrorsAndEvents.InvalidBundleQuantities.selector, bundleData.auctionId, bundleData.commitHash);

		// check that bundle has non-zero total demand
		bool hasNonZeroDemand = false;
		for (uint256 i = 0; i < bundleData.quantities.length; i++) {
			if (bundleData.quantities[i] > 0) {
				hasNonZeroDemand = true;
				break;
			}
		}
		if (!hasNonZeroDemand) return abi.encodeWithSelector(IErrorsAndEvents.InvalidBundleQuantities.selector, bundleData.auctionId, bundleData.commitHash);

		// check that the bundle id is valid. bundle id is keccak256(commitHash, bundleContentsHash)
		// if(bundleData.bundleId != BundleIdLibrary.createId(bundleData.commitHash, keccak256(abi.encode(bundleData.quantities)))) return abi.encodeWithSelector(InvalidBundleId.selector, bundleData.auctionId, bundleData.commitHash);

		// check that the bundle is not already submitted
		// if auctionBundles[bundleId] has a non-zero commitHash, it exists
		if (auctionBundles[bundleId].commitHash != bytes32(0)) return abi.encodeWithSelector(IErrorsAndEvents.DuplicateBundle.selector, bundleData.auctionId, bundleData.commitHash);

		return "";
	}

    /**
	 * @notice Check if a bundle exists (for allocators to validate references)
	 * @param auctionBundles The auction-specific bundles mapping (bundles[auctionId])
	 * @param bundleId The bundle ID to check
	 * @return exists True if bundle exists
	 */
	function bundleExists(mapping(BundleId => AuctionTypes.Bundle) storage auctionBundles, BundleId bundleId) internal view returns (bool exists) {
		return auctionBundles[bundleId].commitHash != bytes32(0);
	}


}
