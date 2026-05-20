// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { PoolId } from "@uniswap/v4-core/src/types/PoolId.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";

import { AuctionTypes } from "../types/AuctionTypes.sol";
import { AuctionId } from "../types/AuctionId.sol";
import { BundleId } from "../types/BundleId.sol";
import { IDiamondCut } from "./IDiamondCut.sol";
import { IDiamondLoupe } from "./IDiamondLoupe.sol";

/**
 * @title ICPAManager
 * @notice Comprehensive interface for the Clock-Proxy Auction Manager
 * @dev This interface defines all public and external functions of the CPAManager contract
 * @author notthatintodefi.eth
 */
interface ICPAManager is IDiamondCut, IDiamondLoupe {
    // ========================================
    // ADMIN FUNCTIONS
    // ========================================
    
    /**
     * @notice Set the CPA auction hook address
     * @dev Only callable by the contract owner
     * @param _cpaAuctionHookAddr The new CPA auction hook address
     */
    function setCpaAuctionHookAddr(address _cpaAuctionHookAddr) external;
    
    // ========================================
    // AUCTION CREATION AND SETUP
    // ========================================

    /**
     * @notice Create a new auction in one call (permissionless — auctionOwner is a parameter).
     */
    function createAuction(
        AuctionTypes.AuctionConfig memory config,
        address auctionOwner
    ) external returns (AuctionId);

    /**
     * @notice Initialize a new auction — registers pools and returns the auction ID.
     * @dev Step 1 of 2 for auction creation. Use createAuction for the single-call version.
     */
    function initAuction(
        AuctionTypes.AuctionConfig memory config,
        address auctionOwner
    ) external returns (AuctionId);

    /**
     * @notice Finalize auction setup — writes AuctionInfo and activates CPAHook state.
     * @dev Step 2 of 2 for auction creation. Use createAuction for the single-call version.
     */
    function finalizeAuction(
        AuctionId auctionId,
        AuctionTypes.AuctionConfig memory config,
        address auctionOwner
    ) external returns (AuctionId);
    
    /**
     * @notice Move deposit from auction owner to a single pool, giving ERC6909 claims to CPAHook
     * @dev Transfers assets from auction owner to the pool manager and mints ERC6909 claims
     * @param auctionId The auction identifier
     * @param poolKey The pool key to deposit to
     * @param depositAmount The amount to deposit
     */
    function moveDeposit(
        AuctionId auctionId,
        PoolKey memory poolKey,
        uint256 depositAmount
    ) external;
    
    /**
     * @notice Deposit to all pools and start clock phase in one transaction
     * @dev Batch operation to deposit to multiple pools and immediately start the clock phase
     * @param auctionId The auction identifier
     * @param poolKeys Array of pool keys to deposit to
     * @param amounts Array of deposit amounts (must match poolKeys length)
     */
    function depositAllAndStartClock(
        AuctionId auctionId,
        PoolKey[] memory poolKeys,
        uint256[] memory amounts
    ) external;
    
    // ========================================
    // AUCTION CONTROL
    // ========================================
    
    /**
     * @notice Pause the auction, preventing further operations
     * @dev Only callable by the auction owner. Paused auctions cannot accept new bids or transitions
     * @param auctionId The auction identifier
     */
    function pause(AuctionId auctionId) external;
    
    /**
     * @notice Unpause the auction, allowing normal operations to resume
     * @dev Only callable by the auction owner. Restores normal auction functionality
     * @param auctionId The auction identifier
     */
    function unpause(AuctionId auctionId) external;
    
    /**
     * @notice Force cancel auction when max pause duration exceeded
     * @dev Anyone can call this after 72 hours of total pause time
     * @param auctionId The auction identifier
     */
    function forceCancelAuction(AuctionId auctionId) external;
    
    /**
     * @notice Cancel the auction and refund all stakes
     * @dev Only allowed in Setup and Clock phases. Refunds all bidder stakes
     * @param auctionId The auction identifier
     */
    function cancelAuction(AuctionId auctionId) external;
    
    /**
     * @notice Reclaim stake from a cancelled auction
     * @dev Allows bidders to reclaim their stake after auction cancellation
     * @param auctionId The auction identifier
     */
    function reclaimStake(AuctionId auctionId) external;
    
    // ========================================
    // CLOCK PHASE OPERATIONS
    // ========================================
    
    /**
     * @notice Start the clock phase of the auction
     * @dev Transitions auction from Setup to Clock phase and opens the first round
     * @param auctionId The auction identifier
     */
    function startClockPhase(AuctionId auctionId) external;
    
    /**
     * @notice End the current clock round in one call (onlyAuctionOwner).
     */
    function endClockRound(AuctionId auctionId) external;

    /**
     * @notice Process one step of the current clock round.
     * @dev Use endClockRound for the single-call version.
     */
    function processClockRoundStep(AuctionId auctionId) external;

    /**
     * @notice Finalize the current clock round.
     * @dev Use endClockRound for the single-call version.
     */
    function finalizeClockRound(AuctionId auctionId) external;

    /**
     * @notice End the clock phase and transition to proxy phase
     * @dev Manually ends the clock phase and moves to proxy phase
     * @param auctionId The auction identifier
     */
    function endClockPhase(AuctionId auctionId) external;
    
    /**
     * @notice Submit a bid during clock phase
     * @dev Submits demand quantities for each asset and provides stake
     * @param auctionId The auction identifier
     * @param demands Array of item demands (quantities for each asset)
     * @param maxStakeAmount Maximum stake amount the bidder is willing to provide (inclusive of allocator reward)
     */
    function submitBid(
        AuctionId auctionId,
        uint256[] calldata demands,
        uint256 maxStakeAmount
    ) external payable;
    
    /**
     * @notice Commit to a bidder (proxy function)
     * @dev Allows a proxy to commit to representing a bidder
     * @param auctionId The auction identifier
     * @param commitHash The commit hash for the proxy relationship
     */
    function commitToBidder(AuctionId auctionId, bytes32 commitHash) external;
    
    /**
     * @notice Register a commit hash for proxy operations
     * @dev Registers a commit hash that can be used for proxy operations
     * @param auctionId The auction identifier
     * @param commitHash The commit hash to register
     */
    function registerCommit(AuctionId auctionId, bytes32 commitHash) external;
    
    /**
     * @notice Dropout from the auction during clock phase
     * @dev Allows bidders to exit the auction, subject to penalties
     * @param auctionId The auction identifier
     */
    function dropout(AuctionId auctionId) external;
    
    // ========================================
    // PROXY PHASE OPERATIONS
    // ========================================
    
    /**
     * @notice Submit bundle during proxy phase
     * @dev Submits a bundle with commit-reveal privacy
     * @param auctionId The auction identifier
     * @param commitHash The commit hash for the bundle
     * @param bundleData The bundle data containing allocations
     * @return The bundle identifier
     */
    function submitBundle(
        AuctionId auctionId,
        bytes32 commitHash,
        AuctionTypes.Bundle calldata bundleData
    ) external returns (BundleId);
    
    // ========================================
    // ALLOCATION PHASE OPERATIONS
    // ========================================
    
    /**
     * @notice Submit allocation during allocation phase
     * @dev Allows allocators to submit their allocation decisions
     * @param auctionId The auction identifier
     * @param allocationData The allocation data containing allocator and allocation details
     */
    function submitAllocation(
        AuctionId auctionId,
        AuctionTypes.Allocation calldata allocationData
    ) external;
    
    // ========================================
    // SETTLEMENT PHASE OPERATIONS
    // ========================================
    
    /**
     * @notice Reveal bidder identity
     * @dev Called by bidders to reveal their identity before settlement
     * @param auctionId The auction identifier
     * @param proxy The proxy address used
     * @param saltA First salt for the reveal
     * @param saltB Second salt for the reveal
     */
    function reveal(
        AuctionId auctionId,
        address proxy,
        bytes32 saltA,
        bytes32 saltB
    ) external;
    
    /**
     * @notice Claim tokens from winning allocation (owner only)
     * @dev Only the contract owner can claim tokens on behalf of bidders
     * @param auctionId The auction identifier
     * @param commitHash The commit hash
     * @param poolId The pool identifier
     */
    function claimToken(
        AuctionId auctionId,
        bytes32 commitHash,
        PoolId poolId
    ) external;
    
    /**
     * @notice Claim all tokens from winning allocation
     * @dev Allows bidders to claim all their allocated tokens at once
     * @param auctionId The auction identifier
     * @param commitHash The commit hash
     */
    function claimAllTokens(AuctionId auctionId, bytes32 commitHash) external;
    
    /**
     * @notice Claim allocator reward
     * @dev Allows the winning allocator to claim their reward
     * @param auctionId The auction identifier
     */
    function claimAllocatorReward(AuctionId auctionId) external;
    
    // ========================================
    // PERMISSIONLESS PHASE TRANSITIONS
    // ========================================
    
    /**
     * @notice Transition from Proxy to Allocation phase (callable by anyone)
     * @dev Permissionless transition when proxy phase expires
     * @param auctionId The auction identifier
     */
    function transitionToAllocation(AuctionId auctionId) external;
    
    /**
     * @notice Transition from Allocation to Settlement phase in one call (permissionless).
     */
    function transitionToSettlement(AuctionId auctionId) external;

    /**
     * @notice Select the winning allocator bundle.
     * @dev Step 1 of 3. Use transitionToSettlement for the single-call version.
     */
    function selectAuctionWinner(AuctionId auctionId) external;

    /**
     * @notice Convert auction assets for settlement.
     * @dev Step 2 of 3. Use transitionToSettlement for the single-call version.
     */
    function convertAuctionAssets(AuctionId auctionId) external;

    /**
     * @notice Mint settlement positions for winning bidders.
     * @dev Step 3 of 3. Use transitionToSettlement for the single-call version.
     */
    function mintSettlementPositions(AuctionId auctionId) external;

    /**
     * @notice Transition from Settlement to Finished phase (callable by anyone)
     * @dev Permissionless transition when settlement phase expires
     * @param auctionId The auction identifier
     */
    function transitionToFinished(AuctionId auctionId) external;
    
    // ========================================
    // FINISHED PHASE OPERATIONS
    // ========================================
    
    /**
     * @notice Forfeit bidder who didn't claim in time
     * @dev Only callable in Finished phase. Caller gets 1% reward incentive
     * @param auctionId The auction identifier
     * @param bidder The bidder address to forfeit
     */
    function forfeit(AuctionId auctionId, address bidder) external;
    
    /**
     * @notice Transfer all NFT positions to the auctioneer
     * @dev Permissionless function - anyone can call as positions only go to auctioneer
     * @param auctionId The auction identifier
     */
    function transferPositionsToAuctioneer(AuctionId auctionId) external;
    
    // ========================================
    // VIEW FUNCTIONS
    // ========================================
    
    /**
     * @notice Get auction information
     * @dev Returns comprehensive auction information including configuration and current state
     * @param auctionId The auction identifier
     * @return The complete auction information
     */
    function getAuctionInfo(AuctionId auctionId) external view returns (AuctionTypes.AuctionInfo memory);
    
    /**
     * @notice Get top allocation for an auction
     * @dev Returns the winning allocation and its score
     * @param auctionId The auction identifier
     * @return allocation The top allocation
     * @return score The top score
     * @return value The total value
     */
    function topAllocation(AuctionId auctionId) external view returns (
        AuctionTypes.Allocation memory allocation,
        uint256 score,
        uint256 value
    );
    
    /**
     * @notice Get bidder stake for a specific auction and bidder
     * @dev Returns the current stake amount for a bidder
     * @param auctionId The auction identifier
     * @param bidder The bidder address
     * @return The stake amount
     */
    function bidderStake(AuctionId auctionId, address bidder) external view returns (uint256);
    
    /**
     * @notice Get revealed mappings for commit hashes
     * @dev Returns the revealed bidder address for a commit hash
     * @param auctionId The auction identifier
     * @param commitHash The commit hash
     * @return The revealed bidder address
     */
    function revealedMappings(AuctionId auctionId, bytes32 commitHash) external view returns (address);

    // ========================================
    // STORAGE GETTERS (auto-generated from CPAStorage public mappings)
    // ========================================

    function getBidderDemands(AuctionId auctionId, address bidder) external view returns (uint256[] memory);
    function poolInfo(PoolId poolId) external view returns (PoolKey memory, int24, int24, uint256, int256, int24, AuctionId, uint256);
    function poolToAuctionId(PoolId poolId) external view returns (AuctionId);
    function bidderBidPoints(AuctionId auctionId, address bidder) external view returns (uint256);
    function protocolPenalties(AuctionId auctionId) external view returns (uint256);
    function winningBundleIds(bytes32 commitHash) external view returns (BundleId);
    function activeBidders(AuctionId auctionId, uint256 index) external view returns (address);

    // Explicit view functions defined in CPAStorage
    function getPoolInfo(PoolId poolId) external view returns (PoolKey memory, int24, int24, uint256, int256, int24, AuctionId, uint256);
    function getBundle(AuctionId auctionId, BundleId bundleId)
        external view returns (AuctionId, bytes32, BundleId, uint256[] memory, uint256, uint256);
    function getNumItems(AuctionId auctionId) external view returns (uint256);
    function getTopAllocation(AuctionId auctionId) external view returns (AuctionTypes.TopAllocation memory);

    // ========================================
    // DIAMOND MANAGEMENT
    // ========================================

    // Register callback op-type to sub-facet mapping (used by CallbackRouterFacet)
    function setCallbackFacets(uint8[] calldata opTypes, address[] calldata facets_) external;

    // ERC-165
    function supportsInterface(bytes4 interfaceId) external view returns (bool);
}