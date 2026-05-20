// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { CPABase } from "../base/CPABase.sol";
import { CPAAllocationPhase } from "../libraries/CPAAllocationPhase.sol";
import { AuctionTypes } from "../types/AuctionTypes.sol";
import { AuctionId } from "../types/AuctionId.sol";

contract SettlementTransitionFacet is CPABase {

    constructor(
        address _owner,
        address _protocolWallet,
        uint256 _protocolFeeBps,
        address _mathFacet
    ) CPABase(_owner, _protocolWallet, _protocolFeeBps, _mathFacet) {}

    function selectAuctionWinner(AuctionId auctionId)
        external
        nonReentrant
        whenAuctionActive(auctionId)
        onlyPhase(auctionId, AuctionTypes.AuctionPhase.Allocation)
    {
        if (!_hasPhaseExpired(auctionId, AuctionTypes.AuctionPhase.Allocation))
            revert PhaseNotExpired(auctionId, AuctionTypes.AuctionPhase.Allocation);
        require(!winnerSelected[auctionId], "Winner already selected");
        if (!hasAllocations[auctionId]) {
            _cancelAuction(auctionId);
            revert NoSubmissionsReceived(auctionId, AuctionTypes.AuctionPhase.Allocation);
        }
        CPAAllocationPhase.selectWinner(auctionId, topAllocation, bundles[auctionId], winningBundleIds);
        winnerSelected[auctionId] = true;
        _changePhase(auctionId, AuctionTypes.AuctionPhase.Settlement);
    }
}
