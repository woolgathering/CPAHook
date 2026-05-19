// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IPositionManager } from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

import { CPABaseClock } from "../base/CPABaseClock.sol";
import { AuctionTypes } from "../types/AuctionTypes.sol";
import { AuctionId } from "../types/AuctionId.sol";

contract ClockEndFacet is CPABaseClock {

	constructor(
		IPoolManager _poolManager,
		address _owner,
		address _cpaAuctionHookAddr,
		IPositionManager _positionManager,
		address _protocolWallet,
		address _mathFacet
	) CPABaseClock(_poolManager, _owner, _cpaAuctionHookAddr, _positionManager, _protocolWallet, _mathFacet) {}

	function endClockPhase(AuctionId auctionId)
		external
		nonReentrant
		onlyAuctionOwner(auctionId)
		onlyPhase(auctionId, AuctionTypes.AuctionPhase.Clock)
	{
		_endClockPhase(auctionId);
	}
}
