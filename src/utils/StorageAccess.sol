// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { StorageSlots } from "./StorageSlots.sol";
import { AuctionId } from "../types/AuctionId.sol";
import { PoolId } from "@uniswap/v4-core/src/types/PoolId.sol";
import { BundleId } from "../types/BundleId.sol";
import { AuctionTypes } from "../types/AuctionTypes.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";

/**
 * @title StorageAccess
 * @notice Library for assembly-based direct storage access to reduce bytecode size
 * @dev Replaces public helper functions in CPAStorage with direct storage slot access
 *      All functions operate in DELEGATECALL context (executing contract's storage)
 */
library StorageAccess {
    using StorageSlots for *;

    // ========================================
    // LOW-LEVEL STORAGE OPERATIONS
    // ========================================
    
    /**
     * @notice Read a bytes32 value from storage
     * @param slot The storage slot to read from
     * @return value The value stored at the slot
     */
    function _sload(bytes32 slot) internal view returns (bytes32 value) {
        assembly {
            value := sload(slot)
        }
    }
    
    /**
     * @notice Write a bytes32 value to storage
     * @param slot The storage slot to write to
     * @param value The value to write
     */
    function _sstore(bytes32 slot, bytes32 value) internal {
        assembly {
            sstore(slot, value)
        }
    }
    
    /**
     * @notice Read a uint256 value from storage
     */
    function _sloadUint256(bytes32 slot) internal view returns (uint256) {
        return uint256(_sload(slot));
    }
    
    /**
     * @notice Write a uint256 value to storage
     */
    function _sstoreUint256(bytes32 slot, uint256 value) internal {
        _sstore(slot, bytes32(value));
    }
    
    /**
     * @notice Read an address value from storage
     */
    function _sloadAddress(bytes32 slot) internal view returns (address) {
        return address(uint160(uint256(_sload(slot))));
    }
    
    /**
     * @notice Write an address value to storage
     */
    function _sstoreAddress(bytes32 slot, address value) internal {
        _sstore(slot, bytes32(uint256(uint160(value))));
    }
    
    /**
     * @notice Read a bool value from storage
     */
    function _sloadBool(bytes32 slot) internal view returns (bool) {
        return uint256(_sload(slot)) != 0;
    }
    
    /**
     * @notice Write a bool value to storage
     */
    function _sstoreBool(bytes32 slot, bool value) internal {
        _sstore(slot, bytes32(uint256(value ? 1 : 0)));
    }
    
    /**
     * @notice Read array length from storage
     */
    function _sloadArrayLength(bytes32 slot) internal view returns (uint256) {
        return _sloadUint256(slot);
    }
    
    /**
     * @notice Write array length to storage
     */
    function _sstoreArrayLength(bytes32 slot, uint256 length) internal {
        _sstoreUint256(slot, length);
    }
    
    /**
     * @notice Increment array length (for push operations)
     */
    function _incrementArrayLength(bytes32 slot) internal returns (uint256 newLength) {
        newLength = _sloadArrayLength(slot) + 1;
        _sstoreArrayLength(slot, newLength);
    }

    // ========================================
    // MAPPING ACCESS FUNCTIONS
    // ========================================
    
    // PoolToAuctionId
    function getPoolToAuctionId(PoolId poolId) internal view returns (AuctionId) {
        bytes32 slot = StorageSlots.mappingSlot(
            StorageSlots.SLOT_POOL_TO_AUCTION_ID,
            StorageSlots.encodePoolId(poolId)
        );
        return AuctionId.wrap(_sload(slot));
    }
    
    function setPoolToAuctionId(PoolId poolId, AuctionId auctionId) internal {
        bytes32 slot = StorageSlots.mappingSlot(
            StorageSlots.SLOT_POOL_TO_AUCTION_ID,
            StorageSlots.encodePoolId(poolId)
        );
        _sstore(slot, AuctionId.unwrap(auctionId));
    }
    
    // BidderStake
    function getBidderStake(AuctionId auctionId, address bidder) internal view returns (uint256) {
        bytes32 slot = StorageSlots.nestedMappingSlot(
            StorageSlots.SLOT_BIDDER_STAKE,
            StorageSlots.encodeAuctionId(auctionId),
            StorageSlots.encodeAddress(bidder)
        );
        return _sloadUint256(slot);
    }
    
    function setBidderStake(AuctionId auctionId, address bidder, uint256 stake) internal {
        bytes32 slot = StorageSlots.nestedMappingSlot(
            StorageSlots.SLOT_BIDDER_STAKE,
            StorageSlots.encodeAuctionId(auctionId),
            StorageSlots.encodeAddress(bidder)
        );
        _sstoreUint256(slot, stake);
    }
    
    // BidderBidPoints
    function getBidderBidPoints(AuctionId auctionId, address bidder) internal view returns (uint256) {
        bytes32 slot = StorageSlots.nestedMappingSlot(
            StorageSlots.SLOT_BIDDER_BID_POINTS,
            StorageSlots.encodeAuctionId(auctionId),
            StorageSlots.encodeAddress(bidder)
        );
        return _sloadUint256(slot);
    }
    
    function setBidderBidPoints(AuctionId auctionId, address bidder, uint256 points) internal {
        bytes32 slot = StorageSlots.nestedMappingSlot(
            StorageSlots.SLOT_BIDDER_BID_POINTS,
            StorageSlots.encodeAuctionId(auctionId),
            StorageSlots.encodeAddress(bidder)
        );
        _sstoreUint256(slot, points);
    }
    
    // ProxyPhaseStartTime
    function getProxyPhaseStartTime(AuctionId auctionId) internal view returns (uint256) {
        bytes32 slot = StorageSlots.mappingSlot(
            StorageSlots.SLOT_PROXY_PHASE_START_TIME,
            StorageSlots.encodeAuctionId(auctionId)
        );
        return _sloadUint256(slot);
    }
    
    function setProxyPhaseStartTime(AuctionId auctionId, uint256 time) internal {
        bytes32 slot = StorageSlots.mappingSlot(
            StorageSlots.SLOT_PROXY_PHASE_START_TIME,
            StorageSlots.encodeAuctionId(auctionId)
        );
        _sstoreUint256(slot, time);
    }
    
    // HasBundles
    function getHasBundles(AuctionId auctionId) internal view returns (bool) {
        bytes32 slot = StorageSlots.mappingSlot(
            StorageSlots.SLOT_HAS_BUNDLES,
            StorageSlots.encodeAuctionId(auctionId)
        );
        return _sloadBool(slot);
    }
    
    function setHasBundles(AuctionId auctionId, bool value) internal {
        bytes32 slot = StorageSlots.mappingSlot(
            StorageSlots.SLOT_HAS_BUNDLES,
            StorageSlots.encodeAuctionId(auctionId)
        );
        _sstoreBool(slot, value);
    }
    
    // CommitProxy
    function getCommitProxy(AuctionId auctionId, bytes32 commitHash) internal view returns (address) {
        bytes32 slot = StorageSlots.nestedMappingSlot(
            StorageSlots.SLOT_COMMIT_PROXY,
            StorageSlots.encodeAuctionId(auctionId),
            commitHash
        );
        return _sloadAddress(slot);
    }
    
    function setCommitProxy(AuctionId auctionId, bytes32 commitHash, address proxy) internal {
        bytes32 slot = StorageSlots.nestedMappingSlot(
            StorageSlots.SLOT_COMMIT_PROXY,
            StorageSlots.encodeAuctionId(auctionId),
            commitHash
        );
        _sstoreAddress(slot, proxy);
    }
    
    // HasAllocations
    function getHasAllocations(AuctionId auctionId) internal view returns (bool) {
        bytes32 slot = StorageSlots.mappingSlot(
            StorageSlots.SLOT_HAS_ALLOCATIONS,
            StorageSlots.encodeAuctionId(auctionId)
        );
        return _sloadBool(slot);
    }
    
    function setHasAllocations(AuctionId auctionId, bool value) internal {
        bytes32 slot = StorageSlots.mappingSlot(
            StorageSlots.SLOT_HAS_ALLOCATIONS,
            StorageSlots.encodeAuctionId(auctionId)
        );
        _sstoreBool(slot, value);
    }
    
    // WinningBundleIds
    function getWinningBundleId(bytes32 commitHash) internal view returns (BundleId) {
        bytes32 slot = StorageSlots.mappingSlot(
            StorageSlots.SLOT_WINNING_BUNDLE_IDS,
            commitHash
        );
        return BundleId.wrap(_sload(slot));
    }
    
    function setWinningBundleId(bytes32 commitHash, BundleId bundleId) internal {
        bytes32 slot = StorageSlots.mappingSlot(
            StorageSlots.SLOT_WINNING_BUNDLE_IDS,
            commitHash
        );
        _sstore(slot, BundleId.unwrap(bundleId));
    }
    
    // RevealedMappings
    function getRevealedMapping(AuctionId auctionId, bytes32 commitHash) internal view returns (address) {
        bytes32 slot = StorageSlots.nestedMappingSlot(
            StorageSlots.SLOT_REVEALED_MAPPINGS,
            StorageSlots.encodeAuctionId(auctionId),
            commitHash
        );
        return _sloadAddress(slot);
    }
    
    function setRevealedMapping(AuctionId auctionId, bytes32 commitHash, address bidder) internal {
        bytes32 slot = StorageSlots.nestedMappingSlot(
            StorageSlots.SLOT_REVEALED_MAPPINGS,
            StorageSlots.encodeAuctionId(auctionId),
            commitHash
        );
        _sstoreAddress(slot, bidder);
    }
    
    // ProtocolPenalties
    function getProtocolPenalty(AuctionId auctionId) internal view returns (uint256) {
        bytes32 slot = StorageSlots.mappingSlot(
            StorageSlots.SLOT_PROTOCOL_PENALTIES,
            StorageSlots.encodeAuctionId(auctionId)
        );
        return _sloadUint256(slot);
    }
    
    function setProtocolPenalty(AuctionId auctionId, uint256 penalty) internal {
        bytes32 slot = StorageSlots.mappingSlot(
            StorageSlots.SLOT_PROTOCOL_PENALTIES,
            StorageSlots.encodeAuctionId(auctionId)
        );
        _sstoreUint256(slot, penalty);
    }
    
    function addProtocolPenalty(AuctionId auctionId, uint256 amount) internal {
        bytes32 slot = StorageSlots.mappingSlot(
            StorageSlots.SLOT_PROTOCOL_PENALTIES,
            StorageSlots.encodeAuctionId(auctionId)
        );
        uint256 current = _sloadUint256(slot);
        _sstoreUint256(slot, current + amount);
    }
    
    // PauseStartTime
    function getPauseStartTime(AuctionId auctionId) internal view returns (uint256) {
        bytes32 slot = StorageSlots.mappingSlot(
            StorageSlots.SLOT_PAUSE_START_TIME,
            StorageSlots.encodeAuctionId(auctionId)
        );
        return _sloadUint256(slot);
    }
    
    function setPauseStartTime(AuctionId auctionId, uint256 time) internal {
        bytes32 slot = StorageSlots.mappingSlot(
            StorageSlots.SLOT_PAUSE_START_TIME,
            StorageSlots.encodeAuctionId(auctionId)
        );
        _sstoreUint256(slot, time);
    }

    // ========================================
    // ARRAY OPERATIONS
    // ========================================
    
    // ActiveBidders array
    function getActiveBiddersLength(AuctionId auctionId) internal view returns (uint256) {
        bytes32 baseSlot = StorageSlots.mappingSlot(
            StorageSlots.SLOT_ACTIVE_BIDDERS,
            StorageSlots.encodeAuctionId(auctionId)
        );
        return _sloadArrayLength(baseSlot);
    }
    
    function getActiveBidder(AuctionId auctionId, uint256 index) internal view returns (address) {
        bytes32 baseSlot = StorageSlots.mappingSlot(
            StorageSlots.SLOT_ACTIVE_BIDDERS,
            StorageSlots.encodeAuctionId(auctionId)
        );
        bytes32 elementSlot = StorageSlots.arrayElementSlot(baseSlot, index);
        return _sloadAddress(elementSlot);
    }
    
    function pushActiveBidder(AuctionId auctionId, address bidder) internal {
        bytes32 baseSlot = StorageSlots.mappingSlot(
            StorageSlots.SLOT_ACTIVE_BIDDERS,
            StorageSlots.encodeAuctionId(auctionId)
        );
        uint256 length = _incrementArrayLength(baseSlot);
        bytes32 elementSlot = StorageSlots.arrayElementSlot(baseSlot, length - 1);
        _sstoreAddress(elementSlot, bidder);
    }
    
    function clearActiveBidders(AuctionId auctionId) internal {
        bytes32 baseSlot = StorageSlots.mappingSlot(
            StorageSlots.SLOT_ACTIVE_BIDDERS,
            StorageSlots.encodeAuctionId(auctionId)
        );
        uint256 length = _sloadArrayLength(baseSlot);
        // Clear length
        _sstoreArrayLength(baseSlot, 0);
        // Clear elements (optional, but good practice)
        for (uint256 i = 0; i < length; i++) {
            bytes32 elementSlot = StorageSlots.arrayElementSlot(baseSlot, i);
            _sstore(elementSlot, bytes32(0));
        }
    }
    
    function getActiveBidders(AuctionId auctionId) internal view returns (address[] memory) {
        uint256 length = getActiveBiddersLength(auctionId);
        address[] memory result = new address[](length);
        for (uint256 i = 0; i < length; i++) {
            result[i] = getActiveBidder(auctionId, i);
        }
        return result;
    }
    
    function setActiveBidder(AuctionId auctionId, uint256 index, address bidder) internal {
        bytes32 baseSlot = StorageSlots.mappingSlot(
            StorageSlots.SLOT_ACTIVE_BIDDERS,
            StorageSlots.encodeAuctionId(auctionId)
        );
        bytes32 elementSlot = StorageSlots.arrayElementSlot(baseSlot, index);
        _sstoreAddress(elementSlot, bidder);
    }
    
    // Bids array (nested: AuctionId -> address -> uint256[])
    function getBidsLength(AuctionId auctionId, address bidder) internal view returns (uint256) {
        bytes32 mappingSlot = StorageSlots.nestedMappingSlot(
            StorageSlots.SLOT_BIDS,
            StorageSlots.encodeAuctionId(auctionId),
            StorageSlots.encodeAddress(bidder)
        );
        return _sloadArrayLength(mappingSlot);
    }
    
    function getBid(AuctionId auctionId, address bidder, uint256 index) internal view returns (uint256) {
        bytes32 mappingSlot = StorageSlots.nestedMappingSlot(
            StorageSlots.SLOT_BIDS,
            StorageSlots.encodeAuctionId(auctionId),
            StorageSlots.encodeAddress(bidder)
        );
        bytes32 elementSlot = StorageSlots.arrayElementSlot(mappingSlot, index);
        return _sloadUint256(elementSlot);
    }
    
    function getBids(AuctionId auctionId, address bidder) internal view returns (uint256[] memory) {
        uint256 length = getBidsLength(auctionId, bidder);
        uint256[] memory result = new uint256[](length);
        for (uint256 i = 0; i < length; i++) {
            result[i] = getBid(auctionId, bidder, i);
        }
        return result;
    }
    
    function setBids(AuctionId auctionId, address bidder, uint256[] memory bidsArray) internal {
        bytes32 mappingSlot = StorageSlots.nestedMappingSlot(
            StorageSlots.SLOT_BIDS,
            StorageSlots.encodeAuctionId(auctionId),
            StorageSlots.encodeAddress(bidder)
        );
        
        // Clear existing array
        uint256 oldLength = _sloadArrayLength(mappingSlot);
        for (uint256 i = 0; i < oldLength; i++) {
            bytes32 elementSlot = StorageSlots.arrayElementSlot(mappingSlot, i);
            _sstore(elementSlot, bytes32(0));
        }
        
        // Set new array
        _sstoreArrayLength(mappingSlot, bidsArray.length);
        for (uint256 i = 0; i < bidsArray.length; i++) {
            bytes32 elementSlot = StorageSlots.arrayElementSlot(mappingSlot, i);
            _sstoreUint256(elementSlot, bidsArray[i]);
        }
    }

    // ========================================
    // AUCTION INFO STRUCT FIELD ACCESS
    // ========================================
    
    function getAuctionInfoBaseSlot(AuctionId auctionId) internal pure returns (bytes32) {
        return StorageSlots.mappingSlot(
            StorageSlots.SLOT_AUCTION_INFO,
            StorageSlots.encodeAuctionId(auctionId)
        );
    }
    
    function getAuctionPhase(AuctionId auctionId) internal view returns (AuctionTypes.AuctionPhase) {
        bytes32 baseSlot = getAuctionInfoBaseSlot(auctionId);
        bytes32 fieldSlot = StorageSlots.structFieldSlot(baseSlot, StorageSlots.AUCTION_INFO_FIELD_CURRENT_PHASE);
        return AuctionTypes.AuctionPhase(uint8(uint256(_sload(fieldSlot))));
    }
    
    function setAuctionPhase(AuctionId auctionId, AuctionTypes.AuctionPhase phase) internal {
        bytes32 baseSlot = getAuctionInfoBaseSlot(auctionId);
        bytes32 fieldSlot = StorageSlots.structFieldSlot(baseSlot, StorageSlots.AUCTION_INFO_FIELD_CURRENT_PHASE);
        _sstore(fieldSlot, bytes32(uint256(uint8(phase))));
    }
    
    function getAuctionStatus(AuctionId auctionId) internal view returns (AuctionTypes.AuctionStatus) {
        bytes32 baseSlot = getAuctionInfoBaseSlot(auctionId);
        bytes32 fieldSlot = StorageSlots.structFieldSlot(baseSlot, StorageSlots.AUCTION_INFO_FIELD_CURRENT_STATUS);
        return AuctionTypes.AuctionStatus(uint8(uint256(_sload(fieldSlot))));
    }
    
    function setAuctionStatus(AuctionId auctionId, AuctionTypes.AuctionStatus status) internal {
        bytes32 baseSlot = getAuctionInfoBaseSlot(auctionId);
        bytes32 fieldSlot = StorageSlots.structFieldSlot(baseSlot, StorageSlots.AUCTION_INFO_FIELD_CURRENT_STATUS);
        _sstore(fieldSlot, bytes32(uint256(uint8(status))));
    }
    
    function getAuctionClockOpen(AuctionId auctionId) internal view returns (uint8) {
        bytes32 baseSlot = getAuctionInfoBaseSlot(auctionId);
        bytes32 fieldSlot = StorageSlots.structFieldSlot(baseSlot, StorageSlots.AUCTION_INFO_FIELD_CLOCK_OPEN);
        return uint8(uint256(_sload(fieldSlot)));
    }
    
    function setAuctionClockOpen(AuctionId auctionId, uint8 clockOpen) internal {
        bytes32 baseSlot = getAuctionInfoBaseSlot(auctionId);
        bytes32 fieldSlot = StorageSlots.structFieldSlot(baseSlot, StorageSlots.AUCTION_INFO_FIELD_CLOCK_OPEN);
        _sstore(fieldSlot, bytes32(uint256(clockOpen)));
    }
    
    function getAuctionCurrentRound(AuctionId auctionId) internal view returns (uint256) {
        bytes32 baseSlot = getAuctionInfoBaseSlot(auctionId);
        bytes32 fieldSlot = StorageSlots.structFieldSlot(baseSlot, StorageSlots.AUCTION_INFO_FIELD_CURRENT_ROUND);
        return _sloadUint256(fieldSlot);
    }
    
    function setAuctionCurrentRound(AuctionId auctionId, uint256 round) internal {
        bytes32 baseSlot = getAuctionInfoBaseSlot(auctionId);
        bytes32 fieldSlot = StorageSlots.structFieldSlot(baseSlot, StorageSlots.AUCTION_INFO_FIELD_CURRENT_ROUND);
        _sstoreUint256(fieldSlot, round);
    }
    
    function getAuctionAllocatorReward(AuctionId auctionId) internal view returns (uint256) {
        bytes32 baseSlot = getAuctionInfoBaseSlot(auctionId);
        bytes32 fieldSlot = StorageSlots.structFieldSlot(baseSlot, StorageSlots.AUCTION_INFO_FIELD_ALLOCATOR_REWARD);
        return _sloadUint256(fieldSlot);
    }
    
    function setAuctionAllocatorReward(AuctionId auctionId, uint256 reward) internal {
        bytes32 baseSlot = getAuctionInfoBaseSlot(auctionId);
        bytes32 fieldSlot = StorageSlots.structFieldSlot(baseSlot, StorageSlots.AUCTION_INFO_FIELD_ALLOCATOR_REWARD);
        _sstoreUint256(fieldSlot, reward);
    }
    
    function getAuctionLastRevenue(AuctionId auctionId) internal view returns (uint256) {
        bytes32 baseSlot = getAuctionInfoBaseSlot(auctionId);
        bytes32 fieldSlot = StorageSlots.structFieldSlot(baseSlot, StorageSlots.AUCTION_INFO_FIELD_LAST_REVENUE);
        return _sloadUint256(fieldSlot);
    }
    
    function setAuctionLastRevenue(AuctionId auctionId, uint256 revenue) internal {
        bytes32 baseSlot = getAuctionInfoBaseSlot(auctionId);
        bytes32 fieldSlot = StorageSlots.structFieldSlot(baseSlot, StorageSlots.AUCTION_INFO_FIELD_LAST_REVENUE);
        _sstoreUint256(fieldSlot, revenue);
    }
    
    // ChangedPrices array (bool[])
    function getChangedPricesLength(AuctionId auctionId) internal view returns (uint256) {
        bytes32 baseSlot = getAuctionInfoBaseSlot(auctionId);
        bytes32 arraySlot = StorageSlots.structFieldSlot(baseSlot, StorageSlots.AUCTION_INFO_FIELD_CHANGED_PRICES);
        return _sloadArrayLength(arraySlot);
    }
    
    function getChangedPrice(AuctionId auctionId, uint256 index) internal view returns (bool) {
        bytes32 baseSlot = getAuctionInfoBaseSlot(auctionId);
        bytes32 arraySlot = StorageSlots.structFieldSlot(baseSlot, StorageSlots.AUCTION_INFO_FIELD_CHANGED_PRICES);
        bytes32 elementSlot = StorageSlots.arrayElementSlot(arraySlot, index);
        return _sloadBool(elementSlot);
    }
    
    function setChangedPrices(AuctionId auctionId, bool[] memory changedPrices) internal {
        bytes32 baseSlot = getAuctionInfoBaseSlot(auctionId);
        bytes32 arraySlot = StorageSlots.structFieldSlot(baseSlot, StorageSlots.AUCTION_INFO_FIELD_CHANGED_PRICES);
        
        // Clear existing array
        uint256 oldLength = _sloadArrayLength(arraySlot);
        for (uint256 i = 0; i < oldLength; i++) {
            bytes32 elementSlot = StorageSlots.arrayElementSlot(arraySlot, i);
            _sstore(elementSlot, bytes32(0));
        }
        
        // Set new array - bools are packed 8 per slot
        _sstoreArrayLength(arraySlot, changedPrices.length);
        for (uint256 i = 0; i < changedPrices.length; i++) {
            bytes32 elementSlot = StorageSlots.arrayElementSlot(arraySlot, i);
            _sstoreBool(elementSlot, changedPrices[i]);
        }
    }
    
    // PoolKeys array - complex, reading entire struct
    function getAuctionPoolKeysLength(AuctionId auctionId) internal view returns (uint256) {
        bytes32 baseSlot = getAuctionInfoBaseSlot(auctionId);
        bytes32 arraySlot = StorageSlots.structFieldSlot(baseSlot, StorageSlots.AUCTION_INFO_FIELD_POOL_KEYS);
        return _sloadArrayLength(arraySlot);
    }

    // ========================================
    // POOL INFO STRUCT FIELD ACCESS
    // ========================================
    
    function getPoolInfoBaseSlot(PoolId poolId) internal pure returns (bytes32) {
        return StorageSlots.mappingSlot(
            StorageSlots.SLOT_POOL_INFO,
            StorageSlots.encodePoolId(poolId)
        );
    }
    
    function getPoolInfoDepositAmount(PoolId poolId) internal view returns (uint256) {
        bytes32 baseSlot = getPoolInfoBaseSlot(poolId);
        bytes32 fieldSlot = StorageSlots.structFieldSlot(baseSlot, StorageSlots.POOL_INFO_FIELD_DEPOSIT_AMOUNT);
        return _sloadUint256(fieldSlot);
    }
    
    function setPoolInfoDepositAmount(PoolId poolId, uint256 depositAmount) internal {
        bytes32 baseSlot = getPoolInfoBaseSlot(poolId);
        bytes32 fieldSlot = StorageSlots.structFieldSlot(baseSlot, StorageSlots.POOL_INFO_FIELD_DEPOSIT_AMOUNT);
        _sstoreUint256(fieldSlot, depositAmount);
    }
    
    function getPoolInfoExcessDemand(PoolId poolId) internal view returns (int256) {
        bytes32 baseSlot = getPoolInfoBaseSlot(poolId);
        bytes32 fieldSlot = StorageSlots.structFieldSlot(baseSlot, StorageSlots.POOL_INFO_FIELD_EXCESS_DEMAND);
        return int256(_sloadUint256(fieldSlot));
    }
    
    function setPoolInfoExcessDemand(PoolId poolId, int256 excessDemand) internal {
        bytes32 baseSlot = getPoolInfoBaseSlot(poolId);
        bytes32 fieldSlot = StorageSlots.structFieldSlot(baseSlot, StorageSlots.POOL_INFO_FIELD_EXCESS_DEMAND);
        _sstore(fieldSlot, bytes32(uint256(excessDemand)));
    }
    
    function getPoolInfoLastOversoldTick(PoolId poolId) internal view returns (int24) {
        bytes32 baseSlot = getPoolInfoBaseSlot(poolId);
        bytes32 fieldSlot = StorageSlots.structFieldSlot(baseSlot, StorageSlots.POOL_INFO_FIELD_LAST_OVERSELL_TICK);
        return int24(uint24(uint256(_sload(fieldSlot))));
    }
    
    function setPoolInfoLastOversoldTick(PoolId poolId, int24 tick) internal {
        bytes32 baseSlot = getPoolInfoBaseSlot(poolId);
        bytes32 fieldSlot = StorageSlots.structFieldSlot(baseSlot, StorageSlots.POOL_INFO_FIELD_LAST_OVERSELL_TICK);
        _sstore(fieldSlot, bytes32(uint256(uint24(tick))));
    }
    
    function getPoolInfoPositionId(PoolId poolId) internal view returns (uint256) {
        bytes32 baseSlot = getPoolInfoBaseSlot(poolId);
        bytes32 fieldSlot = StorageSlots.structFieldSlot(baseSlot, StorageSlots.POOL_INFO_FIELD_POSITION_ID);
        return _sloadUint256(fieldSlot);
    }
    
    function setPoolInfoPositionId(PoolId poolId, uint256 positionId) internal {
        bytes32 baseSlot = getPoolInfoBaseSlot(poolId);
        bytes32 fieldSlot = StorageSlots.structFieldSlot(baseSlot, StorageSlots.POOL_INFO_FIELD_POSITION_ID);
        _sstoreUint256(fieldSlot, positionId);
    }
    
    /**
     * @notice Write full PoolInfo struct (expensive, use field accessors when possible)
     */
    function setPoolInfo(PoolId poolId, AuctionTypes.PoolInfo memory pool) internal {
        bytes32 baseSlot = getPoolInfoBaseSlot(poolId);
        
        // Write PoolKey struct (5 slots)
        bytes32 keySlot = StorageSlots.structFieldSlot(baseSlot, StorageSlots.POOL_INFO_FIELD_KEY);
        _sstore(keySlot, bytes32(uint256(uint160(address(Currency.unwrap(pool.key.currency0))))));
        keySlot = StorageSlots.structFieldSlot(baseSlot, StorageSlots.POOL_INFO_FIELD_KEY + StorageSlots.POOL_KEY_FIELD_CURRENCY1);
        _sstore(keySlot, bytes32(uint256(uint160(address(Currency.unwrap(pool.key.currency1))))));
        keySlot = StorageSlots.structFieldSlot(baseSlot, StorageSlots.POOL_INFO_FIELD_KEY + StorageSlots.POOL_KEY_FIELD_FEE);
        _sstore(keySlot, bytes32(uint256(pool.key.fee)));
        keySlot = StorageSlots.structFieldSlot(baseSlot, StorageSlots.POOL_INFO_FIELD_KEY + StorageSlots.POOL_KEY_FIELD_TICK_SPACING);
        _sstore(keySlot, bytes32(uint256(uint24(pool.key.tickSpacing))));
        keySlot = StorageSlots.structFieldSlot(baseSlot, StorageSlots.POOL_INFO_FIELD_KEY + StorageSlots.POOL_KEY_FIELD_HOOKS);
        _sstore(keySlot, bytes32(uint256(uint160(address(pool.key.hooks)))));
        
        // Write other PoolInfo fields
        bytes32 fieldSlot = StorageSlots.structFieldSlot(baseSlot, StorageSlots.POOL_INFO_FIELD_STARTING_TICK);
        _sstore(fieldSlot, bytes32(uint256(uint24(pool.startingTick))));
        
        fieldSlot = StorageSlots.structFieldSlot(baseSlot, StorageSlots.POOL_INFO_FIELD_PRICE_INCREMENT);
        _sstore(fieldSlot, bytes32(uint256(uint24(pool.priceIncrement))));
        
        setPoolInfoDepositAmount(poolId, pool.depositAmount);
        setPoolInfoExcessDemand(poolId, pool.excessDemand);
        setPoolInfoLastOversoldTick(poolId, pool.lastOversoldTick);
        
        fieldSlot = StorageSlots.structFieldSlot(baseSlot, StorageSlots.POOL_INFO_FIELD_AUCTION_ID);
        _sstore(fieldSlot, AuctionId.unwrap(pool.auctionId));
        
        setPoolInfoPositionId(poolId, pool.positionId);
    }

    // ========================================
    // COMPLEX STRUCT READ FUNCTIONS
    // ========================================
    // Note: Full struct reads are expensive but sometimes necessary.
    // These functions reconstruct structs from storage.
    
    /**
     * @notice Read full PoolInfo struct (expensive, use field accessors when possible)
     */
    function getPoolInfo(PoolId poolId) internal view returns (AuctionTypes.PoolInfo memory) {
        bytes32 baseSlot = getPoolInfoBaseSlot(poolId);
        AuctionTypes.PoolInfo memory pool;
        
        // Read PoolKey struct (5 slots starting at offset 0)
        bytes32 keySlot = StorageSlots.structFieldSlot(baseSlot, StorageSlots.POOL_INFO_FIELD_KEY);
        pool.key.currency0 = Currency.wrap(address(uint160(uint256(_sload(keySlot)))));
        keySlot = StorageSlots.structFieldSlot(baseSlot, StorageSlots.POOL_INFO_FIELD_KEY + StorageSlots.POOL_KEY_FIELD_CURRENCY1);
        pool.key.currency1 = Currency.wrap(address(uint160(uint256(_sload(keySlot)))));
        keySlot = StorageSlots.structFieldSlot(baseSlot, StorageSlots.POOL_INFO_FIELD_KEY + StorageSlots.POOL_KEY_FIELD_FEE);
        pool.key.fee = uint24(uint256(_sload(keySlot)));
        keySlot = StorageSlots.structFieldSlot(baseSlot, StorageSlots.POOL_INFO_FIELD_KEY + StorageSlots.POOL_KEY_FIELD_TICK_SPACING);
        pool.key.tickSpacing = int24(int256(uint256(_sload(keySlot))));
        keySlot = StorageSlots.structFieldSlot(baseSlot, StorageSlots.POOL_INFO_FIELD_KEY + StorageSlots.POOL_KEY_FIELD_HOOKS);
        pool.key.hooks = IHooks(address(uint160(uint256(_sload(keySlot)))));
        
        // Read other PoolInfo fields
        bytes32 fieldSlot = StorageSlots.structFieldSlot(baseSlot, StorageSlots.POOL_INFO_FIELD_STARTING_TICK);
        pool.startingTick = int24(int256(uint256(_sload(fieldSlot))));
        
        fieldSlot = StorageSlots.structFieldSlot(baseSlot, StorageSlots.POOL_INFO_FIELD_PRICE_INCREMENT);
        pool.priceIncrement = int24(int256(uint256(_sload(fieldSlot))));
        
        pool.depositAmount = getPoolInfoDepositAmount(poolId);
        pool.excessDemand = getPoolInfoExcessDemand(poolId);
        pool.lastOversoldTick = getPoolInfoLastOversoldTick(poolId);
        
        fieldSlot = StorageSlots.structFieldSlot(baseSlot, StorageSlots.POOL_INFO_FIELD_AUCTION_ID);
        pool.auctionId = AuctionId.wrap(_sload(fieldSlot));
        
        pool.positionId = getPoolInfoPositionId(poolId);
        
        return pool;
    }
    
    /**
     * @notice Read full AuctionInfo struct (expensive, use field accessors when possible)
     * @dev This reads nested structs and arrays - very gas expensive
     */
    function getAuctionInfo(AuctionId auctionId) internal view returns (AuctionTypes.AuctionInfo memory) {
        bytes32 baseSlot = getAuctionInfoBaseSlot(auctionId);
        AuctionTypes.AuctionInfo memory info;
        
        // Read simple fields
        bytes32 fieldSlot = StorageSlots.structFieldSlot(baseSlot, StorageSlots.AUCTION_INFO_FIELD_AUCTION_OWNER);
        info.auctionOwner = _sloadAddress(fieldSlot);
        
        fieldSlot = StorageSlots.structFieldSlot(baseSlot, StorageSlots.AUCTION_INFO_FIELD_COMMON_NUMERAIRE);
        info.commonNumeraire = _sloadAddress(fieldSlot);
        
        // Read AuctionConfig struct (complex nested struct)
        bytes32 configSlot = StorageSlots.structFieldSlot(baseSlot, StorageSlots.AUCTION_INFO_FIELD_CONFIG);
        fieldSlot = StorageSlots.structFieldSlot(configSlot, StorageSlots.CONFIG_FIELD_COMMON_NUMERAIRE);
        info.config.commonNumeraire = _sloadAddress(fieldSlot);
        
        fieldSlot = StorageSlots.structFieldSlot(configSlot, StorageSlots.CONFIG_FIELD_MIN_SPEND_RATIO);
        info.config.minSpendRatio = _sloadUint256(fieldSlot);
        
        fieldSlot = StorageSlots.structFieldSlot(configSlot, StorageSlots.CONFIG_FIELD_DROPOUT_SLASH_RATIO);
        info.config.dropoutSlashRatio = _sloadUint256(fieldSlot);
        
        fieldSlot = StorageSlots.structFieldSlot(configSlot, StorageSlots.CONFIG_FIELD_SPENDING_VIOLATION_SLASH_RATIO);
        info.config.spendingViolationSlashRatio = _sloadUint256(fieldSlot);
        
        fieldSlot = StorageSlots.structFieldSlot(configSlot, StorageSlots.CONFIG_FIELD_MAX_ROUNDS);
        info.config.maxRounds = _sloadUint256(fieldSlot);
        
        fieldSlot = StorageSlots.structFieldSlot(configSlot, StorageSlots.CONFIG_FIELD_ALLOCATOR_REWARD_PCT);
        info.config.allocatorRewardPct = _sloadUint256(fieldSlot);
        
        // Read config arrays
        bytes32 arraySlot = StorageSlots.structFieldSlot(configSlot, StorageSlots.CONFIG_FIELD_PHASE_DURATIONS);
        uint256 arrayLength = _sloadArrayLength(arraySlot);
        info.config.phaseDurations = new uint256[](arrayLength);
        for (uint256 i = 0; i < arrayLength; i++) {
            bytes32 elementSlot = StorageSlots.arrayElementSlot(arraySlot, i);
            info.config.phaseDurations[i] = _sloadUint256(elementSlot);
        }
        
        arraySlot = StorageSlots.structFieldSlot(configSlot, StorageSlots.CONFIG_FIELD_POOL_KEYS);
        arrayLength = _sloadArrayLength(arraySlot);
        info.config.poolKeys = new PoolKey[](arrayLength);
        for (uint256 i = 0; i < arrayLength; i++) {
            bytes32 elementBaseSlot = StorageSlots.arrayElementSlot(arraySlot, i);
            // Each PoolKey is 5 slots
            info.config.poolKeys[i].currency0 = Currency.wrap(address(uint160(uint256(_sload(elementBaseSlot)))));
            elementBaseSlot = StorageSlots.structFieldSlot(elementBaseSlot, StorageSlots.POOL_KEY_FIELD_CURRENCY1);
            info.config.poolKeys[i].currency1 = Currency.wrap(address(uint160(uint256(_sload(elementBaseSlot)))));
            elementBaseSlot = StorageSlots.structFieldSlot(elementBaseSlot, StorageSlots.POOL_KEY_FIELD_FEE);
            info.config.poolKeys[i].fee = uint24(uint256(_sload(elementBaseSlot)));
            elementBaseSlot = StorageSlots.structFieldSlot(elementBaseSlot, StorageSlots.POOL_KEY_FIELD_TICK_SPACING);
            info.config.poolKeys[i].tickSpacing = int24(int256(uint256(_sload(elementBaseSlot))));
            elementBaseSlot = StorageSlots.structFieldSlot(elementBaseSlot, StorageSlots.POOL_KEY_FIELD_HOOKS);
            info.config.poolKeys[i].hooks = IHooks(address(uint160(uint256(_sload(elementBaseSlot)))));
        }
        
        arraySlot = StorageSlots.structFieldSlot(configSlot, StorageSlots.CONFIG_FIELD_INITIAL_SQRT_PRICES_X96);
        arrayLength = _sloadArrayLength(arraySlot);
        info.config.initialSqrtPricesX96 = new uint160[](arrayLength);
        for (uint256 i = 0; i < arrayLength; i++) {
            bytes32 elementSlot = StorageSlots.arrayElementSlot(arraySlot, i);
            info.config.initialSqrtPricesX96[i] = uint160(uint256(_sload(elementSlot)));
        }
        
        arraySlot = StorageSlots.structFieldSlot(configSlot, StorageSlots.CONFIG_FIELD_PRICE_INCREMENTS);
        arrayLength = _sloadArrayLength(arraySlot);
        info.config.priceIncrements = new int24[](arrayLength);
        for (uint256 i = 0; i < arrayLength; i++) {
            bytes32 elementSlot = StorageSlots.arrayElementSlot(arraySlot, i);
            info.config.priceIncrements[i] = int24(int256(uint256(_sload(elementSlot))));
        }
        
        // Read remaining AuctionInfo fields
        fieldSlot = StorageSlots.structFieldSlot(baseSlot, StorageSlots.AUCTION_INFO_FIELD_CURRENT_PHASE);
        info.currentPhase = AuctionTypes.AuctionPhase(uint8(uint256(_sload(fieldSlot))));
        
        fieldSlot = StorageSlots.structFieldSlot(baseSlot, StorageSlots.AUCTION_INFO_FIELD_CURRENT_STATUS);
        info.currentStatus = AuctionTypes.AuctionStatus(uint8(uint256(_sload(fieldSlot))));
        
        info.clockOpen = getAuctionClockOpen(auctionId);
        info.currentRound = getAuctionCurrentRound(auctionId);
        
        // Read poolKeys array (different from config.poolKeys)
        arraySlot = StorageSlots.structFieldSlot(baseSlot, StorageSlots.AUCTION_INFO_FIELD_POOL_KEYS);
        arrayLength = _sloadArrayLength(arraySlot);
        info.poolKeys = new PoolKey[](arrayLength);
        for (uint256 i = 0; i < arrayLength; i++) {
            bytes32 elementBaseSlot = StorageSlots.arrayElementSlot(arraySlot, i);
            info.poolKeys[i].currency0 = Currency.wrap(address(uint160(uint256(_sload(elementBaseSlot)))));
            elementBaseSlot = StorageSlots.structFieldSlot(elementBaseSlot, StorageSlots.POOL_KEY_FIELD_CURRENCY1);
            info.poolKeys[i].currency1 = Currency.wrap(address(uint160(uint256(_sload(elementBaseSlot)))));
            elementBaseSlot = StorageSlots.structFieldSlot(elementBaseSlot, StorageSlots.POOL_KEY_FIELD_FEE);
            info.poolKeys[i].fee = uint24(uint256(_sload(elementBaseSlot)));
            elementBaseSlot = StorageSlots.structFieldSlot(elementBaseSlot, StorageSlots.POOL_KEY_FIELD_TICK_SPACING);
            info.poolKeys[i].tickSpacing = int24(int256(uint256(_sload(elementBaseSlot))));
            elementBaseSlot = StorageSlots.structFieldSlot(elementBaseSlot, StorageSlots.POOL_KEY_FIELD_HOOKS);
            info.poolKeys[i].hooks = IHooks(address(uint160(uint256(_sload(elementBaseSlot)))));
        }
        
        info.allocatorReward = getAuctionAllocatorReward(auctionId);
        
        // Read changedPrices array
        arraySlot = StorageSlots.structFieldSlot(baseSlot, StorageSlots.AUCTION_INFO_FIELD_CHANGED_PRICES);
        arrayLength = _sloadArrayLength(arraySlot);
        info.changedPrices = new bool[](arrayLength);
        for (uint256 i = 0; i < arrayLength; i++) {
            bytes32 elementSlot = StorageSlots.arrayElementSlot(arraySlot, i);
            info.changedPrices[i] = _sloadBool(elementSlot);
        }
        
        info.lastRevenue = getAuctionLastRevenue(auctionId);
        
        fieldSlot = StorageSlots.structFieldSlot(baseSlot, StorageSlots.AUCTION_INFO_FIELD_TOTAL_PAUSE_DURATION);
        info.totalPauseDuration = _sloadUint256(fieldSlot);
        
        return info;
    }
    
    /**
     * @notice Write full AuctionInfo struct (very expensive, use field accessors when possible)
     */
    function setAuctionInfo(AuctionId auctionId, AuctionTypes.AuctionInfo memory info) internal {
        bytes32 baseSlot = getAuctionInfoBaseSlot(auctionId);
        
        // Write simple fields
        bytes32 fieldSlot = StorageSlots.structFieldSlot(baseSlot, StorageSlots.AUCTION_INFO_FIELD_AUCTION_OWNER);
        _sstoreAddress(fieldSlot, info.auctionOwner);
        
        fieldSlot = StorageSlots.structFieldSlot(baseSlot, StorageSlots.AUCTION_INFO_FIELD_COMMON_NUMERAIRE);
        _sstoreAddress(fieldSlot, info.commonNumeraire);
        
        // Write AuctionConfig struct
        bytes32 configSlot = StorageSlots.structFieldSlot(baseSlot, StorageSlots.AUCTION_INFO_FIELD_CONFIG);
        fieldSlot = StorageSlots.structFieldSlot(configSlot, StorageSlots.CONFIG_FIELD_COMMON_NUMERAIRE);
        _sstoreAddress(fieldSlot, info.config.commonNumeraire);
        
        fieldSlot = StorageSlots.structFieldSlot(configSlot, StorageSlots.CONFIG_FIELD_MIN_SPEND_RATIO);
        _sstoreUint256(fieldSlot, info.config.minSpendRatio);
        
        fieldSlot = StorageSlots.structFieldSlot(configSlot, StorageSlots.CONFIG_FIELD_DROPOUT_SLASH_RATIO);
        _sstoreUint256(fieldSlot, info.config.dropoutSlashRatio);
        
        fieldSlot = StorageSlots.structFieldSlot(configSlot, StorageSlots.CONFIG_FIELD_SPENDING_VIOLATION_SLASH_RATIO);
        _sstoreUint256(fieldSlot, info.config.spendingViolationSlashRatio);
        
        fieldSlot = StorageSlots.structFieldSlot(configSlot, StorageSlots.CONFIG_FIELD_MAX_ROUNDS);
        _sstoreUint256(fieldSlot, info.config.maxRounds);
        
        fieldSlot = StorageSlots.structFieldSlot(configSlot, StorageSlots.CONFIG_FIELD_ALLOCATOR_REWARD_PCT);
        _sstoreUint256(fieldSlot, info.config.allocatorRewardPct);
        
        // Write config arrays
        bytes32 arraySlot = StorageSlots.structFieldSlot(configSlot, StorageSlots.CONFIG_FIELD_PHASE_DURATIONS);
        uint256 oldLength = _sloadArrayLength(arraySlot);
        for (uint256 i = 0; i < oldLength; i++) {
            bytes32 elementSlot = StorageSlots.arrayElementSlot(arraySlot, i);
            _sstore(elementSlot, bytes32(0));
        }
        _sstoreArrayLength(arraySlot, info.config.phaseDurations.length);
        for (uint256 i = 0; i < info.config.phaseDurations.length; i++) {
            bytes32 elementSlot = StorageSlots.arrayElementSlot(arraySlot, i);
            _sstoreUint256(elementSlot, info.config.phaseDurations[i]);
        }
        
        arraySlot = StorageSlots.structFieldSlot(configSlot, StorageSlots.CONFIG_FIELD_POOL_KEYS);
        oldLength = _sloadArrayLength(arraySlot);
        // Clear old PoolKeys (5 slots each)
        for (uint256 i = 0; i < oldLength; i++) {
            bytes32 elementBaseSlot = StorageSlots.arrayElementSlot(arraySlot, i);
            for (uint256 j = 0; j < 5; j++) {
                bytes32 elementSlot = StorageSlots.structFieldSlot(elementBaseSlot, j);
                _sstore(elementSlot, bytes32(0));
            }
        }
        _sstoreArrayLength(arraySlot, info.config.poolKeys.length);
        for (uint256 i = 0; i < info.config.poolKeys.length; i++) {
            bytes32 elementBaseSlot = StorageSlots.arrayElementSlot(arraySlot, i);
            _sstore(elementBaseSlot, bytes32(uint256(uint160(address(Currency.unwrap(info.config.poolKeys[i].currency0))))));
            elementBaseSlot = StorageSlots.structFieldSlot(elementBaseSlot, StorageSlots.POOL_KEY_FIELD_CURRENCY1);
            _sstore(elementBaseSlot, bytes32(uint256(uint160(address(Currency.unwrap(info.config.poolKeys[i].currency1))))));
            elementBaseSlot = StorageSlots.structFieldSlot(elementBaseSlot, StorageSlots.POOL_KEY_FIELD_FEE);
            _sstore(elementBaseSlot, bytes32(uint256(info.config.poolKeys[i].fee)));
            elementBaseSlot = StorageSlots.structFieldSlot(elementBaseSlot, StorageSlots.POOL_KEY_FIELD_TICK_SPACING);
            _sstore(elementBaseSlot, bytes32(uint256(uint24(info.config.poolKeys[i].tickSpacing))));
            elementBaseSlot = StorageSlots.structFieldSlot(elementBaseSlot, StorageSlots.POOL_KEY_FIELD_HOOKS);
            _sstore(elementBaseSlot, bytes32(uint256(uint160(address(info.config.poolKeys[i].hooks)))));
        }
        
        arraySlot = StorageSlots.structFieldSlot(configSlot, StorageSlots.CONFIG_FIELD_INITIAL_SQRT_PRICES_X96);
        oldLength = _sloadArrayLength(arraySlot);
        for (uint256 i = 0; i < oldLength; i++) {
            bytes32 elementSlot = StorageSlots.arrayElementSlot(arraySlot, i);
            _sstore(elementSlot, bytes32(0));
        }
        _sstoreArrayLength(arraySlot, info.config.initialSqrtPricesX96.length);
        for (uint256 i = 0; i < info.config.initialSqrtPricesX96.length; i++) {
            bytes32 elementSlot = StorageSlots.arrayElementSlot(arraySlot, i);
            _sstore(elementSlot, bytes32(uint256(info.config.initialSqrtPricesX96[i])));
        }
        
        arraySlot = StorageSlots.structFieldSlot(configSlot, StorageSlots.CONFIG_FIELD_PRICE_INCREMENTS);
        oldLength = _sloadArrayLength(arraySlot);
        for (uint256 i = 0; i < oldLength; i++) {
            bytes32 elementSlot = StorageSlots.arrayElementSlot(arraySlot, i);
            _sstore(elementSlot, bytes32(0));
        }
        _sstoreArrayLength(arraySlot, info.config.priceIncrements.length);
        for (uint256 i = 0; i < info.config.priceIncrements.length; i++) {
            bytes32 elementSlot = StorageSlots.arrayElementSlot(arraySlot, i);
            _sstore(elementSlot, bytes32(uint256(uint24(info.config.priceIncrements[i]))));
        }
        
        // Write remaining AuctionInfo fields
        fieldSlot = StorageSlots.structFieldSlot(baseSlot, StorageSlots.AUCTION_INFO_FIELD_CURRENT_PHASE);
        _sstore(fieldSlot, bytes32(uint256(uint8(info.currentPhase))));
        
        fieldSlot = StorageSlots.structFieldSlot(baseSlot, StorageSlots.AUCTION_INFO_FIELD_CURRENT_STATUS);
        _sstore(fieldSlot, bytes32(uint256(uint8(info.currentStatus))));
        
        setAuctionClockOpen(auctionId, uint8(info.clockOpen));
        setAuctionCurrentRound(auctionId, info.currentRound);
        
        // Write poolKeys array
        arraySlot = StorageSlots.structFieldSlot(baseSlot, StorageSlots.AUCTION_INFO_FIELD_POOL_KEYS);
        oldLength = _sloadArrayLength(arraySlot);
        for (uint256 i = 0; i < oldLength; i++) {
            bytes32 elementBaseSlot = StorageSlots.arrayElementSlot(arraySlot, i);
            for (uint256 j = 0; j < 5; j++) {
                bytes32 elementSlot = StorageSlots.structFieldSlot(elementBaseSlot, j);
                _sstore(elementSlot, bytes32(0));
            }
        }
        _sstoreArrayLength(arraySlot, info.poolKeys.length);
        for (uint256 i = 0; i < info.poolKeys.length; i++) {
            bytes32 elementBaseSlot = StorageSlots.arrayElementSlot(arraySlot, i);
            _sstore(elementBaseSlot, bytes32(uint256(uint160(address(Currency.unwrap(info.poolKeys[i].currency0))))));
            elementBaseSlot = StorageSlots.structFieldSlot(elementBaseSlot, StorageSlots.POOL_KEY_FIELD_CURRENCY1);
            _sstore(elementBaseSlot, bytes32(uint256(uint160(address(Currency.unwrap(info.poolKeys[i].currency1))))));
            elementBaseSlot = StorageSlots.structFieldSlot(elementBaseSlot, StorageSlots.POOL_KEY_FIELD_FEE);
            _sstore(elementBaseSlot, bytes32(uint256(info.poolKeys[i].fee)));
            elementBaseSlot = StorageSlots.structFieldSlot(elementBaseSlot, StorageSlots.POOL_KEY_FIELD_TICK_SPACING);
            _sstore(elementBaseSlot, bytes32(uint256(uint24(info.poolKeys[i].tickSpacing))));
            elementBaseSlot = StorageSlots.structFieldSlot(elementBaseSlot, StorageSlots.POOL_KEY_FIELD_HOOKS);
            _sstore(elementBaseSlot, bytes32(uint256(uint160(address(info.poolKeys[i].hooks)))));
        }
        
        setAuctionAllocatorReward(auctionId, info.allocatorReward);
        setChangedPrices(auctionId, info.changedPrices);
        setAuctionLastRevenue(auctionId, info.lastRevenue);
        
        fieldSlot = StorageSlots.structFieldSlot(baseSlot, StorageSlots.AUCTION_INFO_FIELD_TOTAL_PAUSE_DURATION);
        _sstoreUint256(fieldSlot, info.totalPauseDuration);
    }
    
    // ========================================
    // TOP ALLOCATION OPERATIONS
    // ========================================
    
    function getTopAllocationBaseSlot(AuctionId auctionId) internal pure returns (bytes32) {
        return StorageSlots.mappingSlot(
            StorageSlots.SLOT_TOP_ALLOCATION,
            StorageSlots.encodeAuctionId(auctionId)
        );
    }
    
    function getTopAllocation(AuctionId auctionId) internal view returns (AuctionTypes.TopAllocation memory) {
        bytes32 baseSlot = getTopAllocationBaseSlot(auctionId);
        AuctionTypes.TopAllocation memory top;
        
        // Read Allocation struct (nested within TopAllocation)
        bytes32 allocSlot = StorageSlots.structFieldSlot(baseSlot, StorageSlots.TOP_ALLOCATION_FIELD_ALLOCATION);
        top.allocation.auctionId = AuctionId.wrap(_sload(StorageSlots.structFieldSlot(allocSlot, StorageSlots.ALLOCATION_FIELD_AUCTION_ID)));
        top.allocation.allocator = _sloadAddress(StorageSlots.structFieldSlot(allocSlot, StorageSlots.ALLOCATION_FIELD_ALLOCATOR));
        
        // Read bundleIds array
        bytes32 bundleIdsSlot = StorageSlots.structFieldSlot(allocSlot, StorageSlots.ALLOCATION_FIELD_BUNDLE_IDS);
        uint256 bundleIdsLength = _sloadArrayLength(bundleIdsSlot);
        top.allocation.bundleIds = new BundleId[](bundleIdsLength);
        for (uint256 i = 0; i < bundleIdsLength; i++) {
            bytes32 elementSlot = StorageSlots.arrayElementSlot(bundleIdsSlot, i);
            top.allocation.bundleIds[i] = BundleId.wrap(_sload(elementSlot));
        }
        
        top.allocation.totalValue = _sloadUint256(StorageSlots.structFieldSlot(allocSlot, StorageSlots.ALLOCATION_FIELD_TOTAL_VALUE));
        top.allocation.timestamp = _sloadUint256(StorageSlots.structFieldSlot(allocSlot, StorageSlots.ALLOCATION_FIELD_TIMESTAMP));
        
        // Read TopAllocation fields
        top.score = _sloadUint256(StorageSlots.structFieldSlot(baseSlot, StorageSlots.TOP_ALLOCATION_FIELD_SCORE));
        top.totalValue = _sloadUint256(StorageSlots.structFieldSlot(baseSlot, StorageSlots.TOP_ALLOCATION_FIELD_TOTAL_VALUE));
        
        return top;
    }
    
    function setTopAllocation(AuctionId auctionId, AuctionTypes.TopAllocation memory top) internal {
        bytes32 baseSlot = getTopAllocationBaseSlot(auctionId);
        
        // Write Allocation struct
        bytes32 allocSlot = StorageSlots.structFieldSlot(baseSlot, StorageSlots.TOP_ALLOCATION_FIELD_ALLOCATION);
        _sstore(StorageSlots.structFieldSlot(allocSlot, StorageSlots.ALLOCATION_FIELD_AUCTION_ID), AuctionId.unwrap(top.allocation.auctionId));
        _sstoreAddress(StorageSlots.structFieldSlot(allocSlot, StorageSlots.ALLOCATION_FIELD_ALLOCATOR), top.allocation.allocator);
        
        // Write bundleIds array
        bytes32 bundleIdsSlot = StorageSlots.structFieldSlot(allocSlot, StorageSlots.ALLOCATION_FIELD_BUNDLE_IDS);
        uint256 oldLength = _sloadArrayLength(bundleIdsSlot);
        for (uint256 i = 0; i < oldLength; i++) {
            bytes32 elementSlot = StorageSlots.arrayElementSlot(bundleIdsSlot, i);
            _sstore(elementSlot, bytes32(0));
        }
        _sstoreArrayLength(bundleIdsSlot, top.allocation.bundleIds.length);
        for (uint256 i = 0; i < top.allocation.bundleIds.length; i++) {
            bytes32 elementSlot = StorageSlots.arrayElementSlot(bundleIdsSlot, i);
            _sstore(elementSlot, BundleId.unwrap(top.allocation.bundleIds[i]));
        }
        
        _sstoreUint256(StorageSlots.structFieldSlot(allocSlot, StorageSlots.ALLOCATION_FIELD_TOTAL_VALUE), top.allocation.totalValue);
        _sstoreUint256(StorageSlots.structFieldSlot(allocSlot, StorageSlots.ALLOCATION_FIELD_TIMESTAMP), top.allocation.timestamp);
        
        // Write TopAllocation fields
        _sstoreUint256(StorageSlots.structFieldSlot(baseSlot, StorageSlots.TOP_ALLOCATION_FIELD_SCORE), top.score);
        _sstoreUint256(StorageSlots.structFieldSlot(baseSlot, StorageSlots.TOP_ALLOCATION_FIELD_TOTAL_VALUE), top.totalValue);
    }
    
    function updateTopAllocation(AuctionId auctionId, AuctionTypes.Allocation calldata allocation, uint256 score, uint256 totalValue) internal {
        bytes32 baseSlot = getTopAllocationBaseSlot(auctionId);
        bytes32 allocSlot = StorageSlots.structFieldSlot(baseSlot, StorageSlots.TOP_ALLOCATION_FIELD_ALLOCATION);
        
        // Update Allocation struct fields
        _sstore(StorageSlots.structFieldSlot(allocSlot, StorageSlots.ALLOCATION_FIELD_AUCTION_ID), AuctionId.unwrap(allocation.auctionId));
        _sstoreAddress(StorageSlots.structFieldSlot(allocSlot, StorageSlots.ALLOCATION_FIELD_ALLOCATOR), allocation.allocator);
        
        // Update bundleIds array
        bytes32 bundleIdsSlot = StorageSlots.structFieldSlot(allocSlot, StorageSlots.ALLOCATION_FIELD_BUNDLE_IDS);
        uint256 oldLength = _sloadArrayLength(bundleIdsSlot);
        for (uint256 i = 0; i < oldLength; i++) {
            bytes32 elementSlot = StorageSlots.arrayElementSlot(bundleIdsSlot, i);
            _sstore(elementSlot, bytes32(0));
        }
        _sstoreArrayLength(bundleIdsSlot, allocation.bundleIds.length);
        for (uint256 i = 0; i < allocation.bundleIds.length; i++) {
            bytes32 elementSlot = StorageSlots.arrayElementSlot(bundleIdsSlot, i);
            _sstore(elementSlot, BundleId.unwrap(allocation.bundleIds[i]));
        }
        
        _sstoreUint256(StorageSlots.structFieldSlot(allocSlot, StorageSlots.ALLOCATION_FIELD_TOTAL_VALUE), allocation.totalValue);
        _sstoreUint256(StorageSlots.structFieldSlot(allocSlot, StorageSlots.ALLOCATION_FIELD_TIMESTAMP), allocation.timestamp);
        
        // Update TopAllocation fields
        _sstoreUint256(StorageSlots.structFieldSlot(baseSlot, StorageSlots.TOP_ALLOCATION_FIELD_SCORE), score);
        _sstoreUint256(StorageSlots.structFieldSlot(baseSlot, StorageSlots.TOP_ALLOCATION_FIELD_TOTAL_VALUE), totalValue);
    }
    
    // ========================================
    // BUNDLE OPERATIONS
    // ========================================
    
    function getBundleBaseSlot(AuctionId auctionId, BundleId bundleId) internal pure returns (bytes32) {
        return StorageSlots.nestedMappingSlot(
            StorageSlots.SLOT_BUNDLES,
            StorageSlots.encodeAuctionId(auctionId),
            StorageSlots.encodeBundleId(bundleId)
        );
    }
    
    function getBundle(AuctionId auctionId, BundleId bundleId) internal view returns (AuctionTypes.Bundle memory) {
        bytes32 baseSlot = getBundleBaseSlot(auctionId, bundleId);
        AuctionTypes.Bundle memory bundle;
        
        bundle.auctionId = AuctionId.wrap(_sload(StorageSlots.structFieldSlot(baseSlot, StorageSlots.BUNDLE_FIELD_AUCTION_ID)));
        bundle.commitHash = _sload(StorageSlots.structFieldSlot(baseSlot, StorageSlots.BUNDLE_FIELD_COMMIT_HASH));
        bundle.value = _sloadUint256(StorageSlots.structFieldSlot(baseSlot, StorageSlots.BUNDLE_FIELD_VALUE));
        
        // Read quantities array
        bytes32 quantitiesSlot = StorageSlots.structFieldSlot(baseSlot, StorageSlots.BUNDLE_FIELD_QUANTITIES);
        uint256 quantitiesLength = _sloadArrayLength(quantitiesSlot);
        bundle.quantities = new uint256[](quantitiesLength);
        for (uint256 i = 0; i < quantitiesLength; i++) {
            bytes32 elementSlot = StorageSlots.arrayElementSlot(quantitiesSlot, i);
            bundle.quantities[i] = _sloadUint256(elementSlot);
        }
        
        bundle.timestamp = _sloadUint256(StorageSlots.structFieldSlot(baseSlot, StorageSlots.BUNDLE_FIELD_TIMESTAMP));
        
        return bundle;
    }
    
    function setBundle(AuctionId auctionId, BundleId bundleId, AuctionTypes.Bundle memory bundle) internal {
        bytes32 baseSlot = getBundleBaseSlot(auctionId, bundleId);
        
        _sstore(StorageSlots.structFieldSlot(baseSlot, StorageSlots.BUNDLE_FIELD_AUCTION_ID), AuctionId.unwrap(bundle.auctionId));
        _sstore(StorageSlots.structFieldSlot(baseSlot, StorageSlots.BUNDLE_FIELD_COMMIT_HASH), bundle.commitHash);
        _sstoreUint256(StorageSlots.structFieldSlot(baseSlot, StorageSlots.BUNDLE_FIELD_VALUE), bundle.value);
        
        // Write quantities array
        bytes32 quantitiesSlot = StorageSlots.structFieldSlot(baseSlot, StorageSlots.BUNDLE_FIELD_QUANTITIES);
        uint256 oldLength = _sloadArrayLength(quantitiesSlot);
        for (uint256 i = 0; i < oldLength; i++) {
            bytes32 elementSlot = StorageSlots.arrayElementSlot(quantitiesSlot, i);
            _sstore(elementSlot, bytes32(0));
        }
        _sstoreArrayLength(quantitiesSlot, bundle.quantities.length);
        for (uint256 i = 0; i < bundle.quantities.length; i++) {
            bytes32 elementSlot = StorageSlots.arrayElementSlot(quantitiesSlot, i);
            _sstoreUint256(elementSlot, bundle.quantities[i]);
        }
        
        _sstoreUint256(StorageSlots.structFieldSlot(baseSlot, StorageSlots.BUNDLE_FIELD_TIMESTAMP), bundle.timestamp);
    }
    
    // DroppedBidders (nested mapping: AuctionId -> address -> bool)
    function getDroppedBidder(AuctionId auctionId, address bidder) internal view returns (bool) {
        bytes32 slot = StorageSlots.nestedMappingSlot(
            StorageSlots.SLOT_DROPPED_BIDDERS,
            StorageSlots.encodeAuctionId(auctionId),
            StorageSlots.encodeAddress(bidder)
        );
        return _sloadBool(slot);
    }
    
    function setDroppedBidder(AuctionId auctionId, address bidder, bool value) internal {
        bytes32 slot = StorageSlots.nestedMappingSlot(
            StorageSlots.SLOT_DROPPED_BIDDERS,
            StorageSlots.encodeAuctionId(auctionId),
            StorageSlots.encodeAddress(bidder)
        );
        _sstoreBool(slot, value);
    }
    
    // CpaAuctionHookAddr (simple storage variable)
    function getCpaAuctionHookAddr() internal view returns (address) {
        return _sloadAddress(bytes32(uint256(StorageSlots.SLOT_CPA_AUCTION_HOOK_ADDR)));
    }
    
    function setCpaAuctionHookAddr(address hookAddr) internal {
        _sstoreAddress(bytes32(uint256(StorageSlots.SLOT_CPA_AUCTION_HOOK_ADDR)), hookAddr);
    }
}


