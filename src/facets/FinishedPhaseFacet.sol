// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { NumeraireLib } from "../libraries/NumeraireLib.sol";

import { CPABase } from "../base/CPABase.sol";
import { AuctionTypes } from "../types/AuctionTypes.sol";
import { AuctionId } from "../types/AuctionId.sol";

contract FinishedPhaseFacet is CPABase {

    constructor(
        address _owner,
        address _protocolWallet,
        uint256 _protocolFeeBps,
        address _mathFacet
    ) CPABase(_owner, _protocolWallet, _protocolFeeBps, _mathFacet) {}

    function forfeit(AuctionId auctionId, address bidder)
        external
        onlyPhase(auctionId, AuctionTypes.AuctionPhase.Finished)
    {
        uint256 stake = _clock[auctionId].bidderStake[bidder];
        if (stake == 0) revert InvalidStakeAmount();

        address numeraire = auctionInfo[auctionId].commonNumeraire;
        uint256 penaltyRate = auctionInfo[auctionId].config.minSpendRatio;

        uint256 penalty = stake * penaltyRate / 10000;
        uint256 callerReward = stake * FORFEITURE_REWARD_RATE / 10000;
        uint256 remaining = stake - penalty - callerReward;

        _settlement[auctionId].protocolAccrued += penalty;
        _clock[auctionId].bidderStake[bidder] = 0;
        _clock[auctionId].bidderBidPoints[bidder] = 0;

        NumeraireLib.transfer(numeraire, msg.sender, callerReward);
        if (callerReward > 0) emit ForfeitureRewardTransferred(auctionId, msg.sender, callerReward);
        NumeraireLib.transfer(numeraire, bidder, remaining);

        emit BundleForfeited(auctionId, bidder, penalty);
    }
}
