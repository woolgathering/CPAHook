// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { CPABase } from "../base/CPABase.sol";
import { CPAAllocationPhase } from "../libraries/CPAAllocationPhase.sol";
import { AuctionTypes } from "../types/AuctionTypes.sol";
import { AuctionId } from "../types/AuctionId.sol";

contract AllocationSubmitFacet is CPABase {

    constructor(
        address _owner,
        address _protocolWallet,
        uint256 _protocolFeeBps,
        address _mathFacet
    ) CPABase(_owner, _protocolWallet, _protocolFeeBps, _mathFacet) {}

    function submitAllocation(
        AuctionId auctionId,
        AuctionTypes.Allocation calldata allocationData
    )
        external
        whenAuctionActive(auctionId)
        onlyPhase(auctionId, AuctionTypes.AuctionPhase.Allocation)
        onlyWhenPhaseNotExpired(auctionId, AuctionTypes.AuctionPhase.Allocation)
    {
        if (msg.sender != allocationData.allocator) revert Unauthorized();

        CPAAllocationPhase.submitAllocation(
            allocationData, _alloc[auctionId], auctionInfo[auctionId], assetInfo, _proxy[auctionId]
        );
    }
}
