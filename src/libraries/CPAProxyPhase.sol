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

	

	function startProxyPhase(CPAStorage self, mapping(AuctionId => uint256) storage proxyPhaseStartTime, AuctionId auctionId) internal {
		// we need to confirm that the clock phase is over
		// and that the auction is ready to start the proxy phase
		// self.setPhase(AuctionTypes.AuctionPhase.Proxy);
		proxyPhaseStartTime[auctionId] = block.timestamp;
	}

	function endProxyPhase(CPAStorage self, AuctionId auctionId) internal view {
		// we need to check here that bundles were submitted
		// I think, perhaps we don't need to do anything
		if (_shouldProxyPhaseEnd(self, auctionId)) {
			// self.setPhase(AuctionTypes.AuctionPhase.Proxy);
		}
	}

	function _shouldProxyPhaseEnd(CPAStorage self, AuctionId auctionId) internal pure returns (bool) {
		// check if our time for the proxy phase has ended
		// the limit should be defined in the auction config
		// uint256 (address, uint256, uint256, uint256, uint256, uint256, uint256, PoolKey[] memory, uint160[] memory, int24[] memory) = self.getAuctionConfig(auctionId);
		// return block.timestamp - self.proxyPhaseStartTime[auctionId] > proxyPhaseDuration;
		return false;
	}

    /**
	 * @notice Submit bundle during proxy phase. This does not do any auction-level checks but updates the state of the auction.
	 * @param self The contract instance
	 * @param commitHash The commit hash
	 * @param bundleData The bundle data
	 */
	function submitBundle(
		CPAStorage self,
		bytes32 commitHash,
		mapping(AuctionId => mapping(BundleId => AuctionTypes.Bundle)) storage bundles,
		mapping(AuctionId => mapping(bytes32 => address)) storage commitProxy,
		AuctionTypes.Bundle calldata bundleData
	) internal returns (BundleId bundleId) {
		bundleId = BundleIdLibrary.createId(bundleData.commitHash, keccak256(abi.encode(bundleData.quantities)));

		// check that the bundle is valid
		bytes memory err = _isValidBundle(self, msg.sender, commitHash, bundleId, bundles, commitProxy, bundleData);
		if (err.length > 0) {
            assembly {
                revert(add(err, 0x20), mload(err))
            }
        }

		// add the bundle to the bundles mapping
		bundles[bundleData.auctionId][bundleId] = bundleData;

		// emit a bundle submitted event
		emit IErrorsAndEvents.BundleSubmitted(bundleData.auctionId, bundleData.commitHash, bundleId, bundleData.quantities, bundleData.value);
	}

	function _isValidBundle(
		CPAStorage self,
		address sender,
		bytes32 commitHash,
		BundleId bundleId,
		mapping(AuctionId => mapping(BundleId => AuctionTypes.Bundle)) storage bundles,
		mapping(AuctionId => mapping(bytes32 => address)) storage commitProxy,
		AuctionTypes.Bundle calldata bundleData
	) internal view returns (bytes memory) {
		// check that the msg.sender is the proxy for the commit hash
		if (commitProxy[bundleData.auctionId][bundleData.commitHash] != sender) return abi.encodeWithSelector(IErrorsAndEvents.SenderIsNotProxy.selector, bundleData.auctionId, bundleData.commitHash);

		// check that the length of the allocation in the bundle is equal to the length of the items in the auction
		if (bundleData.quantities.length != self.getNumItems(bundleData.auctionId)) return abi.encodeWithSelector(IErrorsAndEvents.InvalidBundleQuantities.selector, bundleData.auctionId, bundleData.commitHash);

		// check that the bundle id is valid. bundle id is keccak256(commitHash, bundleContentsHash)
		// if(bundleData.bundleId != BundleIdLibrary.createId(bundleData.commitHash, keccak256(abi.encode(bundleData.quantities)))) return abi.encodeWithSelector(InvalidBundleId.selector, bundleData.auctionId, bundleData.commitHash);

		// check that the bundle is not already submitted
		// if bundles[auctionId][bundleId] has a non-zero commitHash, it exists
		if (bundles[bundleData.auctionId][bundleId].commitHash != bytes32(0)) return abi.encodeWithSelector(IErrorsAndEvents.DuplicateBundle.selector, bundleData.auctionId, bundleData.commitHash);

		return "";
	}

    /**
	 * @notice Check if a bundle exists (for allocators to validate references)
	 * @param bundles The bundles mapping
	 * @param auctionId The auction ID
	 * @param bundleId The bundle ID to check
	 * @return exists True if bundle exists
	 */
	function bundleExists(mapping(AuctionId => mapping(BundleId => AuctionTypes.Bundle)) storage bundles, AuctionId auctionId, BundleId bundleId) internal view returns (bool exists) {
		return bundles[auctionId][bundleId].commitHash != bytes32(0);
	}

}
