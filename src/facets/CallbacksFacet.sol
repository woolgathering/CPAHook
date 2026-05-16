// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IPositionManager } from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { Currency, CurrencyLibrary } from "@uniswap/v4-core/src/types/Currency.sol";
import { SwapParams, ModifyLiquidityParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";
import { BalanceDelta, toBalanceDelta, BalanceDeltaLibrary } from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { SafeCast } from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { CurrencySettler } from "@openzeppelin/uniswap-hooks/src/utils/CurrencySettler.sol";

import { CPABase } from "../base/CPABase.sol";
import { CPASetup } from "../libraries/CPASetup.sol";
import { AuctionTypes } from "../types/AuctionTypes.sol";
import { AuctionId } from "../types/AuctionId.sol";

contract CallbacksFacet is CPABase {
	using CurrencySettler for Currency;
	using BalanceDeltaLibrary for BalanceDelta;
	using SafeCast for *;

	constructor(
		IPoolManager _poolManager,
		address _owner,
		address _cpaAuctionHookAddr,
		IPositionManager _positionManager,
		address _protocolWallet
	) CPAStorage(_cpaAuctionHookAddr, _positionManager) Ownable(_owner) {
		manager = _poolManager;
		protocolWallet = _protocolWallet;
	}

	function unlockCallback(bytes calldata rawData)
		external
		onlyPoolManager
		returns (bytes memory returnData)
	{
		(uint8 operationType, bytes memory operationData) = abi.decode(rawData, (uint8, bytes));

		if (operationType == 0) {
			return _handleBid(operationData);
		} else if (operationType == 1) {
			return _handleDepositTransfer(operationData);
		} else if (operationType == 2) {
			return _handlePriceUpdateSwap(operationData);
		} else if (operationType == 3) {
			return _handleMintPosition(operationData);
		} else if (operationType == 4) {
			return _handleClaimToken(operationData);
		} else if (operationType == 5) {
			return _refundStake(operationData);
		} else if (operationType == 6) {
			return _handleClaimAllocatorReward(operationData);
		} else if (operationType == 7) {
			return _handleClaimAllTokens(operationData);
		} else if (operationType == 8) {
			return _handleBatchDepositTransfer(operationData);
		} else if (operationType == 9) {
			return _handleBatchERC6909ToERC20Conversion(operationData);
		} else {
			revert("Invalid operation type");
		}
	}

	function _handleDepositTransfer(bytes memory operationData) internal returns (bytes memory) {
		(, , , AuctionId auctionId, ) =
			abi.decode(operationData, (PoolKey, Currency, uint256, AuctionId, address));
		return CPASetup.handleDepositTransfer(this, auctionInfo[auctionId], poolInfo, operationData);
	}

	function _handleBatchDepositTransfer(bytes memory operationData) internal returns (bytes memory) {
		AuctionTypes.CallbackDataBatchDeposit memory batchData =
			abi.decode(operationData, (AuctionTypes.CallbackDataBatchDeposit));

		require(batchData.originalCaller == auctionInfo[batchData.auctionId].auctionOwner, "Not auction owner");

		BalanceDelta[] memory deltas = new BalanceDelta[](batchData.poolKeys.length);

		for (uint256 i = 0; i < batchData.poolKeys.length; i++) {
			poolInfo[batchData.poolKeys[i].toId()].depositAmount = batchData.depositAmounts[i];

			batchData.itemCurrencies[i].settle(manager, batchData.originalCaller, batchData.depositAmounts[i], false);
			batchData.itemCurrencies[i].take(manager, address(this), batchData.depositAmounts[i], true);

			int128 amount0 = 0;
			int128 amount1 = 0;

			if (address(Currency.unwrap(batchData.poolKeys[i].currency0)) == address(Currency.unwrap(batchData.itemCurrencies[i]))) {
				amount0 = int128(uint128(batchData.depositAmounts[i]));
			} else {
				amount1 = int128(uint128(batchData.depositAmounts[i]));
			}

			deltas[i] = toBalanceDelta(amount0, amount1);

			emit AssetsDeposited(
				batchData.auctionId,
				batchData.poolKeys[i].toId(),
				address(Currency.unwrap(batchData.itemCurrencies[i])),
				batchData.depositAmounts[i],
				cpaAuctionHookAddr
			);
		}

		return abi.encode(deltas, BalanceDeltaLibrary.ZERO_DELTA);
	}

	function _handleBid(bytes memory operationData) internal returns (bytes memory) {
		(AuctionTypes.CallbackDataBid memory data) = abi.decode(operationData, (AuctionTypes.CallbackDataBid));

		require(block.timestamp <= data.deadline, "Bid deadline expired");

		Currency.wrap(data.numeraire).settle(manager, data.sender, uint256(int256(data.stake)), false);
		Currency.wrap(data.numeraire).take(manager, address(this), uint256(int256(data.stake)), true);

		return abi.encode(
			toBalanceDelta(0, -data.stake),
			BalanceDeltaLibrary.ZERO_DELTA
		);
	}

	function _handlePriceUpdateSwap(bytes memory operationData) internal returns (bytes memory) {
		(PoolKey memory poolKey, SwapParams memory swapParams) = abi.decode(operationData, (PoolKey, SwapParams));
		BalanceDelta delta = manager.swap(poolKey, swapParams, "");
		return abi.encode(delta);
	}

	function _handleMintPosition(bytes memory operationData) internal returns (bytes memory) {
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

		if (callerDelta.amount0() < 0)
			data.poolKey.currency0.settle(manager, address(this), uint256(int256(-callerDelta.amount0())), true);

		if (callerDelta.amount1() < 0)
			data.poolKey.currency1.settle(manager, address(this), uint256(int256(-callerDelta.amount1())), true);

		return abi.encode(callerDelta, feesAccrued);
	}

	function _handleClaimToken(bytes memory operationData) internal returns (bytes memory) {
		AuctionTypes.CallbackDataClaimToken memory callbackData = abi.decode(operationData, (AuctionTypes.CallbackDataClaimToken));

		BalanceDelta delta = manager.swap(callbackData.poolKey, callbackData.swapParams, "");

		Currency numeraire = Currency.wrap(callbackData.numeraire);
		uint256 numeraireOwed;
		uint256 assetGained;
		{
			Currency asset;
			if (callbackData.swapParams.zeroForOne) {
				if (delta.amount1() < 0) revert("Should not owe asset");
				numeraireOwed = uint256((-delta.amount0()).toUint128());
				assetGained = uint256((delta.amount1()).toUint128());
				asset = callbackData.poolKey.currency1;
			} else {
				if (delta.amount0() < 0) revert("Should not owe asset");
				numeraireOwed = uint256((-delta.amount1()).toUint128());
				assetGained = uint256((delta.amount0()).toUint128());
				asset = callbackData.poolKey.currency0;
			}
			asset.take(manager, callbackData.bidder, assetGained, false);
		}

		uint256 stake = bidderStake[callbackData.auctionId][callbackData.bidder];
		uint256 numerairePaidByManager = 0;
		if (stake >= numeraireOwed) {
			numeraire.settle(manager, address(this), numeraireOwed, true);
			numerairePaidByManager = numeraireOwed;
		} else {
			numeraire.settle(manager, address(this), stake, true);
			numeraire.settle(manager, callbackData.bidder, numeraireOwed - stake, false);
			numerairePaidByManager = stake;
		}

		return abi.encode(numerairePaidByManager, assetGained);
	}

	function _handleClaimAllTokens(bytes memory operationData) internal returns (bytes memory) {
		AuctionTypes.CallbackDataClaimAllTokens memory callbackData = abi.decode(operationData, (AuctionTypes.CallbackDataClaimAllTokens));

		Currency numeraire = Currency.wrap(callbackData.numeraire);
		uint256 totalNumeraireOwed = 0;

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

				BalanceDelta delta = manager.swap(poolKey, params, "");

				uint256 numeraireOwed;
				{
					Currency asset;
					if (params.zeroForOne) {
						if (delta.amount1() < 0) revert("Should not owe asset");
						numeraireOwed = uint256((-delta.amount0()).toUint128());
						uint256 assetGained = uint256((delta.amount1()).toUint128());
						asset = poolKey.currency1;
						asset.take(manager, callbackData.bidder, assetGained, false);
					} else {
						if (delta.amount0() < 0) revert("Should not owe asset");
						numeraireOwed = uint256((-delta.amount1()).toUint128());
						uint256 assetGained = uint256((delta.amount0()).toUint128());
						asset = poolKey.currency0;
						asset.take(manager, callbackData.bidder, assetGained, false);
					}
				}

				totalNumeraireOwed += numeraireOwed;
			}
		}

		uint256 stake = bidderStake[callbackData.auctionId][callbackData.bidder];
		uint256 numerairePaidByManager = 0;
		uint256 protocolPenalty = 0;
		if (stake >= totalNumeraireOwed) {
			numeraire.settle(manager, address(this), totalNumeraireOwed, true);
			numerairePaidByManager = totalNumeraireOwed;

			uint256 minSpendAmount = auctionInfo[callbackData.auctionId].config.minSpendRatio * stake / 10000;
			if (minSpendAmount > numerairePaidByManager) {
				protocolPenalty = minSpendAmount - numerairePaidByManager;
				protocolPenalties[callbackData.auctionId] += protocolPenalty;
				stake -= minSpendAmount;
			}

			manager.burn(address(this), CurrencyLibrary.toId(numeraire), stake - totalNumeraireOwed - protocolPenalty);
			numeraire.take(manager, callbackData.bidder, stake - totalNumeraireOwed - protocolPenalty, false);
		} else {
			numeraire.settle(manager, address(this), stake, true);
			numeraire.settle(manager, callbackData.bidder, totalNumeraireOwed - stake, false);
			numerairePaidByManager = stake;
		}

		return abi.encode(numerairePaidByManager);
	}

	function _refundStake(bytes memory operationData) internal returns (bytes memory) {
		(AuctionTypes.CallbackDataRefundStake memory data) = abi.decode(operationData, (AuctionTypes.CallbackDataRefundStake));

		manager.burn(address(this), CurrencyLibrary.toId(Currency.wrap(data.numeraire)), data.amount);
		Currency.wrap(data.numeraire).take(manager, data.recipient, data.amount, false);

		return abi.encode(data.amount);
	}

	function _handleClaimAllocatorReward(bytes memory operationData) internal returns (bytes memory) {
		(AuctionTypes.CallbackDataClaimAllocatorReward memory data) = abi.decode(operationData, (AuctionTypes.CallbackDataClaimAllocatorReward));

		Currency.wrap(data.numeraire).take(manager, data.allocator, data.reward, false);
		manager.burn(address(this), CurrencyLibrary.toId(Currency.wrap(data.numeraire)), data.reward);

		return abi.encode(data.reward);
	}

	function _handleBatchERC6909ToERC20Conversion(bytes memory operationData) internal returns (bytes memory) {
		AuctionTypes.CallbackDataBatchERC6909ToERC20 memory data = abi.decode(
			operationData,
			(AuctionTypes.CallbackDataBatchERC6909ToERC20)
		);

		for (uint256 i = 0; i < data.assetCurrencies.length; i++) {
			manager.burn(address(this), CurrencyLibrary.toId(data.assetCurrencies[i]), data.amounts[i]);
			data.assetCurrencies[i].take(manager, address(this), data.amounts[i], false);
		}

		return "";
	}
}
