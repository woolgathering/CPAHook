// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { AuctionId } from "../types/AuctionId.sol";
import { PoolId } from "@uniswap/v4-core/src/types/PoolId.sol";
import { BundleId } from "../types/BundleId.sol";

/**
 * @title StorageSlots
 * @notice Library for calculating storage slot positions in CPAStorage
 * @dev Used for assembly-based direct storage access to reduce bytecode size
 */
library StorageSlots {
    // ========================================
    // BASE STORAGE SLOT CONSTANTS
    // ========================================
    uint256 constant SLOT_COMMIT_PROXY = 0;
    uint256 constant SLOT_POOL_TO_AUCTION_ID = 1;
    uint256 constant SLOT_AUCTION_INFO = 2;
    uint256 constant SLOT_POOL_INFO = 3;
    uint256 constant SLOT_PAUSE_START_TIME = 4;
    uint256 constant SLOT_CURRENT_PRICES = 5;
    uint256 constant SLOT_CPA_AUCTION_HOOK_ADDR = 6;
    uint256 constant SLOT_DROPPED_BIDDERS = 7;
    uint256 constant SLOT_BIDDER_STAKE = 8;
    uint256 constant SLOT_BIDDER_BID_POINTS = 9;
    uint256 constant SLOT_BIDS = 10;
    uint256 constant SLOT_ACTIVE_BIDDERS = 11;
    uint256 constant SLOT_BUNDLES = 12;
    uint256 constant SLOT_PROXY_PHASE_START_TIME = 13;
    uint256 constant SLOT_ALLOCATION_PHASE_START_TIME = 14;
    uint256 constant SLOT_SETTLEMENT_PHASE_START_TIME = 15;
    uint256 constant SLOT_HAS_BUNDLES = 16;
    uint256 constant SLOT_HAS_ALLOCATIONS = 17;
    uint256 constant SLOT_PROTOCOL_PENALTIES = 18;
    uint256 constant SLOT_TOP_ALLOCATION = 19;
    uint256 constant SLOT_WINNING_BUNDLE_IDS = 20;
    uint256 constant SLOT_REVEALED_MAPPINGS = 21;

    // ========================================
    // STRUCT FIELD OFFSETS
    // ========================================
    
    // PoolInfo struct field offsets (from base slot)
    uint256 constant POOL_INFO_FIELD_KEY = 0;              // PoolKey struct (takes multiple slots, ~5)
    uint256 constant POOL_INFO_FIELD_STARTING_TICK = 5;    // int24 (but takes full slot)
    uint256 constant POOL_INFO_FIELD_PRICE_INCREMENT = 6;  // int24 (but takes full slot)
    uint256 constant POOL_INFO_FIELD_DEPOSIT_AMOUNT = 7;   // uint256
    uint256 constant POOL_INFO_FIELD_EXCESS_DEMAND = 8;    // int256
    uint256 constant POOL_INFO_FIELD_LAST_OVERSELL_TICK = 9; // int24 (but takes full slot)
    uint256 constant POOL_INFO_FIELD_AUCTION_ID = 10;      // AuctionId (bytes32)
    uint256 constant POOL_INFO_FIELD_POSITION_ID = 11;     // uint256
    
    // PoolKey struct field offsets (within PoolInfo)
    uint256 constant POOL_KEY_FIELD_CURRENCY0 = 0;         // Currency (address, takes full slot)
    uint256 constant POOL_KEY_FIELD_CURRENCY1 = 1;         // Currency (address, takes full slot)
    uint256 constant POOL_KEY_FIELD_FEE = 2;               // uint24 (but takes full slot due to alignment)
    uint256 constant POOL_KEY_FIELD_TICK_SPACING = 3;      // int24 (but takes full slot)
    uint256 constant POOL_KEY_FIELD_HOOKS = 4;             // IHooks (address, takes full slot)
    
    // AuctionInfo struct field offsets (from base slot)
    uint256 constant AUCTION_INFO_FIELD_AUCTION_OWNER = 0;        // address
    uint256 constant AUCTION_INFO_FIELD_COMMON_NUMERAIRE = 1;     // address
    uint256 constant AUCTION_INFO_FIELD_CONFIG = 2;               // AuctionConfig struct (starts here, takes ~10 slots)
    uint256 constant AUCTION_INFO_FIELD_CURRENT_PHASE = 12;       // AuctionPhase (enum, uint8 but takes full slot)
    uint256 constant AUCTION_INFO_FIELD_CURRENT_STATUS = 13;      // AuctionStatus (enum, uint8 but takes full slot)
    uint256 constant AUCTION_INFO_FIELD_CLOCK_OPEN = 14;          // uint256
    uint256 constant AUCTION_INFO_FIELD_CURRENT_ROUND = 15;       // uint256
    uint256 constant AUCTION_INFO_FIELD_POOL_KEYS = 16;           // PoolKey[] (array length at this slot)
    uint256 constant AUCTION_INFO_FIELD_ALLOCATOR_REWARD = 17;    // uint256
    uint256 constant AUCTION_INFO_FIELD_CHANGED_PRICES = 18;      // bool[] (array length at this slot)
    uint256 constant AUCTION_INFO_FIELD_LAST_REVENUE = 19;        // uint256
    uint256 constant AUCTION_INFO_FIELD_TOTAL_PAUSE_DURATION = 20; // uint256
    
    // AuctionConfig struct field offsets (within AuctionInfo, from config field)
    uint256 constant CONFIG_FIELD_COMMON_NUMERAIRE = 0;           // address
    uint256 constant CONFIG_FIELD_MIN_SPEND_RATIO = 1;            // uint256
    uint256 constant CONFIG_FIELD_DROPOUT_SLASH_RATIO = 2;        // uint256
    uint256 constant CONFIG_FIELD_SPENDING_VIOLATION_SLASH_RATIO = 3; // uint256
    uint256 constant CONFIG_FIELD_MAX_ROUNDS = 4;                 // uint256
    uint256 constant CONFIG_FIELD_ALLOCATOR_REWARD_PCT = 5;       // uint256
    uint256 constant CONFIG_FIELD_PHASE_DURATIONS = 6;            // uint256[] (array length)
    uint256 constant CONFIG_FIELD_POOL_KEYS = 7;                  // PoolKey[] (array length)
    uint256 constant CONFIG_FIELD_INITIAL_SQRT_PRICES_X96 = 8;    // uint160[] (array length)
    uint256 constant CONFIG_FIELD_PRICE_INCREMENTS = 9;           // int24[] (array length)
    
    // Bundle struct field offsets (from base slot)
    uint256 constant BUNDLE_FIELD_AUCTION_ID = 0;         // AuctionId (bytes32)
    uint256 constant BUNDLE_FIELD_COMMIT_HASH = 1;        // bytes32
    uint256 constant BUNDLE_FIELD_VALUE = 2;              // uint256
    uint256 constant BUNDLE_FIELD_QUANTITIES = 3;         // uint256[] (array length)
    uint256 constant BUNDLE_FIELD_TIMESTAMP = 4;          // uint256
    
    // TopAllocation struct field offsets (from base slot)
    uint256 constant TOP_ALLOCATION_FIELD_ALLOCATION = 0; // Allocation struct (starts here, takes ~5 slots)
    uint256 constant TOP_ALLOCATION_FIELD_SCORE = 5;      // uint256
    uint256 constant TOP_ALLOCATION_FIELD_TOTAL_VALUE = 6; // uint256
    
    // Allocation struct field offsets (within TopAllocation)
    uint256 constant ALLOCATION_FIELD_AUCTION_ID = 0;     // AuctionId (bytes32)
    uint256 constant ALLOCATION_FIELD_ALLOCATOR = 1;      // address
    uint256 constant ALLOCATION_FIELD_BUNDLE_IDS = 2;     // BundleId[] (array length)
    uint256 constant ALLOCATION_FIELD_TOTAL_VALUE = 3;    // uint256
    uint256 constant ALLOCATION_FIELD_TIMESTAMP = 4;      // uint256

    // ========================================
    // STORAGE SLOT CALCULATION FUNCTIONS
    // ========================================
    
    /**
     * @notice Calculate slot for a simple mapping value
     * @param baseSlot The base slot of the mapping
     * @param key The mapping key (encoded as bytes32)
     * @return slot The calculated storage slot
     */
    function mappingSlot(uint256 baseSlot, bytes32 key) internal pure returns (bytes32 slot) {
        assembly {
            mstore(0x00, key)
            mstore(0x20, baseSlot)
            slot := keccak256(0x00, 0x40)
        }
    }
    
    /**
     * @notice Calculate slot for a nested mapping value
     * @param baseSlot The base slot of the mapping
     * @param key1 The first mapping key
     * @param key2 The second mapping key
     * @return slot The calculated storage slot
     */
    function nestedMappingSlot(uint256 baseSlot, bytes32 key1, bytes32 key2) internal pure returns (bytes32 slot) {
        assembly {
            // Calculate inner mapping slot: keccak256(key1, baseSlot)
            mstore(0x00, key1)
            mstore(0x20, baseSlot)
            let innerSlot := keccak256(0x00, 0x40)
            
            // Calculate outer mapping slot: keccak256(key2, innerSlot)
            mstore(0x00, key2)
            mstore(0x20, innerSlot)
            slot := keccak256(0x00, 0x40)
        }
    }
    
    /**
     * @notice Calculate slot for a struct field
     * @param structBaseSlot The base slot of the struct
     * @param fieldOffset The field offset within the struct
     * @return slot The calculated storage slot
     */
    function structFieldSlot(bytes32 structBaseSlot, uint256 fieldOffset) internal pure returns (bytes32 slot) {
        assembly {
            slot := add(structBaseSlot, fieldOffset)
        }
    }
    
    /**
     * @notice Calculate slot for an array element
     * @param arrayBaseSlot The base slot where array length is stored
     * @param index The array index
     * @return slot The calculated storage slot
     */
    function arrayElementSlot(bytes32 arrayBaseSlot, uint256 index) internal pure returns (bytes32 slot) {
        assembly {
            mstore(0x00, arrayBaseSlot)
            let arrayDataSlot := keccak256(0x00, 0x20)
            slot := add(arrayDataSlot, index)
        }
    }
    
    /**
     * @notice Encode AuctionId to bytes32 for storage slot calculation
     */
    function encodeAuctionId(AuctionId auctionId) internal pure returns (bytes32) {
        return AuctionId.unwrap(auctionId);
    }
    
    /**
     * @notice Encode PoolId to bytes32 for storage slot calculation
     */
    function encodePoolId(PoolId poolId) internal pure returns (bytes32) {
        return PoolId.unwrap(poolId);
    }
    
    /**
     * @notice Encode BundleId to bytes32 for storage slot calculation
     */
    function encodeBundleId(BundleId bundleId) internal pure returns (bytes32) {
        return BundleId.unwrap(bundleId);
    }
    
    /**
     * @notice Encode address to bytes32 for storage slot calculation (left-padded)
     */
    function encodeAddress(address addr) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(addr)));
    }
}


