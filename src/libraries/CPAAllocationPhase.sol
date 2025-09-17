// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { console } from "forge-std/console.sol";

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { BundleId } from "../BundleId.sol";
import { AuctionTypes } from "../AuctionTypes.sol";
import { CPAStorage } from "../base/CPAStorage.sol";
import { AuctionId } from "../AuctionId.sol";
import { IErrorsAndEvents } from "../utils/IErrorsAndEvents.sol";
import { IPositionManager } from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import { Actions } from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import { LiquidityAmounts } from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import { SafeCast } from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import { BalanceDelta } from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import { ModifyLiquidityParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";
import { CurrencySettler } from "@openzeppelin/uniswap-hooks/src/utils/CurrencySettler.sol";
import { Position } from "@uniswap/v4-core/src/libraries/Position.sol";

import { PriceUtils } from "../utils/PriceUtils.sol";
import { console } from "forge-std/console.sol";

library CPAAllocationPhase {
	using PriceUtils for IPoolManager;
	using StateLibrary for IPoolManager;
	using SafeCast for uint256;
	using CurrencySettler for Currency;

    /**
	 * @notice Submit allocation during allocation phase
	 * @param self The contract instance
	 * @param allocationData The allocation data
	 */
	function submitAllocation(
		CPAStorage self,
		AuctionTypes.Allocation calldata allocationData,
		mapping(AuctionId => AuctionTypes.TopAllocation) storage topAllocation,
		mapping(AuctionId => AuctionTypes.AuctionInfo) storage auctionInfo,
		mapping(PoolId => AuctionTypes.PoolInfo) storage poolInfo,
		mapping(AuctionId => mapping(BundleId => AuctionTypes.Bundle)) storage bundles
	) external {
		AuctionId auctionId = allocationData.auctionId;

		// check if the submitted allocation outscores the existing top allocation
		(uint256 score, uint256 totalValue) = _scoreAllocation(self, auctionId, allocationData, auctionInfo, poolInfo, bundles);
		if (score > topAllocation[auctionId].score) {
			topAllocation[auctionId].allocation = allocationData;
			topAllocation[auctionId].score = score;
			topAllocation[auctionId].totalValue = totalValue; // in this case, the total value is the same as the score
		}

		// emit a allocation submitted event
		emit IErrorsAndEvents.AllocationSubmitted(allocationData.auctionId, allocationData.allocator, score);
	}

	function _scoreAllocation(
		CPAStorage self,
		AuctionId auctionId,
		AuctionTypes.Allocation calldata allocationData,
		mapping(AuctionId => AuctionTypes.AuctionInfo) storage auctionInfo,
		mapping(PoolId => AuctionTypes.PoolInfo) storage poolInfo,
		mapping(AuctionId => mapping(BundleId => AuctionTypes.Bundle)) storage bundles
	) internal view returns (uint256, uint256) {
		/* 
			This is where it gets interesting:
			We have created a competitive system where allocators are competing to win the allocation by submitting the highest value allocation 
			as fast as possible. What metric they try to maximize (or minimize)	is up to the auctioneer. 
			
			For the purporses of the POC, we will simply use a revenue maximization for the auctioneer. But in theory, any metric could be used.
			And the auctioneer could even use a combination of metrics.
			
			Other ideas for metrics:
			- Revenue maximization
			- Fairness
			- Efficiency
			- Arbitrary constraint satisfaction
			- Token distribution preferences
			- etc.

			The hard part going forward would be to VERIFY that the allocation maximizes/minimizes the arbitrarymetric. This may, in further versions,
			require off-chain computing. Verifying revenue maximization is relatively straightforward and can be done on-chain.
		*/

		// we have already checked at this point that the allocation is valid
		// before we do anything, we need to map the various BundleIds to their corresponding bundles and then get the quantities
		// so we can just compute the value of the allocation in terms of the numeraire.
		// to do this, we need to get the prices of the assets in terms of the numeraire in each pool
		// then we need to multiply the quantities of the assets by the prices and sum them up.

		// (, address commonNumeraire, , , , , , , PoolKey[] memory poolKeys) = self.getAuctionInfo(auctionId);
		PoolKey[] memory poolKeys = auctionInfo[auctionId].poolKeys;
		uint256 totalValue = 0;
		uint256[] memory quantities = new uint256[](poolKeys.length);
		bytes32[] memory existingCommitHashes = new bytes32[](allocationData.bundleIds.length);

		// in the bundle submission we have already verified that the length of the quantities is equal to the number of assets in the auction
		// so we don't need to worry about reading beyond the array length
		// here we just sum the quantities of the bundles
		for (uint256 i = 0; i < allocationData.bundleIds.length; i++) {
			BundleId bundleId = allocationData.bundleIds[i];
			
			// check that the bundle exists
			if (bundles[auctionId][bundleId].commitHash == bytes32(0)) revert IErrorsAndEvents.InvalidBundle(auctionId, bundleId);

			// check that no bidder (commitHash) has been allocated more than one bundle
			if (_checkIfDuplicateAllocation(bundles[auctionId][bundleId].commitHash, existingCommitHashes, i)) revert IErrorsAndEvents.DuplicateAllocation(auctionId, bundles[auctionId][bundleId].commitHash);

			// update the quantities
			AuctionTypes.Bundle memory bundle = bundles[auctionId][bundleId];
			for (uint256 j = 0; j < bundle.quantities.length; j++) {
				quantities[j] += bundle.quantities[j];
			}

			// update the existing commit hashes
			existingCommitHashes[i] = bundles[auctionId][bundleId].commitHash;
		}

		// Validate quantities and compute total value in a single loop
		for (uint256 i = 0; i < poolKeys.length; i++) {
			PoolKey memory poolKey = poolKeys[i];
			PoolId poolId = poolKey.toId();
			
			// Check if the requested quantity exceeds the available deposit
			if (quantities[i] > poolInfo[poolId].depositAmount) {
				revert IErrorsAndEvents.InvalidQuantities(auctionId, quantities[i]);
			}
			
			// Determine which currency is the asset (not the numeraire)
			address assetCurrency;
			if (Currency.unwrap(poolKey.currency0) == auctionInfo[auctionId].commonNumeraire) {
				// currency0 is numeraire, currency1 is the asset
				assetCurrency = Currency.unwrap(poolKey.currency1);
			} else {
				// currency1 is numeraire, currency0 is the asset
				assetCurrency = Currency.unwrap(poolKey.currency0);
			}
			
			// Get the price of the asset in terms of numeraire
			uint256 price = self.manager().getPriceOfCurrency(poolKey, assetCurrency);
			
			// Calculate value: quantity * price
			totalValue += (quantities[i] * price) / 10**18; // this will need to divide by the decimals of the numeraire (should be dynamic not static)
		}
		
		return (totalValue, totalValue); // again, the total value is the same as the score here
	}

	function _checkIfDuplicateAllocation(
		bytes32 commitHash,
		bytes32[] memory existingCommitHashes,
		uint256 index
	) internal view returns (bool) {
		for (uint256 i = 0; i < index; i++) {
			if (existingCommitHashes[i] == commitHash) return true;
		}
		return false;
	}

	function endAllocationPhase(
		CPAStorage self,
		AuctionId auctionId,
		mapping(AuctionId => AuctionTypes.TopAllocation) storage topAllocation,
		mapping(AuctionId => AuctionTypes.AuctionInfo) storage auctionInfo,
		mapping(PoolId => AuctionTypes.PoolInfo) storage poolInfo,
		mapping(AuctionId => mapping(BundleId => AuctionTypes.Bundle)) storage bundles,
		mapping(bytes32 => BundleId) storage winningBundleIds
	) internal {
		// whatever allocation is the top one is the winner
		// we check if the window has passed in the function that calls this
		AuctionTypes.Allocation memory winner = topAllocation[auctionId].allocation;
		// emit IErrorsAndEvents.AllocationWinner(auctionId, winner.allocator);

		// store the winning bundle ids
		for (uint i = 0; i < winner.bundleIds.length; i++) {
			winningBundleIds[bundles[auctionId][winner.bundleIds[i]].commitHash] = winner.bundleIds[i];
		}
		
		// Transfer assets to pools at final prices
		_transferAssetsToPools(self, auctionId, auctionInfo, poolInfo);
	}
	
	/**
	 * @notice Transfer full deposit amounts of assets to pools at final prices
	 * @param self The contract instance
	 * @param auctionId The auction ID
	 * @param auctionInfo The auction info mapping
	 * @param poolInfo The pool info mapping
	 */
	function _transferAssetsToPools(
		CPAStorage self,
		AuctionId auctionId,
		mapping(AuctionId => AuctionTypes.AuctionInfo) storage auctionInfo,
		mapping(PoolId => AuctionTypes.PoolInfo) storage poolInfo
	) internal {
		AuctionTypes.AuctionInfo storage auction = auctionInfo[auctionId];
		PoolKey[] memory poolKeys = auction.poolKeys;
		
		// Create dynamic actions array - 2 actions per pool (mint + settle)
		// bytes memory actions = new bytes(poolKeys.length * 2);
		// bytes[] memory params = new bytes[](poolKeys.length * 2);

		bytes[] memory params = new bytes[](poolKeys.length);
		
		for (uint256 i = 0; i < poolKeys.length; i++) {
			// params[i] = _processPoolForLiquidity(
			// 	self, 
			// 	auctionId, 
			// 	auctionInfo, 
			// 	poolInfo, 
			// 	positionManager, 
			// 	poolKeys[i], 
			// 	i
			// );

			// lets try it with an unlock without the position manager
			(int24 tickLower, int24 tickUpper, uint128 liquidity) = _calculateLiquidityParams(self, auctionId, auctionInfo, poolInfo, poolKeys[i]);
			bytes memory callbackData = abi.encode(
				uint8(3), // operationType = 3 for mint position after allocation
				abi.encode(AuctionTypes.CallbackDataMintPosition({
					poolKey: poolKeys[i],
					tickLower: tickLower,
					tickUpper: tickUpper,
					liquidity: liquidity,
					hookData: "",
					auctionId: auctionId
				}))
			);
			self.manager().unlock(callbackData);

			// since this is being deposited on behalf of the auctioneer outside of the position manager,
			// we need to keep track of the position id manually
			poolInfo[poolKeys[i].toId()].positionId = Position.calculatePositionKey(address(self), tickLower, tickUpper, AuctionId.unwrap(auctionId));
		}

		// positionManager.multicall(params);
	}
	
	function _processPoolForLiquidity(
		CPAStorage self,
		AuctionId auctionId,
		mapping(AuctionId => AuctionTypes.AuctionInfo) storage auctionInfo,
		mapping(PoolId => AuctionTypes.PoolInfo) storage poolInfo,
		PoolKey memory poolKey,
		uint256 index
	) internal returns (bytes memory) {
		PoolId poolId = poolKey.toId();
		AuctionTypes.PoolInfo storage pool = poolInfo[poolId];
		
		// Get the final price from the pool (set during clock phase)
		(uint160 sqrtPriceX96, , , ) = self.manager().getSlot0(poolId);
		int24 tick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
		
		// Determine currency order and calculate parameters
		bool assetIsCurrency0 = auctionInfo[auctionId].commonNumeraire != address(Currency.unwrap(poolKey.currency0));
		
		int24 tickLower;
		int24 tickUpper;
		uint128 amount0Max;
		uint128 amount1Max;
		uint128 liquidity;
		address assetAddress;
		
		if (assetIsCurrency0) {
			// Asset is currency0
			tickLower = _alignComputedTickWithTickSpacing(true, tick, poolKey.tickSpacing);
			tickUpper = tickLower + poolKey.tickSpacing;
			amount0Max = uint128(pool.depositAmount);
			amount1Max = 0;
			liquidity = LiquidityAmounts.getLiquidityForAmount0(
				TickMath.getSqrtPriceAtTick(tickLower), 
				TickMath.getSqrtPriceAtTick(tickUpper), 
				pool.depositAmount
			);
			assetAddress = address(Currency.unwrap(poolKey.currency0));
		} else {
			// Asset is currency1
			tickUpper = _alignComputedTickWithTickSpacing(false, tick, poolKey.tickSpacing);
			tickLower = tickUpper - poolKey.tickSpacing;
			amount0Max = 0;
			amount1Max = uint128(pool.depositAmount);
			liquidity = LiquidityAmounts.getLiquidityForAmount1(
				TickMath.getSqrtPriceAtTick(tickLower), 
				TickMath.getSqrtPriceAtTick(tickUpper), 
				pool.depositAmount
			);
			assetAddress = address(Currency.unwrap(poolKey.currency1));
		}
		
		// Redeem ERC6909 claims to get actual tokens
		// this is ugly and we can avoid doing this by just doing the settling directly
		
		// Note: No longer using PositionManager or Permit2 - calling PoolManager directly
		
		// Encode parameters
		bytes memory actions = abi.encodePacked(
			uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR)
		);
		bytes[] memory mintParams = new bytes[](2);
		mintParams[0] = abi.encode(poolKey, tickLower, tickUpper, liquidity, amount0Max, amount1Max, address(self), "");
		mintParams[1] = abi.encode(poolKey.currency0, poolKey.currency1);

		// Note: This function is no longer used since we call PoolManager directly
		return "";
	}

	function _calculateLiquidityParams(
		CPAStorage self,
		AuctionId auctionId,
		mapping(AuctionId => AuctionTypes.AuctionInfo) storage auctionInfo,
		mapping(PoolId => AuctionTypes.PoolInfo) storage poolInfo,
		PoolKey memory poolKey
	) internal view returns (int24 tickLower, int24 tickUpper, uint128 liquidity) {
		PoolId poolId = poolKey.toId();
		AuctionTypes.PoolInfo storage pool = poolInfo[poolId];
		
		// Get the final price from the pool (set during clock phase)
		(uint160 sqrtPriceX96, , , ) = self.manager().getSlot0(poolId);
		int24 tick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
		
		// Determine currency order and calculate parameters
		bool assetIsCurrency0 = auctionInfo[auctionId].commonNumeraire != address(Currency.unwrap(poolKey.currency0));
		
		// Debug output
		console.log("=== TICK CALCULATION DEBUG ===");
		console.log("PoolId:", uint256(PoolId.unwrap(poolId)));
		console.log("Current tick:", tick);
		console.log("Tick spacing:", poolKey.tickSpacing);
		console.log("Asset is currency0:", assetIsCurrency0);
		console.log("Deposit amount:", pool.depositAmount);
		console.log("Currency0 address:", address(Currency.unwrap(poolKey.currency0)));
		console.log("Currency1 address:", address(Currency.unwrap(poolKey.currency1)));
		console.log("Common numeraire:", auctionInfo[auctionId].commonNumeraire);
		
		if (assetIsCurrency0) {
			// Asset is currency0
			tickLower = _alignComputedTickWithTickSpacing(false, tick, poolKey.tickSpacing);
			tickUpper = tickLower + poolKey.tickSpacing;
			liquidity = LiquidityAmounts.getLiquidityForAmount0(
				TickMath.getSqrtPriceAtTick(tickLower), 
				TickMath.getSqrtPriceAtTick(tickUpper), 
				pool.depositAmount
			);
			console.log("Asset is currency0 - tickLower:", tickLower);
			console.log("Asset is currency0 - tickUpper:", tickUpper);
			console.log("Asset is currency0 - liquidity:", liquidity);
		} else {
			// Asset is currency1
			tickUpper = _alignComputedTickWithTickSpacing(true, tick, poolKey.tickSpacing);
			tickLower = tickUpper - poolKey.tickSpacing;
			liquidity = LiquidityAmounts.getLiquidityForAmount1(
				TickMath.getSqrtPriceAtTick(tickLower), 
				TickMath.getSqrtPriceAtTick(tickUpper), 
				pool.depositAmount
			);
			console.log("Asset is currency1 - tickLower:", tickLower);
			console.log("Asset is currency1 - tickUpper:", tickUpper);
			console.log("Asset is currency1 - liquidity:", liquidity);
		}
	}

	function handleMintPosition(
		CPAStorage self,
		bytes memory operationData
	) internal returns (bytes memory) {
		// decode the operation data
		(AuctionTypes.CallbackDataMintPosition memory data) = abi.decode(operationData, (AuctionTypes.CallbackDataMintPosition));

		 (BalanceDelta callerDelta, BalanceDelta feesAccrued) = IPoolManager(self.manager()).modifyLiquidity(
            data.poolKey,
            ModifyLiquidityParams({
                tickLower: data.tickLower,
                tickUpper: data.tickUpper,
                liquidityDelta: data.liquidity.toInt128(),
                salt: AuctionId.unwrap(data.auctionId)
            }),
            data.hookData
        );

		// handle the deltas
		if (callerDelta.amount0() < 0) {
			// If amount0 is negative, send tokens from the sender to the pool
			data.poolKey.currency0.settle(self.manager(), address(self), uint256(int256(-callerDelta.amount0())), true);
		}

		if (callerDelta.amount1() < 0) {
			// If amount1 is negative, send tokens from the sender to the pool
			data.poolKey.currency1.settle(self.manager(), address(self), uint256(int256(-callerDelta.amount1())), true);
		}

		return abi.encode(callerDelta, feesAccrued);
	}

	function claimReward(
		CPAStorage self,
		AuctionId auctionId,
		AuctionTypes.TopAllocation memory topAllocation,
		mapping(AuctionId => AuctionTypes.AuctionInfo) storage auctionInfo
	) internal {
		// claim the reward
		// check in the encapsulating function that the window has passed and that the caller is the winner
	}

	function _rewardAllocator(
		CPAStorage self,
		AuctionId auctionId,
		AuctionTypes.TopAllocation memory topAllocation,
		mapping(AuctionId => AuctionTypes.AuctionInfo) storage auctionInfo
	) internal {
		// reward the allocator
		// uint256 reward = topAllocation.allocation.totalValue * auctionInfo[auctionId].config.rewardPercentage;
		
		// the CPAManager has ERC6909 numeraireclaim tokens, held by the PoolManager, that need to be redeemed for ERC20 and 
		// transferred to the allocator.
	}

    /**
     * @notice Aligns a given tick with the tickSpacing of the pool
     *         Rounds down according to the asset token denominated price
     * @param tick The tick to align
     * @param tickSpacing The tick spacing of the pool
     */
    function _alignComputedTickWithTickSpacing(bool isToken0, int24 tick, int24 tickSpacing) internal view returns (int24) {
        if (isToken0) {
            // Round down if isToken0
            if (tick < 0) {
                // If the tick is negative, we round up (negatively) the negative result to round down
                return (tick - tickSpacing + 1) / tickSpacing * tickSpacing;
            } else {
                // Else if positive, we simply round down
                return tick / tickSpacing * tickSpacing;
            }
        } else {
            // Round up if isToken1
            if (tick < 0) {
                // If the tick is negative, we round down the negative result to round up
                return tick / tickSpacing * tickSpacing;
            } else {
                // Else if positive, we simply round up
                return (tick + tickSpacing - 1) / tickSpacing * tickSpacing;
            }
        }
    }

}
