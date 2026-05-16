// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IPositionManager } from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

import { CPABaseClock } from "../base/CPABaseClock.sol";
import { CPAClockPhase } from "../libraries/CPAClockPhase.sol";
import { AuctionTypes } from "../types/AuctionTypes.sol";
import { AuctionId } from "../types/AuctionId.sol";

contract ClockBidFacet is CPABaseClock {

	constructor(
		IPoolManager _poolManager,
		address _owner,
		address _cpaAuctionHookAddr,
		IPositionManager _positionManager,
		address _protocolWallet,
		address _mathFacet
	) CPABaseClock(_poolManager, _owner, _cpaAuctionHookAddr, _positionManager, _protocolWallet, _mathFacet) {}

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
}
