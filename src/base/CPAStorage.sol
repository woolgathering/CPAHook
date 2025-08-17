// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";

import { AuctionTypes } from "../AuctionTypes.sol";

abstract contract CPAStorage {

	/// @notice Common numeraire token (Y token)
	address public immutable commonNumeraire;
	
	/// @notice Current auction phase
	AuctionTypes.AuctionPhase public currentPhase;
	
	/// @notice Auction configuration
	AuctionTypes.AuctionConfig public config;
	
	/// @notice Whether auction is paused
	bool public paused;
	
	/// @notice Whether auction is cancelled
	bool public cancelled;

	/// @notice Commit hash to proxy mapping
	mapping(bytes32 => address) public commitProxy;

	/// @notice Pool hook addresses
	address[] public poolHooks;

	///////
	// SETUP PHASE
	///////

	/// @notice Pool information mapping
	mapping(PoolId => AuctionTypes.PoolInfo) public poolInfo;

	/// @notice Pool IDs
	PoolId[] public pools;

	/**
	 * @notice Add a pool to the storage
	 * @param poolId The pool ID
	 * @param info The pool info
	 */
	function _addPool(PoolId poolId, AuctionTypes.PoolInfo memory info) internal {
		poolInfo[poolId] = info;
		pools.push(poolId);
	}

	/**
	 * @notice Get all pool IDs
	 * @return Array of all pool IDs
	 */
	function getAllPools() external view returns (PoolId[] memory) {
		return pools;
	}


    ////////
    // CLOCK PHASE
    ////////
    /// @notice Current clock round
	uint256 public currentRound;

    /// @notice Clock round open for bidding
	bool public clockOpen;

	/**
	 * @notice Set clock open state
	 * @param _clockOpen The new clock state
	 */
	function _setClockOpen(bool _clockOpen) internal {
		clockOpen = _clockOpen;
	}

    /// @notice Round bids storage
	AuctionTypes.Bid[] public roundBids;

    /// @notice Dropped bidders
	mapping(address => bool) public droppedBidders;

    /// @notice Bidder stake mapping
	mapping(address => uint256) public bidderStake;

	/**
	 * @notice Add stake for a bidder
	 * @param bidder The bidder address
	 * @param amount The amount to add
	 */
	function _addBidderStake(address bidder, uint256 amount) internal {
		bidderStake[bidder] += amount;
	}

	/**
	 * @notice Set bidder bid points
	 * @param bidder The bidder address
	 * @param points The bid points
	 */
	function _setBidderBidPoints(address bidder, uint256 points) internal {
		bidderBidPoints[bidder] = points;
	}

	/**
	 * @notice Add a bid to round bids
	 * @param bid The bid to add
	 */
	function _addRoundBid(AuctionTypes.Bid memory bid) internal {
		roundBids.push(bid);
	}

	/**
	 * @notice Set dropped bidder status
	 * @param bidder The bidder address
	 * @param dropped Whether the bidder is dropped
	 */
	function _setDroppedBidder(address bidder, bool dropped) internal {
		droppedBidders[bidder] = dropped;
	}

	/**
	 * @notice Clear bidder stake and bid points
	 * @param bidder The bidder address
	 */
	function _clearBidderData(address bidder) internal {
		bidderStake[bidder] = 0;
		bidderBidPoints[bidder] = 0;
	}

	/**
	 * @notice Get number of round bids
	 * @return Number of round bids
	 */
	function getRoundBidsLength() external view returns (uint256) {
		return roundBids.length;
	}

	/**
	 * @notice Get a round bid by index
	 * @param index The index of the bid
	 * @return The bid struct
	 */
	function getRoundBid(uint256 index) external view returns (AuctionTypes.Bid memory) {
		return roundBids[index];
	}

	/**
	 * @notice Get number of bundles for a commit hash
	 * @param commitHash The commit hash
	 * @return Number of bundles
	 */
	function getBundlesLength(bytes32 commitHash) external view returns (uint256) {
		return bundles[commitHash].length;
	}

	/**
	 * @notice Add a bundle to the bundles array
	 * @param commitHash The commit hash
	 * @param bundle The bundle to add
	 */
	function _addBundle(bytes32 commitHash, AuctionTypes.Bundle memory bundle) internal {
		bundles[commitHash].push(bundle);
	}
	
	/// @notice Bidder bid points mapping
	mapping(address => uint256) public bidderBidPoints;

    ////////
    // PROXY PHASE
    ////////
    /// @notice Bundle storage
	mapping(bytes32 => AuctionTypes.Bundle[]) public bundles;

    ////////
    // ALLOCATION PHASE
    ////////
    /// @notice Allocation storage
	AuctionTypes.Allocation[] public allocations;

	/**
	 * @notice Get number of allocations
	 * @return Number of allocations
	 */
	function getAllocationsLength() external view returns (uint256) {
		return allocations.length;
	}

	/**
	 * @notice Add an allocation to the allocations array
	 * @param allocation The allocation to add
	 */
	function _addAllocation(AuctionTypes.Allocation memory allocation) internal {
		allocations.push(allocation);
	}

    ////////
    // REVEAL PHASE
    ////////
    /// @notice Revealed mappings
	mapping(bytes32 => address) public revealedMappings;

	/**
	 * @notice Set revealed mapping
	 * @param commitHash The commit hash
	 * @param bidder The bidder address
	 */
	function _setRevealedMapping(bytes32 commitHash, address bidder) internal {
		revealedMappings[commitHash] = bidder;
	}

    /// @notice Final allocation
	AuctionTypes.Allocation public finalAllocation;

    /// @notice Winning allocator
	address public winningAllocator;

	/**
	 * @notice Constructor
	 * @param _commonNumeraire The common numeraire token
	 * @param _config The auction configuration
	 */
	constructor(
		address _commonNumeraire,
		AuctionTypes.AuctionConfig memory _config
	) {
		commonNumeraire = _commonNumeraire;
		config = _config;
		currentPhase = AuctionTypes.AuctionPhase.Setup;
	}

}