// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IPositionManager } from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

import { CPABase } from "../base/CPABase.sol";
import { CPAAllocationPhase } from "../libraries/CPAAllocationPhase.sol";
import { AuctionTypes } from "../types/AuctionTypes.sol";
import { AuctionId } from "../types/AuctionId.sol";

contract AllocationPhaseFacet is CPABase {

	constructor(
		IPoolManager _poolManager,
		address _owner,
		address _cpaAuctionHookAddr,
		IPositionManager _positionManager,
		address _protocolWallet
	) CPABase(_poolManager, _owner, _cpaAuctionHookAddr, _positionManager, _protocolWallet) {}

	function submitAllocation(
		AuctionId auctionId,
		AuctionTypes.Allocation calldata allocationData
	)
		external
		whenAuctionActive(auctionId)
		onlyPhase(auctionId, AuctionTypes.AuctionPhase.Allocation)
		onlyWhenPhaseNotExpired(auctionId, AuctionTypes.AuctionPhase.Allocation)
	{
		if (msg.sender != allocationData.allocator) revert Unauthorized();

		CPAAllocationPhase.submitAllocation(
			this, allocationData, topAllocation, auctionInfo[auctionId], poolInfo, bundles[auctionId], hasAllocations
		);
	}

	function transitionToAllocation(AuctionId auctionId)
		external
		nonReentrant
		whenAuctionActive(auctionId)
		onlyPhase(auctionId, AuctionTypes.AuctionPhase.Proxy)
	{
		if (!_hasPhaseExpired(auctionId, AuctionTypes.AuctionPhase.Proxy))
			revert PhaseNotExpired(auctionId, AuctionTypes.AuctionPhase.Proxy);

		if (!hasBundles[auctionId]) {
			_cancelAuction(auctionId);
			revert NoSubmissionsReceived(auctionId, AuctionTypes.AuctionPhase.Proxy);
		}

		_changePhase(auctionId, AuctionTypes.AuctionPhase.Allocation);
	}
}
