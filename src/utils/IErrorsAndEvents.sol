// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { AuctionTypes } from "../types/AuctionTypes.sol";
import { AuctionId } from "../types/AuctionId.sol";
import { AssetId } from "../types/AssetConfig.sol";
import { BundleId } from "../types/BundleId.sol";

interface IErrorsAndEvents {

    // ========================================
    // EVENTS
    // ========================================

    // Auction lifecycle
    event AuctionCreated(AuctionId auctionId, address auctionOwner);
    event AuctionPhaseChanged(AuctionId auctionId, AuctionTypes.AuctionPhase newPhase);
    event AuctionPaused(AuctionId auctionId, address by);
    event AuctionUnpaused(AuctionId auctionId, address by);
    event AuctionCancelled(AuctionId auctionId, address by);

    // Bidding
    event BidSubmitted(AuctionId auctionId, address bidder, uint256 stakeAmount, uint256 round);
    event ClockRoundOpened(AuctionId auctionId, uint256 round);
    event ClockRoundClosed(AuctionId auctionId, uint256 round, uint256 totalBids);

    // Bundle and allocation
    event BundleSubmitted(AuctionId auctionId, bytes32 commitHash, BundleId bundleId, uint256[] quantities, uint256 value);
    event AllocationSubmitted(AuctionId auctionId, address allocator, uint256 score);
    event AllocatorRewardClaimed(AuctionId auctionId, address allocator, uint256 reward);

    // Privacy and settlement
    event RevealProcessed(AuctionId auctionId, address bidder, address proxy, bytes32 commitHash);

    // Stake and assets
    event StakeAdded(AuctionId auctionId, address bidder, uint256 amount);
    event StakeRefunded(AuctionId auctionId, address bidder, uint256 amount);
    event PenaltyApplied(AuctionId auctionId, address bidder, uint256 amount);
    event ForfeitureReward(AuctionId auctionId, address caller, uint256 amount);
    event ForfeitureRewardTransferred(AuctionId auctionId, address caller, uint256 amount);
    event BundleForfeited(AuctionId auctionId, address bidder, uint256 penalty);
    event AssetsDeposited(AuctionId auctionId, AssetId assetId, address token, uint256 amount);
    event AssetsWithdrawn(AuctionId auctionId, AssetId assetId, address token, uint256 amount);
    event ProceedsClaimed(AuctionId auctionId, address auctionOwner, uint256 numeraireAmount);
    event ProtocolFeesWithdrawn(AuctionId auctionId, address protocolWallet, uint256 amount);

    // ========================================
    // ERRORS
    // ========================================

    // Authorization
    error OnlyOwner();
    error Unauthorized();

    // Auction state
    error InvalidPhase(AuctionTypes.AuctionPhase expected, AuctionTypes.AuctionPhase actual);
    error AuctionNotActive(AuctionId auctionId, AuctionTypes.AuctionStatus status);
    error AuctionNotCancelled(AuctionId auctionId);
    error AuctionAlreadyExists();
    error AuctionNotFound();
    error AuctionNotSetup();
    error AuctionNotStarted();
    error AuctionNotEnded();
    error SetupNotComplete();
    error PhaseNotStarted(AuctionId auctionId);

    // Pause
    error MaxPauseDurationExceeded(uint256 totalPauseDuration, uint256 maxAllowed);
    error PauseDurationNotExceeded(uint256 totalPauseDuration, uint256 maxRequired);

    // Clock
    error ClockNotOpen();
    error ClockAlreadyOpen();

    // Bidding
    error InsufficientBidPoints();
    error InvalidBidsLength();
    error MaxStakeTooLow(AuctionId auctionId);
    error InvalidStakeAmount();
    error ActivityRuleViolation();

    // Bundle and allocation
    error DuplicateBundle();
    error InvalidBundle(AuctionId auctionId, BundleId bundleId);
    error InvalidQuantities(AuctionId auctionId, uint256 quantities);
    error DuplicateAllocation(AuctionId auctionId, bytes32 commitHash);
    error SenderIsNotProxy(AuctionId auctionId, bytes32 commitHash);
    error InvalidBundleQuantities(AuctionId auctionId, bytes32 commitHash);
    error EmptyAllocation(AuctionId auctionId);

    // Privacy and commit-reveal
    error InvalidCommitHash();
    error NoSuchCommitHash(AuctionId auctionId, bytes32 commitHash);
    error DuplicateReveal(AuctionId auctionId, bytes32 commitHash);
    error CommitHashNotYetRevealed(AuctionId auctionId, bytes32 commitHash);

    // Asset errors
    error InvalidNumeraire();
    error MismatchedNumeraires();
    error InvalidPool();
    error AssetNotFound(AuctionId auctionId, AssetId assetId);

    // Proceeds
    error ProceedsAlreadyClaimed(AuctionId auctionId);
    error World2NotImplemented();

    // Phase transition
    error CannotCancelInThisPhase(AuctionId auctionId, AuctionTypes.AuctionPhase phase);
    error PhaseNotExpired(AuctionId auctionId, AuctionTypes.AuctionPhase phase);
    error PhaseExpired(AuctionId auctionId, AuctionTypes.AuctionPhase phase);
    error NoSubmissionsReceived(AuctionId auctionId, AuctionTypes.AuctionPhase phase);
    error AuctionAlreadyFinished(AuctionId auctionId);

    // ETH validation
    error EthRequired();
    error EthNotAllowed();
}
