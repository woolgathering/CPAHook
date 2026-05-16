// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IPositionManager } from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

import { CPABase } from "../base/CPABase.sol";
import { CPAClockPhase } from "../libraries/CPAClockPhase.sol";
import { AuctionTypes } from "../types/AuctionTypes.sol";
import { AuctionId } from "../types/AuctionId.sol";

contract ClockPhaseFacet is CPABase {

	constructor(
		IPoolManager _poolManager,
		address _owner,
		address _cpaAuctionHookAddr,
		IPositionManager _positionManager,
		address _protocolWallet
	) CPABase(_poolManager, _owner, _cpaAuctionHookAddr, _positionManager, _protocolWallet) {}

	function startClockPhase(AuctionId auctionId)
		external
		nonReentrant
		onlyAuctionOwner(auctionId)
		onlyPhase(auctionId, AuctionTypes.AuctionPhase.Setup)
	{
		_startClockRound(auctionId);
	}

	function endClockRound(AuctionId auctionId)
		external
		nonReentrant
		onlyAuctionOwner(auctionId)
		onlyPhase(auctionId, AuctionTypes.AuctionPhase.Clock)
	{
		CPAClockPhase.setClockOpen(auctionId, 1, auctionInfo);

		uint256[] memory totalDemands = CPAClockPhase.processClockRound(
			this, auctionId, auctionInfo[auctionId], poolInfo, bids[auctionId], activeBidders
		);

		emit ClockRoundClosed(auctionId, auctionInfo[auctionId].currentRound, activeBidders[auctionId].length);

		if (CPAClockPhase.shouldEndClockPhase(auctionId, auctionInfo[auctionId], poolInfo, totalDemands, manager)) {
			_endClockPhase(auctionId);
		} else {
			_startClockRound(auctionId);
		}
	}

	function endClockPhase(AuctionId auctionId)
		external
		nonReentrant
		onlyAuctionOwner(auctionId)
		onlyPhase(auctionId, AuctionTypes.AuctionPhase.Clock)
	{
		_endClockPhase(auctionId);
	}

	function submitBid(
		AuctionId auctionId,
		uint256[] calldata demands,
		uint256 maxStakeAmount
	)
		external
		payable
		whenAuctionActive(auctionId)
		onlyPhase(auctionId, AuctionTypes.AuctionPhase.Clock)
		onlyWhenPhaseNotExpired(auctionId, AuctionTypes.AuctionPhase.Clock)
		validateEthForNumeraire(auctionId)
	{
		CPAClockPhase.processBid(
			this,
			auctionId,
			demands,
			maxStakeAmount,
			auctionInfo[auctionId],
			bidderStake[auctionId],
			bidderBidPoints[auctionId],
			bids[auctionId],
			activeBidders[auctionId]
		);
	}

	function commitToBidder(AuctionId auctionId, bytes32 commitHash) external {
		commitProxy[auctionId][commitHash] = msg.sender;
	}

	function registerCommit(AuctionId auctionId, bytes32 commitHash) external {
		if (commitProxy[auctionId][commitHash] != address(0)) revert InvalidCommitHash();
		commitProxy[auctionId][commitHash] = msg.sender;
	}

	function dropout(AuctionId auctionId)
		external
		whenAuctionActive(auctionId)
		onlyPhase(auctionId, AuctionTypes.AuctionPhase.Clock)
		onlyWhenPhaseNotExpired(auctionId, AuctionTypes.AuctionPhase.Clock)
	{
		uint256 stake = bidderStake[auctionId][msg.sender];
		if (stake == 0) revert InvalidStakeAmount();

		uint256 penalty = (stake * auctionInfo[auctionId].config.dropoutSlashRatio) / 10000;
		uint256 refund = stake - penalty;

		bidderStake[auctionId][msg.sender] = 0;
		bidderBidPoints[auctionId][msg.sender] = 0;
		removeBidder(auctionId, msg.sender);

		droppedBidders[auctionId][msg.sender] = true;
		protocolPenalties[auctionId] += penalty;

		AuctionTypes.CallbackDataRefundStake memory data = AuctionTypes.CallbackDataRefundStake({
			numeraire: auctionInfo[auctionId].commonNumeraire,
			recipient: msg.sender,
			amount: refund
		});
		manager.unlock(abi.encode(uint8(5), abi.encode(data)));

		emit PenaltyApplied(auctionId, msg.sender, penalty);
		emit StakeRefunded(auctionId, msg.sender, refund);
	}
}
