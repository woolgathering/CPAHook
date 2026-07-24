// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { AuctionTypes } from "../types/AuctionTypes.sol";
import { AuctionId } from "../types/AuctionId.sol";
import { AssetId } from "../types/AssetConfig.sol";
import { BundleId } from "../types/BundleId.sol";
import { IDiamondCut } from "./IDiamondCut.sol";
import { IDiamondLoupe } from "./IDiamondLoupe.sol";

interface ICPAManager is IDiamondCut, IDiamondLoupe {

    // ========================================
    // AUCTION CREATION AND SETUP
    // ========================================

    function createAuction(AuctionTypes.AuctionConfig memory config, address auctionOwner) external returns (AuctionId);
    function initAuction(AuctionTypes.AuctionConfig memory config, address auctionOwner) external returns (AuctionId);
    function finalizeAuction(AuctionId auctionId, AuctionTypes.AuctionConfig memory config, address auctionOwner) external returns (AuctionId);

    function moveDeposit(AuctionId auctionId, address assetToken, uint256 depositAmount) external;
    function depositAllAndStartClock(AuctionId auctionId, uint256[] memory amounts) external;

    // ========================================
    // AUCTION CONTROL
    // ========================================

    function pause(AuctionId auctionId) external;
    function unpause(AuctionId auctionId) external;
    function forceCancelAuction(AuctionId auctionId) external;
    function cancelAuction(AuctionId auctionId) external;
    function reclaimStake(AuctionId auctionId) external;

    // ========================================
    // CLOCK PHASE
    // ========================================

    function startClockPhase(AuctionId auctionId) external;
    function endClockRound(AuctionId auctionId) external;
    function processClockRoundStep(AuctionId auctionId) external;
    function finalizeClockRound(AuctionId auctionId) external;
    function endClockPhase(AuctionId auctionId) external;

    function submitBid(AuctionId auctionId, uint256[] calldata demands, uint256 maxStakeAmount) external;
    function commitToBidder(AuctionId auctionId, bytes32 commitHash) external;
    function registerCommit(AuctionId auctionId, bytes32 commitHash) external;
    function dropout(AuctionId auctionId) external;

    // ========================================
    // PROXY PHASE
    // ========================================

    function submitBundle(AuctionId auctionId, bytes32 commitHash, AuctionTypes.Bundle calldata bundleData) external returns (BundleId);

    // ========================================
    // ALLOCATION PHASE
    // ========================================

    function submitAllocation(AuctionId auctionId, AuctionTypes.Allocation calldata allocationData) external;

    // ========================================
    // SETTLEMENT PHASE
    // ========================================

    function reveal(AuctionId auctionId, address proxy, bytes32 saltA, bytes32 saltB) external;
    function claimAllTokens(AuctionId auctionId, bytes32 commitHash) external;
    function claimAllocatorReward(AuctionId auctionId) external;

    // ========================================
    // PHASE TRANSITIONS
    // ========================================

    function transitionToAllocation(AuctionId auctionId) external;
    function transitionToSettlement(AuctionId auctionId) external;
    function selectAuctionWinner(AuctionId auctionId) external;
    function transitionToFinished(AuctionId auctionId) external;

    // ========================================
    // FINISHED PHASE
    // ========================================

    function forfeit(AuctionId auctionId, address bidder) external;

    // ========================================
    // PROCEEDS
    // ========================================

    function returnProceeds(AuctionId auctionId) external;
    function withdrawProtocolFees(AuctionId auctionId) external;

    // ========================================
    // VIEW FUNCTIONS
    // ========================================

    function getAuctionInfo(AuctionId auctionId) external view returns (AuctionTypes.AuctionInfo memory);
    function getAssetInfo(AssetId assetId) external view returns (AuctionTypes.AssetInfo memory);
    function getBidderDemands(AuctionId auctionId, address bidder) external view returns (uint256[] memory);
    function getBundle(AuctionId auctionId, BundleId bundleId) external view returns (AuctionId, bytes32, BundleId, uint256[] memory, uint256, uint256);
    function getNumItems(AuctionId auctionId) external view returns (uint256);
    function getTopAllocation(AuctionId auctionId) external view returns (AuctionTypes.TopAllocation memory);

    function bidderStake(AuctionId auctionId, address bidder) external view returns (uint256);
    function bidderBidPoints(AuctionId auctionId, address bidder) external view returns (uint256);
    function revealedMappings(AuctionId auctionId, bytes32 commitHash) external view returns (address);
    function winningBundleIds(bytes32 commitHash) external view returns (BundleId);
    function activeBidders(AuctionId auctionId, uint256 index) external view returns (address);
    function protocolAccrued(AuctionId auctionId) external view returns (uint256);
    function assetBalance(AuctionId auctionId, address assetToken) external view returns (uint256);
    function proceedsClaimed(AuctionId auctionId) external view returns (bool);

    // ERC-165
    function supportsInterface(bytes4 interfaceId) external view returns (bool);
}
