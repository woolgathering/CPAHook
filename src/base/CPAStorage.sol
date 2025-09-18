// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { BundleId } from "../BundleId.sol";

import { AuctionTypes } from "../AuctionTypes.sol";
import { AuctionId } from "../AuctionId.sol";
import { IErrorsAndEvents } from "../utils/IErrorsAndEvents.sol";

abstract contract CPAStorage {

	/// @notice Current auction phase
	// mapping(AuctionId => AuctionTypes.AuctionPhase) public auctionPhase;
	
	/// @notice Auction configuration
	// mapping(AuctionId => AuctionTypes.AuctionConfig) public auctionConfig;
	
	/// @notice Whether auction is paused
	// mapping(AuctionId => bool) public paused;
	
	/// @notice Whether auction is cancelled
	// mapping(AuctionId => bool) public cancelled;

	/// @notice Commit hash to proxy mapping
	// AuctionId -> CommitHash -> Proxy Address
	mapping(AuctionId => mapping(bytes32 => address)) public commitProxy;

	/// @notice Pool key to auction owner mapping
	mapping(PoolId => AuctionId) public poolToAuctionId;

	/// @notice Auction info mapping
	mapping(AuctionId => AuctionTypes.AuctionInfo) public auctionInfo;

	/// @notice Pool info mapping
	mapping(PoolId => AuctionTypes.PoolInfo) public poolInfo;

	/// @notice Current prices for currencies (in numeraire units)
	/// @dev Currency address => price in numeraire (e.g., 1e18 = 1 numeraire token per currency unit)
	mapping(address => uint256) public currentPrices;

	/// @notice CPA Auction Hook address
	// this is the hook that all auction item pools share
	address public cpaAuctionHookAddr;

	IPoolManager public manager;

	//// getters
	function getAuctionInfo(AuctionId auctionId) external view returns (AuctionTypes.AuctionInfo memory) {
    	return auctionInfo[auctionId];
	}

	function getPoolInfo(PoolId poolId) external view returns (PoolKey memory, int24, int24, uint256, uint256, AuctionId, bytes32) {
		return (
			poolInfo[poolId].key,
			poolInfo[poolId].startingTick,
			poolInfo[poolId].priceIncrement,
			poolInfo[poolId].depositAmount,
			poolInfo[poolId].excessDemand,
			poolInfo[poolId].auctionId,
			poolInfo[poolId].positionId
		);
	}


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

	function getNumItems(AuctionId auctionId) external view returns (uint256) {
		return auctionInfo[auctionId].poolKeys.length;
	}



    ////////
    // CLOCK PHASE
    ////////
    /// @notice Dropped bidders (not stored in AuctionInfo)
	mapping(AuctionId => mapping(address => bool)) public droppedBidders;

    /// @notice Bidder stake mapping (not stored in AuctionInfo)
	mapping(AuctionId => mapping(address => uint256)) public bidderStake;

	/// @notice The amount of stake that is available to be reclaimed by a bidder
	mapping(AuctionId => mapping(address => uint256)) public availableToReclaim;

    /// @notice Bidder bid points mapping (not stored in AuctionInfo)
	mapping(AuctionId => mapping(address => uint256)) public bidderBidPoints;

	/// @notice Number of bidders in an auction
	// mapping(AuctionId => uint256) public numBidders;

    ////////
    // PROXY PHASE
    ////////
    /// @notice Bundle storage (id -> bundleId -> bundle)
	mapping(AuctionId => mapping(BundleId => AuctionTypes.Bundle)) public bundles;

	/// @notice Proxy phase start time
	mapping(AuctionId => uint256) public proxyPhaseStartTime;

	function getBundle(AuctionId auctionId, BundleId bundleId) external view returns (AuctionId, bytes32, BundleId, uint256[] memory, uint256, uint256) {
		return (
			auctionId,
			bundles[auctionId][bundleId].commitHash,
			bundleId,
			bundles[auctionId][bundleId].quantities,
			bundles[auctionId][bundleId].value,
			bundles[auctionId][bundleId].timestamp
		);
	}

    ////////
    // ALLOCATION PHASE
    ////////
    
	/// @notice Top allocation storage
	mapping(AuctionId => AuctionTypes.TopAllocation) public topAllocation;

	/// @notice Winning bundle ids storage
	/// commitHash -> bundleId
	mapping(bytes32 => BundleId) public winningBundleIds;

	/// @notice Already allocated
	/// checks if a bundle has been allocated 
	// mapping(AuctionId => mapping(bytes32 => bool)) public alreadyAllocated;
	

	/**
	 * @notice Get top allocation
	 * @param auctionId The auction ID
	 * @return Top allocation
	 */
	function getTopAllocation(AuctionId auctionId) external view returns (AuctionTypes.TopAllocation memory) {
		return topAllocation[auctionId];
	}

    ////////
    // SETTLEMENT PHASE
    ////////
    /// @notice Revealed mappings. AuctionId -> CommitHash -> Bidder Address
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

	/**
	 * @notice Constructor
	 * @param _cpaAuctionHookAddr The CPA auction hook address
	 */
	constructor(address _cpaAuctionHookAddr) {
		cpaAuctionHookAddr = _cpaAuctionHookAddr;
	}
}