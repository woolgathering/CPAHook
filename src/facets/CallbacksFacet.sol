// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IPositionManager } from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { Currency, CurrencyLibrary } from "@uniswap/v4-core/src/types/Currency.sol";
import { SwapParams, ModifyLiquidityParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";
import { BalanceDelta, toBalanceDelta, BalanceDeltaLibrary } from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import { SafeCast } from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import { CurrencySettler } from "@openzeppelin/uniswap-hooks/src/utils/CurrencySettler.sol";

import { CPABase } from "../base/CPABase.sol";
import { AuctionTypes } from "../types/AuctionTypes.sol";
import { AuctionId } from "../types/AuctionId.sol";

contract CallbacksClockFacet is CPABase {
	using CurrencySettler for Currency;
	using BalanceDeltaLibrary for BalanceDelta;
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

		if (operationType == 0) {
			return _handleBid(operationData);
		} else if (operationType == 2) {
			return _handlePriceUpdateSwap(operationData);
		} else if (operationType == 3) {
			return _handleMintPosition(operationData);
		} else if (operationType == 9) {
			return _handleBatchErc6909ToErc20Conversion(operationData);
		} else {
			revert("Invalid operation type");
		}
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

	function _handleBatchErc6909ToErc20Conversion(bytes memory operationData) internal returns (bytes memory) {
		AuctionTypes.CallbackDataBatchErc6909ToErc20 memory data = abi.decode(
			operationData,
			(AuctionTypes.CallbackDataBatchErc6909ToErc20)
		);

		for (uint256 i = 0; i < data.assetCurrencies.length; i++) {
			manager.burn(address(this), CurrencyLibrary.toId(data.assetCurrencies[i]), data.amounts[i]);
			data.assetCurrencies[i].take(manager, address(this), data.amounts[i], false);
		}

		return "";
	}
}
