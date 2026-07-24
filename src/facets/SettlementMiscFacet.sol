// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { NumeraireLib } from "../libraries/NumeraireLib.sol";

import { CPABase } from "../base/CPABase.sol";
import { AuctionTypes } from "../types/AuctionTypes.sol";
import { AuctionId } from "../types/AuctionId.sol";

contract SettlementMiscFacet is CPABase {

    constructor(
        address _owner,
        address _protocolWallet,
        uint256 _protocolFeeBps,
        address _mathFacet
    ) CPABase(_owner, _protocolWallet, _protocolFeeBps, _mathFacet) {}

    function claimAllocatorReward(AuctionId auctionId) external {
        address winningAllocator = _alloc[auctionId].topAllocation.allocation.allocator;
        if (msg.sender != winningAllocator) revert Unauthorized();

        AuctionTypes.AuctionPhase phase = auctionInfo[auctionId].currentPhase;
        if (phase != AuctionTypes.AuctionPhase.Settlement && phase != AuctionTypes.AuctionPhase.Finished)
            revert InvalidPhase(AuctionTypes.AuctionPhase.Settlement, phase);

        uint256 reward = auctionInfo[auctionId].allocatorReward;
        auctionInfo[auctionId].allocatorReward = 0;

        emit AllocatorRewardClaimed(auctionId, winningAllocator, reward);
        NumeraireLib.transfer(auctionInfo[auctionId].commonNumeraire, winningAllocator, reward);
    }

    function reclaimStake(AuctionId auctionId) external {
        uint256 stake = _clock[auctionId].bidderStake[msg.sender];
        if (stake == 0) revert InvalidStakeAmount();

        address numeraire = auctionInfo[auctionId].commonNumeraire;
        AuctionTypes.AuctionStatus status = auctionInfo[auctionId].currentStatus;

        if (status == AuctionTypes.AuctionStatus.Cancelled) {
            _clock[auctionId].bidderStake[msg.sender] = 0;
            _clock[auctionId].bidderBidPoints[msg.sender] = 0;
            NumeraireLib.transfer(numeraire, msg.sender, stake);
            emit StakeRefunded(auctionId, msg.sender, stake);
            return;
        }

        if (auctionInfo[auctionId].currentPhase != AuctionTypes.AuctionPhase.Finished)
            revert InvalidPhase(AuctionTypes.AuctionPhase.Finished, auctionInfo[auctionId].currentPhase);

        uint256 penaltyRate = auctionInfo[auctionId].config.minSpendRatio;
        uint256 penalty = stake * penaltyRate / 10000;
        uint256 refund = stake - penalty;

        _settlement[auctionId].protocolAccrued += penalty;
        _clock[auctionId].bidderStake[msg.sender] = 0;
        _clock[auctionId].bidderBidPoints[msg.sender] = 0;

        NumeraireLib.transfer(numeraire, msg.sender, refund);

        emit PenaltyApplied(auctionId, msg.sender, penalty);
        emit StakeRefunded(auctionId, msg.sender, refund);
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
