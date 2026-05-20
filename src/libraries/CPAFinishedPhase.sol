// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { IErrorsAndEvents } from "../utils/IErrorsAndEvents.sol";
import { AuctionTypes } from "../types/AuctionTypes.sol";
import { AuctionId } from "../types/AuctionId.sol";

/**
 * @title CPAFinishedPhase
 * @notice Library for the Finished phase.
 *         Token and numeraire returns are handled by ProceedsFacet.returnProceeds().
 */
library CPAFinishedPhase {

    function validateFinishedPhase(
        AuctionId auctionId,
        AuctionTypes.AuctionInfo storage auctionInfo
    ) internal view {
        if (auctionInfo.currentPhase != AuctionTypes.AuctionPhase.Finished)
            revert IErrorsAndEvents.InvalidPhase(
                AuctionTypes.AuctionPhase.Finished,
                auctionInfo.currentPhase
            );
    }
}
