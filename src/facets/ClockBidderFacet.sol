// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { NumeraireLib } from "../libraries/NumeraireLib.sol";

import { CPABaseClock } from "../base/CPABaseClock.sol";
import { AuctionTypes } from "../types/AuctionTypes.sol";
import { AuctionId } from "../types/AuctionId.sol";

contract ClockCommitFacet is CPABaseClock {

    constructor(
        address _owner,
        address _protocolWallet,
        uint256 _protocolFeeBps,
        address _mathFacet
    ) CPABaseClock(_owner, _protocolWallet, _protocolFeeBps, _mathFacet) {}

    function commitToBidder(AuctionId auctionId, bytes32 commitHash) external {
        commitProxy[auctionId][commitHash] = msg.sender;
    }

    function registerCommit(AuctionId auctionId, bytes32 commitHash) external {
        if (commitProxy[auctionId][commitHash] != address(0)) revert InvalidCommitHash();
        commitProxy[auctionId][commitHash] = msg.sender;
    }

    function dropout(AuctionId auctionId)
        external
        whenAuctionActive(auctionId)
        onlyPhase(auctionId, AuctionTypes.AuctionPhase.Clock)
        onlyWhenPhaseNotExpired(auctionId, AuctionTypes.AuctionPhase.Clock)
    {
        uint256 stake = bidderStake[auctionId][msg.sender];
        if (stake == 0) revert InvalidStakeAmount();

        uint256 penalty = (stake * auctionInfo[auctionId].config.dropoutSlashRatio) / 10000;
        uint256 refund = stake - penalty;

        bidderStake[auctionId][msg.sender] = 0;
        bidderBidPoints[auctionId][msg.sender] = 0;
        removeBidder(auctionId, msg.sender);

        droppedBidders[auctionId][msg.sender] = true;
        protocolAccrued[auctionId] += penalty;

        NumeraireLib.transfer(auctionInfo[auctionId].commonNumeraire, msg.sender, refund);

        emit PenaltyApplied(auctionId, msg.sender, penalty);
        emit StakeRefunded(auctionId, msg.sender, refund);
    }
}
