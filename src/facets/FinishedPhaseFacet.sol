// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { CPABase } from "../base/CPABase.sol";
import { AuctionTypes } from "../types/AuctionTypes.sol";
import { AuctionId } from "../types/AuctionId.sol";

contract FinishedPhaseFacet is CPABase {
    using SafeERC20 for IERC20;

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
        uint256 stake = bidderStake[auctionId][bidder];
        if (stake == 0) revert InvalidStakeAmount();

        address numeraire = auctionInfo[auctionId].commonNumeraire;
        uint256 penaltyRate = auctionInfo[auctionId].config.minSpendRatio;

        uint256 penalty = stake * penaltyRate / 10000;
        uint256 callerReward = stake * FORFEITURE_REWARD_RATE / 10000;
        uint256 remaining = stake - penalty - callerReward;

        protocolAccrued[auctionId] += penalty;
        bidderStake[auctionId][bidder] = 0;
        bidderBidPoints[auctionId][bidder] = 0;

        if (callerReward > 0) {
            IERC20(numeraire).safeTransfer(msg.sender, callerReward);
            emit ForfeitureRewardTransferred(auctionId, msg.sender, callerReward);
        }
        if (remaining > 0) {
            IERC20(numeraire).safeTransfer(bidder, remaining);
        }

        emit BundleForfeited(auctionId, bidder, penalty);
    }
}
