// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { AuctionId } from "./AuctionId.sol";
import { AssetConfig, AssetId } from "./AssetConfig.sol";
import { BundleId } from "./BundleId.sol";

/**
 * @title AuctionTypes
 * @notice Type definitions and structs for the Clock-Proxy Auction system
 */
library AuctionTypes {
    /// @notice Auction phases
    enum AuctionPhase {
        Setup,      // Initial setup and configuration
        Clock,      // Price discovery phase
        Proxy,      // Bundle submission phase
        Allocation, // Allocator competition phase
        Settlement, // Final settlement phase
        Finished    // Auction finished
    }

    /// @notice Auction status
    enum AuctionStatus {
        Active,
        Paused,
        Cancelled
    }

    /// @notice Maximum total pause duration (72 hours)
    uint256 public constant MAX_PAUSE_DURATION = 72 * 60 * 60;

    /// @notice Bundle structure for proxy submissions
    struct Bundle {
        AuctionId auctionId;
        bytes32 commitHash;
        uint256 value;
        uint256[] quantities;   // one entry per asset, indexed same as AuctionInfo.assets
        uint256 timestamp;
    }

    /// @notice Allocation structure for allocator submissions
    struct Allocation {
        AuctionId auctionId;
        address allocator;
        BundleId[] bundleIds;
        uint256 totalValue;
        uint256 timestamp;
    }

    struct TopAllocation {
        Allocation allocation;
        uint256 score;
        uint256 totalValue;
    }

    /// @notice Bid structure for clock phase
    struct Bid {
        address bidder;
        uint256 stakeAmount;
        uint256[] itemIds;
        uint256[] quantities;
        uint256 round;
        uint256 timestamp;
    }

    /// @notice Reveal structure for identity disclosure
    struct Reveal {
        address bidder;
        address proxy;
        bytes32 saltA;
        bytes32 saltB;
    }

    /// @notice Configuration structure for auction parameters
    struct AuctionConfig {
        address commonNumeraire;
        uint256 minSpendRatio;              // Minimum spending ratio (basis points)
        uint256 dropoutSlashRatio;          // Dropout penalty ratio (basis points)
        uint256 spendingViolationSlashRatio; // Spending violation penalty (basis points)
        uint256 maxRounds;
        uint256 allocatorRewardPct;         // Allocator reward (basis points of numeraire)
        uint256[] phaseDurations;           // [proxy, allocation, settlement]
        AssetConfig[] assets;               // One entry per auctioned token
        bool createPoolOnFinish;            // If true, returnProceeds creates a V4 pool (World 2)
    }

    /// @notice Per-asset state tracked during and after the auction
    struct AssetInfo {
        AssetConfig config;
        uint256 depositAmount;      // actual amount deposited (== config.supply after deposit)
        int256 excessDemand;        // demand - supply at end of last clock round
        uint256 lastOversoldPrice;  // currentPrice when last oversold; used for revertUndersoldPrices
        uint256 currentPrice;       // live price; set to clearingPrice at clock end, immutable after
        AuctionId auctionId;
    }

    struct AuctionInfo {
        address auctionOwner;
        address commonNumeraire;
        AuctionTypes.AuctionConfig config;
        AuctionPhase currentPhase;
        AuctionStatus currentStatus;
        uint256 clockOpen;
        uint256 currentRound;
        AssetConfig[] assets;       // mirrors config.assets; kept here for quick access
        uint256 allocatorReward;
        bool[] changedPrices;       // which assets had a price change in the current round
        uint256 lastRevenue;
        uint256 totalPauseDuration;
    }
}
