// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { BaseHook } from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { Hooks } from "@uniswap/v4-core/src/libraries/Hooks.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { SwapParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import { AuctionTypes } from "../AuctionTypes.sol";
import { AuctionId } from "../AuctionId.sol";
import { IErrorsAndEvents } from "../utils/IErrorsAndEvents.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { CommitReveal } from "../CommitReveal.sol";
import { CPAStorage } from "../base/CPAStorage.sol";

library CPAClockPhase {
	using StateLibrary for IPoolManager;
	/**
	 * @notice Get current price from pool using tick-based calculation
	 * @param poolId The pool ID
	 * @param poolManager The pool manager instance
	 * @return price The current price in numeraire units (scaled by 10^18)
	 */
	function getCurrentPoolPrice(
		PoolId poolId,
		IPoolManager poolManager
	) internal view returns (uint256 price) {
		// Get the current sqrt price from the pool
		(uint160 sqrtPriceX96, , , ) = poolManager.getSlot0(poolId);
		
		// Convert sqrtPriceX96 to price
		// price = (sqrtPriceX96 / 2^96)^2
		// For now, assuming 1:1 scaling with 18 decimals
		uint256 priceX96 = uint256(sqrtPriceX96) * uint256(sqrtPriceX96);
		price = priceX96 / (2**192); // Divide by 2^192 to get the actual price
	}

	function getCurrentPoolSqrtPriceX96(
		PoolId poolId,
		IPoolManager poolManager
	) internal view returns (uint160 sqrtPriceX96) {
		(sqrtPriceX96, , , ) = poolManager.getSlot0(poolId);
	}

	/**
	 * @notice Process a bid as liquidity during clock phase
	 * @param self The contract instance
	 * @param auctionId The auction ID
	 * @param demands Array of item demands
	 * @param maxStakeAmount Maximum stake amount the bidder is willing to provide
	 * @param auctionInfo Mapping for auction info
	 * @param bidderStake Mapping for bidder stakes
	 * @param bidderBidPoints Mapping for bidder bid points
	 */
	function processBid(
		CPAStorage self,
		AuctionId auctionId,
		uint256[] calldata demands,
		uint256 maxStakeAmount,
		mapping(AuctionId => AuctionTypes.AuctionInfo) storage auctionInfo,
		mapping(AuctionId => mapping(address => uint256)) storage bidderStake,
		mapping(AuctionId => mapping(address => uint256)) storage bidderBidPoints,
		mapping(PoolId => AuctionTypes.PoolInfo) storage poolInfo,
		mapping(AuctionId => mapping(bytes32 => address)) storage commitProxy
	) internal {
		if (auctionInfo[auctionId].clockOpen == 1) revert IErrorsAndEvents.ClockNotOpen();
		if (demands.length != auctionInfo[auctionId].poolKeys.length) revert IErrorsAndEvents.InvalidBidsLength();
		
		// Calculate total bid value first
		uint256 totalValue = calculateBidValue(demands, auctionId, auctionInfo, poolInfo, self.manager());
		
		// Check if bidder already has sufficient bid points
		uint256 currentBidPoints = bidderBidPoints[auctionId][msg.sender];
		if (totalValue > currentBidPoints) {
			// Bidder needs additional stake
			uint256 requiredAdditionalStake = totalValue - currentBidPoints;

			// Safety check: ensure the bidder's max stake is sufficient for the required amount
			if (maxStakeAmount < requiredAdditionalStake) revert IErrorsAndEvents.MaxStakeTooLow(auctionId);
			
			// Add the required stake amount to bidder (not the max, just what's needed)
			bidderStake[auctionId][msg.sender] += requiredAdditionalStake;
			
			// Set bidder bid points
			bidderBidPoints[auctionId][msg.sender] = computeBidPoints(bidderStake[auctionId][msg.sender]);
			
			// Transfer the required stake amount from bidder to auction contract via pool manager
			if (requiredAdditionalStake > 0) {
				// Call swap callback to transfer tokens from user to pool manager
				// and mint ERC6909 claims to hook
				AuctionTypes.CallbackDataBid memory callbackDataStruct = AuctionTypes.CallbackDataBid({
					sender: msg.sender,
					token0: address(0), // unused, we need to remove this
					token1: auctionInfo[auctionId].commonNumeraire,
					amount0: int128(int256(0)), // unused, we need to remove this
					amount1: int128(int256(requiredAdditionalStake)), // numeraire amount (positive for add)
					deadline: block.timestamp + 60
				});
				bytes memory callbackData = abi.encode(uint8(0), abi.encode(callbackDataStruct));
				self.manager().unlock(callbackData);
			}
		} else {
			// Bidder already has sufficient bid points, no additional stake needed
			// No transfer needed in this case
		}
		// would be interesting to eventually have "deposits" for bidders who use the system often
		// so that they don't have to transfer the common numeraire every time they bid.
		// the deposit could be rehypothecated by the protocol when not being used. During auctions,
		// this auction contract would make a "claim" against the deposits that are needed for staking.
		// the complication is that we do not assert a common numeraire across all auction contracts.
		
		// Calculate the actual stake amount used for this bid
		uint256 actualStakeAmount = totalValue > currentBidPoints ? totalValue - currentBidPoints : 0;
		
		// Record the bid
		AuctionTypes.Bid memory bid = AuctionTypes.Bid({
			bidder: msg.sender,
			stakeAmount: actualStakeAmount,
			itemIds: new uint256[](0), // TODO: Add item IDs
			quantities: demands,
			round: auctionInfo[auctionId].currentRound,
			timestamp: block.timestamp
		});
		
		auctionInfo[auctionId].roundBids.push(bid);
		
		emit IErrorsAndEvents.BidSubmitted(auctionId, msg.sender, actualStakeAmount, auctionInfo[auctionId].currentRound);
		// another thought is that "active" bids could be ERC721 tokens that could be traded on secondary markets
		// would be useful if there are participant-limited auctions where more people want in than actually got in.
	}


	function computeBidPoints(uint256 stakeAmount) internal pure returns (uint256 bidPoints) {
		bidPoints = stakeAmount; // 1:1 ratio for now, could theoretically be anything
	}

    // /**
	//  * @notice Dropout from auction with penalty
	//  * @param auctionId The auction ID
	//  * @param bidder The bidder address
	//  * @param auctionInfo Mapping for auction info
	//  * @param bidderStake Mapping for bidder stakes
	//  * @param bidderBidPoints Mapping for bidder bid points
	//  * @param droppedBidders Mapping for dropped bidders
	//  */
	// function dropout(
	// 	AuctionId auctionId,
	// 	address bidder,
	// 	mapping(AuctionId => AuctionTypes.AuctionInfo) storage auctionInfo,
	// 	mapping(AuctionId => mapping(address => uint256)) storage bidderStake,
	// 	mapping(AuctionId => mapping(address => uint256)) storage bidderBidPoints,
	// 	mapping(AuctionId => mapping(address => bool)) storage droppedBidders
	// ) internal {
	// 	uint256 stake = bidderStake[auctionId][bidder];
	// 	if (stake == 0) revert IErrorsAndEvents.InvalidStakeAmount();
		
	// 	uint256 penalty = (stake * auctionInfo[auctionId].config.dropoutSlashRatio) / 10000;
	// 	uint256 refund = stake - penalty;
		
	// 	// Clear bidder data
	// 	bidderStake[auctionId][bidder] = 0;
	// 	bidderBidPoints[auctionId][bidder] = 0;
		
	// 	// Set dropped bidder status
	// 	droppedBidders[auctionId][bidder] = true;
		
	// 	// Transfer refund to bidder (simplified)
	// 	// In practice, this would use SafeERC20
		
	// 	emit IErrorsAndEvents.PenaltyApplied(auctionId, bidder, penalty);
	// 	emit IErrorsAndEvents.StakeRefunded(auctionId, bidder, refund);
	// }
    

	/**
	 * @notice Process clock round results
	 * @param auctionId The auction ID
	 * @param auctionInfo Mapping for auction info
	 * @param poolInfo Mapping for pool info
	 */
	function processClockRound(
		CPAStorage self,
		AuctionId auctionId,
		mapping(AuctionId => AuctionTypes.AuctionInfo) storage auctionInfo,
		mapping(PoolId => AuctionTypes.PoolInfo) storage poolInfo
	) internal {
		// Calculate excess demand for each item and update pool prices accordingly
		AuctionTypes.AuctionInfo storage auction = auctionInfo[auctionId];
		PoolId[] memory pools = getAllPools(auctionId, auctionInfo);
		for (uint256 i = 0; i < pools.length; i++) {
			PoolId poolId = pools[i];
			uint256 totalDemand = 0;
			
			// Sum up all demand for this item across all bids
			for (uint256 j = 0; j < auction.roundBids.length; j++) {
				AuctionTypes.Bid memory bid = auction.roundBids[j];
				if (bid.quantities.length > i) {
					totalDemand += bid.quantities[i];
				}
			}
			
			// Calculate excess demand and update price
			AuctionTypes.PoolInfo storage pool = poolInfo[poolId];
			pool.excessDemand = totalDemand > pool.depositAmount ? totalDemand - pool.depositAmount : 0;
			
			// If there is excess demand, increase the price by tick increment
			if (pool.excessDemand > 0) {
				_updatePoolPrice(poolId, pool.key, pool.priceIncrement, self.manager(), auction.commonNumeraire);
			}
		}
		
		// Clear round bids after processing
		delete auction.roundBids;
	}

	function _updatePoolPrice(
		PoolId poolId,
		PoolKey memory poolKey,
		int24 priceIncrement,
		IPoolManager poolManager,
		address commonNumeraire
	) internal {
		// Doppler-style price manipulation: perform a swap on a pool with no liquidity
		// to move the price by the specified tick increment
		
		// Get current tick from pool
		( , int24 currentTick, , ) = poolManager.getSlot0(poolId);
		
		// Determine which currency is the asset vs numeraire
		bool assetIsCurrency0 = Currency.unwrap(poolKey.currency0) != commonNumeraire;
		
		// Calculate new tick based on which currency is the asset
		int24 newTick;
		bool zeroForOne;
		if (assetIsCurrency0) {
			// Asset is currency0, numeraire is currency1
			// Price = currency1/currency0, so to increase price, move tick down (subtract)
			newTick = currentTick + priceIncrement;
			// To increase price (move tick down), we need to swap currency0 for currency1
			// zeroForOne = false means swap currency1 for currency0
			zeroForOne = false;
		} else {
			// Asset is currency1, numeraire is currency0  
			// Price = currency0/currency1, so to increase price, move tick up (add)
			newTick = currentTick - priceIncrement;
			// To increase price (move tick up), we need to swap currency1 for currency0
			// zeroForOne = true means swap currency0 for currency1
			zeroForOne = true;
		} 
		
		// Convert new tick to sqrtPriceX96
		uint160 newSqrtPriceX96 = TickMath.getSqrtPriceAtTick(newTick);
		
		// Create swap parameters for minimal swap
		SwapParams memory swapParams = SwapParams({
			zeroForOne: zeroForOne,
			amountSpecified: 1, // minimal amount
			sqrtPriceLimitX96: newSqrtPriceX96 // target price
		});
		
		// Perform the swap to update the price using callback approach
		// Encode the operation type (2) and the swap parameters
		bytes memory callbackData = abi.encode(uint8(2), abi.encode(poolKey, swapParams));
		poolManager.unlock(callbackData);
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
		// For now, clock phase does not end automatically
		// It must be manually ended by the auctioneer
		return false;
	}

	/**
	 * @notice Calculate bid value
	 * @param demands Array of demands
	 * @param auctionId The auction ID
	 * @param auctionInfo Mapping for auction info
	 * @param poolInfo Mapping for pool info
	 * @param poolManager The pool manager instance
	 * @return totalValue Total value of the bid
	 */
	function calculateBidValue(
		uint256[] calldata demands,
		AuctionId auctionId,
		mapping(AuctionId => AuctionTypes.AuctionInfo) storage auctionInfo,
		mapping(PoolId => AuctionTypes.PoolInfo) storage poolInfo,
		IPoolManager poolManager
	) internal view returns (uint256 totalValue) {
		// Get all pool keys for this auction
		PoolKey[] memory poolKeys = auctionInfo[auctionId].poolKeys;
		
		// Calculate inner product: sum(demands[i] * prices[i])
		for (uint256 i = 0; i < demands.length && i < poolKeys.length; i++) {
			// Get the pool ID and its current price from the pool
			PoolId poolId = poolKeys[i].toId();
			uint256 price = getCurrentPoolPrice(poolId, poolManager);
			
			// Add to total value: demand * price
			totalValue += (demands[i] * price) / 10**18; // this will need to divide by the decimals of the numeraire (should be dynamic not static)
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
		uint256 _clockOpen,
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
		
		// 1. Validate auction is active (not paused or cancelled)
		if (info.currentStatus != AuctionTypes.AuctionStatus.Active) {
			revert IErrorsAndEvents.AuctionNotActive(auctionId, info.currentStatus);
		}
		
		// 2. Validate clock is closed - we close between rounds
		if (info.clockOpen == 2) {
			revert IErrorsAndEvents.ClockAlreadyOpen();
		}
		
		// 3. Validate we're in Clock phase (phase transition handled in startClockRound)
		if (info.currentPhase != AuctionTypes.AuctionPhase.Clock) {
			revert IErrorsAndEvents.InvalidPhase(AuctionTypes.AuctionPhase.Clock, info.currentPhase);
		}
		
		// 4. Set clock open and increment round (unchecked for gas optimization)
		unchecked {
			info.clockOpen = 2;
			info.currentRound++;
		}
		
		// 5. Emit event with cached round number
		emit IErrorsAndEvents.ClockRoundOpened(auctionId, info.currentRound);
	}
}
