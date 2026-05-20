// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IPositionManager } from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

import { CPABaseClock } from "../base/CPABaseClock.sol";
import { CPAClockPhase } from "../libraries/CPAClockPhase.sol";
import { AuctionTypes } from "../types/AuctionTypes.sol";
import { AuctionId } from "../types/AuctionId.sol";

contract ClockFinalizeRoundFacet is CPABaseClock {

	constructor(
		IPoolManager _poolManager,
		address _owner,
		address _cpaAuctionHookAddr,
		IPositionManager _positionManager,
		address _protocolWallet,
		address _mathFacet
	) CPABaseClock(_poolManager, _owner, _cpaAuctionHookAddr, _positionManager, _protocolWallet, _mathFacet) {}

	function finalizeClockRound(AuctionId auctionId)
		external
		nonReentrant
		onlyAuctionOwnerOrSelf(auctionId)
		onlyPhase(auctionId, AuctionTypes.AuctionPhase.Clock)
	{
		require(roundPendingFinalize[auctionId], "No round pending finalization");
		uint256[] memory totalDemands = pendingRoundDemands[auctionId];
		delete pendingRoundDemands[auctionId];
		roundPendingFinalize[auctionId] = false;

		if (CPAClockPhase.shouldEndClockPhase(auctionId, auctionInfo[auctionId], poolInfo, totalDemands, manager, mathFacet)) {
			_endClockPhase(auctionId);
		} else {
			_startClockRound(auctionId);
		}
	}
}
