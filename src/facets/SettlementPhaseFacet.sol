// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IPositionManager } from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import { PoolId } from "@uniswap/v4-core/src/types/PoolId.sol";

import { CPABase } from "../base/CPABase.sol";
import { CPASettlementPhase } from "../libraries/CPASettlementPhase.sol";
import { AuctionTypes } from "../types/AuctionTypes.sol";
import { AuctionId } from "../types/AuctionId.sol";
import { BundleId } from "../types/BundleId.sol";

contract SettlementClaimFacet is CPABase {

	constructor(
		IPoolManager _poolManager,
		address _owner,
		address _cpaAuctionHookAddr,
		IPositionManager _positionManager,
		address _protocolWallet,
		address _mathFacet
	) CPABase(_poolManager, _owner, _cpaAuctionHookAddr, _positionManager, _protocolWallet, _mathFacet) {}

	function reveal(
		AuctionId auctionId,
		address proxy,
		bytes32 saltA,
		bytes32 saltB
	) external whenAuctionActive(auctionId) onlyPhase(auctionId, AuctionTypes.AuctionPhase.Settlement) {
		CPASettlementPhase.reveal(this, auctionId, msg.sender, proxy, saltA, saltB, commitProxy, revealedMappings);
	}

	function claimToken(AuctionId auctionId, bytes32 commitHash, PoolId poolId)
		external
		payable
		whenAuctionActive(auctionId)
		onlyPhase(auctionId, AuctionTypes.AuctionPhase.Settlement)
		onlyOwner()
	{
		CPASettlementPhase.claimToken(
			this,
			msg.sender,
			auctionId,
			commitHash,
			poolId,
			topAllocation[auctionId].allocation,
			auctionInfo[auctionId],
			bundles[auctionId],
			winningBundleIds,
			bidderStake[auctionId],
			revealedMappings[auctionId]
		);
	}

	function claimAllTokens(AuctionId auctionId, bytes32 commitHash)
		external
		payable
		whenAuctionActive(auctionId)
		onlyPhase(auctionId, AuctionTypes.AuctionPhase.Settlement)
	{
		CPASettlementPhase.claimAllTokens(
			this,
			msg.sender,
			auctionId,
			commitHash,
			auctionInfo[auctionId],
			revealedMappings[auctionId],
			bidderStake[auctionId],
			bundles[auctionId],
			winningBundleIds,
			protocolPenalties
		);

		winningBundleIds[commitHash] = BundleId.wrap(0);
	}
}
