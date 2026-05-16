// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IPositionManager } from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

import { CPABase } from "../base/CPABase.sol";
import { AuctionTypes } from "../types/AuctionTypes.sol";
import { AuctionId } from "../types/AuctionId.sol";

contract CoreFacet is CPABase {

	constructor(
		IPoolManager _poolManager,
		address _owner,
		address _cpaAuctionHookAddr,
		IPositionManager _positionManager,
		address _protocolWallet
	) CPABase(_poolManager, _owner, _cpaAuctionHookAddr, _positionManager, _protocolWallet) {}

	function setCpaAuctionHookAddr(address _cpaAuctionHookAddr) external onlyOwner {
		cpaAuctionHookAddr = _cpaAuctionHookAddr;
	}

	function pause(AuctionId auctionId) external nonReentrant onlyAuctionOwner(auctionId) {
		AuctionTypes.AuctionInfo storage auction = auctionInfo[auctionId];

		if (auction.currentStatus == AuctionTypes.AuctionStatus.Paused)
			revert AuctionNotActive(auctionId, AuctionTypes.AuctionStatus.Paused);

		if (
			auction.currentPhase == AuctionTypes.AuctionPhase.Settlement ||
			auction.currentPhase == AuctionTypes.AuctionPhase.Finished
		) revert InvalidPhase(AuctionTypes.AuctionPhase.Setup, auction.currentPhase);

		uint256 currentPauseDuration = auction.totalPauseDuration;
		if (currentPauseDuration > AuctionTypes.MAX_PAUSE_DURATION)
			revert MaxPauseDurationExceeded(currentPauseDuration, AuctionTypes.MAX_PAUSE_DURATION);

		auction.currentStatus = AuctionTypes.AuctionStatus.Paused;
		pauseStartTime[auctionId] = block.timestamp;
		_updateCPAHookStates(auctionId);
		emit AuctionPaused(auctionId, msg.sender);
	}

	function unpause(AuctionId auctionId) external nonReentrant onlyAuctionOwner(auctionId) {
		AuctionTypes.AuctionInfo storage auction = auctionInfo[auctionId];

		if (auction.currentStatus != AuctionTypes.AuctionStatus.Paused)
			revert AuctionNotActive(auctionId, auction.currentStatus);

		uint256 newTotalPauseDuration = auction.totalPauseDuration + (block.timestamp - pauseStartTime[auctionId]);

		if (newTotalPauseDuration >= AuctionTypes.MAX_PAUSE_DURATION)
			revert MaxPauseDurationExceeded(newTotalPauseDuration, AuctionTypes.MAX_PAUSE_DURATION);

		auction.totalPauseDuration = newTotalPauseDuration;
		pauseStartTime[auctionId] = 0;
		auction.currentStatus = AuctionTypes.AuctionStatus.Active;
		_updateCPAHookStates(auctionId);
		emit AuctionUnpaused(auctionId, msg.sender);
	}

	function cancelAuction(AuctionId auctionId) external nonReentrant onlyAuctionOwner(auctionId) {
		AuctionTypes.AuctionPhase phase = auctionInfo[auctionId].currentPhase;
		if (phase != AuctionTypes.AuctionPhase.Setup && phase != AuctionTypes.AuctionPhase.Clock)
			revert CannotCancelInThisPhase(auctionId, phase);

		auctionInfo[auctionId].currentStatus = AuctionTypes.AuctionStatus.Cancelled;
		_updateCPAHookStates(auctionId);
		emit AuctionCancelled(auctionId, msg.sender);
	}

	function forceCancelAuction(AuctionId auctionId) external nonReentrant {
		AuctionTypes.AuctionInfo storage auction = auctionInfo[auctionId];

		uint256 totalPauseDuration = auction.totalPauseDuration;
		if (auction.currentStatus == AuctionTypes.AuctionStatus.Paused)
			totalPauseDuration += block.timestamp - pauseStartTime[auctionId];

		if (totalPauseDuration < AuctionTypes.MAX_PAUSE_DURATION)
			revert PauseDurationNotExceeded(totalPauseDuration, AuctionTypes.MAX_PAUSE_DURATION);

		auction.currentStatus = AuctionTypes.AuctionStatus.Cancelled;
		_updateCPAHookStates(auctionId);
		emit AuctionCancelled(auctionId, msg.sender);
	}
}
