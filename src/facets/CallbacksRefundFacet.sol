// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IPositionManager } from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import { Currency, CurrencyLibrary } from "@uniswap/v4-core/src/types/Currency.sol";
import { CurrencySettler } from "@openzeppelin/uniswap-hooks/src/utils/CurrencySettler.sol";

import { CPABase } from "../base/CPABase.sol";
import { AuctionTypes } from "../types/AuctionTypes.sol";

contract CallbacksRefundFacet is CPABase {
	using CurrencySettler for Currency;

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

		if (operationType == 5) {
			return _refundStake(operationData);
		} else if (operationType == 6) {
			return _handleClaimAllocatorReward(operationData);
		} else {
			revert("Invalid operation type");
		}
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
}
