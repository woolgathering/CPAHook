// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { PoolId } from "@uniswap/v4-core/src/types/PoolId.sol";

import { AuctionTypes } from "../types/AuctionTypes.sol";
import { AuctionId } from "../types/AuctionId.sol";
import { BundleId } from "../types/BundleId.sol";
import { AllocationId } from "../types/AllocationId.sol";

/**
 * @title IClockProxyAuction
 * @notice Interface for Clock-Proxy Auction system with shared errors and events
 * @author Clock-Proxy Auction Team
 */
interface IErrorsAndEvents {

	/// @notice Events
	
	// Auction Lifecycle Events
	event AuctionCreated(AuctionId auctionId, address auctionOwner);
	event AuctionPhaseChanged(AuctionId auctionId, AuctionTypes.AuctionPhase newPhase);
	event AuctionPaused(AuctionId auctionId, address by);
	event AuctionUnpaused(AuctionId auctionId, address by);
	event AuctionCancelled(AuctionId auctionId, address by);
	
	// Bidding Events
	event BidSubmitted(AuctionId auctionId, address bidder, uint256 stakeAmount, uint256 round);
	event ClockRoundOpened(AuctionId auctionId, uint256 round);
	event ClockRoundClosed(AuctionId auctionId, uint256 round, uint256 totalBids);
	
	// Bundle and Allocation Events
	event BundleSubmitted(AuctionId auctionId, bytes32 commitHash, BundleId bundleId, uint256[] quantities, uint256 value);
	event AllocationSubmitted(AuctionId auctionId, address allocator, uint256 score);
	event AllocatorRewardClaimed(AuctionId auctionId, address allocator, uint256 reward);
	
	// Privacy and Settlement Events
	event RevealProcessed(AuctionId auctionId, address bidder, address proxy, bytes32 commitHash);
	
	// Stake and Asset Events
	event StakeAdded(AuctionId auctionId, address bidder, uint256 amount);
	event StakeRefunded(AuctionId auctionId, address bidder, uint256 amount);
	event PenaltyApplied(AuctionId auctionId, address bidder, uint256 amount);
	event AssetsDeposited(AuctionId auctionId, PoolId poolId, address currency, uint256 amount, address hookAddress);
	event AssetsWithdrawn(AuctionId auctionId, PoolId poolId, address currency, uint256 amount, address hookAddress);

	/// @notice Shared errors
	
	// Authorization Errors
	error OnlyOwner();
	error Unauthorized();
	
	// Auction State Errors
	error InvalidPhase(AuctionTypes.AuctionPhase expected, AuctionTypes.AuctionPhase actual);
	error AuctionNotActive(AuctionId auctionId, AuctionTypes.AuctionStatus status);
	error AuctionNotCancelled(AuctionId auctionId);
	error AuctionAlreadyExists();
	error AuctionNotFound();
	error AuctionNotSetup();
	error AuctionNotStarted();
	error AuctionNotEnded();
	error SetupNotComplete();
	
	// Clock Phase Errors
	error ClockNotOpen();
	error ClockAlreadyOpen();
	
	// Bidding Errors
	error InsufficientBidPoints();
	error InvalidBidsLength();
	error MaxStakeTooLow(AuctionId auctionId);
	error InvalidStakeAmount();
	
	// Bundle and Allocation Errors
	error DuplicateBundle();
	error InvalidBundle(AuctionId auctionId, BundleId bundleId);
	error InvalidQuantities(AuctionId auctionId, uint256 quantities);
	error DuplicateAllocation(AuctionId auctionId, bytes32 commitHash);
	
	// Privacy and Commit-Reveal Errors
	error InvalidCommitHash();
	error NoSuchCommitHash(AuctionId auctionId, bytes32 commitHash);
	error DuplicateReveal(AuctionId auctionId, bytes32 commitHash);
	error CommitHashNotYetRevealed(AuctionId auctionId, bytes32 commitHash);
	
	// Pool and Asset Errors
	error InvalidNumeraire();
	error NumeraireAlreadySet();
	error PoolAlreadyExists();
	error MismatchedNumeraires();
	error InvalidHook();
	error PoolPriceUpdateFailed();
	error PoolNotFound(AuctionId auctionId, PoolId poolId);
}
