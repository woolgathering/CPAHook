// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { SwapParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";

import { CPAStorage } from "../base/CPAStorage.sol";
import { CommitReveal } from "../utils/CommitReveal.sol";
import { IErrorsAndEvents } from "../utils/IErrorsAndEvents.sol";
import { PriceUtils } from "../utils/PriceUtils.sol";
import { AuctionTypes } from "../types/AuctionTypes.sol";
import { AuctionId } from "../types/AuctionId.sol";

library CPAClockPhase {
	using StateLibrary for IPoolManager;
	using PriceUtils for IPoolManager;

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
		mapping(address => uint256[]) storage bids, // pre-read mapping
		address[] storage activeBidders
	) internal {
		if (auctionInfo[auctionId].clockOpen == 1) revert IErrorsAndEvents.ClockNotOpen();
		if (demands.length != auctionInfo[auctionId].poolKeys.length) revert IErrorsAndEvents.InvalidBidsLength();

		// before storing the new demands, we need to validate the activity rule
		// Get the bidder's previous demands
		uint256[] memory previousDemands = bids[msg.sender];
		
		// If bidder has previous demands, validate the activity rule
		if (previousDemands.length > 0) {
			bool[] memory changedPrices = auctionInfo[auctionId].changedPrices;
			// Ensure arrays have the same length (not needed, this gets checked elsewhere)
			// require(changedPrices.length == demands.length && changedPrices.length == previousDemands.length, "Array length mismatch");
			
			for(uint256 i = 0; i < changedPrices.length; i++) {
				// If price increased (changedPrices[i] is true), new demand must be <= previous demand
				if(changedPrices[i] && demands[i] > previousDemands[i]) {
					revert IErrorsAndEvents.ActivityRuleViolation();
				}
			}
		}
		
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

				uint256 allocatorRewardAmount = (requiredAdditionalStake * auctionInfo[auctionId].config.allocatorRewardPct) / 10000;
				auctionInfo[auctionId].allocatorReward += allocatorRewardAmount; // add this to the allocator reward
				requiredAdditionalStake = requiredAdditionalStake + allocatorRewardAmount; // update


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
		}
		// would be interesting to eventually have "deposits" for bidders who use the system often
		// so that they don't have to transfer the common numeraire every time they bid.
		// the deposit could be rehypothecated by the protocol when not being used. During auctions,
		// this auction contract would make a "claim" against the deposits that are needed for staking.
		// the complication is that we do not assert a common numeraire across all auction contracts.
		
		// Calculate the actual stake amount used for this bid
		uint256 actualStakeAmount = totalValue > currentBidPoints ? totalValue - currentBidPoints : 0;
		
		// // Record the bid
		// AuctionTypes.Bid memory bid = AuctionTypes.Bid({
		// 	bidder: msg.sender,
		// 	stakeAmount: actualStakeAmount,
		// 	itemIds: new uint256[](0), // TODO: Add item IDs
		// 	quantities: demands,
		// 	round: auctionInfo[auctionId].currentRound,
		// 	timestamp: block.timestamp
		// });
		
		// auctionInfo[auctionId].roundBids.push(bid);
		// I am going to change the above line and logic to instead just a mapping of bidder to demand vector.
		// we need to keep the last bid for each bidder so that we can validate the activity rule
		// and cross-round constraint validation
		// however, we will need a list of bidders so that we can iterate over them and update the price for
		// each pool if there is excess demand

		// Store bidder demands in the mapping
		bids[msg.sender] = demands;
		
		// Note: Active bidders management should be handled by the calling function
		// since activeBidders is a separate mapping in CPAStorage, not part of AuctionInfo
		activeBidders.push(msg.sender);
		
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
	 * @param bids Mapping for bidder demands
	 * @param activeBidders Mapping for active bidders
	 */
	function processClockRound(
		CPAStorage self,
		AuctionId auctionId,
		mapping(AuctionId => AuctionTypes.AuctionInfo) storage auctionInfo,
		mapping(PoolId => AuctionTypes.PoolInfo) storage poolInfo,
		mapping(AuctionId => mapping(address => uint256[])) storage bids,
		mapping(AuctionId => address[]) storage activeBidders
	) internal returns (uint256[] memory) {
		// Calculate excess demand for each item and update pool prices accordingly
		AuctionTypes.AuctionInfo storage auction = auctionInfo[auctionId];
		PoolId[] memory pools = getAllPools(auctionId, auctionInfo);
		uint256[] memory totalDemands = new uint256[](pools.length);

		// Note: changedPrices array is already initialized in openClockRound

		// Iterate over pools and calculate excess demand
		for (uint256 i = 0; i < pools.length; i++) {
			PoolId poolId = pools[i];
			
			// Sum up all demand for this item across all active bidders
			for (uint256 j = 0; j < activeBidders[auctionId].length; j++) {
				totalDemands[i] += bids[auctionId][activeBidders[auctionId][j]][i];
			}
			
			// Calculate excess demand (can be negative for undersell)
			AuctionTypes.PoolInfo storage pool = poolInfo[poolId];
			pool.excessDemand = int256(totalDemands[i]) - int256(pool.depositAmount);
			poolInfo[poolId].excessDemand = pool.excessDemand;
			
			// If there is excess demand (oversell), increase the price by tick increment
			if (pool.excessDemand > 0) {
				// Track last oversold tick BEFORE updating price
				(, int24 currentTick, , ) = StateLibrary.getSlot0(self.manager(), poolId);
				poolInfo[poolId].lastOversoldTick = currentTick;
				
				_updatePoolPrice(poolId, pool.key, pool.priceIncrement, self.manager(), auction.commonNumeraire);
				auction.changedPrices[i] = true; // Mark this price as changed
			} else {
				auction.changedPrices[i] = false; // Mark this price as not changed
			}
		}

		delete activeBidders[auctionId]; // clear the active bidders list
		
		// Note: We don't clear bids here anymore since we want to keep them for activity rule validation
		// The bids mapping persists across rounds until explicitly cleared

		return totalDemands;
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
		( , int24 tick, , ) = poolManager.getSlot0(poolId);
		
		// Calculate new tick based on which currency is the asset
		bool zeroForOne = Currency.unwrap(poolKey.currency0) == commonNumeraire;
		if (zeroForOne) {
			// Numeraire is currency0, asset is currency1
			// To increase price of the asset (move tick down), decrease the tick
			tick -= priceIncrement;
		} else {
			// Numeraire is currency1, asset is currency0  
			// To increase price of the asset (move tick up), increase the tick
			tick += priceIncrement;
		} 
		
		// Create swap parameters for minimal swap
		SwapParams memory swapParams = SwapParams({
			zeroForOne: zeroForOne,
			amountSpecified: 1, // minimal amount
			sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(tick) // target price
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
		AuctionTypes.AuctionInfo storage auctionInfo,
		mapping(PoolId => AuctionTypes.PoolInfo) storage poolInfo,
		uint256[] memory totalDemands,
		IPoolManager poolManager
	) internal returns (bool) {
		// For now, clock phase does not end automatically
		// It must be manually ended by the auctioneer
		// return false;

		// there are three conditions under which clock phase should end
		// 1. No excess demand on any item
		// 2. Max clock rounds exceeded
		// 3. Revenue improvement is less than ½ percent for two consecutive rounds

		// 1. No excess demand on any item - end clock phase
		bool hasExcessDemand = false;
		for (uint256 i = 0; i < auctionInfo.poolKeys.length; i++) {
			if (poolInfo[auctionInfo.poolKeys[i].toId()].excessDemand > 0) {
				hasExcessDemand = true;
				break;
			}
		}
		if (!hasExcessDemand) {
			return true; // End clock phase - no excess demand on any item
		}

		// 2. Max clock rounds exceeded
		// greater than or equal to because we increment the round after the clock round is processed
		if (auctionInfo.currentRound >= auctionInfo.config.maxRounds) {
			return true;
		}

		// 3. Revenue improvement is less than 1/2 percent for two consecutive rounds.
		// Here we use an EMA formula to avoid using two storage slots. I have not checked
		// for mathemetical equivalence but I think it should be relatively close. It's fine
		// for now.
		// EMA formula: R_t = alpha * r_t + (1 - alpha) * R_{t-1}
		uint256 alpha = 5e17; // 1/2 in 1e18 precision
		uint256 revenue = calculateBidValueWithMemoryDemands(totalDemands, auctionId, auctionInfo, poolInfo, poolManager);
		uint256 R_t = _computeEMA(revenue, auctionInfo.lastRevenue, alpha);
		// if (R_t < revenue * 0.005) {
		if ((R_t * 1e18) / revenue <= (5e15)) { // 1/2 percent in 1e18 precision
			return true;
		} else {
			auctionInfo.lastRevenue = revenue;
		}
		// Note: lastRevenue update is handled in the calling function

		return false; // keep going
	}

	/**
	 * @notice Compute EMA
	 * @param r_t The current revenue
	 * @param R_t_1 The previous revenue
	 * @param alpha The alpha value
	 * @return The EMA value
	 */
	function _computeEMA(
		uint256 r_t,
		uint256 R_t_1,
		uint256 alpha
	) internal pure returns (uint256) {
		return (alpha * r_t + (1e18 - alpha) * R_t_1) / 1e18;
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
			uint256 price;
			if (Currency.unwrap(poolKeys[i].currency0) == auctionInfo[auctionId].commonNumeraire) {
				// Since the numeraire is currency0, we need to get the price of currency1
				price = poolManager.getPriceOfCurrency1(poolKeys[i]);
			} else {
				// Since the numeraire is currency1, we need to get the price of currency0
				price = poolManager.getPriceOfCurrency0(poolKeys[i]);
			}
			
			// Add to total value: demand * price
			totalValue += (demands[i] * price) / 10**18; // this will need to divide by the decimals of the numeraire (should be dynamic not static)
		}
	}

	function calculateBidValueWithMemoryDemands(
		uint256[] memory demands,
		AuctionId auctionId,
		AuctionTypes.AuctionInfo storage auctionInfo,
		mapping(PoolId => AuctionTypes.PoolInfo) storage poolInfo,
		IPoolManager poolManager
	) internal view returns (uint256 totalValue) {
		// Get all pool keys for this auction
		PoolKey[] memory poolKeys = auctionInfo.poolKeys;
		
		// Calculate inner product: sum(demands[i] * prices[i])
		for (uint256 i = 0; i < demands.length && i < poolKeys.length; i++) {
			// Get the pool ID and its current price from the pool
			PoolId poolId = poolKeys[i].toId();
			uint256 price;
			if (Currency.unwrap(poolKeys[i].currency0) == auctionInfo.commonNumeraire) {
				// Since the numeraire is currency0, we need to get the price of currency1
				price = poolManager.getPriceOfCurrency1(poolKeys[i]);
			} else {
				// Since the numeraire is currency1, we need to get the price of currency0
				price = poolManager.getPriceOfCurrency0(poolKeys[i]);
			}
			
			// Add to total value: demand * price
			totalValue += (demands[i] * price) / 10**18; // this will need to divide by the decimals of the numeraire (should be dynamic not static)
		}
	}


	/**
	 * @notice Get total bidders
	 * @param auctionId The auction ID
	 * @param activeBidders Mapping for active bidders
	 * @return totalBidders Total number of bidders
	 */
	function getTotalBidders(
		AuctionId auctionId,
		address[] storage activeBidders
	) internal view returns (uint256 totalBidders) {
		return activeBidders.length;
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
	 * @notice Add a bidder to active bidders list
	 * @param auctionId The auction ID
	 * @param bidder The bidder address
	 * @param activeBidders Mapping for active bidders
	 */
	function addActiveBidder(
		AuctionId auctionId, 
		address bidder,
		mapping(AuctionId => address[]) storage activeBidders
	) internal {
		activeBidders[auctionId].push(bidder);
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
	 * @notice Get bidder demands
	 * @param auctionId The auction ID
	 * @param bidder The bidder address
	 * @param bids Mapping for bidder demands
	 * @return The bidder's demand array
	 */
	function getBidderDemands(
		AuctionId auctionId, 
		address bidder,
		mapping(AuctionId => mapping(address => uint256[])) storage bids
	) internal view returns (uint256[] memory) {
		return bids[auctionId][bidder];
	}

	/**
	 * @notice Set bidder demands
	 * @param auctionId The auction ID
	 * @param bidder The bidder address
	 * @param demands The demand array
	 * @param bids Mapping for bidder demands
	 */
	function setBidderDemands(
		AuctionId auctionId, 
		address bidder,
		uint256[] memory demands,
		mapping(AuctionId => mapping(address => uint256[])) storage bids
	) internal {
		bids[auctionId][bidder] = demands;
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

	/**
	 * @notice Revert prices to last oversold ticks for any items currently undersold
	 * @param self The contract instance
	 * @param auctionId The auction ID
	 * @param auctionInfo Storage reference to auction info
	 * @param poolInfo Storage reference to pool info
	 * @param poolManager The pool manager instance
	 */
	function revertUndersoldPrices(
		CPAStorage self,
		AuctionId auctionId,
		AuctionTypes.AuctionInfo storage auctionInfo,
		mapping(PoolId => AuctionTypes.PoolInfo) storage poolInfo,
		IPoolManager poolManager
	) internal {
		PoolKey[] memory poolKeys = auctionInfo.poolKeys;
		
		for (uint256 i = 0; i < poolKeys.length; i++) {
			PoolId poolId = poolKeys[i].toId();
			AuctionTypes.PoolInfo storage pool = poolInfo[poolId];
			
			// Check if this item is undersold (excessDemand < 0)
			if (pool.excessDemand < 0 && pool.lastOversoldTick != 0) {
				// Revert to last oversold tick
				(, int24 currentTick, , ) = StateLibrary.getSlot0(poolManager, poolId);
				// int24 tickDelta = pool.lastOversoldTick - currentTick;
				
				if (pool.lastOversoldTick != currentTick) {
					// Use existing price update logic with negative tick delta for price decrease
					_updatePoolPriceByTick(pool.key, pool.lastOversoldTick, poolManager, auctionInfo.commonNumeraire);
				}
			}
		}
	}

	/**
	 * @notice Update pool price by tick delta (can be negative to decrease price)
	 * @param poolKey The pool key
	 * @param tickTarget The tick change (positive or negative)
	 * @param poolManager The pool manager instance
	 * @param commonNumeraire The common numeraire address
	 */
	function _updatePoolPriceByTick(
		PoolKey memory poolKey,
		int24 tickTarget,
		IPoolManager poolManager,
		address commonNumeraire
	) internal {
		// Calculate new sqrt price from tick
		// uint160 newSqrtPriceX96 = TickMath.getSqrtPriceAtTick(tickTarget);
		
		// Determine swap direction based on numeraire position
		// bool zeroForOne = Currency.unwrap(poolKey.currency0) != commonNumeraire;
		
		// Create swap parameters for minimal swap
		SwapParams memory swapParams = SwapParams({
			zeroForOne: Currency.unwrap(poolKey.currency0) != commonNumeraire,
			amountSpecified: 1, // minimal amount
			sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(tickTarget) // target price
		});
		
		// Perform the swap to update the price using callback approach
		// Encode the operation type (2) and the swap parameters
		bytes memory callbackData = abi.encode(uint8(2), abi.encode(poolKey, swapParams));
		poolManager.unlock(callbackData);
	}
}
