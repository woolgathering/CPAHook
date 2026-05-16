// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IPositionManager } from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { BalanceDelta, toBalanceDelta, BalanceDeltaLibrary } from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import { CurrencySettler } from "@openzeppelin/uniswap-hooks/src/utils/CurrencySettler.sol";

import { CPABase } from "../base/CPABase.sol";
import { CPASetup } from "../libraries/CPASetup.sol";
import { AuctionTypes } from "../types/AuctionTypes.sol";
import { AuctionId } from "../types/AuctionId.sol";

contract CallbacksDepositFacet is CPABase {
	using CurrencySettler for Currency;
	using BalanceDeltaLibrary for BalanceDelta;

	constructor(
		IPoolManager _poolManager,
		address _owner,
		address _cpaAuctionHookAddr,
		IPositionManager _positionManager,
		address _protocolWallet,
		address _mathFacet
	) CPABase(_poolManager, _owner, _cpaAuctionHookAddr, _positionManager, _protocolWallet, _mathFacet) {}

	function unlockCallback(bytes calldata rawData)
		external
		onlyPoolManager
		returns (bytes memory returnData)
	{
		(uint8 operationType, bytes memory operationData) = abi.decode(rawData, (uint8, bytes));

		if (operationType == 1) {
			return _handleDepositTransfer(operationData);
		} else if (operationType == 8) {
			return _handleBatchDepositTransfer(operationData);
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
}
