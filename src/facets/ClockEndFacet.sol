// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { CPABaseClock } from "../base/CPABaseClock.sol";
import { AuctionTypes } from "../types/AuctionTypes.sol";
import { AuctionId } from "../types/AuctionId.sol";

contract ClockEndFacet is CPABaseClock {

    constructor(
        address _owner,
        address _protocolWallet,
        uint256 _protocolFeeBps,
        address _mathFacet
    ) CPABaseClock(_owner, _protocolWallet, _protocolFeeBps, _mathFacet) {}

    function endClockPhase(AuctionId auctionId)
        external
        nonReentrant
        onlyAuctionOwner(auctionId)
        onlyPhase(auctionId, AuctionTypes.AuctionPhase.Clock)
    {
        _endClockPhase(auctionId);
    }
}
