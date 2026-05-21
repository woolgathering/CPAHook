// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { CPABase } from "../base/CPABase.sol";
import { AuctionTypes } from "../types/AuctionTypes.sol";
import { AuctionId } from "../types/AuctionId.sol";

contract AllocationTransitionFacet is CPABase {

    constructor(
        address _owner,
        address _protocolWallet,
        uint256 _protocolFeeBps,
        address _mathFacet
    ) CPABase(_owner, _protocolWallet, _protocolFeeBps, _mathFacet) {}

    function transitionToAllocation(AuctionId auctionId)
        external
        nonReentrant
        whenAuctionActive(auctionId)
        onlyPhase(auctionId, AuctionTypes.AuctionPhase.Proxy)
    {
        if (!_hasPhaseExpired(auctionId, AuctionTypes.AuctionPhase.Proxy))
            revert PhaseNotExpired(auctionId, AuctionTypes.AuctionPhase.Proxy);

        if (!_proxy[auctionId].hasBundles) {
            _cancelAuction(auctionId);
            revert NoSubmissionsReceived(auctionId, AuctionTypes.AuctionPhase.Proxy);
        }

        _changePhase(auctionId, AuctionTypes.AuctionPhase.Allocation);
    }
}
