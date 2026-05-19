// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IPositionManager } from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

import { CPABase } from "../base/CPABase.sol";
import { CPAFinishedPhase } from "../libraries/CPAFinishedPhase.sol";
import { AuctionTypes } from "../types/AuctionTypes.sol";
import { AuctionId } from "../types/AuctionId.sol";

contract FinishedPhaseFacet is CPABase {

	constructor(
		IPoolManager _poolManager,
		address _owner,
		address _cpaAuctionHookAddr,
		IPositionManager _positionManager,
		address _protocolWallet,
		address _mathFacet
	) CPABase(_poolManager, _owner, _cpaAuctionHookAddr, _positionManager, _protocolWallet, _mathFacet) {}

	function transferPositionsToAuctioneer(AuctionId auctionId)
		external
		nonReentrant
		whenAuctionActive(auctionId)
		onlyPhase(auctionId, AuctionTypes.AuctionPhase.Finished)
	{
		CPAFinishedPhase.transferPositionsToAuctioneer(this, auctionId, auctionInfo[auctionId], poolInfo);
	}

	function forfeit(AuctionId auctionId, address bidder)
		external
		onlyPhase(auctionId, AuctionTypes.AuctionPhase.Finished)
	{
		uint256 stake = bidderStake[auctionId][bidder];
		if (stake == 0) revert InvalidStakeAmount();

		uint256 penaltyRate = auctionInfo[auctionId].config.minSpendRatio;

		protocolPenalties[auctionId] += stake * penaltyRate / 10000;

		uint256 callerReward = stake * FORFEITURE_REWARD_RATE / 10000;
		if (callerReward > 0) {
			AuctionTypes.CallbackDataRefundStake memory data = AuctionTypes.CallbackDataRefundStake({
				numeraire: auctionInfo[auctionId].commonNumeraire,
				recipient: msg.sender,
				amount: callerReward
			});
			manager.unlock(abi.encode(uint8(5), abi.encode(data)));
			emit ForfeitureRewardTransferred(auctionId, msg.sender, callerReward);
		}

		uint256 remaining = stake - (stake * (penaltyRate + FORFEITURE_REWARD_RATE) / 10000);
		if (remaining > 0) {
			AuctionTypes.CallbackDataRefundStake memory refundData = AuctionTypes.CallbackDataRefundStake({
				numeraire: auctionInfo[auctionId].commonNumeraire,
				recipient: bidder,
				amount: remaining
			});
			manager.unlock(abi.encode(uint8(5), abi.encode(refundData)));
		}

		bidderStake[auctionId][bidder] = 0;
		bidderBidPoints[auctionId][bidder] = 0;

		emit BundleForfeited(auctionId, bidder, stake * penaltyRate / 10000);
	}
}
