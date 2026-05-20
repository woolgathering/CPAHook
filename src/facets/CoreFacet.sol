// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { CPABase } from "../base/CPABase.sol";
import { AuctionTypes } from "../types/AuctionTypes.sol";
import { AuctionId } from "../types/AuctionId.sol";

contract CoreFacet is CPABase {

    constructor(
        address _owner,
        address _protocolWallet,
        uint256 _protocolFeeBps,
        address _mathFacet
    ) CPABase(_owner, _protocolWallet, _protocolFeeBps, _mathFacet) {}

    function pause(AuctionId auctionId) external nonReentrant onlyAuctionOwner(auctionId) {
        AuctionTypes.AuctionInfo storage auction = auctionInfo[auctionId];

        if (auction.currentStatus == AuctionTypes.AuctionStatus.Paused)
            revert AuctionNotActive(auctionId, AuctionTypes.AuctionStatus.Paused);

        if (
            auction.currentPhase == AuctionTypes.AuctionPhase.Settlement ||
            auction.currentPhase == AuctionTypes.AuctionPhase.Finished
        ) revert InvalidPhase(AuctionTypes.AuctionPhase.Setup, auction.currentPhase);

        uint256 currentPauseDuration = auction.totalPauseDuration;
        if (currentPauseDuration > AuctionTypes.MAX_PAUSE_DURATION)
            revert MaxPauseDurationExceeded(currentPauseDuration, AuctionTypes.MAX_PAUSE_DURATION);

        auction.currentStatus = AuctionTypes.AuctionStatus.Paused;
        pauseStartTime[auctionId] = block.timestamp;
        emit AuctionPaused(auctionId, msg.sender);
    }

    function unpause(AuctionId auctionId) external nonReentrant onlyAuctionOwner(auctionId) {
        AuctionTypes.AuctionInfo storage auction = auctionInfo[auctionId];

        if (auction.currentStatus != AuctionTypes.AuctionStatus.Paused)
            revert AuctionNotActive(auctionId, auction.currentStatus);

        uint256 newTotalPauseDuration = auction.totalPauseDuration + (block.timestamp - pauseStartTime[auctionId]);

        if (newTotalPauseDuration >= AuctionTypes.MAX_PAUSE_DURATION)
            revert MaxPauseDurationExceeded(newTotalPauseDuration, AuctionTypes.MAX_PAUSE_DURATION);

        auction.totalPauseDuration = newTotalPauseDuration;
        pauseStartTime[auctionId] = 0;
        auction.currentStatus = AuctionTypes.AuctionStatus.Active;
        emit AuctionUnpaused(auctionId, msg.sender);
    }

    function cancelAuction(AuctionId auctionId) external nonReentrant onlyAuctionOwner(auctionId) {
        AuctionTypes.AuctionPhase phase = auctionInfo[auctionId].currentPhase;
        if (phase != AuctionTypes.AuctionPhase.Setup && phase != AuctionTypes.AuctionPhase.Clock)
            revert CannotCancelInThisPhase(auctionId, phase);

        auctionInfo[auctionId].currentStatus = AuctionTypes.AuctionStatus.Cancelled;
        emit AuctionCancelled(auctionId, msg.sender);
    }

    function forceCancelAuction(AuctionId auctionId) external nonReentrant {
        AuctionTypes.AuctionInfo storage auction = auctionInfo[auctionId];

        uint256 totalPauseDuration = auction.totalPauseDuration;
        if (auction.currentStatus == AuctionTypes.AuctionStatus.Paused)
            totalPauseDuration += block.timestamp - pauseStartTime[auctionId];

        if (totalPauseDuration < AuctionTypes.MAX_PAUSE_DURATION)
            revert PauseDurationNotExceeded(totalPauseDuration, AuctionTypes.MAX_PAUSE_DURATION);

        auction.currentStatus = AuctionTypes.AuctionStatus.Cancelled;
        emit AuctionCancelled(auctionId, msg.sender);
    }
}
