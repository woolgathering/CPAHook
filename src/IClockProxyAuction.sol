// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { AuctionTypes } from "./AuctionTypes.sol";

/**
 * @title IClockProxyAuction
 * @notice Interface for Clock-Proxy Auction system with shared errors and events
 * @author Clock-Proxy Auction Team
 */
interface IClockProxyAuction {
	/// @notice Events
	event AuctionPhaseChanged(AuctionTypes.AuctionPhase oldPhase, AuctionTypes.AuctionPhase newPhase);
	event ClockRoundOpened(uint256 round);
	event ClockRoundClosed(uint256 round, uint256 totalBids);
	event BidSubmitted(address bidder, bytes32 commitHash, uint256 stakeAmount, uint256 round);
	event BundleSubmitted(bytes32 commitHash, uint256 bundleId);
	event AllocationSubmitted(address allocator, uint256 allocationId);
	event RevealProcessed(address bidder, address proxy, bytes32 commitHash);
	event AuctionPaused(address by);
	event AuctionUnpaused(address by);
	event AuctionCancelled(address by);
	event StakeAdded(address bidder, uint256 amount);
	event StakeRefunded(address bidder, uint256 amount);
	event PenaltyApplied(address bidder, uint256 amount);

	/// @notice Shared errors
	error OnlyOwner();
	error InvalidPhase(AuctionTypes.AuctionPhase expected, AuctionTypes.AuctionPhase actual);
	error AuctionPaused();
	error AuctionCancelled();
	error ClockNotOpen();
	error InvalidCommitHash();
	error InsufficientBidPoints();
	error InvalidStakeAmount();
	error DuplicateBundle();
	error DuplicateAllocation();
	error InvalidReveal();
	error Unauthorized();
}
