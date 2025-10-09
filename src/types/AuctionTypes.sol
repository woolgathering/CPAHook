// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { SwapParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";
import { AuctionId } from "./AuctionId.sol";
import { BundleId } from "./BundleId.sol";

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
		Settlement, // Final settlement phase
		Finished     // Auction finished
	}

	/// @notice Auction status
	enum AuctionStatus {
		Active,
		Paused,
		Cancelled
	}

	/// @notice Bundle structure for proxy submissions
	struct Bundle {
		AuctionId auctionId;        // ID of the auction for this bundle
		bytes32 commitHash;         // Commit hash for privacy
		uint256 value;              // Value of the bundle to the bidder
		uint256[] quantities;       // Corresponding quantities for each item
		uint256 timestamp;          // When bundle was submitted
	}

	/// @notice Allocation structure for allocator submissions
	struct Allocation {
		AuctionId auctionId;        // ID of the auction for this allocation
		address allocator;          // Address of the allocator
		BundleId[] bundleIds;        // Array of selected bundle IDs
		uint256 totalValue;         // Total value of the allocation
		uint256 timestamp;          // When allocation was submitted
	}

	struct TopAllocation {
		Allocation allocation;
		uint256 score;
		uint256 totalValue;
	}

	/// @notice Bid structure for clock phase
	struct Bid {
		address bidder;             // Address of the bidder
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
	}

	/// @notice Configuration structure for auction parameters
	struct AuctionConfig {
		address commonNumeraire;
		uint256 minSpendRatio;              // Minimum spending ratio (basis points)
		uint256 dropoutSlashRatio;          // Dropout penalty ratio (basis points)
		uint256 spendingViolationSlashRatio; // Spending violation penalty (basis points)
		uint256 maxRounds;                  // Maximum clock rounds
		uint256 allocatorRewardPct;         // Allocator reward for an auction in terms of numeraire (basis points)ttlement phase
		uint256[] phaseDurations;                // Durations for each phase [clock, proxy, allocation, settlement]
		PoolKey[] poolKeys;                 // Pool keys for the auction
		uint160[] initialSqrtPricesX96;     // Initial sqrt prices for each pool
		int24[] priceIncrements;            // Price increments in ticks for each pool
	}

	/// @notice Pool information structure
	struct PoolInfo {
		PoolKey key;                // Pool key
		int24 startingTick;         // Starting tick for the pool
		int24 priceIncrement;       // Price increment in ticks, added to the current tick at the end of the clock phase if there is excess demand
		uint256 depositAmount;      // Amount deposited for auction
		uint256 excessDemand;       // Current excess demand
		AuctionId auctionId;        // ID of the auction for this pool
		bytes32 positionId;         // ID of the position for this pool when we deposit liquidity
	}

	struct AuctionInfo {
		address auctionOwner;
		address commonNumeraire;
		AuctionTypes.AuctionConfig config;
		AuctionPhase currentPhase;
		AuctionStatus currentStatus;
		uint256 clockOpen;
		uint256 currentRound;
		PoolKey[] poolKeys;         // Array of pool keys for this auction
		uint256 allocatorReward;
		bool[] changedPrices;       // Array tracking which prices changed in current round
		uint256 lastRevenue;        // Last revenue for EMA calculation
	}
	
	/// @notice Callback data structure for bid as liquidity operations
	struct CallbackDataBid {
		address sender;
		address token0;
		address token1;
		int128 amount0;  
		int128 amount1;  
		uint256 deadline; // deadline for the operation
	}

	struct CallbackDataMintPosition {
		PoolKey poolKey;
		int24 tickLower;
		int24 tickUpper;
		uint256 liquidity;
		bytes hookData;
		AuctionId auctionId;
	}

	struct CallbackDataClaimToken {
		address bidder;
		address numeraire;
		AuctionId auctionId;
		PoolKey poolKey;
		SwapParams swapParams;
	}

	struct CallbackDataClaimAllTokens {
		address bidder;
		address numeraire;
		AuctionId auctionId;
		PoolKey[] poolKeys;
		uint256[] allocatedQuantities;
	}

	struct CallbackDataRefundStake {
		address numeraire;
		uint256 amount;
	}	

	struct CallbackDataClaimAllocatorReward {
		address allocator;
		address numeraire;
		uint256 reward;
	}

}
