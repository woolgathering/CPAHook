// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { BaseHook } from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { Hooks } from "@uniswap/v4-core/src/libraries/Hooks.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { AuctionTypes } from "../AuctionTypes.sol";
import { CPAStorage } from "../base/CPAStorage.sol";
import { AllocationScoring } from "../AllocationScoring.sol";
import { IErrorsAndEvents } from "../utils/IErrorsAndEvents.sol";

library CPAAllocationPhase {

    /**
	 * @notice Submit allocation during allocation phase
	 * @param self The contract instance
	 * @param allocationData The allocation data
	 */
	function submitAllocation(
		CPAStorage self,
		AuctionTypes.Allocation calldata allocationData
	) external {
		AuctionTypes.Allocation memory newAllocation = allocationData;
		newAllocation.allocator = msg.sender;
		newAllocation.allocationId = self.getAllocationsLength();
		newAllocation.timestamp = block.timestamp;
		
		(bool success,) = address(self).call(
			abi.encodeWithSignature("_addAllocation((uint256,address,uint256,uint256[],uint256[],uint256))", newAllocation)
		);
		require(success, "Allocation add failed");
		
		emit IErrorsAndEvents.AllocationSubmitted(msg.sender, newAllocation.allocationId);
	}

}
