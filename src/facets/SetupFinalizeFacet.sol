// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IPositionManager } from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import { CPABase } from "../base/CPABase.sol";
import { CPASetup } from "../libraries/CPASetup.sol";
import { AuctionTypes } from "../types/AuctionTypes.sol";
import { AuctionId } from "../types/AuctionId.sol";

contract SetupFinalizeFacet is CPABase {

	constructor(
		IPoolManager _poolManager,
		address _owner,
		address _cpaAuctionHookAddr,
		IPositionManager _positionManager,
		address _protocolWallet,
		address _mathFacet
	) CPABase(_poolManager, _owner, _cpaAuctionHookAddr, _positionManager, _protocolWallet, _mathFacet) {}

	function finalizeAuction(
		AuctionId auctionId,
		AuctionTypes.AuctionConfig memory config,
		address auctionOwner
	) external nonReentrant returns (AuctionId) {
		require(poolsRegistered[auctionId], "Pools not registered");
		poolsRegistered[auctionId] = false;
		CPASetup.finalizeAuctionCreation(config, auctionId, auctionOwner, auctionInfo);
		_updateCPAHookStates(auctionId);
		return auctionId;
	}
}
