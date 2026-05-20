// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IPositionManager } from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { BalanceDelta } from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import { SafeCast } from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import { CurrencySettler } from "@openzeppelin/uniswap-hooks/src/utils/CurrencySettler.sol";

import { CPABase } from "../base/CPABase.sol";
import { AuctionTypes } from "../types/AuctionTypes.sol";

contract CallbacksClaimTokenFacet is CPABase {
	using CurrencySettler for Currency;
	using SafeCast for *;

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

		if (operationType == 4) {
			return _handleClaimToken(operationData);
		} else {
			revert("Invalid operation type");
		}
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

}
