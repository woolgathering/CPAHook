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
	event AuctionPhaseChanged(AuctionTypes.AuctionPhase oldPhase, AuctionTypes.AuctionPhase newPhase);
	event ClockRoundOpened(uint256 round);
	event ClockRoundClosed(uint256 round, uint256 totalBids);
	event BidSubmitted(address bidder, bytes32 commitHash, uint256 stakeAmount, uint256 round);
	event BundleSubmitted(bytes32 commitHash, uint256 bundleId);
	event AllocationSubmitted(address allocator, uint256 allocationId);
	event RevealProcessed(address bidder, address proxy, bytes32 commitHash);
	event AuctionPaused(AuctionId auctionId, address by);
	event AuctionUnpaused(AuctionId auctionId, address by);
	event AuctionCancelled(AuctionId auctionId, address by);
	event StakeAdded(address bidder, uint256 amount);
	event StakeRefunded(address bidder, uint256 amount);
	event PenaltyApplied(address bidder, uint256 amount);
	event AssetsDeposited(AuctionId auctionId, PoolId poolId, address currency, uint256 amount, address hookAddress);
	event AssetsWithdrawn(AuctionId auctionId, PoolId poolId, address currency, uint256 amount, address hookAddress);

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
}
