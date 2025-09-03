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



    ////////
    // CLOCK PHASE
    ////////
    /// @notice Dropped bidders (not stored in AuctionInfo)
	mapping(AuctionId => mapping(address => bool)) public droppedBidders;

    /// @notice Bidder stake mapping (not stored in AuctionInfo)
	mapping(AuctionId => mapping(address => uint256)) public bidderStake;

    /// @notice Bidder bid points mapping (not stored in AuctionInfo)
	mapping(AuctionId => mapping(address => uint256)) public bidderBidPoints;

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