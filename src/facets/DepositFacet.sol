// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { CPABase } from "../base/CPABase.sol";
import { CPASetup } from "../libraries/CPASetup.sol";
import { AuctionTypes } from "../types/AuctionTypes.sol";
import { AuctionId } from "../types/AuctionId.sol";

contract DepositFacet is CPABase {

    constructor(
        address _owner,
        address _protocolWallet,
        uint256 _protocolFeeBps,
        address _mathFacet
    ) CPABase(_owner, _protocolWallet, _protocolFeeBps, _mathFacet) {}

    function moveDeposit(
        AuctionId auctionId,
        address assetToken,
        uint256 depositAmount
    ) external nonReentrant onlyAuctionOwner(auctionId) {
        CPASetup.moveDeposit(auctionInfo[auctionId], assetInfo, assetBalance, auctionId, assetToken, depositAmount);
    }

    function depositAllAndStartClock(
        AuctionId auctionId,
        uint256[] memory amounts
    ) external nonReentrant onlyAuctionOwner(auctionId) onlyPhase(auctionId, AuctionTypes.AuctionPhase.Setup) {
        CPASetup.depositAllAndStartClock(auctionInfo[auctionId], assetInfo, assetBalance, amounts, auctionId);
    }
}
