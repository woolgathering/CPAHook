// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IPositionManager } from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";

import { CPABase } from "../base/CPABase.sol";
import { CPASetup } from "../libraries/CPASetup.sol";
import { AuctionTypes } from "../types/AuctionTypes.sol";
import { AuctionId } from "../types/AuctionId.sol";

contract DepositFacet is CPABase {

	constructor(
		IPoolManager _poolManager,
		address _owner,
		address _cpaAuctionHookAddr,
		IPositionManager _positionManager,
		address _protocolWallet,
		address _mathFacet
	) CPABase(_poolManager, _owner, _cpaAuctionHookAddr, _positionManager, _protocolWallet, _mathFacet) {}

	function moveDeposit(
		AuctionId auctionId,
		PoolKey memory poolKey,
		uint256 depositAmount
	) external nonReentrant onlyAuctionOwner(auctionId) {
		CPASetup.moveDeposit(this, auctionInfo[auctionId], poolInfo, poolKey, auctionId, depositAmount);
		_updateCpaHookStates(auctionId);
	}

	function depositAllAndStartClock(
		AuctionId auctionId,
		PoolKey[] memory poolKeys,
		uint256[] memory amounts
	) external nonReentrant onlyAuctionOwner(auctionId) onlyPhase(auctionId, AuctionTypes.AuctionPhase.Setup) {
		CPASetup.depositAllAndStartClock(this, auctionInfo[auctionId], poolInfo, poolKeys, amounts, auctionId);
		_updateCpaHookStates(auctionId);
	}
}
