# Rok

Rok is a privacy-preserving auction protocol built on Uniswap V4 hooks that enables efficient multi-item token auctions with commit-reveal privacy and allocator competition.

## Overview

Rok implements a clock-proxy auction system that leverages hooks and the singleton architecture of Uniswap V4. Clock-proxy auctions are established systems for combinatorial price discovery, proven in complex asset distributions across traditional finance. See [The Clock-Proxy Auction:
A Practical Combinatorial Auction Design](https://web.stanford.edu/~milgrom/publishedarticles/clock-proxy-auction.pdf) or [Clock Auctions, Proxy Auctions, and Possible Hybrids](https://wireless.fcc.gov/auctions/conferences/combin2003/presentations/ausubel-hybrid-clock-proxy-auctions.ppt) for more information.

The system addresses the need for institutional-grade auction mechanisms in DeFi by providing combinatorial price discovery through iterative bidding with privacy-preserving commit-reveal mechanisms and competitive allocation determination. This brings a well-understood and studied auction mechanism to the blockchain ecosystem. The architecture uses a two-contract design with CPAManager handling auction logic and CPAHook controlling Uniswap V4 pools during auctions. The auction system is designed for scenarios requiring fair distribution of assets with price discovery, such as token launches, asset bundle sales, and private auctions. It enables bidders to express preferences across multiple assets while maintaining privacy through commit-reveal mechanisms, and uses allocator competition to determine optimal allocations with on-chain rewards.

A proper whitepaper is forthcoming.

### Key Features

- Privacy-Preserving Bidding: Commit-reveal system maintains bidder-proxy anonymity during auction
- Multi-Asset Auctions: Support for auctions across multiple token pairs with shared numeraire
- Allocator Competition: On-chain scoring system with 1% rewards for optimal allocations
- Batch Settlement: Efficient token claiming with `claimAllTokens()` function
- Uniswap V4 Integration: Built using V4 hooks for pool control and price manipulation

## Architecture

The system uses a two-contract architecture:

- CPAManager: Manager contract that handles auction logic and state management
- CPAHook: V4 hook that controls asset pools during auctions

### Uniswap V4 Integration

The system integrates with Uniswap V4 through:
- CPAHook: Implements V4 hook interface to control pool operations
- Price Manipulation: Uses Doppler-style swaps for price discovery during the clock phase
- Settlement: Executes swaps for token distribution

## Commit-Reveal Privacy System

The auction system implements a two-salt commit-reveal mechanism to maintain bidder-proxy anonymity during the auction process. Bidders generate a commit hash using two salts (saltA and saltB) and their chosen proxy address, then register this hash before any bidding begins. The proxy receives the entire commit hash privately so that the bidder can later reveal the relationship. This privacy is maintained throughout the clock and proxy phases with the actual bidder-proxy mapping only disclosed during the reveal phase. This anonymity is fundamental to the proxy auction mechanism, ensuring that allocators can submit optimal allocations without bias during the allocation phase.

## Auction Mechanics

The auction follows a six-phase process with privacy-preserving commit-reveal mechanisms:

```
Setup Phase
    ↓
Clock Phase (Bidding + Commit Registration)
    ↓
Proxy Phase (Bundle Submission)
    ↓
Allocation Phase (Allocator Competition)
    ↓
Reveal Phase (Identity Disclosure)
    ↓
Settlement Phase (Token Claiming)
    ↓
Finished Phase
```

### Phase Details

Setup Phase: Auction creation with asset pools and configuration
- Create asset pools (A<>USDC, B<>USDC, C<>USDC) with CPAHook attached
- Configure auction parameters and numeraire
- Auctioneer (auction owner) is set

Clock Phase: Price discovery through iterative bidding
- Bidders submit bids with deposit: `submitBid(auctionId, demands, maxDepositForThisBid)`
- Commit-reveal privacy: `registerCommit(commitHash)` before bidding
- Price discovery through a traditional clock auction
- Price tracking in UniSwap V4 pools via price manipulation
- Off-chain: Bidders share their commit hash with their chosen proxy (critical step)

Proxy Phase: Bundle submission with privacy
- Proxies submit bundles: `submitBundle(commitHash, bundleData)`
- Bundle data includes quantities for each asset
- Bidder ↔ proxy link privacy is maintained through commit hashes
- Off-chain: Bidders communicate preferences to proxies to be encoded into bundles (often proxies are the same entity as the bidders)

Allocation Phase: Competitive allocation determination
- Allocators submit allocations as sets of bundles maximizing auctioneer revenue: `submitAllocation(allocationData)`
- On-chain scoring determines winning allocation (would be powerful to move offchain and enable more complex metrics to maximize/minimize)
- Best allocation submitted by the end of the phase is chosen as the top allocation

Reveal Phase: Identity disclosure
- Technically part of the settlement phase but must occur after allocation and prior to claiming tokens
- Bidders reveal identity: `reveal(bidderID, saltA, proxyAddress, saltB)`
- Links bidder ↔ proxy publicly
- Enables verification of bidder-proxy relationship and therefore bidder-allocated bundle relationship

Settlement Phase: Token claiming
- Batch token claiming: `claimAllTokens(auctionId, commitHash)`
- Individual token claiming: `claimToken(auctionId, commitHash, poolId)` (protocol owner only)
- Uses deposited stake first, additional numeraire if needed
- Refunds excess stake to bidders (if any)
- Winning allocator receives a reward according to the auctioneers' configuration: `claimAllocatorReward(auctionId)`

Finished Stage (not fully implemented)
- Liquidity positions in the pools are transferred from the CPAManager to the auctioneer
- Bidders who did not claim in settlement forfeit their allocation
- Pools are opened to trading and liquidity provisioning by anyone

## Installation

### Requirements
- Foundry (stable version)

### Setup
```bash
# Clone repository
git clone https://github.com/woolgathering/CPAHook/tree/clock-proxy-auction
cd clock-proxy-auction

# Install dependencies
forge install

# Build contracts
forge build

# Run tests
forge test
```

## Usage

### Creating an Auction

```solidity
// Assume CPAManager and CPAHook are already deployed
ICPAManager manager = ICPAManager(MANAGER_ADDRESS);

// Create auction with configuration
AuctionTypes.AuctionConfig memory config = AuctionTypes.AuctionConfig({
    commonNumeraire: address(usdcToken),           // Common numeraire token
    minSpendRatio: 1000,                          // 10% minimum spending ratio
    dropoutSlashRatio: 1000,                      // 10% dropout penalty
    spendingViolationSlashRatio: 2000,            // 20% spending violation penalty
    allocatorRewardPct: 100,                      // 1% allocator reward
    maxRounds: 100,                               // Maximum clock rounds
    phaseDurations: [3600, 1800, 3600, 3600],    // [clock, proxy, allocation, settlement] in seconds
    poolKeys: [asset1PoolKey, asset2PoolKey],    // Asset pools
    initialSqrtPricesX96: [79228162514264337593543950336, 112045541949572287496682733568], // Initial prices
    priceIncrements: [100, 50]                    // Price increments in ticks
});

// Create auction
AuctionId auctionId = manager.createAuction(poolKeys, config, auctionOwner);
```

### Bidding Process

```solidity
// Start clock round
manager.startClockRound(auctionId);

// Bidders create commit proxy hashes (OFF-CHAIN)
// bytes32 commitHash1 = keccak256(abi.encodePacked(bidder1, proxy1, saltA1, saltB1));
// bytes32 commitHash2 = keccak256(abi.encodePacked(bidder2, proxy2, saltA2, saltB2));
// bytes32 commitHash3 = keccak256(abi.encodePacked(bidder3, proxy1, saltA3, saltB3));

// Register commit hashes for privacy (called by proxies)
manager.commitToBidder(auctionId, commitHash1);
manager.commitToBidder(auctionId, commitHash2);
manager.commitToBidder(auctionId, commitHash3);

// Submit bids with stake (called by bidders)
int256[] memory demands1 = [100, 50, 200]; // demand quantities for each asset at current prices
int256[] memory demands2 = [50, 100, 75];  // demand quantities for each asset at current prices
int256[] memory demands3 = [25, 100, 150]; // demand quantities for each asset at current prices

uint256 maxDepositThisBid = 1000e18;
manager.submitBid(auctionId, demands1, maxDepositThisBid); // Bidder 1
manager.submitBid(auctionId, demands2, maxDepositThisBid); // Bidder 2
manager.submitBid(auctionId, demands3, maxDepositThisBid); // Bidder 3

// Several rounds go by, more bids are accepted, price rises until there are no over-demanded assets

// End clock round
// Prices at the end of the clock phase are final
manager.endClockRound(auctionId);
```

### Proxy Phase (Bundle Submission)

```solidity
// Proxies can submit multiple bundles on behalf of bidders
// First proxy submits 2 bundles for bidder1
AuctionTypes.Bundle memory bundle1a = AuctionTypes.Bundle({
    auctionId: auctionId,
    commitHash: commitHash1,
    value: 1000e18,                    // Total value of the bundle (curretly unused)
    quantities: [50, 25],             // First bundle: 50 asset1, 25 asset2
    timestamp: block.timestamp
});

AuctionTypes.Bundle memory bundle1b = AuctionTypes.Bundle({
    auctionId: auctionId,
    commitHash: commitHash1,
    value: 1200e18,
    quantities: [60, 30],             // Second bundle: 60 asset1, 30 asset2
    timestamp: block.timestamp
});

// Second proxy submits 3 bundles for bidder2
AuctionTypes.Bundle memory bundle2a = AuctionTypes.Bundle({
    auctionId: auctionId,
    commitHash: commitHash2,
    value: 750e18,
    quantities: [35, 25],             // First bundle: 35 asset1, 25 asset2
    timestamp: block.timestamp
});

AuctionTypes.Bundle memory bundle2b = AuctionTypes.Bundle({
    auctionId: auctionId,
    commitHash: commitHash2,
    value: 800e18,
    quantities: [38, 29],             // Second bundle: 38 asset1, 29 asset2
    timestamp: block.timestamp
});

AuctionTypes.Bundle memory bundle2c = AuctionTypes.Bundle({
    auctionId: auctionId,
    commitHash: commitHash2,
    value: 850e18,
    quantities: [41, 33],             // Third bundle: 41 asset1, 33 asset2
    timestamp: block.timestamp
});

// Third proxy submits 2 bundles for bidder3
AuctionTypes.Bundle memory bundle3a = AuctionTypes.Bundle({
    auctionId: auctionId,
    commitHash: commitHash3,
    value: 900e18,
    quantities: [45, 35],             // First bundle: 45 asset1, 35 asset2
    timestamp: block.timestamp
});

AuctionTypes.Bundle memory bundle3b = AuctionTypes.Bundle({
    auctionId: auctionId,
    commitHash: commitHash3,
    value: 950e18,
    quantities: [50, 40],             // Second bundle: 50 asset1, 40 asset2
    timestamp: block.timestamp
});

// Submit bundles (called by proxies)
// First proxy submits 2 bundles for bidder1
manager.submitBundle(auctionId, commitHash1, bundle1a);
manager.submitBundle(auctionId, commitHash1, bundle1b);

// Second proxy submits 3 bundles for bidder2
manager.submitBundle(auctionId, commitHash2, bundle2a);
manager.submitBundle(auctionId, commitHash2, bundle2b);
manager.submitBundle(auctionId, commitHash2, bundle2c);

// Third proxy submits 2 bundles for bidder3
manager.submitBundle(auctionId, commitHash3, bundle3a);
manager.submitBundle(auctionId, commitHash3, bundle3b);

// End proxy phase
manager.endProxyPhase(auctionId);
```

### Allocation Phase (Competitive Allocation)

```solidity
// Allocators compete to find the optimal allocation
// Each bidder can only have one bundle selected in any allocation
// Allocator 1 submits a conservative allocation (1 bundle from bidder1 only)
BundleId[] memory allocator1Bundles = new BundleId[](1);
allocator1Bundles[0] = BundleIdLibrary.createId(commitHash1, keccak256(abi.encode([50, 25]))); // bundleId1a

AuctionTypes.Allocation memory allocation1 = AuctionTypes.Allocation({
    auctionId: auctionId,
    allocator: allocator1,
    bundleIds: allocator1Bundles,
    totalValue: 0,                    // Calculated automatically
    timestamp: block.timestamp
});

manager.submitAllocation(auctionId, allocation1);

// Allocator 2 submits a different allocation (1 bundle from bidder2 only)
BundleId[] memory allocator2Bundles = new BundleId[](1);
allocator2Bundles[0] = BundleIdLibrary.createId(commitHash2, keccak256(abi.encode([35, 25]))); // bundleId2a

AuctionTypes.Allocation memory allocation2 = AuctionTypes.Allocation({
    auctionId: auctionId,
    allocator: allocator2,
    bundleIds: allocator2Bundles,
    totalValue: 0,                    // Calculated automatically
    timestamp: block.timestamp
});

manager.submitAllocation(auctionId, allocation2);

// Allocator 3 submits a comprehensive allocation (1 bundle from each bidder)
BundleId[] memory allocator3Bundles = new BundleId[](3);
allocator3Bundles[0] = BundleIdLibrary.createId(commitHash1, keccak256(abi.encode([60, 30]))); // bundleId1b
allocator3Bundles[1] = BundleIdLibrary.createId(commitHash2, keccak256(abi.encode([38, 29]))); // bundleId2b
allocator3Bundles[2] = BundleIdLibrary.createId(commitHash3, keccak256(abi.encode([45, 35]))); // bundleId3a

AuctionTypes.Allocation memory allocation3 = AuctionTypes.Allocation({
    auctionId: auctionId,
    allocator: allocator3,
    bundleIds: allocator3Bundles,
    totalValue: 0,                    // Calculated automatically
    timestamp: block.timestamp
});

manager.submitAllocation(auctionId, allocation3);

// End allocation phase (winner determined by highest revenue)
manager.endAllocationPhase(auctionId);
```

### Settlement

```solidity
// First, bidders reveal their identity to link bidder ↔ proxy
manager.reveal(auctionId, proxy1, saltA1, saltB1); // Called by bidder1
manager.reveal(auctionId, proxy2, saltA2, saltB2); // Called by bidder2
manager.reveal(auctionId, proxy1, saltA3, saltB3); // Called by bidder3

// Then, each bidder claims their allocated tokens paying with their stake first, their own wallet second
// If there is stake left over, it is refunded to the bidder
manager.claimAllTokens(auctionId, commitHash1); // Called by bidder1
manager.claimAllTokens(auctionId, commitHash2); // Called by bidder2
manager.claimAllTokens(auctionId, commitHash3); // Called by bidder3

// Finally, the winning allocator claims their reward
manager.claimAllocatorReward(auctionId); // Called by winningAllocator

// Alternative: claim individual tokens (owner only)
// manager.claimToken(auctionId, commitHash, poolId);
```

## Testing

The project includes some test coverage:

```bash
# Run all tests
forge test

# Run specific test files
forge test --match-path test/CPACompleteFlow.t.sol
forge test --match-path test/CPAClockPhase.t.sol
forge test --match-path test/CPASettlementPhase.t.sol
```

### Test Coverage

- Complete Flow Tests: End-to-end auction scenarios
- Phase Transition Tests: All auction phase changes
- Privacy Tests: Commit-reveal mechanism validation
- Settlement Tests: Token claiming and stake management

## Documentation

Technical documentation is available in the `docs/` directory. It is not technical and is not guarenteed to be up-to-date.:

- Implementation Specification: `docs/productAndIdeas/clockProxyHookImplementation.md`
- Logic Flow: `docs/productAndIdeas/mainLogicFlow.md`
- V4 Analysis: `docs/productAndIdeas/clockProxyV4Analysis.md`

## Partner Integrations

No partner integrations - This project focuses on core Uniswap V4 hook functionality without external integrations.

## Development

### Project Structure

```
src/
├── CPAManager.sol              # Main auction manager
├── CPAHook.sol                # V4 hook for pool control
├── base/
│   └── CPAStorage.sol         # Storage patterns
├── libraries/
│   ├── CPASetup.sol           # Setup phase logic
│   ├── CPAClockPhase.sol      # Bidding logic
│   ├── CPAProxyPhase.sol      # Bundle submission
│   ├── CPAAllocationPhase.sol # Allocator competition
│   └── CPASettlementPhase.sol # Token claiming
├── types/
│   ├── AllocationId.sol       # Allocation ID type
│   ├── AuctionId.sol          # Auction ID type
│   ├── AuctionTypes.sol       # Type definitions
│   └── BundleId.sol           # Bundle ID type
└── utils/
    ├── CommitReveal.sol       # Commit-reveal utilities
    ├── IErrorsAndEvents.sol   # Interface for errors and events
    ├── PoolUtils.sol          # Pool management utilities
    └── PriceUtils.sol         # Price calculation utilities
```

### Key Components

- Auction Management: Multi-auction support with isolated state
- Privacy System: Two-salt commit-reveal for bidder-proxy anonymity
- Allocator Rewards: 1% fee system with on-chain claiming
- Batch Operations: Efficient settlement with `claimAllTokens()`
- Gas Optimization: Library-based architecture for efficiency

### Known Issues

These issues will be mitigated in future versions. There is nothing in the architecture that precludes solutions.

- The numeraire is currently required to be in 18 decimal precision. Future versions will eliminate this requirement.
- Bidder dropout is not yet implemented. If a proxy does not submit a bid on behalf of a bidder or the bidder is not included in the final allocation, their stake is lost.
- The auction manager must manually progress the auction.
- Stakes are unrefundable if an auction is cancelled.

## License

This project is licensed under the BUSL-1.1 License - see the LICENSE file for details.
