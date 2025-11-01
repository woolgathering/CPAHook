// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";

import { CPAStorage } from "../base/CPAStorage.sol";
import { StorageAccess } from "../utils/StorageAccess.sol";
import { IErrorsAndEvents } from "../utils/IErrorsAndEvents.sol";
import { AuctionTypes } from "../types/AuctionTypes.sol";
import { AuctionId } from "../types/AuctionId.sol";
import { BundleId, BundleIdLibrary } from "../types/BundleId.sol";

contract CPAProxyPhase {
	using StorageAccess for *;

	

	function startProxyPhase(
		CPAStorage self,
		AuctionId auctionId
	) public {
		// we need to confirm that the clock phase is over
		// and that the auction is ready to start the proxy phase
		// self.setPhase(AuctionTypes.AuctionPhase.Proxy);
		StorageAccess.setProxyPhaseStartTime(auctionId, block.timestamp);
	}

	function shouldProxyPhaseEnd(
		CPAStorage self, 
		AuctionId auctionId
	) public view returns (bool) {
		// Check if proxy phase duration has expired
		uint256 startTime = StorageAccess.getProxyPhaseStartTime(auctionId);
		if (startTime == 0) return true; // Phase not started yet

		if (StorageAccess.getHasBundles(auctionId)) {
			// Get auctionInfo and phase duration from auction config
			AuctionTypes.AuctionInfo memory auctionInfoData = StorageAccess.getAuctionInfo(auctionId);
			return block.timestamp < (startTime + auctionInfoData.config.phaseDurations[0]);
		} else {
			return true;
		}
	}

    /**
	 * @notice Submit bundle during proxy phase. This does not do any auction-level checks but updates the state of the auction.
	 * @param self The contract instance (CPAManager via DELEGATECALL)
	 * @param commitHash The commit hash
	 * @param bundleData The bundle data
	 * @return bundleId The created bundle ID
	 * @dev Storage mappings are accessed via helpers since DELEGATECALL executes in CPAManager's storage context
	 */
	function submitBundle(
		CPAStorage self,
		bytes32 commitHash,
		AuctionTypes.Bundle calldata bundleData
	) public returns (BundleId bundleId) {
		bundleId = BundleIdLibrary.createId(bundleData.commitHash, keccak256(abi.encode(bundleData.quantities)));

		// check that the bundle is valid
		bytes memory err = _isValidBundle(self, msg.sender, commitHash, bundleId, bundleData);
		if (err.length > 0) {
            assembly {
                revert(add(err, 0x20), mload(err))
            }
        }

		// Convert calldata to memory for StorageAccess
		AuctionTypes.Bundle memory bundleMemory = bundleData;
		// add the bundle to the bundles mapping via StorageAccess
		StorageAccess.setBundle(bundleData.auctionId, bundleId, bundleMemory);

		// mark that bundles have been submitted for this auction
		StorageAccess.setHasBundles(bundleData.auctionId, true);

		// emit a bundle submitted event
		emit IErrorsAndEvents.BundleSubmitted(bundleData.auctionId, bundleData.commitHash, bundleId, bundleData.quantities, bundleData.value);
	}

	function _isValidBundle(
		CPAStorage self,
		address sender,
		bytes32 commitHash,
		BundleId bundleId,
		AuctionTypes.Bundle calldata bundleData
	) internal view returns (bytes memory) {
		// check that the commit hash matches the one in bundle data
		if (commitHash != bundleData.commitHash) return abi.encodeWithSelector(IErrorsAndEvents.SenderIsNotProxy.selector, bundleData.auctionId, bundleData.commitHash);
		
		// check that the msg.sender is the proxy for the commit hash
		address proxy = StorageAccess.getCommitProxy(bundleData.auctionId, bundleData.commitHash);
		if (proxy != sender) return abi.encodeWithSelector(IErrorsAndEvents.SenderIsNotProxy.selector, bundleData.auctionId, bundleData.commitHash);

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

		// check that the bundle is not already submitted via StorageAccess
		AuctionTypes.Bundle memory existingBundle = StorageAccess.getBundle(bundleData.auctionId, bundleId);
		if (existingBundle.commitHash != bytes32(0)) return abi.encodeWithSelector(IErrorsAndEvents.DuplicateBundle.selector, bundleData.auctionId, bundleData.commitHash);

		return "";
	}

    /**
	 * @notice Check if a bundle exists (for allocators to validate references)
	 * @param self The contract instance (CPAManager via DELEGATECALL)
	 * @param auctionId The auction ID
	 * @param bundleId The bundle ID to check
	 * @return exists True if bundle exists
	 */
	function bundleExists(
		CPAStorage self,
		AuctionId auctionId,
		BundleId bundleId
	) public view returns (bool exists) {
		AuctionTypes.Bundle memory bundle = StorageAccess.getBundle(auctionId, bundleId);
		return bundle.commitHash != bytes32(0);
	}


}
