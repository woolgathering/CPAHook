// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { CPABase } from "../base/CPABase.sol";
import { CPAClockPhase } from "../libraries/CPAClockPhase.sol";
import { AuctionTypes } from "../types/AuctionTypes.sol";
import { AuctionId } from "../types/AuctionId.sol";

contract ClockEndRoundFacet is CPABase {

    constructor(
        address _owner,
        address _protocolWallet,
        uint256 _protocolFeeBps,
        address _mathFacet
    ) CPABase(_owner, _protocolWallet, _protocolFeeBps, _mathFacet) {}

    function processClockRoundStep(AuctionId auctionId)
        external
        nonReentrant
        onlyAuctionOwnerOrSelf(auctionId)
        onlyPhase(auctionId, AuctionTypes.AuctionPhase.Clock)
    {
        require(!roundPendingFinalize[auctionId], "Round already processed - finalize first");
        uint256 activeBidderCount = activeBidders[auctionId].length;
        CPAClockPhase.setClockOpen(auctionId, 1, auctionInfo);
        uint256[] memory totalDemands = CPAClockPhase.processClockRound(
            auctionId, auctionInfo[auctionId], assetInfo, bids[auctionId], activeBidders
        );
        pendingRoundDemands[auctionId] = totalDemands;
        roundPendingFinalize[auctionId] = true;
        emit ClockRoundClosed(auctionId, auctionInfo[auctionId].currentRound, activeBidderCount);
    }
}
