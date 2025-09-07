// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { BaseHook } from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { Hooks } from "@uniswap/v4-core/src/libraries/Hooks.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { AuctionTypes } from "../AuctionTypes.sol";
import { CPAStorage } from "../base/CPAStorage.sol";
import { IErrorsAndEvents } from "../utils/IErrorsAndEvents.sol";

library CPAProxyPhase {

    /**
	 * @notice Submit bundle during proxy phase
	 * @param self The contract instance
	 * @param commitHash The commit hash
	 * @param bundleData The bundle data
	 */
	function submitBundle(
		CPAStorage self,
		bytes32 commitHash,
		AuctionTypes.Bundle calldata bundleData
	) external {
		if (self.commitProxy(commitHash) != msg.sender) revert IErrorsAndEvents.Unauthorized();
		if (self.getBundlesLength(commitHash) > 0) revert IErrorsAndEvents.DuplicateBundle();
		
		(bool success,) = address(self).call(
			abi.encodeWithSignature("_addBundle(bytes32,(uint256,uint256,uint256[],uint256[],uint256))", commitHash, bundleData)
		);
		require(success, "Bundle add failed");
		
		emit IErrorsAndEvents.BundleSubmitted(commitHash, bundleData.bundleId);
	}

    /**
	 * @notice Get all bundles
	 * @param self The contract instance
	 * @return allBundles Array of all bundles
	 */
	function getAllBundles(CPAStorage self) internal view returns (AuctionTypes.Bundle[] memory allBundles) {
		// TODO: Implement bundle collection
		// This should flatten all bundles from all commit hashes
		// into a single array for allocation scoring
		
		// Placeholder: return empty array
		return allBundles;
	}

}
