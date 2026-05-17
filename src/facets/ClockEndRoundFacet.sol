// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IPositionManager } from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

import { CPABase } from "../base/CPABase.sol";
import { CPAClockPhase } from "../libraries/CPAClockPhase.sol";
import { AuctionTypes } from "../types/AuctionTypes.sol";
import { AuctionId } from "../types/AuctionId.sol";

contract ClockEndRoundFacet is CPABase {

	constructor(
		IPoolManager _poolManager,
		address _owner,
		address _cpaAuctionHookAddr,
		IPositionManager _positionManager,
		address _protocolWallet,
		address _mathFacet
	) CPABase(_poolManager, _owner, _cpaAuctionHookAddr, _positionManager, _protocolWallet, _mathFacet) {}

	function processClockRoundStep(AuctionId auctionId)
		external
		nonReentrant
		onlyAuctionOwner(auctionId)
		onlyPhase(auctionId, AuctionTypes.AuctionPhase.Clock)
	{
		require(!roundPendingFinalize[auctionId], "Round already processed - finalize first");
		uint256 activeBidderCount = activeBidders[auctionId].length;
		CPAClockPhase.setClockOpen(auctionId, 1, auctionInfo);
		uint256[] memory totalDemands = CPAClockPhase.processClockRound(
			this, auctionId, auctionInfo[auctionId], poolInfo, bids[auctionId], activeBidders
		);
		pendingRoundDemands[auctionId] = totalDemands;
		roundPendingFinalize[auctionId] = true;
		emit ClockRoundClosed(auctionId, auctionInfo[auctionId].currentRound, activeBidderCount);
	}
}
