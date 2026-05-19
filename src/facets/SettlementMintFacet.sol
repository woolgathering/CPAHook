// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IPositionManager } from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import { CPABase } from "../base/CPABase.sol";
import { CPAAllocationPhase } from "../libraries/CPAAllocationPhase.sol";
import { AuctionTypes } from "../types/AuctionTypes.sol";
import { AuctionId } from "../types/AuctionId.sol";

contract SettlementMintFacet is CPABase {

	constructor(
		IPoolManager _poolManager,
		address _owner,
		address _cpaAuctionHookAddr,
		IPositionManager _positionManager,
		address _protocolWallet,
		address _mathFacet
	) CPABase(_poolManager, _owner, _cpaAuctionHookAddr, _positionManager, _protocolWallet, _mathFacet) {}

	function mintSettlementPositions(AuctionId auctionId)
		external
		nonReentrant
		whenAuctionActive(auctionId)
		onlyPhase(auctionId, AuctionTypes.AuctionPhase.Allocation)
	{
		require(assetsConverted[auctionId], "Assets not yet converted");
		assetsConverted[auctionId] = false;
		uint256 startTokenId = settleStartTokenId[auctionId];
		CPAAllocationPhase.mintPositionsForAuction(this, auctionId, startTokenId, auctionInfo, poolInfo);
		_changePhase(auctionId, AuctionTypes.AuctionPhase.Settlement);
	}
}
