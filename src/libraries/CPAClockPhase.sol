// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { BaseHook } from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { Hooks } from "@uniswap/v4-core/src/libraries/Hooks.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { AuctionTypes } from "../AuctionTypes.sol";
import { IErrorsAndEvents } from "../utils/IErrorsAndEvents.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { CommitReveal } from "../CommitReveal.sol";
import { CPAStorage } from "../base/CPAStorage.sol";

library CPAClockPhase {

	/**
	 * @notice Submit a bid during clock phase
	 * @param self The contract instance
	 * @param demands Array of item demands
	 * @param commitHash The commit hash for privacy
	 * @param stakeAmount Additional stake amount
	 */
	function submitBid(
		CPAStorage self,
		uint256[] calldata demands,
		bytes32 commitHash,
		uint256 stakeAmount
	) external {
		if (!self.clockOpen()) revert IErrorsAndEvents.ClockNotOpen();
		if (!CommitReveal.isValidCommitHash(commitHash)) revert IErrorsAndEvents.InvalidCommitHash();
		
		// Add stake to bidder
		(bool success1,) = address(self).call(
			abi.encodeWithSignature("_addBidderStake(address,uint256)", msg.sender, stakeAmount)
		);
		require(success1, "Stake update failed");
		
		(bool success2,) = address(self).call(
			abi.encodeWithSignature("_setBidderBidPoints(address,uint256)", msg.sender, computeBidPoints(self.bidderStake(msg.sender)))
		);
		require(success2, "Bid points update failed");

		// Transfer stake from bidder to auction contract
		if (stakeAmount > 0) {
			IERC20(self.commonNumeraire()).transferFrom(msg.sender, address(this), stakeAmount); 
		}
		// would be interesting to eventually have "deposits" for bidders who use the system often
		// so that they don't have to transfer the common numeraire every time they bid.
		// the deposit could be rehypothecated by the protocol when not being used. During auctions,
		// this auction contract would make a "claim" against the deposits that are needed for staking.
		// the complication is that we do not assert a common numeraire across all auction contracts.
		
		// Calculate total bid value
		uint256 totalValue = calculateBidValue(self, demands);
		if (totalValue > self.bidderBidPoints(msg.sender)) revert IErrorsAndEvents.InsufficientBidPoints();
		
		// Record the bid
		AuctionTypes.Bid memory bid = AuctionTypes.Bid({
			bidder: msg.sender,
			commitHash: commitHash,
			stakeAmount: stakeAmount,
			itemIds: new uint256[](0), // TODO: Add item IDs
			quantities: demands,
			round: self.currentRound(),
			timestamp: block.timestamp
		});
		
		(bool success3,) = address(self).call(
			abi.encodeWithSignature("_addRoundBid((address,bytes32,uint256,uint256[],uint256[],uint256,uint256))", bid)
		);
		require(success3, "Bid recording failed");
		
		emit IErrorsAndEvents.BidSubmitted(msg.sender, commitHash, stakeAmount, self.currentRound());
	}

	function computeBidPoints(uint256 stakeAmount) internal pure returns (uint256 bidPoints) {
		bidPoints = stakeAmount; // 1:1 ratio for now, could theoretically be anything
	}

    /**
	 * @notice Dropout from auction with penalty
	 */
	function dropout(CPAStorage self) external {
		uint256 stake = self.bidderStake(msg.sender);
		if (stake == 0) revert IErrorsAndEvents.InvalidStakeAmount();
		
		(, uint256 dropoutSlashRatio, , , , , , , , ) = self.config();
		uint256 penalty = (stake * dropoutSlashRatio) / 10000;
		uint256 refund = stake - penalty;
		
		(bool success4,) = address(self).call(
			abi.encodeWithSignature("_clearBidderData(address)", msg.sender)
		);
		require(success4, "Bidder data clear failed");
		
		(bool success5,) = address(self).call(
			abi.encodeWithSignature("_setDroppedBidder(address,bool)", msg.sender, true)
		);
		require(success5, "Dropped bidder set failed");
		
		// Transfer refund to bidder (simplified)
		// In practice, this would use SafeERC20
		
		emit IErrorsAndEvents.PenaltyApplied(msg.sender, penalty);
		emit IErrorsAndEvents.StakeRefunded(msg.sender, refund);
	}
    

	/**
	 * @notice Process clock round results
	 */
	function processClockRound(CPAStorage self) internal {
		// TODO: Implement clock round processing
		// This should calculate excess demand for each item
		// and update pool prices accordingly
		
		// Placeholder: basic excess demand calculation
		PoolId[] memory pools = self.getAllPools();
		for (uint256 i = 0; i < pools.length; i++) {
			uint256 totalDemand = 0;
			for (uint256 j = 0; j < self.getRoundBidsLength(); j++) {
				AuctionTypes.Bid memory bid = self.getRoundBid(j);
				if (bid.itemIds.length > i) {
					totalDemand += bid.quantities[i];
				}
			}
			
            // if there is excess demand, increase the price
			(PoolKey memory key, uint256 currentPrice, uint256 depositAmount, uint256 excessDemand) = self.poolInfo(pools[i]);
			if (totalDemand > depositAmount) {
				
			} else {
				// no excess demand
			}
		}
	}

	/**
	 * @notice Check if clock phase should end
	 * @param self The contract instance
	 * @return shouldEnd True if clock phase should end
	 */
	function shouldEndClockPhase(CPAStorage self) internal view returns (bool shouldEnd) {
		PoolId[] memory pools = self.getAllPools();
		for (uint256 i = 0; i < pools.length; i++) {
			// TODO: Check excess demand logic
			// if (self.pools[i].excessDemand > 0) {
			// 	return false;
			// }
		}
		return true;
	}

	/**
	 * @notice Calculate bid value
	 * @param self The contract instance
	 * @param demands Array of demands
	 * @return totalValue Total value of the bid
	 */
	function calculateBidValue(CPAStorage self, uint256[] calldata demands) internal view returns (uint256 totalValue) {
		// TODO: Implement bid value calculation
		// This should calculate the total value based on current prices
		// and the bidder's demands
		
		// Placeholder: simple multiplication
		PoolId[] memory pools = self.getAllPools();
		for (uint256 i = 0; i < demands.length && i < pools.length; i++) {
			// totalValue += demands[i] * self.pools[i].currentPrice;
		}
	}


	/**
	 * @notice Get total bidders
	 * @param self The contract instance
	 * @return totalBidders Total number of bidders
	 */
	function getTotalBidders(CPAStorage self) internal view returns (uint256 totalBidders) {
		// TODO: Implement bidder counting
		// This should count unique bidders, not just round bids
		
		// Placeholder: return round bids length
		return self.getRoundBidsLength();
	}
}
