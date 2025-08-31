// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import { AuctionTypes } from "../AuctionTypes.sol";
import { AuctionId } from "../AuctionId.sol";
import { IErrorsAndEvents } from "../utils/IErrorsAndEvents.sol";

abstract contract CPAStorage {

	/// @notice Current auction phase
	// mapping(AuctionId => AuctionTypes.AuctionPhase) public auctionPhase;
	
	/// @notice Auction configuration
	// mapping(AuctionId => AuctionTypes.AuctionConfig) public auctionConfig;
	
	/// @notice Whether auction is paused
	mapping(AuctionId => bool) public paused;
	
	/// @notice Whether auction is cancelled
	mapping(AuctionId => bool) public cancelled;

	/// @notice Commit hash to proxy mapping
	// AuctionId -> CommitHash -> Proxy Address
	mapping(AuctionId => mapping(bytes32 => address)) public commitProxy;

	/// @notice Pool key to auction owner mapping
	mapping(PoolId => AuctionId) public poolToAuctionId;

	/// @notice Auction owner mapping
	// mapping(AuctionId => address) public auctionOwner;

	/// @notice Auction info mapping
	mapping(AuctionId => AuctionTypes.AuctionInfo) public auctionInfo;

	/// @notice Pool info mapping
	mapping(PoolId => AuctionTypes.PoolInfo) public poolInfo;

	/// @notice CPA Auction Hook address
	// this is the hook that all auction item pools share
	address public cpaAuctionHookAddr;

	IPoolManager public manager;

	///////
	// SETUP PHASE
	///////

	/**
	 * @notice Update deposit amount for a pool
	 * @param auctionId The auction ID
	 * @param poolId The pool ID
	 * @param depositAmount The deposit amount to set
	 */
	function _updatePoolDepositAmount(AuctionId auctionId, PoolId poolId, uint256 depositAmount) internal {
		poolInfo[poolId].depositAmount = depositAmount;
	}

	/**
	 * @notice Get all pool IDs for an auction
	 * @param auctionId The auction ID
	 * @return Array of all pool IDs
	 */
	function getAllPools(AuctionId auctionId) external view returns (PoolId[] memory) {
		PoolKey[] memory poolKeys = auctionInfo[auctionId].poolKeys;
		PoolId[] memory poolIds = new PoolId[](poolKeys.length);
		
		for (uint256 i = 0; i < poolKeys.length; i++) {
			poolIds[i] = poolKeys[i].toId();
		}
		
		return poolIds;
	}

    ////////
    // CLOCK PHASE
    ////////
    /// @notice Current clock round
	mapping(AuctionId => uint256) public currentRound;

    /// @notice Clock round open for bidding
	mapping(AuctionId => bool) public clockOpen;

	/**
	 * @notice Set clock open state
	 * @param auctionId The auction ID
	 * @param _clockOpen The new clock state
	 */
	function _setClockOpen(AuctionId auctionId, bool _clockOpen) internal {
		clockOpen[auctionId] = _clockOpen;
	}

    /// @notice Round bids storage
	mapping(AuctionId => AuctionTypes.Bid[]) public roundBids;

    /// @notice Dropped bidders
	mapping(AuctionId => mapping(address => bool)) public droppedBidders;

    /// @notice Bidder stake mapping
	mapping(AuctionId => mapping(address => uint256)) public bidderStake;

	/**
	 * @notice Add stake for a bidder
	 * @param auctionId The auction ID
	 * @param bidder The bidder address
	 * @param amount The amount to add
	 */
	function _addBidderStake(AuctionId auctionId, address bidder, uint256 amount) internal {
		bidderStake[auctionId][bidder] += amount;
	}

	/**
	 * @notice Set bidder bid points
	 * @param auctionId The auction ID
	 * @param bidder The bidder address
	 * @param points The bid points
	 */
	function _setBidderBidPoints(AuctionId auctionId, address bidder, uint256 points) internal {
		bidderBidPoints[auctionId][bidder] = points;
	}

	/**
	 * @notice Add a bid to round bids
	 * @param auctionId The auction ID
	 * @param bid The bid to add
	 */
	function _addRoundBid(AuctionId auctionId, AuctionTypes.Bid memory bid) internal {
		roundBids[auctionId].push(bid);
	}

	/**
	 * @notice Set dropped bidder status
	 * @param auctionId The auction ID
	 * @param bidder The bidder address
	 * @param dropped Whether the bidder is dropped
	 */
	function _setDroppedBidder(AuctionId auctionId, address bidder, bool dropped) internal {
		droppedBidders[auctionId][bidder] = dropped;
	}

	/**
	 * @notice Clear bidder stake and bid points
	 * @param auctionId The auction ID
	 * @param bidder The bidder address
	 */
	function _clearBidderData(AuctionId auctionId, address bidder) internal {
		bidderStake[auctionId][bidder] = 0;
		bidderBidPoints[auctionId][bidder] = 0;
	}

	/**
	 * @notice Get number of round bids
	 * @param auctionId The auction ID
	 * @return Number of round bids
	 */
	function getRoundBidsLength(AuctionId auctionId) external view returns (uint256) {
		return roundBids[auctionId].length;
	}

	/**
	 * @notice Get a round bid by index
	 * @param auctionId The auction ID
	 * @param index The index of the bid
	 * @return The bid struct
	 */
	function getRoundBid(AuctionId auctionId, uint256 index) external view returns (AuctionTypes.Bid memory) {
		return roundBids[auctionId][index];
	}

	/**
	 * @notice Get number of bundles for a commit hash
	 * @param auctionId The auction ID
	 * @param commitHash The commit hash
	 * @return Number of bundles
	 */
	function getBundlesLength(AuctionId auctionId, bytes32 commitHash) external view returns (uint256) {
		return bundles[auctionId][commitHash].length;
	}

	/**
	 * @notice Add a bundle to the bundles array
	 * @param auctionId The auction ID
	 * @param commitHash The commit hash
	 * @param bundle The bundle to add
	 */
	function _addBundle(AuctionId auctionId, bytes32 commitHash, AuctionTypes.Bundle memory bundle) internal {
		bundles[auctionId][commitHash].push(bundle);
	}
	
	/// @notice Bidder bid points mapping
	mapping(AuctionId => mapping(address => uint256)) public bidderBidPoints;

    ////////
    // PROXY PHASE
    ////////
    /// @notice Bundle storage
	mapping(AuctionId => mapping(bytes32 => AuctionTypes.Bundle[])) public bundles;

    ////////
    // ALLOCATION PHASE
    ////////
    /// @notice Allocation storage
	mapping(AuctionId => AuctionTypes.Allocation[]) public allocations;

	/**
	 * @notice Get number of allocations
	 * @param auctionId The auction ID
	 * @return Number of allocations
	 */
	function getAllocationsLength(AuctionId auctionId) external view returns (uint256) {
		return allocations[auctionId].length;
	}

	/**
	 * @notice Add an allocation to the allocations array
	 * @param auctionId The auction ID
	 * @param allocation The allocation to add
	 */
	function _addAllocation(AuctionId auctionId, AuctionTypes.Allocation memory allocation) internal {
		allocations[auctionId].push(allocation);
	}

    ////////
    // REVEAL PHASE
    ////////
    /// @notice Revealed mappings
	mapping(AuctionId => mapping(bytes32 => address)) public revealedMappings;

	/**
	 * @notice Set revealed mapping
	 * @param auctionId The auction ID
	 * @param commitHash The commit hash
	 * @param bidder The bidder address
	 */
	function _setRevealedMapping(AuctionId auctionId, bytes32 commitHash, address bidder) internal {
		revealedMappings[auctionId][commitHash] = bidder;
	}

    /// @notice Final allocation
	mapping(AuctionId => AuctionTypes.Allocation) public finalAllocation;

    /// @notice Winning allocator
	mapping(AuctionId => address) public winningAllocator;

	/**
	 * @notice Constructor
	 * @param _cpaAuctionHookAddr The CPA auction hook address
	 */
	constructor(address _cpaAuctionHookAddr) {
		cpaAuctionHookAddr = _cpaAuctionHookAddr;
	}
}