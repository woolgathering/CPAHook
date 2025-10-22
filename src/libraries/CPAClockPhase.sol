// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { SwapParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";
import { IERC20 } from "forge-std/interfaces/IERC20.sol";

import { CPAStorage } from "../base/CPAStorage.sol";
import { CurrencyDecimals } from "../utils/CurrencyDecimals.sol";
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
		AuctionTypes.AuctionInfo storage auctionInfo,
		mapping(address => uint256) storage bidderStake,
		mapping(address => uint256) storage bidderBidPoints,
		mapping(address => uint256[]) storage bids, // pre-read mapping
		address[] storage activeBidders
	) internal {
		address bidder = msg.sender;
		
		if (auctionInfo.clockOpen == 1) revert IErrorsAndEvents.ClockNotOpen();
		if (demands.length != auctionInfo.poolKeys.length) revert IErrorsAndEvents.InvalidBidsLength();

		// before storing the new demands, we need to validate the activity rule
		// Get the bidder's previous demands
		uint256[] memory previousDemands = bids[bidder];
		
		// If bidder has previous demands, validate the activity rule
		if (previousDemands.length > 0) {
			bool[] memory changedPrices = auctionInfo.changedPrices;
			for(uint256 i = 0; i < changedPrices.length; i++) {
				// If price increased (changedPrices[i] is true), new demand must be <= previous demand
				if(changedPrices[i] && demands[i] > previousDemands[i]) {
					revert IErrorsAndEvents.ActivityRuleViolation();
				}
			}
		}
		
		// Calculate total bid value first
		uint256 totalValueInNumeraire = calculateBidValue(demands, auctionInfo, self.manager());
		uint256 requiredBidPoints = computeBidPoints(totalValueInNumeraire, auctionInfo.commonNumeraire);
		
		// Check if bidder already has sufficient bid points
		uint256 currentBidPoints = bidderBidPoints[bidder];
		uint256 requiredAdditionalStake = 0;
		
		if (requiredBidPoints > currentBidPoints) {
			// Bidder needs additional stake
			uint256 currentStake = bidderStake[bidder];
			requiredAdditionalStake = totalValueInNumeraire - currentStake;
			uint256 allocatorRewardAmount = (requiredAdditionalStake * auctionInfo.config.allocatorRewardPct) / 10000;

			// Safety check: ensure the bidder's max stake is sufficient for the required amount
			if (maxStakeAmount < requiredAdditionalStake + allocatorRewardAmount) revert IErrorsAndEvents.MaxStakeTooLow(auctionId);
			
			// Update storage directly
			bidderStake[bidder] += requiredAdditionalStake;
			bidderBidPoints[bidder] = computeBidPoints(bidderStake[bidder], auctionInfo.commonNumeraire);
			
			// Transfer the required stake amount from bidder to auction contract via pool manager
			if (requiredAdditionalStake > 0) {
				// Call swap callback to transfer tokens from user to pool manager
				// and mint ERC6909 claims to hook
				auctionInfo.allocatorReward += allocatorRewardAmount; // add this to the allocator reward

				AuctionTypes.CallbackDataBid memory callbackDataStruct = AuctionTypes.CallbackDataBid({
					sender: bidder,
					numeraire: auctionInfo.commonNumeraire,
					stake: int128(int256(requiredAdditionalStake + allocatorRewardAmount)), // stake amount in numeraire
					deadline: block.timestamp + 60
				});
				self.manager().unlock(abi.encode(uint8(0), abi.encode(callbackDataStruct)));
			}
		}
		// would be interesting to eventually have "deposits" for bidders who use the system often
		// so that they don't have to transfer the common numeraire every time they bid.
		// the deposit could be rehypothecated by the protocol when not being used. During auctions,
		// this auction contract would make a "claim" against the deposits that are needed for staking.
		// the complication is that we do not assert a common numeraire across all auction contracts.
		
		// Calculate the actual stake amount used for this bid
		uint256 actualStakeAmount = totalValueInNumeraire > currentBidPoints ? totalValueInNumeraire - currentBidPoints : 0;

		// Store bidder demands
		bids[bidder] = demands;
		
		// Note: Active bidders management should be handled by the calling function
		// since activeBidders is a separate mapping in CPAStorage, not part of AuctionInfo
		activeBidders.push(bidder);
		
		emit IErrorsAndEvents.BidSubmitted(auctionId, bidder, requiredAdditionalStake, auctionInfo.currentRound);
		// another thought is that "active" bids could be ERC721 tokens that could be traded on secondary markets
		// would be useful if there are participant-limited auctions where more people want in than actually got in.
	}

	function computeBidPoints(uint256 stakeAmount, address numeraire) internal view returns (uint256 bidPoints) {
		bidPoints = stakeAmount * 10**18 / (10**CurrencyDecimals.getDecimals(numeraire));
	}
    
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
		AuctionTypes.AuctionInfo storage auctionInfo,
		mapping(PoolId => AuctionTypes.PoolInfo) storage poolInfo,
		mapping(address => uint256[]) storage bids,
		mapping(AuctionId => address[]) storage activeBidders
	) internal returns (uint256[] memory) {
		// Calculate excess demand for each item and update pool prices accordingly
		PoolId[] memory pools = getAllPools(auctionInfo);
		uint256[] memory totalDemands = new uint256[](pools.length);

		// Pre-index the activeBidders array for gas efficiency
		address[] storage currentActiveBidders = activeBidders[auctionId];

		// Note: changedPrices array is already initialized in openClockRound

		// Iterate over pools and calculate excess demand
		for (uint256 i = 0; i < pools.length; i++) {
			PoolId poolId = pools[i];
			
			// Sum up all demand for this item across all active bidders
			address bidder;
			for (uint256 j = 0; j < currentActiveBidders.length; j++) {
				bidder = currentActiveBidders[j]; // just one read
				if (bidder != address(0)) {
					totalDemands[i] += bids[bidder][i];
				}
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
				
				_updatePoolPrice(poolId, pool.key, pool.priceIncrement, self.manager(), auctionInfo.commonNumeraire);
				auctionInfo.changedPrices[i] = true; // Mark this price as changed
			} else {
				auctionInfo.changedPrices[i] = false; // Mark this price as not changed
			}
		}

		// Clear the active bidders list using delete (more gas efficient)
		delete activeBidders[auctionId];
		
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
		uint256 revenue = calculateBidValueWithMemoryDemands(totalDemands, auctionInfo, poolManager);
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
	 * @param auctionInfo Mapping for auction info
	 * @param poolManager The pool manager instance
	 * @return totalValue Total value of the bid
	 */
	function calculateBidValue(
		uint256[] calldata demands,
		AuctionTypes.AuctionInfo storage auctionInfo,
		IPoolManager poolManager
	) internal view returns (uint256 totalValue) {
		// Get all pool keys for this auction
		PoolKey[] memory poolKeys = auctionInfo.poolKeys;
		
		// Calculate inner product: sum(demands[i] * prices[i])
		for (uint256 i = 0; i < demands.length && i < poolKeys.length; i++) {
			// Get the pool ID and its current price from the pool
			uint256 price;
			if (Currency.unwrap(poolKeys[i].currency0) == auctionInfo.commonNumeraire) {
				// Since the numeraire is currency0, we need to get the price of currency1
				price = poolManager.getPriceOfCurrency1(poolKeys[i]);
			} else {
				// Since the numeraire is currency1, we need to get the price of currency0
				price = poolManager.getPriceOfCurrency0(poolKeys[i]);
			}
			
			// Get asset decimals for this pool
			address assetCurrency;
			if (Currency.unwrap(poolKeys[i].currency0) == auctionInfo.commonNumeraire) {
				assetCurrency = Currency.unwrap(poolKeys[i].currency1);
			} else {
				assetCurrency = Currency.unwrap(poolKeys[i].currency0);
			}
			
			// Convert: (demand in asset decimals) * (price in 18 decimals) => value in numeraire decimals
			// Formula: (quantity * price * 10^numeraireDecimals) / (10^(18 + assetDecimals))
			totalValue += (demands[i] * price * (10**CurrencyDecimals.getDecimals(auctionInfo.commonNumeraire))) / (10**(18 + CurrencyDecimals.getDecimals(assetCurrency)));
		}
	}

	/**
	 * @notice Calculate bid value using memory demands array
	 * @param demands Array of demands (memory parameter - used when demands are already in memory)
	 * @param auctionInfo Mapping for auction info
	 * @param poolManager The pool manager instance
	 * @return totalValue Total value of the bid
	 * @dev This function is identical to calculateBidValue() but takes memory demands instead of calldata.
	 *      Used when demands are already loaded into memory (e.g., from totalDemands array in shouldEndClockPhase).
	 *      Avoids unnecessary data copying between calldata and memory.
	 */
	function calculateBidValueWithMemoryDemands(
		uint256[] memory demands,
		AuctionTypes.AuctionInfo storage auctionInfo,
		IPoolManager poolManager
	) internal view returns (uint256 totalValue) {
		// Get all pool keys for this auction
		PoolKey[] memory poolKeys = auctionInfo.poolKeys;
		
		// Calculate inner product: sum(demands[i] * prices[i])
		for (uint256 i = 0; i < demands.length && i < poolKeys.length; i++) {
			// Get the pool ID and its current price from the pool
			uint256 price;
			if (Currency.unwrap(poolKeys[i].currency0) == auctionInfo.commonNumeraire) {
				// Since the numeraire is currency0, we need to get the price of currency1
				price = poolManager.getPriceOfCurrency1(poolKeys[i]);
			} else {
				// Since the numeraire is currency1, we need to get the price of currency0
				price = poolManager.getPriceOfCurrency0(poolKeys[i]);
			}
			
			// Get asset decimals for this pool
			address assetCurrency;
			if (Currency.unwrap(poolKeys[i].currency0) == auctionInfo.commonNumeraire) {
				assetCurrency = Currency.unwrap(poolKeys[i].currency1);
			} else {
				assetCurrency = Currency.unwrap(poolKeys[i].currency0);
			}
			
			// Convert: (demand in asset decimals) * (price in 18 decimals) => value in numeraire decimals
			// Formula: (quantity * price * 10^numeraireDecimals) / (10^(18 + assetDecimals))
			totalValue += (demands[i] * price * (10**CurrencyDecimals.getDecimals(auctionInfo.commonNumeraire))) / (10**(18 + CurrencyDecimals.getDecimals(assetCurrency)));
		}
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
	 * @notice Get all pool IDs for an auction
	 * @param auctionInfo Storage reference to auction info
	 * @return Array of all pool IDs
	 */
	function getAllPools(
		AuctionTypes.AuctionInfo storage auctionInfo
	) internal view returns (PoolId[] memory) {
		PoolKey[] memory poolKeys = auctionInfo.poolKeys;
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
	 * @param auctionInfo Storage reference to auction info
	 * @param poolInfo Storage reference to pool info
	 * @param poolManager The pool manager instance
	 */
	function revertUndersoldPrices(
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
