// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { CPASetup } from "../libraries/CPASetup.sol";
import { CPAStorage } from "../base/CPAStorage.sol";
import { IErrorsAndEvents } from "./IErrorsAndEvents.sol";
import { AuctionTypes } from "../types/AuctionTypes.sol";
import { AuctionId } from "../types/AuctionId.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { Currency, CurrencyLibrary } from "@uniswap/v4-core/src/types/Currency.sol";
import { CurrencySettler } from "@openzeppelin/uniswap-hooks/src/utils/CurrencySettler.sol";
import { BalanceDelta, toBalanceDelta, BalanceDeltaLibrary } from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import { SwapParams, ModifyLiquidityParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeCast } from "@uniswap/v4-core/src/libraries/SafeCast.sol";

/**
 * @title Callbacks
 * @notice Utility functions for handling callbacks from the PoolManager
 * @author Clock-Proxy Auction Team
 */
abstract contract Callbacks is CPAStorage {
	using CurrencySettler for Currency;
	using BalanceDeltaLibrary for BalanceDelta;
	using SafeCast for *;

	/**
	 * @notice Performs a DELEGATECALL to an external library
	 * @param lib Address of the library contract
	 * @param data Encoded function call data
	 * @return result Return data from the library call
	 * @dev Uses assembly for optimal gas efficiency and bytecode size
	 *      Must be implemented by inheriting contract (CPAManager)
	 */
	function _delegatecallLibrary(address lib, bytes memory data) internal returns (bytes memory result) {
		assembly {
			result := mload(0x40)
			let success := delegatecall(gas(), lib, add(data, 0x20), mload(data), codesize(), 0x00)
			
			if iszero(success) {
				// Bubble up the revert if the delegatecall reverts
				returndatacopy(result, 0x00, returndatasize())
				revert(result, returndatasize())
			}
			
			if iszero(returndatasize()) {
				// Check if library is a contract
				if iszero(extcodesize(lib)) {
					mstore(0x00, 0x5a836a5f) // TargetIsNotContract() selector
					revert(0x1c, 0x04)
				}
			}
			
			// Store return data length
			mstore(result, returndatasize())
			let o := add(result, 0x20)
			returndatacopy(o, 0x00, returndatasize())
			mstore(0x40, add(o, returndatasize()))
		}
	}

	/**
	 * @notice Handle deposit transfer operation (setup)
	 * @param operationData The encoded operation data
	 * @return returnData The encoded balance deltas
	 */
	/**
	 * @notice Get setupLib address - must be implemented by inheriting contract
	 */
	function getSetupLib() internal view virtual returns (address);

	function _handleDepositTransfer(bytes memory operationData) internal returns (bytes memory returnData) {
		(, , , AuctionId auctionId, ) = 
			abi.decode(operationData, (PoolKey, Currency, uint256, AuctionId, address));
		// Call external library via DELEGATECALL
		bytes memory result = _delegatecallLibrary(
			getSetupLib(),
			abi.encodeWithSelector(
				CPASetup.handleDepositTransfer.selector,
				address(this),
				operationData
			)
		);
		return abi.decode(result, (bytes));
	}

	/**
	 * @dev Handle batch deposit transfer operation (setup)
	 * @param operationData The encoded batch deposit data
	 * @return returnData The encoded balance deltas
	 */
	function _handleBatchDepositTransfer(bytes memory operationData) internal returns (bytes memory returnData) {
		// Decode batch deposit data
		AuctionTypes.CallbackDataBatchDeposit memory batchData = 
			abi.decode(operationData, (AuctionTypes.CallbackDataBatchDeposit));
		
		// Verify this is a legitimate auction owner
		require(batchData.originalCaller == auctionInfo[batchData.auctionId].auctionOwner, "Not auction owner");
		
		// Process each deposit
		BalanceDelta[] memory deltas = new BalanceDelta[](batchData.poolKeys.length);
		
		for (uint256 i = 0; i < batchData.poolKeys.length; i++) {
			// Update pool info deposit amount
			poolInfo[batchData.poolKeys[i].toId()].depositAmount = batchData.depositAmounts[i];
			
			// Transfer assets using V4's settle/take mechanism
			batchData.itemCurrencies[i].settle(manager, batchData.originalCaller, batchData.depositAmounts[i], false);
			batchData.itemCurrencies[i].take(manager, address(this), batchData.depositAmounts[i], true);
			
			// Create balance delta for this pool
			int128 amount0 = 0;
			int128 amount1 = 0;
			
			if (address(Currency.unwrap(batchData.poolKeys[i].currency0)) == address(Currency.unwrap(batchData.itemCurrencies[i]))) {
				amount0 = int128(uint128(batchData.depositAmounts[i]));
			} else {
				amount1 = int128(uint128(batchData.depositAmounts[i]));
			}
			
			deltas[i] = toBalanceDelta(amount0, amount1);
			
			// Emit event for each deposit
			emit IErrorsAndEvents.AssetsDeposited(
				batchData.auctionId, 
				batchData.poolKeys[i].toId(), 
				address(Currency.unwrap(batchData.itemCurrencies[i])), 
				batchData.depositAmounts[i], 
				cpaAuctionHookAddr
			);
		}
		
		// Return all balance deltas
		return abi.encode(deltas, BalanceDeltaLibrary.ZERO_DELTA);
	}
	
	/**
	 * @dev Handle bid as liquidity add operation
	 * @param operationData The encoded operation data containing (int128 amount0, int128 amount1)
	 * @return returnData The encoded balance deltas
	 */
	function _handleBid(bytes memory operationData) internal returns (bytes memory returnData) {
		// Decode the callback data
		(AuctionTypes.CallbackDataBid memory data) = abi.decode(operationData, (AuctionTypes.CallbackDataBid));
		address sender = data.sender;
		address numeraire = data.numeraire;
		int128 stake = data.stake;
		
		// Validate deadline
		require(block.timestamp <= data.deadline, "Bid deadline expired");
		
		// Transfer numeraire from bidder to pool manager
		Currency.wrap(numeraire).settle(manager, sender, uint256(int256(stake)), false);
		
		// Mint ERC6909 claims to this hook (bypassing V3 curve)
		Currency.wrap(numeraire).take(manager, address(this), uint256(int256(stake)), true);
		
		// Return the balance deltas
		return abi.encode(
			toBalanceDelta(0, -stake), // callerDelta
			BalanceDeltaLibrary.ZERO_DELTA // feesAccrued
		);
	}

	/**
	 * @notice Handle price update swap in callback
	 */
	function _handlePriceUpdateSwap(bytes memory operationData) internal returns (bytes memory) {
		// Decode the swap parameters
		(PoolKey memory poolKey, SwapParams memory swapParams) = abi.decode(operationData, (PoolKey, SwapParams)); 
		
		// Execute the swap to update the price
		BalanceDelta delta = manager.swap(poolKey, swapParams, "");

		// Return the delta
		return abi.encode(delta);
	}
	
	/**
	 * @dev Handle mint position after allocation
	 * @param operationData The encoded operation data
	 * @return returnData The encoded balance deltas
	 */
	function _handleMintPosition(bytes memory operationData) internal returns (bytes memory returnData) {
		// decode the operation data
		(AuctionTypes.CallbackDataMintPosition memory data) = abi.decode(operationData, (AuctionTypes.CallbackDataMintPosition));

		(BalanceDelta callerDelta, BalanceDelta feesAccrued) = manager.modifyLiquidity(
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
			data.poolKey.currency0.settle(manager, address(this), uint256(int256(-callerDelta.amount0())), true);
		}

		if (callerDelta.amount1() < 0) {
			// If amount1 is negative, send tokens from the sender to the pool
			data.poolKey.currency1.settle(manager, address(this), uint256(int256(-callerDelta.amount1())), true);
		}

		return abi.encode(callerDelta, feesAccrued);
	}

	/**
	 * @notice Handle claim token settlement operation
	 * @param operationData The encoded operation data
	 * @return returnData The encoded balance deltas
	 */
	function _handleClaimToken(bytes memory operationData) internal returns (bytes memory returnData) {
		// Decode the operation data
		AuctionTypes.CallbackDataClaimToken memory callbackData = abi.decode(operationData, (AuctionTypes.CallbackDataClaimToken));
		
		// now that we have everything, we need to call swap on the pool manager
		BalanceDelta delta = manager.swap(callbackData.poolKey, callbackData.swapParams, "");

		Currency numeraire = Currency.wrap(callbackData.numeraire);
		uint256 numeraireOwed;
		uint256 assetGained;
		{
			Currency asset;
			if (callbackData.swapParams.zeroForOne) {
				// if zeroForOne is true, this means that the numeraire is token0
				if (delta.amount1() < 0) revert("Should not owe asset");
				numeraireOwed = uint256((-delta.amount0()).toUint128());
				assetGained = uint256((delta.amount1()).toUint128());
				asset = callbackData.poolKey.currency1;
			} else {
				// if zeroForOne is false, this means that the numeraire is token1
				if (delta.amount0() < 0) revert("Should not owe asset");
				numeraireOwed = uint256((-delta.amount1()).toUint128());
				assetGained = uint256((delta.amount0()).toUint128());
				asset = callbackData.poolKey.currency0;
			}
			asset.take(manager, callbackData.bidder, assetGained, false);
		}

		uint256 bidderStake = bidderStake[callbackData.auctionId][callbackData.bidder];
		uint256 numerairePaidByManager = 0;
		if (bidderStake >= numeraireOwed) {
			// since they have enough to cover, we can settle directly
			numeraire.settle(manager, address(this), numeraireOwed, true); // might need to be true since the manager has ERC6909 claims
			numerairePaidByManager = numeraireOwed;
		} else {
			//since they don't have enough, we need to do two settles
			numeraire.settle(manager, address(this), bidderStake, true); // might need to be true since the manager has ERC6909 claims
			numeraire.settle(manager, callbackData.bidder, numeraireOwed - bidderStake, false); // the bidder pays in ERC20
			numerairePaidByManager = bidderStake;
		}
		
		// Return the balance delta
		return abi.encode(numerairePaidByManager, assetGained);
	}


	/**
	 * @notice Handle claim token settlement operation
	 * @param operationData The encoded operation data
	 * @return returnData The encoded balance deltas
	 */
	function _handleClaimAllTokens(bytes memory operationData) internal returns (bytes memory returnData) {
		// Decode the operation data
		AuctionTypes.CallbackDataClaimAllTokens memory callbackData = abi.decode(operationData, (AuctionTypes.CallbackDataClaimAllTokens));
		
		Currency numeraire = Currency.wrap(callbackData.numeraire);
		uint256 totalNumeraireOwed = 0;
		
		// Loop through all pool keys and execute swaps for tokens the bidder is owed
		for (uint256 i = 0; i < callbackData.poolKeys.length; i++) {
			uint256 amountOwed = callbackData.allocatedQuantities[i];
			if (amountOwed > 0) {
				PoolKey memory poolKey = callbackData.poolKeys[i];
				bool numeraireIsCurrency0 = (Currency.unwrap(poolKey.currency0) == callbackData.numeraire);

				SwapParams memory params = SwapParams({
					zeroForOne: numeraireIsCurrency0,
					amountSpecified: (amountOwed.toInt256()),
					sqrtPriceLimitX96: numeraireIsCurrency0
						? TickMath.MIN_SQRT_PRICE + 1
						: TickMath.MAX_SQRT_PRICE - 1
				});
				
				// Execute swap on this pool
				BalanceDelta delta = manager.swap(poolKey, params, "");

				uint256 numeraireOwed;
				{
					Currency asset;
					if (params.zeroForOne) {
						// if zeroForOne is true, this means that the numeraire is token0
						if (delta.amount1() < 0) revert("Should not owe asset");
						numeraireOwed = uint256((-delta.amount0()).toUint128());
						uint256 assetGained = uint256((delta.amount1()).toUint128());
						asset = poolKey.currency1;
						asset.take(manager, callbackData.bidder, assetGained, false);
					} else {
						// if zeroForOne is false, this means that the numeraire is token1
						if (delta.amount0() < 0) revert("Should not owe asset");
						numeraireOwed = uint256((-delta.amount1()).toUint128());
						uint256 assetGained = uint256((delta.amount0()).toUint128());
						asset = poolKey.currency0;
						asset.take(manager, callbackData.bidder, assetGained, false);
					}
				}
				
				// Add to total numeraire owed
				totalNumeraireOwed += numeraireOwed;
			}
		}

		uint256 bidderStake = bidderStake[callbackData.auctionId][callbackData.bidder];
		uint256 numerairePaidByManager = 0;
		uint256 protocolPenalty = 0;
		if (bidderStake >= totalNumeraireOwed) {
			// since they have enough to cover, we can settle directly
			numeraire.settle(manager, address(this), totalNumeraireOwed, true); // might need to be true since the manager has ERC6909 claims
			numerairePaidByManager = totalNumeraireOwed;

			// since they had enough, we need to check if they met the minimum spend ratio and refund any leftover numeraire
			uint256 minSpendAmount = auctionInfo[callbackData.auctionId].config.minSpendRatio * bidderStake / 10000;
			if (minSpendAmount > numerairePaidByManager) {
				// Didn't meet minimum spend - penalty applies
				protocolPenalty = minSpendAmount - numerairePaidByManager;
				protocolPenalties[callbackData.auctionId] += protocolPenalty;
				bidderStake -= minSpendAmount;
			} // else they met the minimum spend ratio so no penalty applies

			// refund the leftover numeraire after applying the penalty
			manager.burn(address(this), CurrencyLibrary.toId(numeraire), bidderStake - totalNumeraireOwed - protocolPenalty);
			numeraire.take(manager, callbackData.bidder, bidderStake - totalNumeraireOwed - protocolPenalty, false);
		} else {
			//since they don't have enough numeraire to cover the bundle price, we need to do two settles
			numeraire.settle(manager, address(this), bidderStake, true); // might need to be true since the manager has ERC6909 claims
			numeraire.settle(manager, callbackData.bidder, totalNumeraireOwed - bidderStake, false); // the bidder pays in ERC20
			numerairePaidByManager = bidderStake;

			// bidder has no leftover stake so there is no need to refund anything
		}
		
		// Return the balance delta
		return abi.encode(numerairePaidByManager);
	}

	function _refundStake(bytes memory operationData) internal returns (bytes memory returnData) {
		// Decode the operation data
		(AuctionTypes.CallbackDataRefundStake memory data) = abi.decode(operationData, (AuctionTypes.CallbackDataRefundStake));
		
		// Refund the stake
		manager.burn(address(this), CurrencyLibrary.toId(Currency.wrap(data.numeraire)), data.amount);

		// now that we are credited, transfer the tokens to the address
		Currency.wrap(data.numeraire).take(manager, data.recipient, data.amount, false);

		// Return the balance delta
		return abi.encode(data.amount);
	}

	function _handleClaimAllocatorReward(bytes memory operationData) internal returns (bytes memory returnData) {
		// Decode the operation data
		(AuctionTypes.CallbackDataClaimAllocatorReward memory data) = abi.decode(operationData, (AuctionTypes.CallbackDataClaimAllocatorReward));
		
		// we are already unlocked here so we just need to transfer tokens from the CPAManager to the allocator
		Currency.wrap(data.numeraire).take(manager, data.allocator, data.reward, false); // give ERC20 to the allocator
		manager.burn(address(this), CurrencyLibrary.toId(Currency.wrap(data.numeraire)), data.reward); // burn ERC6909 from the CPAManager
		
		return abi.encode(data.reward);
	}

	/**
	 * @notice Handle batch ERC6909 to ERC20 conversion for position minting
	 * @dev Converts all asset ERC6909 claims to ERC20 in single unlock callback
	 * @param operationData The encoded batch conversion data
	 * @return returnData Empty bytes (no balance deltas needed)
	 */
	function _handleBatchERC6909ToERC20Conversion(bytes memory operationData) internal returns (bytes memory) {
		AuctionTypes.CallbackDataBatchERC6909ToERC20 memory data = abi.decode(
			operationData, 
			(AuctionTypes.CallbackDataBatchERC6909ToERC20)
		);
		
		// Convert all ERC6909 claims to ERC20 for each asset
		for (uint256 i = 0; i < data.assetCurrencies.length; i++) {
			manager.burn(address(this), CurrencyLibrary.toId(data.assetCurrencies[i]), data.amounts[i]);
			data.assetCurrencies[i].take(manager, address(this), data.amounts[i], false);
		}
		
		return "";
	}

}