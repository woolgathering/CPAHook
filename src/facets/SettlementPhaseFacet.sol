// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IPositionManager } from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import { PoolId } from "@uniswap/v4-core/src/types/PoolId.sol";
import { Currency, CurrencyLibrary } from "@uniswap/v4-core/src/types/Currency.sol";

import { CPABase } from "../base/CPABase.sol";
import { CPAAllocationPhase } from "../libraries/CPAAllocationPhase.sol";
import { CPASettlementPhase } from "../libraries/CPASettlementPhase.sol";
import { AuctionTypes } from "../types/AuctionTypes.sol";
import { AuctionId } from "../types/AuctionId.sol";
import { BundleId } from "../types/BundleId.sol";

contract SettlementPhaseFacet is CPABase {

	constructor(
		IPoolManager _poolManager,
		address _owner,
		address _cpaAuctionHookAddr,
		IPositionManager _positionManager,
		address _protocolWallet
	) CPABase(_poolManager, _owner, _cpaAuctionHookAddr, _positionManager, _protocolWallet) {}

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

	function claimAllocatorReward(AuctionId auctionId) external {
		address winningAllocator = topAllocation[auctionId].allocation.allocator;
		if (msg.sender != winningAllocator) revert Unauthorized();

		AuctionTypes.AuctionPhase phase = auctionInfo[auctionId].currentPhase;
		if (phase != AuctionTypes.AuctionPhase.Settlement && phase != AuctionTypes.AuctionPhase.Finished)
			revert InvalidPhase(AuctionTypes.AuctionPhase.Settlement, phase);

		AuctionTypes.CallbackDataClaimAllocatorReward memory data = AuctionTypes.CallbackDataClaimAllocatorReward({
			allocator: winningAllocator,
			reward: auctionInfo[auctionId].allocatorReward,
			numeraire: auctionInfo[auctionId].commonNumeraire
		});
		emit AllocatorRewardClaimed(auctionId, winningAllocator, auctionInfo[auctionId].allocatorReward);
		manager.unlock(abi.encode(uint8(6), abi.encode(data)));
		auctionInfo[auctionId].allocatorReward = 0;
	}

	function reclaimStake(AuctionId auctionId) external {
		uint256 stake = bidderStake[auctionId][msg.sender];
		if (stake == 0) revert InvalidStakeAmount();

		AuctionTypes.AuctionStatus status = auctionInfo[auctionId].currentStatus;

		if (status == AuctionTypes.AuctionStatus.Cancelled) {
			bidderStake[auctionId][msg.sender] = 0;
			bidderBidPoints[auctionId][msg.sender] = 0;

			AuctionTypes.CallbackDataRefundStake memory refundData = AuctionTypes.CallbackDataRefundStake({
				numeraire: auctionInfo[auctionId].commonNumeraire,
				recipient: msg.sender,
				amount: stake
			});
			manager.unlock(abi.encode(uint8(5), abi.encode(refundData)));
			emit StakeRefunded(auctionId, msg.sender, stake);
			return;
		}

		if (auctionInfo[auctionId].currentPhase != AuctionTypes.AuctionPhase.Finished)
			revert InvalidPhase(AuctionTypes.AuctionPhase.Finished, auctionInfo[auctionId].currentPhase);

		uint256 penaltyRate = auctionInfo[auctionId].config.minSpendRatio;
		protocolPenalties[auctionId] += stake * penaltyRate / 10000;

		bidderStake[auctionId][msg.sender] = 0;
		bidderBidPoints[auctionId][msg.sender] = 0;

		AuctionTypes.CallbackDataRefundStake memory data = AuctionTypes.CallbackDataRefundStake({
			numeraire: auctionInfo[auctionId].commonNumeraire,
			recipient: msg.sender,
			amount: stake - (stake * penaltyRate / 10000)
		});
		manager.unlock(abi.encode(uint8(5), abi.encode(data)));

		emit PenaltyApplied(auctionId, msg.sender, stake * penaltyRate / 10000);
		emit StakeRefunded(auctionId, msg.sender, stake - (stake * penaltyRate / 10000));
	}

	function transitionToSettlement(AuctionId auctionId)
		external
		nonReentrant
		whenAuctionActive(auctionId)
		onlyPhase(auctionId, AuctionTypes.AuctionPhase.Allocation)
	{
		if (!_hasPhaseExpired(auctionId, AuctionTypes.AuctionPhase.Allocation))
			revert PhaseNotExpired(auctionId, AuctionTypes.AuctionPhase.Allocation);

		if (!hasAllocations[auctionId]) {
			_cancelAuction(auctionId);
			revert NoSubmissionsReceived(auctionId, AuctionTypes.AuctionPhase.Allocation);
		}

		CPAAllocationPhase.selectWinner(this, auctionId, topAllocation, auctionInfo, poolInfo, bundles[auctionId], winningBundleIds);
		CPAAllocationPhase.transferAssetsToPools(this, auctionId, auctionInfo, poolInfo);

		_changePhase(auctionId, AuctionTypes.AuctionPhase.Settlement);
	}

	function transitionToFinished(AuctionId auctionId)
		external
		nonReentrant
		whenAuctionActive(auctionId)
		onlyPhase(auctionId, AuctionTypes.AuctionPhase.Settlement)
	{
		if (!_hasPhaseExpired(auctionId, AuctionTypes.AuctionPhase.Settlement))
			revert PhaseNotExpired(auctionId, AuctionTypes.AuctionPhase.Settlement);

		_changePhase(auctionId, AuctionTypes.AuctionPhase.Finished);
	}
}
