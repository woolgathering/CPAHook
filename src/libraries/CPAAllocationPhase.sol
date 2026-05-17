// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;


import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IPositionManager } from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import { Actions } from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import { SafeCast } from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import { Position } from "@uniswap/v4-core/src/libraries/Position.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { BalanceDelta } from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import { ModifyLiquidityParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";
import { IERC20 } from "forge-std/interfaces/IERC20.sol";
import { CurrencySettler } from "@openzeppelin/uniswap-hooks/src/utils/CurrencySettler.sol";
import { CurrencyDecimals } from "../utils/CurrencyDecimals.sol";

import { CPAStorage } from "../base/CPAStorage.sol";
import { IMathFacet } from "../interfaces/IMathFacet.sol";
import { PriceUtils } from "../utils/PriceUtils.sol";
import { IErrorsAndEvents } from "../utils/IErrorsAndEvents.sol";
import { AuctionTypes } from "../types/AuctionTypes.sol";
import { AuctionId } from "../types/AuctionId.sol";
import { BundleId } from "../types/BundleId.sol";

library CPAAllocationPhase {
	using PriceUtils for IPoolManager;
	using StateLibrary for IPoolManager;
	using SafeCast for uint256;
	using CurrencySettler for Currency;

    /**
	 * @notice Submit allocation during allocation phase
	 * @param self The contract instance
	 * @param allocationData The allocation data
	 * @param topAllocation The top allocation mapping
	 * @param auctionInfo The auction info mapping
	 * @param poolInfo The pool info mapping
	 * @param auctionBundles The auction-specific bundles mapping (bundles[auctionId])
	 * @param hasAllocations The hasAllocations mapping
	 */
	function submitAllocation(
		CPAStorage self,
		AuctionTypes.Allocation calldata allocationData,
		mapping(AuctionId => AuctionTypes.TopAllocation) storage topAllocation,
		AuctionTypes.AuctionInfo storage auctionInfo,
		mapping(PoolId => AuctionTypes.PoolInfo) storage poolInfo,
		mapping(BundleId => AuctionTypes.Bundle) storage auctionBundles,
		mapping(AuctionId => bool) storage hasAllocations
	) internal {
		AuctionId auctionId = allocationData.auctionId;

		// check if the submitted allocation outscores the existing top allocation
		(uint256 score, uint256 totalValue) = _scoreAllocation(self, auctionId, allocationData, auctionInfo, poolInfo, auctionBundles);
		if (score > topAllocation[auctionId].score) {
			topAllocation[auctionId].allocation = allocationData;
			topAllocation[auctionId].score = score;
			topAllocation[auctionId].totalValue = totalValue; // in this case, the total value is the same as the score
		}

		// mark that allocations have been submitted for this auction
		hasAllocations[allocationData.auctionId] = true;

		// emit a allocation submitted event
		emit IErrorsAndEvents.AllocationSubmitted(allocationData.auctionId, allocationData.allocator, score);
	}

	function _scoreAllocation(
		CPAStorage self,
		AuctionId auctionId,
		AuctionTypes.Allocation calldata allocationData,
		AuctionTypes.AuctionInfo storage auctionInfo,
		mapping(PoolId => AuctionTypes.PoolInfo) storage poolInfo,
		mapping(BundleId => AuctionTypes.Bundle) storage auctionBundles
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

		// Check that allocation is not empty
		if (allocationData.bundleIds.length == 0) revert IErrorsAndEvents.EmptyAllocation(auctionId);

		// (, address commonNumeraire, , , , , , , PoolKey[] memory poolKeys) = self.getAuctionInfo(auctionId);
		PoolKey[] memory poolKeys = auctionInfo.poolKeys;
		uint256 totalValue = 0;
		uint256[] memory quantities = new uint256[](poolKeys.length);
		bytes32[] memory existingCommitHashes = new bytes32[](allocationData.bundleIds.length);

		// in the bundle submission we have already verified that the length of the quantities is equal to the number of assets in the auction
		// so we don't need to worry about reading beyond the array length
		// here we just sum the quantities of the bundles
		for (uint256 i = 0; i < allocationData.bundleIds.length; ) {
			BundleId bundleId = allocationData.bundleIds[i];
			
			// check that the bundle exists
			if (auctionBundles[bundleId].commitHash == bytes32(0)) revert IErrorsAndEvents.InvalidBundle(auctionId, bundleId);

			// check that no bidder (commitHash) has been allocated more than one bundle
			if (_checkIfDuplicateAllocation(auctionBundles[bundleId].commitHash, existingCommitHashes, i)) revert IErrorsAndEvents.DuplicateAllocation(auctionId, auctionBundles[bundleId].commitHash);

			// update the quantities
			AuctionTypes.Bundle memory bundle = auctionBundles[bundleId];
			for (uint256 j = 0; j < bundle.quantities.length; ) {
				quantities[j] += bundle.quantities[j];
				unchecked { ++j; }
			}

			// update the existing commit hashes
			existingCommitHashes[i] = auctionBundles[bundleId].commitHash;
			unchecked { ++i; }
		}

		// Get numeraire decimals once for efficiency
		uint8 numeraireDecimals = CurrencyDecimals.getDecimals(auctionInfo.commonNumeraire);
		
		// Validate quantities and compute total value in a single loop
		for (uint256 i = 0; i < poolKeys.length; ) {
			PoolKey memory poolKey = poolKeys[i];
			PoolId poolId = poolKey.toId();
			
			// Check if the requested quantity exceeds the available deposit
			if (quantities[i] > poolInfo[poolId].depositAmount) {
				revert IErrorsAndEvents.InvalidQuantities(auctionId, quantities[i]);
			}
			
			// Determine which currency is the asset (not the numeraire)
			address assetCurrency;
			if (Currency.unwrap(poolKey.currency0) == auctionInfo.commonNumeraire) {
				// currency0 is numeraire, currency1 is the asset
				assetCurrency = Currency.unwrap(poolKey.currency1);
			} else {
				// currency1 is numeraire, currency0 is the asset
				assetCurrency = Currency.unwrap(poolKey.currency0);
			}
			
			// Get the price of the asset in terms of numeraire
			uint256 price = self.manager().getPriceOfCurrency(poolKey, assetCurrency, self.mathFacet());
			
			// Get asset decimals for this pool
			uint8 assetDecimals = CurrencyDecimals.getDecimals(assetCurrency);
			
			// Convert: (quantity in asset decimals) * (price in 18 decimals) => value in numeraire decimals
			// Formula: (quantity * price * 10^numeraireDecimals) / (10^(18 + assetDecimals))
			totalValue += (quantities[i] * price * (10**numeraireDecimals)) / (10**(18 + assetDecimals));
			unchecked { ++i; }
		}
		
		return (totalValue, totalValue); // again, the total value is the same as the score here
	}

	function _checkIfDuplicateAllocation(
		bytes32 commitHash,
		bytes32[] memory existingCommitHashes,
		uint256 index
	) internal pure returns (bool) {
		for (uint256 i = 0; i < index; i++) {
			if (existingCommitHashes[i] == commitHash) return true;
		}
		return false;
	}

	function selectWinner(
		CPAStorage self,
		AuctionId auctionId,
		mapping(AuctionId => AuctionTypes.TopAllocation) storage topAllocation,
		mapping(AuctionId => AuctionTypes.AuctionInfo) storage auctionInfo,
		mapping(PoolId => AuctionTypes.PoolInfo) storage poolInfo,
		mapping(BundleId => AuctionTypes.Bundle) storage auctionBundles,
		mapping(bytes32 => BundleId) storage winningBundleIds
	) internal {
		// whatever allocation is the top one is the winner
		// we check if the window has passed in the function that calls this
		AuctionTypes.Allocation memory winner = topAllocation[auctionId].allocation;

		// store the winning bundle ids
		for (uint256 i = 0; i < winner.bundleIds.length; ) {
			winningBundleIds[auctionBundles[winner.bundleIds[i]].commitHash] = winner.bundleIds[i];
			unchecked { ++i; }
		}
	}
	
	/**
	 * @notice Transfer full deposit amounts of assets to pools at final prices
	 * @param self The contract instance
	 * @param auctionId The auction ID
	 * @param auctionInfo The auction info mapping
	 * @param poolInfo The pool info mapping
	 */
	function transferAssetsToPools(
		CPAStorage self,
		AuctionId auctionId,
		mapping(AuctionId => AuctionTypes.AuctionInfo) storage auctionInfo,
		mapping(PoolId => AuctionTypes.PoolInfo) storage poolInfo
	) internal {
		AuctionTypes.AuctionInfo storage auction = auctionInfo[auctionId];
		PoolKey[] memory poolKeys = auction.poolKeys;
		uint256 numPools = poolKeys.length;

		// Step 1: Collect all data in single loop
		Currency[] memory assetCurrencies = new Currency[](numPools);
		uint256[] memory amounts = new uint256[](numPools);
		bytes memory actions;
		bytes[] memory params = new bytes[](numPools * 2);
		
		// Capture starting tokenId before any mints
		uint256 startTokenId = self.positionManager().nextTokenId();
		
		for (uint256 i = 0; i < numPools; ) {
			// Collect asset currencies and amounts for ERC6909→ERC20 conversion
			assetCurrencies[i] = _getAssetCurrency(poolKeys[i], auction.commonNumeraire);
			amounts[i] = poolInfo[poolKeys[i].toId()].depositAmount;
			
			// Build actions array (MINT_POSITION + SETTLE_PAIR pattern)
			actions = bytes.concat(
				actions, 
				abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR))
			);
			
			// Calculate liquidity parameters
			(int24 tickLower, int24 tickUpper, uint128 liquidity) = _calculateLiquidityParams(
				self, auctionId, auctionInfo, poolInfo, poolKeys[i]
			);
			
			// Calculate amount maxes with 1% buffer
			(uint128 amount0Max, uint128 amount1Max) = _calculateAmountMaxes(
				poolKeys[i], poolInfo[poolKeys[i].toId()].depositAmount, auction.commonNumeraire
			);
			
			// MINT_POSITION params at index i*2
			params[i * 2] = abi.encode(
				poolKeys[i], tickLower, tickUpper, liquidity, 
				amount0Max, amount1Max, address(self), ""
			);
			
			// SETTLE_PAIR params at index i*2 + 1
			params[i * 2 + 1] = abi.encode(poolKeys[i].currency0, poolKeys[i].currency1);
			
			// Pre-store tokenId (will be startTokenId + i after minting)
			poolInfo[poolKeys[i].toId()].positionId = startTokenId + i;
			unchecked { ++i; }
		}
		
		// Step 2: Single batch callback to convert all ERC6909 to ERC20
		bytes memory callbackData = abi.encode(
			uint8(9), // operationType = 9 for batch ERC6909 to ERC20 conversion
			abi.encode(AuctionTypes.CallbackDataBatchERC6909ToERC20({
				assetCurrencies: assetCurrencies,
				amounts: amounts
			}))
		);
		self.manager().unlock(callbackData);

		// Single call to mint all positions (if this fails, entire tx reverts including stored tokenIds)
		uint256 deadline = block.timestamp + 60;
		self.positionManager().modifyLiquidities(abi.encode(actions, params), deadline);
	}

	/**
	 * @notice Step 1 of 2-step settlement: convert ERC6909 auction assets to ERC20.
	 * @dev Returns the nextTokenId captured before conversion (to pre-store position IDs in step 2).
	 */
	function convertAssetsToERC20(
		CPAStorage self,
		AuctionId auctionId,
		mapping(AuctionId => AuctionTypes.AuctionInfo) storage auctionInfo,
		mapping(PoolId => AuctionTypes.PoolInfo) storage poolInfo
	) internal returns (uint256 startTokenId) {
		AuctionTypes.AuctionInfo storage auction = auctionInfo[auctionId];
		PoolKey[] memory poolKeys = auction.poolKeys;
		uint256 numPools = poolKeys.length;

		Currency[] memory assetCurrencies = new Currency[](numPools);
		uint256[] memory amounts = new uint256[](numPools);
		for (uint256 i = 0; i < numPools; ) {
			assetCurrencies[i] = _getAssetCurrency(poolKeys[i], auction.commonNumeraire);
			amounts[i] = poolInfo[poolKeys[i].toId()].depositAmount;
			unchecked { ++i; }
		}

		startTokenId = self.positionManager().nextTokenId();

		bytes memory callbackData = abi.encode(
			uint8(9),
			abi.encode(AuctionTypes.CallbackDataBatchERC6909ToERC20({
				assetCurrencies: assetCurrencies,
				amounts: amounts
			}))
		);
		self.manager().unlock(callbackData);
	}

	/**
	 * @notice Step 2 of 2-step settlement: mint Uniswap V4 positions for each pool.
	 * @dev Requires convertAssetsToERC20 to have been called first.
	 *      startTokenId must be the value returned by convertAssetsToERC20.
	 */
	function mintPositionsForAuction(
		CPAStorage self,
		AuctionId auctionId,
		uint256 startTokenId,
		mapping(AuctionId => AuctionTypes.AuctionInfo) storage auctionInfo,
		mapping(PoolId => AuctionTypes.PoolInfo) storage poolInfo
	) internal {
		AuctionTypes.AuctionInfo storage auction = auctionInfo[auctionId];
		PoolKey[] memory poolKeys = auction.poolKeys;
		uint256 numPools = poolKeys.length;

		bytes memory actions;
		bytes[] memory params = new bytes[](numPools * 2);

		for (uint256 i = 0; i < numPools; ) {
			actions = bytes.concat(
				actions,
				abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR))
			);

			(int24 tickLower, int24 tickUpper, uint128 liquidity) = _calculateLiquidityParams(
				self, auctionId, auctionInfo, poolInfo, poolKeys[i]
			);
			(uint128 amount0Max, uint128 amount1Max) = _calculateAmountMaxes(
				poolKeys[i], poolInfo[poolKeys[i].toId()].depositAmount, auction.commonNumeraire
			);

			params[i * 2] = abi.encode(
				poolKeys[i], tickLower, tickUpper, liquidity,
				amount0Max, amount1Max, address(self), ""
			);
			params[i * 2 + 1] = abi.encode(poolKeys[i].currency0, poolKeys[i].currency1);

			poolInfo[poolKeys[i].toId()].positionId = startTokenId + i;
			unchecked { ++i; }
		}

		self.positionManager().modifyLiquidities(abi.encode(actions, params), block.timestamp + 60);
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
		IMathFacet math = IMathFacet(self.mathFacet());
		int24 tick = math.getTickAtSqrtPrice(sqrtPriceX96);

		// Determine currency order and calculate parameters
		bool assetIsCurrency0 = auctionInfo[auctionId].commonNumeraire != address(Currency.unwrap(poolKey.currency0));

		if (assetIsCurrency0) {
			// Asset is currency0
			tickLower = _alignComputedTickWithTickSpacing(false, tick, poolKey.tickSpacing);
			tickUpper = tickLower + poolKey.tickSpacing;
			liquidity = math.getLiquidityForAmount0(
				math.getSqrtPriceAtTick(tickLower),
				math.getSqrtPriceAtTick(tickUpper),
				pool.depositAmount
			);
		} else {
			// Asset is currency1
			tickUpper = _alignComputedTickWithTickSpacing(true, tick, poolKey.tickSpacing);
			tickLower = tickUpper - poolKey.tickSpacing;
			liquidity = math.getLiquidityForAmount1(
				math.getSqrtPriceAtTick(tickLower),
				math.getSqrtPriceAtTick(tickUpper),
				pool.depositAmount
			);
		}
	}




    /**
     * @notice Aligns a given tick with the tickSpacing of the pool
     *         Rounds down according to the asset token denominated price
     * @param tick The tick to align
     * @param tickSpacing The tick spacing of the pool
     */
    function _alignComputedTickWithTickSpacing(bool isToken0, int24 tick, int24 tickSpacing) internal pure returns (int24) {
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

	/**
	 * @notice Check if allocation phase should end based on duration
	 * @param self The contract instance
	 * @param auctionId The auction ID
	 * @param auctionInfo The auction info mapping
	 * @return true if allocation phase duration has expired
	 */
	function shouldAllocationPhaseEnd(
		CPAStorage self, 
		AuctionId auctionId,
		mapping(AuctionId => AuctionTypes.AuctionInfo) storage auctionInfo
	) internal view returns (bool) {
		// Check if allocation phase duration has expired
		uint256 startTime = self.allocationPhaseStartTime(auctionId);
		if (startTime == 0) return false; // Phase not started yet
		
		// Get phase duration from auction config
		return block.timestamp >= startTime + auctionInfo[auctionId].config.phaseDurations[1];
	}

	/**
	 * @notice Get the asset currency (non-numeraire) from a pool key
	 * @param poolKey The pool key
	 * @param commonNumeraire The common numeraire address
	 * @return The asset currency
	 */
	function _getAssetCurrency(PoolKey memory poolKey, address commonNumeraire) internal pure returns (Currency) {
		if (address(Currency.unwrap(poolKey.currency0)) == commonNumeraire) {
			return poolKey.currency1;
		} else {
			return poolKey.currency0;
		}
	}

	/**
	 * @notice Calculate amount0Max and amount1Max for position minting (exact amounts for single-sided)
	 * @param poolKey The pool key
	 * @param depositAmount The deposit amount
	 * @param commonNumeraire The common numeraire address
	 * @return amount0Max The maximum amount for currency0
	 * @return amount1Max The maximum amount for currency1
	 */
	function _calculateAmountMaxes(
		PoolKey memory poolKey, 
		uint256 depositAmount, 
		address commonNumeraire
	) internal pure returns (uint128 amount0Max, uint128 amount1Max) {
		if (address(Currency.unwrap(poolKey.currency0)) == commonNumeraire) {
			// Asset is currency1, numeraire is currency0
			amount0Max = 0; // No numeraire liquidity
			amount1Max = uint128(depositAmount); // Exact deposit amount
		} else {
			// Asset is currency0, numeraire is currency1
			amount0Max = uint128(depositAmount); // Exact deposit amount
			amount1Max = 0; // No numeraire liquidity
		}
	}

}
