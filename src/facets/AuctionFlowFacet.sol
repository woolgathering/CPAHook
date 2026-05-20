// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { CPABase } from "../base/CPABase.sol";
import { ICPAManager } from "../interfaces/ICPAManager.sol";
import { AuctionTypes } from "../types/AuctionTypes.sol";
import { AuctionId } from "../types/AuctionId.sol";

/**
 * @title AuctionFlowFacet
 * @notice Single-call orchestrators for multi-step auction flows.
 */
contract AuctionFlowFacet is CPABase {

    constructor(
        address _owner,
        address _protocolWallet,
        uint256 _protocolFeeBps,
        address _mathFacet
    ) CPABase(_owner, _protocolWallet, _protocolFeeBps, _mathFacet) {}

    function createAuction(
        AuctionTypes.AuctionConfig memory config,
        address auctionOwner
    ) external returns (AuctionId) {
        AuctionId auctionId = ICPAManager(address(this)).initAuction(config, auctionOwner);
        ICPAManager(address(this)).finalizeAuction(auctionId, config, auctionOwner);
        return auctionId;
    }

    function endClockRound(AuctionId auctionId) external onlyAuctionOwner(auctionId) {
        ICPAManager(address(this)).processClockRoundStep(auctionId);
        ICPAManager(address(this)).finalizeClockRound(auctionId);
    }

    /// @notice Transition from Allocation to Settlement — selects winner then opens Settlement.
    function transitionToSettlement(AuctionId auctionId) external {
        ICPAManager(address(this)).selectAuctionWinner(auctionId);
    }
}
