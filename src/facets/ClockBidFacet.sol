// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { CPABaseClock } from "../base/CPABaseClock.sol";
import { CPAClockPhase } from "../libraries/CPAClockPhase.sol";
import { AuctionTypes } from "../types/AuctionTypes.sol";
import { AuctionId } from "../types/AuctionId.sol";

contract ClockBidFacet is CPABaseClock {

    constructor(
        address _owner,
        address _protocolWallet,
        uint256 _protocolFeeBps,
        address _mathFacet
    ) CPABaseClock(_owner, _protocolWallet, _protocolFeeBps, _mathFacet) {}

    function submitBid(
        AuctionId auctionId,
        uint256[] calldata demands,
        uint256 maxStakeAmount
    )
        external
        payable
        whenAuctionActive(auctionId)
        onlyPhase(auctionId, AuctionTypes.AuctionPhase.Clock)
        onlyWhenPhaseNotExpired(auctionId, AuctionTypes.AuctionPhase.Clock)
    {
        CPAClockPhase.processBid(
            auctionId,
            demands,
            maxStakeAmount,
            msg.value,
            auctionInfo[auctionId],
            assetInfo,
            bidderStake[auctionId],
            bidderBidPoints[auctionId],
            bids[auctionId],
            activeBidders[auctionId]
        );
    }
}
