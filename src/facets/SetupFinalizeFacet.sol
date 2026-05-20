// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { CPABase } from "../base/CPABase.sol";
import { CPASetup } from "../libraries/CPASetup.sol";
import { AuctionTypes } from "../types/AuctionTypes.sol";
import { AuctionId } from "../types/AuctionId.sol";

contract SetupFinalizeFacet is CPABase {

    constructor(
        address _owner,
        address _protocolWallet,
        uint256 _protocolFeeBps,
        address _mathFacet
    ) CPABase(_owner, _protocolWallet, _protocolFeeBps, _mathFacet) {}

    function finalizeAuction(
        AuctionId auctionId,
        AuctionTypes.AuctionConfig memory config,
        address auctionOwner
    ) external nonReentrant returns (AuctionId) {
        require(poolsRegistered[auctionId], "Assets not registered");
        poolsRegistered[auctionId] = false;
        CPASetup.finalizeAuctionCreation(config, auctionId, auctionOwner, auctionInfo);
        return auctionId;
    }
}
