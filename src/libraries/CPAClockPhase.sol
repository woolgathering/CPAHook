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
import { StorageAccess } from "../utils/StorageAccess.sol";
import { CurrencyDecimals } from "../utils/CurrencyDecimals.sol";
import { CommitReveal } from "../utils/CommitReveal.sol";
import { IErrorsAndEvents } from "../utils/IErrorsAndEvents.sol";
import { PriceUtils } from "../utils/PriceUtils.sol";
import { AuctionTypes } from "../types/AuctionTypes.sol";
import { AuctionId } from "../types/AuctionId.sol";
import { CPAComputationLibrary } from "./CPAComputationLibrary.sol";

contract CPAClockPhase {
	using StateLibrary for IPoolManager;
	using PriceUtils for IPoolManager;
	using StorageAccess for *;

	/**
	 * @notice Process a bid as liquidity during clock phase
	 * @param self The contract instance (CPAManager via DELEGATECALL)
	 * @param auctionId The auction ID
	 * @param demands Array of item demands
	 * @param maxStakeAmount Maximum stake amount the bidder is willing to provide
	 * @dev Storage mappings are accessed via helpers since DELEGATECALL executes in CPAManager's storage context
	 */
    function processBid(
		CPAStorage self,
		AuctionId auctionId,
		uint256[] calldata demands,
		uint256 maxStakeAmount
	) public {
		address bidder = msg.sender;
		
		// Get auctionInfo via StorageAccess
		AuctionTypes.AuctionInfo memory auctionInfoData = StorageAccess.getAuctionInfo(auctionId);
		
		if (auctionInfoData.clockOpen == 1) revert IErrorsAndEvents.ClockNotOpen();
		if (demands.length != auctionInfoData.poolKeys.length) revert IErrorsAndEvents.InvalidBidsLength();
        
		// Get previous bids via StorageAccess
		uint256[] memory previousBids = StorageAccess.getBids(auctionId, bidder);
        
        // Scope 1: Validate activity rule
        {
            _validateActivityRule(demands, previousBids, auctionInfoData.changedPrices);
        }

        // Scope 2: Calculate required stake and update bidder state
        uint256 requiredAdditionalStake;
        uint256 allocatorRewardAmount;
        {
			uint256 currentStake = StorageAccess.getBidderStake(auctionId, bidder);
			uint256 currentBidPoints = StorageAccess.getBidderBidPoints(auctionId, bidder);
			
            (requiredAdditionalStake, allocatorRewardAmount) = _calculateRequiredStake(
                demands,
                auctionInfoData,
                currentStake,
                currentBidPoints,
                maxStakeAmount,
                auctionId,
                self.manager()
            );

            if (requiredAdditionalStake > 0) {
                // Update storage via StorageAccess
                uint256 newStake = currentStake + requiredAdditionalStake;
                StorageAccess.setBidderStake(auctionId, bidder, newStake);
                uint256 newBidPoints = CPAComputationLibrary.computeBidPoints(newStake, auctionInfoData.commonNumeraire);
                StorageAccess.setBidderBidPoints(auctionId, bidder, newBidPoints);

                // Account allocator reward now
                uint256 newAllocatorReward = auctionInfoData.allocatorReward + allocatorRewardAmount;
                StorageAccess.setAuctionAllocatorReward(auctionId, newAllocatorReward);

                // Transfer the required stake amount from bidder to auction contract via pool manager
                AuctionTypes.CallbackDataBid memory callbackDataStruct = AuctionTypes.CallbackDataBid({
                    sender: bidder,
                    numeraire: auctionInfoData.commonNumeraire,
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
		
		// Store bidder demands via StorageAccess
		StorageAccess.setBids(auctionId, bidder, demands);
		
		// Note: Active bidders management should be handled by the calling function
		// since activeBidders is a separate mapping in CPAStorage, not part of AuctionInfo
		StorageAccess.pushActiveBidder(auctionId, bidder);
		
		emit IErrorsAndEvents.BidSubmitted(auctionId, bidder, requiredAdditionalStake, auctionInfoData.currentRound);
		// another thought is that "active" bids could be ERC721 tokens that could be traded on secondary markets
		// would be useful if there are participant-limited auctions where more people want in than actually got in.
	}

	/**
	 * @notice Process clock round results
	 * @param self The contract instance (CPAManager via DELEGATECALL)
	 * @param auctionId The auction ID
	 * @dev Storage mappings are accessed via helpers since DELEGATECALL executes in CPAManager's storage context
	 */
	function processClockRound(
		CPAStorage self,
		AuctionId auctionId
	) public returns (uint256[] memory) {
		// Get auctionInfo via StorageAccess
		AuctionTypes.AuctionInfo memory auctionInfoData = StorageAccess.getAuctionInfo(auctionId);
		
		// Calculate excess demand for each item and update pool prices accordingly
		PoolId[] memory pools = getAllPools(auctionInfoData);
		uint256[] memory totalDemands = new uint256[](pools.length);

		// Get activeBidders array via StorageAccess
		address[] memory currentActiveBidders = StorageAccess.getActiveBidders(auctionId);

		// Note: changedPrices array is already initialized in openClockRound

		// Iterate over pools and calculate excess demand
		bool[] memory changedPrices = new bool[](pools.length);
		for (uint256 i = 0; i < pools.length; ) {
			PoolId poolId = pools[i];
			
			// Get poolInfo via StorageAccess
			AuctionTypes.PoolInfo memory pool = StorageAccess.getPoolInfo(poolId);
			
			// Sum up all demand for this item across all active bidders
			for (uint256 j = 0; j < currentActiveBidders.length; ) {
				address bidder = currentActiveBidders[j];
				if (bidder != address(0)) {
					uint256[] memory bidderBids = StorageAccess.getBids(auctionId, bidder);
					if (i < bidderBids.length) {
						totalDemands[i] += bidderBids[i];
					}
				}
				unchecked { ++j; }
			}
			
			// Calculate excess demand (can be negative for undersell)
			int256 excessDemand = int256(totalDemands[i]) - int256(pool.depositAmount);
			StorageAccess.setPoolInfoExcessDemand(poolId, excessDemand);
			
			// If there is excess demand (oversell), increase the price by tick increment
			if (excessDemand > 0) {
				// Track last oversold tick BEFORE updating price
				(, int24 currentTick, , ) = StateLibrary.getSlot0(self.manager(), poolId);
				StorageAccess.setPoolInfoLastOversoldTick(poolId, currentTick);
				
				_updatePoolPrice(poolId, pool.key, pool.priceIncrement, self.manager(), auctionInfoData.commonNumeraire);
				changedPrices[i] = true; // Mark this price as changed
			} else {
				changedPrices[i] = false; // Mark this price as not changed
			}
			unchecked { ++i; }
		}

		// Update changedPrices array via StorageAccess
		StorageAccess.setChangedPrices(auctionId, changedPrices);
		
		// Clear the active bidders list via StorageAccess
		StorageAccess.clearActiveBidders(auctionId);
		
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
	 * @param self The contract instance (CPAManager via DELEGATECALL)
	 * @param auctionId The auction ID
	 * @param totalDemands Array of total demands per pool
	 * @param poolManager The pool manager instance
	 * @return shouldEnd True if clock phase should end
	 * @dev Storage mappings are accessed via helpers since DELEGATECALL executes in CPAManager's storage context
	 */
	function shouldEndClockPhase(
		CPAStorage self,
		AuctionId auctionId,
		uint256[] memory totalDemands,
		IPoolManager poolManager
	) public returns (bool) {
		// Get auctionInfo via helper
		AuctionTypes.AuctionInfo memory auctionInfo = StorageAccess.getAuctionInfo(auctionId);
		// For now, clock phase does not end automatically
		// It must be manually ended by the auctioneer
		// return false;

		// there are three conditions under which clock phase should end
		// 1. No excess demand on any item
		// 2. Max clock rounds exceeded
		// 3. Revenue improvement is less than ½ percent for two consecutive rounds

		// 1. No excess demand on any item - end clock phase
		bool hasExcessDemand = false;
		for (uint256 i = 0; i < auctionInfo.poolKeys.length; ) {
			PoolId poolId = auctionInfo.poolKeys[i].toId();
			AuctionTypes.PoolInfo memory pool = StorageAccess.getPoolInfo(poolId);
			if (pool.excessDemand > 0) {
				hasExcessDemand = true;
				break;
			}
			unchecked { ++i; }
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
		PoolKey[] memory poolKeys = auctionInfo.poolKeys;
		uint256 revenue = CPAComputationLibrary.calculateBidValueWithMemoryDemands(totalDemands, auctionInfo.commonNumeraire, poolManager, poolKeys);
		uint256 R_t = _computeEMA(revenue, auctionInfo.lastRevenue, alpha);
		// if (R_t < revenue * 0.005) {
		if ((R_t * 1e18) / revenue <= (5e15)) { // 1/2 percent in 1e18 precision
			return true;
		} else {
			StorageAccess.setAuctionLastRevenue(auctionId, revenue);
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

	// Helper: validate activity rule based on changedPrices and previous demands
	function _validateActivityRule(
		uint256[] calldata demands,
		uint256[] memory previousDemands,
		bool[] memory changedPrices
	) private pure {
		if (previousDemands.length == 0) return;
		for (uint256 i = 0; i < changedPrices.length; i++) {
			if (changedPrices[i] && demands[i] > previousDemands[i]) {
				revert IErrorsAndEvents.ActivityRuleViolation();
			}
		}
	}

	// Helper: calculate required stake and allocator reward; validates maxStake
	function _calculateRequiredStake(
		uint256[] calldata demands,
		AuctionTypes.AuctionInfo memory auctionInfo,
		uint256 currentStake,
		uint256 currentBidPoints,
		uint256 maxStakeAmount,
		AuctionId auctionId,
		IPoolManager poolManager
	) private view returns (uint256 requiredAdditionalStake, uint256 allocatorReward) {
		PoolKey[] memory poolKeys = auctionInfo.poolKeys;
		uint256 totalValueInNumeraire = CPAComputationLibrary.calculateBidValue(demands, auctionInfo.commonNumeraire, poolManager, poolKeys);
		uint256 requiredBidPoints = CPAComputationLibrary.computeBidPoints(totalValueInNumeraire, auctionInfo.commonNumeraire);
		if (requiredBidPoints <= currentBidPoints) {
			return (0, 0);
		}
		requiredAdditionalStake = totalValueInNumeraire - currentStake;
		allocatorReward = (requiredAdditionalStake * auctionInfo.config.allocatorRewardPct) / 10000;
		if (maxStakeAmount < requiredAdditionalStake + allocatorReward) revert IErrorsAndEvents.MaxStakeTooLow(auctionId);
	}

	/**
	 * @notice Set clock open state in AuctionInfo
	 * @param self The contract instance (CPAManager via DELEGATECALL)
	 * @param auctionId The auction ID
	 * @param _clockOpen The new clock state (1 = closed, 2 = open)
	 * @dev Storage mappings are accessed via helpers since DELEGATECALL executes in CPAManager's storage context
	 */
	function setClockOpen(
		CPAStorage self,
		AuctionId auctionId, 
		uint256 _clockOpen
	) public {
		StorageAccess.setAuctionClockOpen(auctionId, uint8(_clockOpen));
	}

	/**
	 * @notice Get all pool IDs for an auction
	 * @param auctionInfo Memory reference to auction info
	 * @return Array of all pool IDs
	 */
	function getAllPools(
		AuctionTypes.AuctionInfo memory auctionInfo
	) internal pure returns (PoolId[] memory) {
		PoolKey[] memory poolKeys = auctionInfo.poolKeys;
		PoolId[] memory poolIds = new PoolId[](poolKeys.length);
		
		for (uint256 i = 0; i < poolKeys.length; ) {
			poolIds[i] = poolKeys[i].toId();
			unchecked { ++i; }
		}
		
		return poolIds;
	}

	/**
	 * @notice Open a new clock round - prepares the entire clock phase
	 * @param self The contract instance (CPAManager via DELEGATECALL)
	 * @param auctionId The auction ID
	 * @dev Storage mappings are accessed via helpers since DELEGATECALL executes in CPAManager's storage context
	 */
	function openClockRound(
		CPAStorage self,
		AuctionId auctionId
	) public {
		// Get auction info via helper
		AuctionTypes.AuctionInfo memory info = StorageAccess.getAuctionInfo(auctionId);
		
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
			StorageAccess.setAuctionClockOpen(auctionId, 2);
			uint256 newRound = info.currentRound + 1;
			StorageAccess.setAuctionCurrentRound(auctionId, newRound);
		}
		
		// Get updated info for event
		AuctionTypes.AuctionInfo memory updatedInfo = StorageAccess.getAuctionInfo(auctionId);
		
		// 5. Emit event with cached round number
		emit IErrorsAndEvents.ClockRoundOpened(auctionId, updatedInfo.currentRound);
	}

	/**
	 * @notice Revert prices to last oversold ticks for any items currently undersold
	 * @param self The contract instance (CPAManager via DELEGATECALL)
	 * @param auctionId The auction ID
	 * @param poolManager The pool manager instance
	 * @dev Storage mappings are accessed via helpers since DELEGATECALL executes in CPAManager's storage context
	 */
	function revertUndersoldPrices(
		CPAStorage self,
		AuctionId auctionId,
		IPoolManager poolManager
	) public {
		// Get auctionInfo via StorageAccess
		AuctionTypes.AuctionInfo memory auctionInfo = StorageAccess.getAuctionInfo(auctionId);
		PoolKey[] memory poolKeys = auctionInfo.poolKeys;
		
		for (uint256 i = 0; i < poolKeys.length; ) {
			PoolId poolId = poolKeys[i].toId();
			// Get poolInfo via StorageAccess
			AuctionTypes.PoolInfo memory pool = StorageAccess.getPoolInfo(poolId);
			
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
			unchecked { ++i; }
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
