// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { AuctionTypes } from "../types/AuctionTypes.sol";
import { AuctionId } from "../types/AuctionId.sol";
import { AssetId } from "../types/AssetConfig.sol";
import { BundleId } from "../types/BundleId.sol";

// ========================================
// PER-PHASE STORAGE STRUCTS
// ========================================

struct ClockPhaseState {
    mapping(address => uint256) bidderStake;      // also read in Settlement
    mapping(address => uint256) bidderBidPoints;
    mapping(address => uint256[]) bids;
    address[] activeBidders;
    mapping(address => bool) droppedBidders;
    uint256[] pendingRoundDemands;
    bool roundPendingFinalize;
}

struct ProxyPhaseState {
    mapping(bytes32 => address) commitProxy;
    mapping(BundleId => AuctionTypes.Bundle) bundles;
    bool hasBundles;
    bool poolsRegistered;
    uint256 proxyPhaseStartTime;
}

struct AllocationPhaseState {
    AuctionTypes.TopAllocation topAllocation;
    bool hasAllocations;
    bool winnerSelected;
    uint256 allocationPhaseStartTime;
}

struct SettlementPhaseState {
    mapping(bytes32 => address) revealedMappings;
    mapping(address => uint256) assetBalance;     // assetToken → balance
    uint256 protocolAccrued;
    bool proceedsClaimed;
    bool createPoolOnFinish;
    uint256 settlementPhaseStartTime;
    uint256 pauseStartTime;
}

abstract contract CPAStorage {

    // ========================================
    // PER-AUCTION PHASE STATE
    // ========================================

    mapping(AuctionId => ClockPhaseState)      internal _clock;
    mapping(AuctionId => ProxyPhaseState)      internal _proxy;
    mapping(AuctionId => AllocationPhaseState) internal _alloc;
    mapping(AuctionId => SettlementPhaseState) internal _settlement;

    // ========================================
    // AUCTION / ASSET LOOKUPS (flat, not per-phase)
    // ========================================

    /// AssetId -> AuctionId
    mapping(AssetId => AuctionId) public assetToAuctionId;

    /// AuctionId -> AuctionInfo
    mapping(AuctionId => AuctionTypes.AuctionInfo) public auctionInfo;

    /// AssetId -> AssetInfo
    mapping(AssetId => AuctionTypes.AssetInfo) public assetInfo;

    // ========================================
    // SETTLEMENT (flat — keyed by commitHash, not AuctionId)
    // ========================================

    /// commitHash -> BundleId
    mapping(bytes32 => BundleId) public winningBundleIds;

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
    // GETTERS — preserve ICPAManager interface
    // ========================================

    function bidderStake(AuctionId id, address b)      external view returns (uint256) { return _clock[id].bidderStake[b]; }
    function bidderBidPoints(AuctionId id, address b)  external view returns (uint256) { return _clock[id].bidderBidPoints[b]; }
    function activeBidders(AuctionId id, uint256 i)    external view returns (address) { return _clock[id].activeBidders[i]; }
    function droppedBidders(AuctionId id, address b)   external view returns (bool)    { return _clock[id].droppedBidders[b]; }
    function pendingRoundDemands(AuctionId id, uint256 i) external view returns (uint256) { return _clock[id].pendingRoundDemands[i]; }
    function roundPendingFinalize(AuctionId id)        external view returns (bool)    { return _clock[id].roundPendingFinalize; }

    function commitProxy(AuctionId id, bytes32 h)      external view returns (address) { return _proxy[id].commitProxy[h]; }
    function hasBundles(AuctionId id)                  external view returns (bool)    { return _proxy[id].hasBundles; }
    function poolsRegistered(AuctionId id)             external view returns (bool)    { return _proxy[id].poolsRegistered; }
    function proxyPhaseStartTime(AuctionId id)         external view returns (uint256) { return _proxy[id].proxyPhaseStartTime; }

    function hasAllocations(AuctionId id)              external view returns (bool)    { return _alloc[id].hasAllocations; }
    function winnerSelected(AuctionId id)              external view returns (bool)    { return _alloc[id].winnerSelected; }
    function allocationPhaseStartTime(AuctionId id)    external view returns (uint256) { return _alloc[id].allocationPhaseStartTime; }

    function revealedMappings(AuctionId id, bytes32 h) external view returns (address) { return _settlement[id].revealedMappings[h]; }
    function assetBalance(AuctionId id, address t)     external view returns (uint256) { return _settlement[id].assetBalance[t]; }
    function protocolAccrued(AuctionId id)             external view returns (uint256) { return _settlement[id].protocolAccrued; }
    function proceedsClaimed(AuctionId id)             external view returns (bool)    { return _settlement[id].proceedsClaimed; }
    function createPoolOnFinish(AuctionId id)          external view returns (bool)    { return _settlement[id].createPoolOnFinish; }
    function settlementPhaseStartTime(AuctionId id)    external view returns (uint256) { return _settlement[id].settlementPhaseStartTime; }
    function pauseStartTime(AuctionId id)              external view returns (uint256) { return _settlement[id].pauseStartTime; }

    // ========================================
    // COMPLEX GETTERS
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
        AuctionTypes.Bundle storage b = _proxy[auctionId].bundles[bundleId];
        return (auctionId, b.commitHash, bundleId, b.quantities, b.value, b.timestamp);
    }

    function getTopAllocation(AuctionId auctionId) external view returns (AuctionTypes.TopAllocation memory) {
        return _alloc[auctionId].topAllocation;
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
