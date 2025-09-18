// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { AuctionTypes } from "../types/AuctionTypes.sol";
import { AuctionId } from "../types/AuctionId.sol";
import { BundleId } from "../types/BundleId.sol";
import { PoolId } from "@uniswap/v4-core/src/types/PoolId.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";

/**
 * @title ICPAManager
 * @notice Interface for the Clock-Proxy Auction Manager
 * @author notthatintodefi.eth
 */
interface ICPAManager {
    // ========================================
    // AUCTION MANAGEMENT
    // ========================================
    
    /**
     * @notice Create a new auction
     * @param config The auction configuration
     * @param auctionOwner The auction owner
     * @return The auction ID
     */
    function createAuction(
        AuctionTypes.AuctionConfig memory config,
        address auctionOwner
    ) external returns (AuctionId);
    
    /**
     * @notice Move deposit from auction owner to a pool
     * @param auctionId The auction ID
     * @param poolKey The pool key
     * @param amount The amount to deposit
     */
    function moveDeposit(
        AuctionId auctionId,
        PoolKey calldata poolKey,
        uint256 amount
    ) external;
    
    // ========================================
    // AUCTION CONTROL
    // ========================================
    
    /**
     * @notice Pause an auction
     * @param auctionId The auction ID
     */
    function pause(AuctionId auctionId) external;
    
    /**
     * @notice Unpause an auction
     * @param auctionId The auction ID
     */
    function unpause(AuctionId auctionId) external;
    
    /**
     * @notice Cancel an auction
     * @param auctionId The auction ID
     */
    function cancelAuction(AuctionId auctionId) external;
    
    /**
     * @notice Reclaim stake from a cancelled auction
     * @param auctionId The auction ID
     */
    function reclaimStake(AuctionId auctionId) external;
    
    // ========================================
    // CLOCK PHASE
    // ========================================
    
    /**
     * @notice Start a clock round
     * @param auctionId The auction ID
     */
    function startClockRound(AuctionId auctionId) external;
    
    /**
     * @notice End a clock round
     * @param auctionId The auction ID
     */
    function endClockRound(AuctionId auctionId) external;
    
    /**
     * @notice End the clock phase
     * @param auctionId The auction ID
     */
    function endClockPhase(AuctionId auctionId) external;
    
    /**
     * @notice Submit a bid during clock phase
     * @param auctionId The auction ID
     * @param demands Array of item demands
     * @param maxStakeAmount Maximum stake amount
     */
    function submitBid(
        AuctionId auctionId,
        uint256[] calldata demands,
        uint256 maxStakeAmount
    ) external;
    
    /**
     * @notice Commit to a bidder (called by proxy)
     * @param auctionId The auction ID
     * @param commitHash The commit hash
     */
    function commitToBidder(AuctionId auctionId, bytes32 commitHash) external;
    
    /**
     * @notice Register a commit hash
     * @param auctionId The auction ID
     * @param commitHash The commit hash
     */
    function registerCommit(AuctionId auctionId, bytes32 commitHash) external;
    
    /**
     * @notice Dropout from auction
     * @param auctionId The auction ID
     */
    function dropout(AuctionId auctionId) external;
    
    // ========================================
    // PROXY PHASE
    // ========================================
    
    /**
     * @notice End the proxy phase
     * @param auctionId The auction ID
     */
    function endProxyPhase(AuctionId auctionId) external;
    
    /**
     * @notice Submit bundle during proxy phase
     * @param auctionId The auction ID
     * @param commitHash The commit hash
     * @param bundleData The bundle data
     * @return The bundle ID
     */
    function submitBundle(
        AuctionId auctionId,
        bytes32 commitHash,
        AuctionTypes.Bundle calldata bundleData
    ) external returns (BundleId);
    
    // ========================================
    // ALLOCATION PHASE
    // ========================================
    
    /**
     * @notice Submit allocation during allocation phase
     * @param auctionId The auction ID
     * @param allocationData The allocation data
     */
    function submitAllocation(
        AuctionId auctionId,
        AuctionTypes.Allocation calldata allocationData
    ) external;
    
    /**
     * @notice End allocation phase
     * @param auctionId The auction ID
     */
    function endAllocationPhase(AuctionId auctionId) external;
    
    // ========================================
    // SETTLEMENT PHASE
    // ========================================
    
    /**
     * @notice Reveal bidder identity
     * @param auctionId The auction ID
     * @param proxy The proxy address
     * @param saltA First salt
     * @param saltB Second salt
     */
    function reveal(
        AuctionId auctionId,
        address proxy,
        bytes32 saltA,
        bytes32 saltB
    ) external;
    
    /**
     * @notice Claim tokens from winning allocation
     * @param auctionId The auction ID
     * @param commitHash The commit hash
     * @param poolId The pool ID
     */
    function claimToken(
        AuctionId auctionId,
        bytes32 commitHash,
        PoolId poolId
    ) external;
    
    /**
     * @notice Claim all tokens from winning allocation
     * @param auctionId The auction ID
     * @param commitHash The commit hash
     */
    function claimAllTokens(AuctionId auctionId, bytes32 commitHash) external;
    
    /**
     * @notice End settlement phase
     * @param auctionId The auction ID
     */
    function endSettlementPhase(AuctionId auctionId) external;
    
    /**
     * @notice Claim allocator reward
     * @param auctionId The auction ID
     */
    function claimAllocatorReward(AuctionId auctionId) external;
    
    // ========================================
    // VIEW FUNCTIONS
    // ========================================
    
    /**
     * @notice Get auction information
     * @param auctionId The auction ID
     * @return The auction information
     */
    function getAuctionInfo(AuctionId auctionId) external view returns (AuctionTypes.AuctionInfo memory);
    
    /**
     * @notice Get top allocation for an auction
     * @param auctionId The auction ID
     * @return The top allocation
     * @return The top score
     * @return The total value
     */
    function topAllocation(AuctionId auctionId) external view returns (
        AuctionTypes.Allocation memory,
        uint256,
        uint256
    );
    
    /**
     * @notice Get bidder stake
     * @param auctionId The auction ID
     * @param bidder The bidder address
     * @return The stake amount
     */
    function bidderStake(AuctionId auctionId, address bidder) external view returns (uint256);
    
    /**
     * @notice Get revealed mappings
     * @param auctionId The auction ID
     * @param commitHash The commit hash
     * @return The revealed bidder address
     */
    function revealedMappings(AuctionId auctionId, bytes32 commitHash) external view returns (address);
}