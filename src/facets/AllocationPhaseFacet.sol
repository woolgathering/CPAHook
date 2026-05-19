// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IPositionManager } from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

import { CPABase } from "../base/CPABase.sol";
import { AuctionTypes } from "../types/AuctionTypes.sol";
import { AuctionId } from "../types/AuctionId.sol";

contract AllocationTransitionFacet is CPABase {

	constructor(
		IPoolManager _poolManager,
		address _owner,
		address _cpaAuctionHookAddr,
		IPositionManager _positionManager,
		address _protocolWallet,
		address _mathFacet
	) CPABase(_poolManager, _owner, _cpaAuctionHookAddr, _positionManager, _protocolWallet, _mathFacet) {}

	function transitionToAllocation(AuctionId auctionId)
		external
		nonReentrant
		whenAuctionActive(auctionId)
		onlyPhase(auctionId, AuctionTypes.AuctionPhase.Proxy)
	{
		if (!_hasPhaseExpired(auctionId, AuctionTypes.AuctionPhase.Proxy))
			revert PhaseNotExpired(auctionId, AuctionTypes.AuctionPhase.Proxy);

		if (!hasBundles[auctionId]) {
			_cancelAuction(auctionId);
			revert NoSubmissionsReceived(auctionId, AuctionTypes.AuctionPhase.Proxy);
		}

		_changePhase(auctionId, AuctionTypes.AuctionPhase.Allocation);
	}
}
