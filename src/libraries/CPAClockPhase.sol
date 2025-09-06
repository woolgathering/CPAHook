// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { BaseHook } from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { Hooks } from "@uniswap/v4-core/src/libraries/Hooks.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { AuctionTypes } from "../AuctionTypes.sol";
import { AuctionId } from "../AuctionId.sol";
import { IErrorsAndEvents } from "../utils/IErrorsAndEvents.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { CommitReveal } from "../CommitReveal.sol";
import { CPAStorage } from "../base/CPAStorage.sol";

library CPAClockPhase {

	/**
	 * @notice Process a bid as liquidity during clock phase
	 * @param self The contract instance
	 * @param auctionId The auction ID
	 * @param demands Array of item demands
	 * @param commitHash The commit hash for privacy
	 * @param stakeAmount Additional stake amount
	 * @param auctionInfo Mapping for auction info
	 * @param bidderStake Mapping for bidder stakes
	 * @param bidderBidPoints Mapping for bidder bid points
	 */
	function processBidAsLiquidity(
		CPAStorage self,
		AuctionId auctionId,
		uint256[] calldata demands,
		bytes32 commitHash,
		uint256 stakeAmount,
		mapping(AuctionId => AuctionTypes.AuctionInfo) storage auctionInfo,
		mapping(AuctionId => mapping(address => uint256)) storage bidderStake,
		mapping(AuctionId => mapping(address => uint256)) storage bidderBidPoints,
		mapping(PoolId => AuctionTypes.PoolInfo) storage poolInfo,
		mapping(AuctionId => mapping(bytes32 => address)) storage commitProxy
	) internal {
		if (!auctionInfo[auctionId].clockOpen) revert IErrorsAndEvents.ClockNotOpen();
		if (!CommitReveal.isValidCommitHash(commitHash)) revert IErrorsAndEvents.InvalidCommitHash();
		
		// Check if commit hash is committed to by a proxy
		if (commitProxy[auctionId][commitHash] == address(0)) revert IErrorsAndEvents.InvalidCommitHash();
		
		// Add stake to bidder
		bidderStake[auctionId][msg.sender] += stakeAmount;
		
		// Set bidder bid points
		bidderBidPoints[auctionId][msg.sender] = computeBidPoints(bidderStake[auctionId][msg.sender]);

		// Calculate total bid value
		uint256 totalValue = calculateBidValue(demands, auctionId, auctionInfo, poolInfo);
		if (totalValue > bidderBidPoints[auctionId][msg.sender]) revert IErrorsAndEvents.InsufficientBidPoints();

		// TODO: Replace direct transfer with liquidity callback
		// Transfer stake from bidder to auction contract via pool manager
		if (stakeAmount > 0) {
					// Call liquidity callback to transfer tokens from user to pool manager
		// and mint ERC6909 claims to hook, bypassing V3 curve
		AuctionTypes.CallbackDataBid memory callbackDataStruct = AuctionTypes.CallbackDataBid({
			sender: msg.sender,
			token0: address(0), // dynamic so we can support other tokens later
			token1: auctionInfo[auctionId].commonNumeraire,
			amount0: int128(int256(0)), // ETH
			amount1: int128(int256(stakeAmount)), // numeraire amount (positive for add)
			deadline: block.timestamp + 60
		});
		bytes memory callbackData = abi.encode(uint8(0), abi.encode(callbackDataStruct));
			self.manager().unlock(callbackData);
		} else {
			revert IErrorsAndEvents.InvalidStakeAmount();
		}
		// would be interesting to eventually have "deposits" for bidders who use the system often
		// so that they don't have to transfer the common numeraire every time they bid.
		// the deposit could be rehypothecated by the protocol when not being used. During auctions,
		// this auction contract would make a "claim" against the deposits that are needed for staking.
		// the complication is that we do not assert a common numeraire across all auction contracts.
		
		// Record the bid
		AuctionTypes.Bid memory bid = AuctionTypes.Bid({
			bidder: msg.sender,
			commitHash: commitHash,
			stakeAmount: stakeAmount,
			itemIds: new uint256[](0), // TODO: Add item IDs
			quantities: demands,
			round: auctionInfo[auctionId].currentRound,
			timestamp: block.timestamp
		});
		
		auctionInfo[auctionId].roundBids.push(bid);
		
		emit IErrorsAndEvents.BidSubmitted(auctionId, msg.sender, commitHash, stakeAmount, auctionInfo[auctionId].currentRound);
	}

	function computeBidPoints(uint256 stakeAmount) internal pure returns (uint256 bidPoints) {
		bidPoints = stakeAmount; // 1:1 ratio for now, could theoretically be anything
	}

    /**
	 * @notice Dropout from auction with penalty
	 * @param auctionId The auction ID
	 * @param bidder The bidder address
	 * @param auctionInfo Mapping for auction info
	 * @param bidderStake Mapping for bidder stakes
	 * @param bidderBidPoints Mapping for bidder bid points
	 * @param droppedBidders Mapping for dropped bidders
	 */
	function dropout(
		AuctionId auctionId,
		address bidder,
		mapping(AuctionId => AuctionTypes.AuctionInfo) storage auctionInfo,
		mapping(AuctionId => mapping(address => uint256)) storage bidderStake,
		mapping(AuctionId => mapping(address => uint256)) storage bidderBidPoints,
		mapping(AuctionId => mapping(address => bool)) storage droppedBidders
	) internal {
		uint256 stake = bidderStake[auctionId][bidder];
		if (stake == 0) revert IErrorsAndEvents.InvalidStakeAmount();
		
		uint256 penalty = (stake * auctionInfo[auctionId].config.dropoutSlashRatio) / 10000;
		uint256 refund = stake - penalty;
		
		// Clear bidder data
		bidderStake[auctionId][bidder] = 0;
		bidderBidPoints[auctionId][bidder] = 0;
		
		// Set dropped bidder status
		droppedBidders[auctionId][bidder] = true;
		
		// Transfer refund to bidder (simplified)
		// In practice, this would use SafeERC20
		
		emit IErrorsAndEvents.PenaltyApplied(auctionId, bidder, penalty);
		emit IErrorsAndEvents.StakeRefunded(auctionId, bidder, refund);
	}
    

	/**
	 * @notice Process clock round results
	 * @param auctionId The auction ID
	 * @param auctionInfo Mapping for auction info
	 * @param poolInfo Mapping for pool info
	 */
	function processClockRound(
		AuctionId auctionId,
		mapping(AuctionId => AuctionTypes.AuctionInfo) storage auctionInfo,
		mapping(PoolId => AuctionTypes.PoolInfo) storage poolInfo
	) internal {
		// Calculate excess demand for each item and update pool prices accordingly
		PoolId[] memory pools = getAllPools(auctionId, auctionInfo);
		for (uint256 i = 0; i < pools.length; i++) {
			PoolId poolId = pools[i];
			uint256 totalDemand = 0;
			
			// Sum up all demand for this item across all bids
			for (uint256 j = 0; j < auctionInfo[auctionId].roundBids.length; j++) {
				AuctionTypes.Bid memory bid = auctionInfo[auctionId].roundBids[j];
				if (bid.quantities.length > i) {
					totalDemand += bid.quantities[i];
				}
			}
			
			// Calculate excess demand and update price
			AuctionTypes.PoolInfo storage pool = poolInfo[poolId];
			pool.excessDemand = totalDemand > pool.depositAmount ? totalDemand - pool.depositAmount : 0;
			
			// If there is excess demand, increase the price linearly
			if (pool.excessDemand > 0) {
				pool.currentPrice += pool.priceIncrement;
			}
		}
	}

	/**
	 * @notice Check if clock phase should end
	 * @param auctionId The auction ID
	 * @param auctionInfo Mapping for auction info
	 * @param poolInfo Mapping for pool info
	 * @return shouldEnd True if clock phase should end
	 */
	function shouldEndClockPhase(
		AuctionId auctionId,
		mapping(AuctionId => AuctionTypes.AuctionInfo) storage auctionInfo,
		mapping(PoolId => AuctionTypes.PoolInfo) storage poolInfo
	) internal view returns (bool shouldEnd) {
		// create the pools here
		return true;
	}

	/**
	 * @notice Calculate bid value
	 * @param demands Array of demands
	 * @param auctionId The auction ID
	 * @param auctionInfo Mapping for auction info
	 * @return totalValue Total value of the bid
	 */
	function calculateBidValue(
		uint256[] calldata demands,
		AuctionId auctionId,
		mapping(AuctionId => AuctionTypes.AuctionInfo) storage auctionInfo,
		mapping(PoolId => AuctionTypes.PoolInfo) storage poolInfo
	) internal view returns (uint256 totalValue) {
		// Get all pool keys for this auction
		PoolKey[] memory poolKeys = auctionInfo[auctionId].poolKeys;
		
		// Calculate inner product: sum(demands[i] * prices[i])
		for (uint256 i = 0; i < demands.length && i < poolKeys.length; i++) {
			// Get the pool ID and its current price
			PoolId poolId = poolKeys[i].toId();
			uint256 price = poolInfo[poolId].currentPrice;
			
			// Add to total value: demand * price
			totalValue += (demands[i] * price) / 10**18; // this will need to divide by the deciamsl of the numeraire
		}
	}

	/**
	 * @notice Update currency prices
	 * @param currencyAddress The currency address to update
	 * @param newPrice The new price in numeraire units
	 * @param currentPrices Mapping for currency prices
	 */
	function updateCurrencyPrice(
		address currencyAddress,
		uint256 newPrice,
		mapping(address => uint256) storage currentPrices
	) internal {
		currentPrices[currencyAddress] = newPrice;
	}

	/**
	 * @notice Get total bidders
	 * @param auctionId The auction ID
	 * @param auctionInfo Mapping for auction info
	 * @return totalBidders Total number of bidders
	 */
	function getTotalBidders(
		AuctionId auctionId,
		mapping(AuctionId => AuctionTypes.AuctionInfo) storage auctionInfo
	) internal view returns (uint256 totalBidders) {
		// TODO: Implement bidder counting
		// This should count unique bidders, not just round bids
		
		// Placeholder: return round bids length
		return auctionInfo[auctionId].roundBids.length;
	}

	/**
	 * @notice Set clock open state in AuctionInfo
	 * @param auctionId The auction ID
	 * @param _clockOpen The new clock state
	 * @param auctionInfo Mapping for auction info
	 */
	function setClockOpen(
		AuctionId auctionId, 
		bool _clockOpen,
		mapping(AuctionId => AuctionTypes.AuctionInfo) storage auctionInfo
	) internal {
		auctionInfo[auctionId].clockOpen = _clockOpen;
	}

	/**
	 * @notice Set current round in AuctionInfo
	 * @param auctionId The auction ID
	 * @param _currentRound The new round number
	 * @param auctionInfo Mapping for auction info
	 */
	function setCurrentRound(
		AuctionId auctionId, 
		uint256 _currentRound,
		mapping(AuctionId => AuctionTypes.AuctionInfo) storage auctionInfo
	) internal {
		auctionInfo[auctionId].currentRound = _currentRound;
	}

	/**
	 * @notice Add a bid to round bids in AuctionInfo
	 * @param auctionId The auction ID
	 * @param bid The bid to add
	 * @param auctionInfo Mapping for auction info
	 */
	function addRoundBid(
		AuctionId auctionId, 
		AuctionTypes.Bid memory bid,
		mapping(AuctionId => AuctionTypes.AuctionInfo) storage auctionInfo
	) internal {
		auctionInfo[auctionId].roundBids.push(bid);
	}

	/**
	 * @notice Set dropped bidder status
	 * @param auctionId The auction ID
	 * @param bidder The bidder address
	 * @param dropped Whether the bidder is dropped
	 * @param droppedBidders Mapping for dropped bidders
	 */
	function setDroppedBidder(
		AuctionId auctionId, 
		address bidder, 
		bool dropped,
		mapping(AuctionId => mapping(address => bool)) storage droppedBidders
	) internal {
		droppedBidders[auctionId][bidder] = dropped;
	}

	/**
	 * @notice Clear bidder stake and bid points
	 * @param auctionId The auction ID
	 * @param bidder The bidder address
	 * @param bidderStake Mapping for bidder stakes
	 * @param bidderBidPoints Mapping for bidder bid points
	 */
	function clearBidderData(
		AuctionId auctionId, 
		address bidder,
		mapping(AuctionId => mapping(address => uint256)) storage bidderStake,
		mapping(AuctionId => mapping(address => uint256)) storage bidderBidPoints
	) internal {
		bidderStake[auctionId][bidder] = 0;
		bidderBidPoints[auctionId][bidder] = 0;
	}

	/**
	 * @notice Get number of round bids from AuctionInfo
	 * @param auctionId The auction ID
	 * @param auctionInfo Mapping for auction info
	 * @return Number of round bids
	 */
	function getRoundBidsLength(
		AuctionId auctionId,
		mapping(AuctionId => AuctionTypes.AuctionInfo) storage auctionInfo
	) internal view returns (uint256) {
		return auctionInfo[auctionId].roundBids.length;
	}

	/**
	 * @notice Get a round bid by index from AuctionInfo
	 * @param auctionId The auction ID
	 * @param index The index of the bid
	 * @param auctionInfo Mapping for auction info
	 * @return The bid struct
	 */
	function getRoundBid(
		AuctionId auctionId, 
		uint256 index,
		mapping(AuctionId => AuctionTypes.AuctionInfo) storage auctionInfo
	) internal view returns (AuctionTypes.Bid memory) {
		return auctionInfo[auctionId].roundBids[index];
	}

	/**
	 * @notice Get all pool IDs for an auction
	 * @param auctionId The auction ID
	 * @param auctionInfo Mapping for auction info
	 * @return Array of all pool IDs
	 */
	function getAllPools(
		AuctionId auctionId,
		mapping(AuctionId => AuctionTypes.AuctionInfo) storage auctionInfo
	) internal view returns (PoolId[] memory) {
		PoolKey[] memory poolKeys = auctionInfo[auctionId].poolKeys;
		PoolId[] memory poolIds = new PoolId[](poolKeys.length);
		
		for (uint256 i = 0; i < poolKeys.length; i++) {
			poolIds[i] = poolKeys[i].toId();
		}
		
		return poolIds;
	}

	/**
	 * @notice Open a new clock round - prepares the entire clock phase
	 * @param auctionId The auction ID
	 * @param auctionInfo Mapping for auction info
	 */
	function openClockRound(
		AuctionId auctionId,
		mapping(AuctionId => AuctionTypes.AuctionInfo) storage auctionInfo
	) internal {
		// Cache auction info to reduce storage reads
		AuctionTypes.AuctionInfo storage info = auctionInfo[auctionId];
		
		// // 1. Validate auction exists
		// if (info.auctionOwner == address(0)) {
		// 	revert IErrorsAndEvents.AuctionNotFound();
		// }
		
		// 2. Validate auction is active (not paused or cancelled)
		if (info.currentStatus != AuctionTypes.AuctionStatus.Active) {
			revert IErrorsAndEvents.AuctionNotActive(auctionId, info.currentStatus);
		}
		
		// 3. Validate clock is closed - we close between rounds
		if (info.clockOpen) {
			revert IErrorsAndEvents.ClockAlreadyOpen();
		}
		
		// 4. Validate current phase - allow both Setup and Clock
		AuctionTypes.AuctionPhase currentPhase = info.currentPhase;
		if (currentPhase != AuctionTypes.AuctionPhase.Setup && 
			currentPhase != AuctionTypes.AuctionPhase.Clock) {
			revert IErrorsAndEvents.InvalidPhase(AuctionTypes.AuctionPhase.Setup, currentPhase);
		}
		
		// 5. Change phase to Clock only if not already there
		if (currentPhase != AuctionTypes.AuctionPhase.Clock) {
			info.currentPhase = AuctionTypes.AuctionPhase.Clock;
		}
		
		// 6. Clear previous round data
		delete info.roundBids;
		
		// 7. Set clock open and increment round (unchecked for gas optimization)
		info.clockOpen = true;
		unchecked {
			info.currentRound++;
		}
		
		// 8. Emit event with cached round number
		emit IErrorsAndEvents.ClockRoundOpened(auctionId, info.currentRound);
	}
}
