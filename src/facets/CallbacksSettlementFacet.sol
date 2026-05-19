// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IPositionManager } from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { Currency, CurrencyLibrary } from "@uniswap/v4-core/src/types/Currency.sol";
import { SwapParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";
import { BalanceDelta } from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import { SafeCast } from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import { CurrencySettler } from "@openzeppelin/uniswap-hooks/src/utils/CurrencySettler.sol";

import { CPABase } from "../base/CPABase.sol";
import { AuctionTypes } from "../types/AuctionTypes.sol";
import { AuctionId } from "../types/AuctionId.sol";

contract CallbacksSettlementFacet is CPABase {
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

		if (operationType == 7) {
			return _handleClaimAllTokens(operationData);
		} else {
			revert("Invalid operation type");
		}
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
						? uint160(4295128739) + 1
						: uint160(1461446703485210103287273052203988822378723970342) - 1
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

}
