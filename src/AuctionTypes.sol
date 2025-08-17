// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";

/**
 * @title AuctionTypes
 * @notice Type definitions and structs for the Clock-Proxy Auction system
 * @author Clock-Proxy Auction Team
 */
library AuctionTypes {
	/// @notice Auction phases
	enum AuctionPhase {
		Setup,      // Initial setup and configuration
		Clock,      // Price discovery phase
		Proxy,      // Bundle submission phase
		Allocation, // Allocator competition phase
		Reveal,     // Identity disclosure phase
		Settlement, // Final settlement phase
		Cancelled,   // Auction cancelled by owner
		Finished     // Auction finishedf
	}

	/// @notice Bundle structure for proxy submissions
	struct Bundle {
		uint256 bundleId;           // Unique identifier for the bundle
		uint256 value;              // Value of the bundle to the bidder
		uint256[] itemIds;          // Array of item IDs in this bundle
		uint256[] quantities;       // Corresponding quantities for each item
		uint256 timestamp;          // When bundle was submitted
	}

	/// @notice Allocation structure for allocator submissions
	struct Allocation {
		uint256 allocationId;       // Unique identifier for the allocation
		address allocator;          // Address of the allocator
		uint256[] bundleIds;        // Array of selected bundle IDs
		uint256 totalValue;         // Total value of the allocation
		uint256 score;              // Allocation score
		uint256 timestamp;          // When allocation was submitted
	}

	/// @notice Bid structure for clock phase
	struct Bid {
		address bidder;             // Address of the bidder
		bytes32 commitHash;         // Commit hash for privacy
		uint256 stakeAmount;        // Stake amount for this bid
		uint256[] itemIds;          // Array of item IDs demanded
		uint256[] quantities;       // Corresponding quantities demanded
		uint256 round;              // Clock round when bid was submitted
		uint256 timestamp;          // When bid was submitted
	}

	/// @notice Reveal structure for identity disclosure
	struct Reveal {
		address bidder;             // Address of the bidder
		address proxy;              // Address of the proxy
		bytes32 saltA;              // First salt for commit hash
		bytes32 saltB;              // Second salt for commit hash
		uint256 finalPurchaseAmount; // Final amount bidder will pay
		uint256 timestamp;          // When reveal was submitted
	}

	/// @notice Configuration structure for auction parameters
	struct AuctionConfig {
		uint256 minSpendRatio;              // Minimum spending ratio (basis points)
		uint256 dropoutSlashRatio;          // Dropout penalty ratio (basis points)
		uint256 spendingViolationSlashRatio; // Spending violation penalty (basis points)
		uint256 maxRounds;                  // Maximum clock rounds
		uint256 clockPriceIncrement;        // Price increment per round
		uint256 allocatorStakeRequirement;  // Minimum stake for allocators
		uint256 proxyStakeRequirement;      // Minimum stake for proxies
		uint256 maxStakeCap;                // Maximum stake per bidder
		uint256 revealWindow;               // Time window for reveals
		uint256 allocationWindow;           // Time window for allocations
	}

	/// @notice Pool information structure
	struct PoolInfo {
		PoolKey key;                // Pool key
		uint256 currentPrice;       // Current price in the pool
		uint256 depositAmount;      // Amount deposited for auction
		uint256 excessDemand;       // Current excess demand
	}
}
