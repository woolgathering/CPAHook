// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { CPABase } from "../base/CPABase.sol";
import { CPAProxyPhase } from "../libraries/CPAProxyPhase.sol";
import { AuctionTypes } from "../types/AuctionTypes.sol";
import { AuctionId } from "../types/AuctionId.sol";
import { BundleId } from "../types/BundleId.sol";

contract ProxyPhaseFacet is CPABase {

    constructor(
        address _owner,
        address _protocolWallet,
        uint256 _protocolFeeBps,
        address _mathFacet
    ) CPABase(_owner, _protocolWallet, _protocolFeeBps, _mathFacet) {}

    function submitBundle(
        AuctionId auctionId,
        bytes32 commitHash,
        AuctionTypes.Bundle calldata bundleData
    )
        external
        whenAuctionActive(auctionId)
        onlyPhase(auctionId, AuctionTypes.AuctionPhase.Proxy)
        onlyWhenPhaseNotExpired(auctionId, AuctionTypes.AuctionPhase.Proxy)
        returns (BundleId bundleId)
    {
        uint256 numItems = auctionInfo[auctionId].assets.length;
        bundleId = CPAProxyPhase.submitBundle(
            auctionId, commitHash, numItems, _proxy[auctionId], bundleData
        );
    }
}
