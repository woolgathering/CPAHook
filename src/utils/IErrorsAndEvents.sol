// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { AuctionTypes } from "../AuctionTypes.sol";
import { AuctionId } from "../AuctionId.sol";
import { PoolId } from "@uniswap/v4-core/src/types/PoolId.sol";

/**
 * @title IClockProxyAuction
 * @notice Interface for Clock-Proxy Auction system with shared errors and events
 * @author Clock-Proxy Auction Team
 */
interface IErrorsAndEvents {


	/// @notice Events
	event AuctionCreated(AuctionId auctionId, address auctionOwner);
	event AuctionPhaseChanged(AuctionId auctionId, AuctionTypes.AuctionPhase oldPhase, AuctionTypes.AuctionPhase newPhase);
	event BidSubmitted(AuctionId auctionId, address bidder, bytes32 commitHash, uint256 stakeAmount, uint256 round);
	event BundleSubmitted(AuctionId auctionId, bytes32 commitHash, uint256 bundleId);
	event AllocationSubmitted(AuctionId auctionId, address allocator, uint256 allocationId);
	event RevealProcessed(AuctionId auctionId, address bidder, address proxy, bytes32 commitHash);
	event AuctionPaused(AuctionId auctionId, address by);
	event AuctionUnpaused(AuctionId auctionId, address by);
	event AuctionCancelled(AuctionId auctionId, address by);
	event StakeAdded(AuctionId auctionId, address bidder, uint256 amount);
	event StakeRefunded(AuctionId auctionId, address bidder, uint256 amount);
	event PenaltyApplied(AuctionId auctionId, address bidder, uint256 amount);
	event AssetsDeposited(AuctionId auctionId, PoolId poolId, address currency, uint256 amount, address hookAddress);
	event AssetsWithdrawn(AuctionId auctionId, PoolId poolId, address currency, uint256 amount, address hookAddress);
	event ClockRoundOpened(AuctionId auctionId, uint256 round);
	event ClockRoundClosed(AuctionId auctionId, uint256 round, uint256 totalBids);

	/// @notice Shared errors
	error OnlyOwner();
	error InvalidPhase(AuctionTypes.AuctionPhase expected, AuctionTypes.AuctionPhase actual);
	error AuctionPausedError();
	error AuctionCancelledError();
	error ClockNotOpen();
	error InvalidCommitHash();
	error InsufficientBidPoints();
	error InvalidStakeAmount();
	error DuplicateBundle();
	error DuplicateAllocation();
	error InvalidReveal();
	error Unauthorized();
	error SetupNotComplete();
	error InvalidNumeraire();
	error NumeraireAlreadySet();
	error PoolAlreadyExists();
	error MismatchedNumeraires();
	error InvalidHook();
	error AuctionAlreadyExists();
	error AuctionNotFound();
	error AuctionNotSetup();
	error AuctionNotStarted();
	error AuctionNotEnded();
	error ClockAlreadyOpen();
}
