// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { CPABase } from "../base/CPABase.sol";
import { CPASettlementPhase } from "../libraries/CPASettlementPhase.sol";
import { AuctionTypes } from "../types/AuctionTypes.sol";
import { AuctionId } from "../types/AuctionId.sol";
import { BundleId } from "../types/BundleId.sol";

contract SettlementClaimFacet is CPABase {

    constructor(
        address _owner,
        address _protocolWallet,
        uint256 _protocolFeeBps,
        address _mathFacet
    ) CPABase(_owner, _protocolWallet, _protocolFeeBps, _mathFacet) {}

    function reveal(
        AuctionId auctionId,
        address proxy,
        bytes32 saltA,
        bytes32 saltB
    ) external whenAuctionActive(auctionId) onlyPhase(auctionId, AuctionTypes.AuctionPhase.Settlement) {
        CPASettlementPhase.reveal(
            auctionId, msg.sender, proxy, saltA, saltB, commitProxy, revealedMappings
        );
    }

    function claimAllTokens(AuctionId auctionId, bytes32 commitHash)
        external
        whenAuctionActive(auctionId)
        onlyPhase(auctionId, AuctionTypes.AuctionPhase.Settlement)
    {
        CPASettlementPhase.claimAllTokens(
            msg.sender,
            auctionId,
            commitHash,
            protocolFeeBps,
            auctionInfo[auctionId],
            assetInfo,
            revealedMappings[auctionId],
            bidderStake[auctionId],
            bundles[auctionId],
            winningBundleIds,
            protocolAccrued,
            assetBalance
        );

        winningBundleIds[commitHash] = BundleId.wrap(0);
    }
}
