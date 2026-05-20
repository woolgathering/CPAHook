// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { AuctionTypes } from "../types/AuctionTypes.sol";
import { AuctionId } from "../types/AuctionId.sol";
import { AssetId } from "../types/AssetConfig.sol";
import { BundleId } from "../types/BundleId.sol";

abstract contract CPAStorage {

    // ========================================
    // COMMIT / REVEAL
    // ========================================

    /// AuctionId -> commitHash -> proxy address
    mapping(AuctionId => mapping(bytes32 => address)) public commitProxy;

    // ========================================
    // AUCTION / ASSET LOOKUPS
    // ========================================

    /// AssetId -> AuctionId  (replaces poolToAuctionId)
    mapping(AssetId => AuctionId) public assetToAuctionId;

    /// AuctionId -> AuctionInfo
    mapping(AuctionId => AuctionTypes.AuctionInfo) public auctionInfo;

    /// AssetId -> AssetInfo  (replaces poolInfo)
    mapping(AssetId => AuctionTypes.AssetInfo) public assetInfo;

    /// Pause start time (0 when not paused)
    mapping(AuctionId => uint256) public pauseStartTime;

    // ========================================
    // PROTOCOL CONFIG (immutable on deployment)
    // ========================================

    /// @notice MathFacet address for mulDiv and decimal helpers
    address public mathFacet;

    /// @notice Protocol wallet — receives accumulated fees/penalties
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    address public immutable protocolWallet;

    /// @notice Protocol fee in basis points, charged in numeraire at token claim time
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    uint256 public immutable protocolFeeBps;

    uint256 public constant FORFEITURE_REWARD_RATE = 500; // 5% (basis points)

    // ========================================
    // CLOCK PHASE
    // ========================================

    mapping(AuctionId => mapping(address => bool)) public droppedBidders;
    mapping(AuctionId => uint256[]) internal pendingRoundDemands;
    mapping(AuctionId => bool) internal roundPendingFinalize;
    mapping(AuctionId => mapping(address => uint256)) public bidderStake;
    mapping(AuctionId => mapping(address => uint256)) public bidderBidPoints;
    mapping(AuctionId => mapping(address => uint256[])) public bids;
    mapping(AuctionId => address[]) public activeBidders;

    // ========================================
    // PROXY PHASE
    // ========================================

    mapping(AuctionId => mapping(BundleId => AuctionTypes.Bundle)) public bundles;
    mapping(AuctionId => uint256) public proxyPhaseStartTime;
    mapping(AuctionId => uint256) public allocationPhaseStartTime;
    mapping(AuctionId => uint256) public settlementPhaseStartTime;
    mapping(AuctionId => bool) public hasBundles;
    mapping(AuctionId => bool) public hasAllocations;
    mapping(AuctionId => bool) internal winnerSelected;
    mapping(AuctionId => bool) internal poolsRegistered;

    // ========================================
    // SETTLEMENT / PROCEEDS
    // ========================================

    /// AuctionId -> assetToken -> remaining balance owned to this auction
    /// Set to supply at deposit; decremented at each claim; drained by returnProceeds
    mapping(AuctionId => mapping(address => uint256)) public assetBalance;

    /// Prevents double-withdrawal in returnProceeds
    mapping(AuctionId => bool) public proceedsClaimed;

    /// World-2 flag: set immutably at auction creation
    mapping(AuctionId => bool) public createPoolOnFinish;

    /// Accumulated protocol fees + penalties per auction (withdrawn by protocolWallet)
    mapping(AuctionId => uint256) public protocolAccrued;

    // ========================================
    // ALLOCATION PHASE
    // ========================================

    mapping(AuctionId => AuctionTypes.TopAllocation) public topAllocation;
    /// commitHash -> BundleId
    mapping(bytes32 => BundleId) public winningBundleIds;

    // ========================================
    // SETTLEMENT PHASE
    // ========================================

    /// AuctionId -> commitHash -> revealed bidder address
    mapping(AuctionId => mapping(bytes32 => address)) public revealedMappings;

    // ========================================
    // GETTERS
    // ========================================

    function getAuctionInfo(AuctionId auctionId) external view returns (AuctionTypes.AuctionInfo memory) {
        return auctionInfo[auctionId];
    }

    function getAssetInfo(AssetId assetId) external view returns (AuctionTypes.AssetInfo memory) {
        return assetInfo[assetId];
    }

    function getNumItems(AuctionId auctionId) external view returns (uint256) {
        return auctionInfo[auctionId].assets.length;
    }

    function getBundle(AuctionId auctionId, BundleId bundleId)
        external view
        returns (AuctionId, bytes32, BundleId, uint256[] memory, uint256, uint256)
    {
        return (
            auctionId,
            bundles[auctionId][bundleId].commitHash,
            bundleId,
            bundles[auctionId][bundleId].quantities,
            bundles[auctionId][bundleId].value,
            bundles[auctionId][bundleId].timestamp
        );
    }

    function getTopAllocation(AuctionId auctionId) external view returns (AuctionTypes.TopAllocation memory) {
        return topAllocation[auctionId];
    }

    // ========================================
    // CONSTRUCTOR
    // ========================================

    constructor(address _mathFacet, address _protocolWallet, uint256 _protocolFeeBps) {
        mathFacet = _mathFacet;
        protocolWallet = _protocolWallet;
        protocolFeeBps = _protocolFeeBps;
    }
}
