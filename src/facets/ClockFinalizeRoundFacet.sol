// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { CPABaseClock } from "../base/CPABaseClock.sol";
import { CPAClockPhase } from "../libraries/CPAClockPhase.sol";
import { AuctionTypes } from "../types/AuctionTypes.sol";
import { AuctionId } from "../types/AuctionId.sol";

contract ClockFinalizeRoundFacet is CPABaseClock {

    constructor(
        address _owner,
        address _protocolWallet,
        uint256 _protocolFeeBps,
        address _mathFacet
    ) CPABaseClock(_owner, _protocolWallet, _protocolFeeBps, _mathFacet) {}

    function finalizeClockRound(AuctionId auctionId)
        external
        nonReentrant
        onlyAuctionOwnerOrSelf(auctionId)
        onlyPhase(auctionId, AuctionTypes.AuctionPhase.Clock)
    {
        require(roundPendingFinalize[auctionId], "No round pending finalization");
        uint256[] memory totalDemands = pendingRoundDemands[auctionId];
        delete pendingRoundDemands[auctionId];
        roundPendingFinalize[auctionId] = false;

        if (CPAClockPhase.shouldEndClockPhase(auctionId, auctionInfo[auctionId], assetInfo, totalDemands)) {
            _endClockPhase(auctionId);
        } else {
            _startClockRound(auctionId);
        }
    }
}
