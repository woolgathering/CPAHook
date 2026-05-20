// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IPositionManager } from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

import { CPABase } from "../base/CPABase.sol";
import { ICPAManager } from "../interfaces/ICPAManager.sol";
import { AuctionTypes } from "../types/AuctionTypes.sol";
import { AuctionId } from "../types/AuctionId.sol";

/**
 * @title AuctionFlowFacet
 * @notice Single-call orchestrators for multi-step auction flows.
 *         Each function sequences the underlying sub-step facets via address(this).call(),
 *         so sub-steps execute against diamond storage and enforce their individual guards.
 */
contract AuctionFlowFacet is CPABase {

	constructor(
		IPoolManager _poolManager,
		address _owner,
		address _cpaAuctionHookAddr,
		IPositionManager _positionManager,
		address _protocolWallet,
		address _mathFacet
	) CPABase(_poolManager, _owner, _cpaAuctionHookAddr, _positionManager, _protocolWallet, _mathFacet) {}

	/// @notice Create a new auction in one call (permissionless — auctionOwner is a parameter).
	function createAuction(
		AuctionTypes.AuctionConfig memory config,
		address auctionOwner
	) external returns (AuctionId) {
		AuctionId auctionId = ICPAManager(address(this)).initAuction(config, auctionOwner);
		ICPAManager(address(this)).finalizeAuction(auctionId, config, auctionOwner);
		return auctionId;
	}

	/// @notice End the current clock round in one call (onlyAuctionOwner).
	/// @dev Sub-steps use onlyAuctionOwnerOrSelf so the diamond can call them here.
	function endClockRound(AuctionId auctionId) external onlyAuctionOwner(auctionId) {
		ICPAManager(address(this)).processClockRoundStep(auctionId);
		ICPAManager(address(this)).finalizeClockRound(auctionId);
	}

	/// @notice Transition from Allocation to Settlement phase in one call (permissionless).
	function transitionToSettlement(AuctionId auctionId) external {
		ICPAManager(address(this)).selectAuctionWinner(auctionId);
		ICPAManager(address(this)).convertAuctionAssets(auctionId);
		ICPAManager(address(this)).mintSettlementPositions(auctionId);
	}
}
