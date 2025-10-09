# Clock-Proxy Auction Implementation Specification

## TODO: Implementation Requirements

### Spending Validation and Penalty System
- `minSpendRatio` validation in auction config
- Spending ratio calculation and enforcement
- Spending violation detection and penalty application
- Escalating penalty system for repeated violations

### Dropout Penalty System
- Active dropout penalty enforcement
- Stake slashing on dropout
- Penalty distribution mechanism

### Maximum Rounds Enforcement
- Round limit checking in `startClockRound()`
- Automatic termination at max rounds
- Graceful auction conclusion

### Phase Duration Enforcement
- Phase duration tracking
- Automatic phase transitions
- Time-based auction progression

## Architecture

The Clock-Proxy Auction system uses two contracts:

1. **CPAManager**: Manager contract that handles auction logic and state management
2. **CPAHook**: Hook contract that all asset pools attach to, controlled by the CPAManager

The CPAManager is not a hook but a pure manager contract that interfaces with V4 pools through the CPAHook.

### Architecture Overview
```plaintext
CPAManager (single contract) - manages multiple auctions
    ↓ controls
CPAHook (single contract) - attached to all asset pools
    ↓ attached to
Asset Pool 1 (A<>USDC) - prices stored as sqrtPriceX96, operations blocked during auction
Asset Pool 2 (B<>USDC) - prices stored as sqrtPriceX96, operations blocked during auction  
Asset Pool 3 (C<>USDC) - prices stored as sqrtPriceX96, operations blocked during auction
```

### Initialization Process (this only happens once and is ready for all future auctions)
1. **Deploy CPAManager**: Single contract that will manage all auctions
2. **Deploy CPAHook**: With CPAManager address as constructor argument (allows CPAManager to modify state of the CPAHook)


### Multi-Auction Support
- **Auction IDs**: Each auction gets a unique auctionId
- **Auction Owners**: Each auction has its own owner (not the CPAManager owner)
- **Isolated State**: All auction variables are indexed by auctionId
- **Owner Controls**: Only the auction owner can start, pause, change phases, etc.
- **Concurrent Auctions**: Multiple auctions can run simultaneously with isolated state

### CPAHook Control Mechanism
- **Centralized Control**: CPAManager controls the single CPAHook
- **State Synchronization**: CPAManager calls setAuctionState() on CPAHook
- **Pool Allowance**: CPAManager can enable/disable specific pools via setPoolAllowed()
- **Operation Blocking**: CPAHook blocks all operations when auction is active

### Auction Creation Flow
1. **Create Auction**: Call CPAManager.createAuction(poolKeys, config, owner)
2. **Setup Phase**: Auction owner deposits assets and configures auction
  a. **Deploy Asset Pools**: Create pools A<>USDC, B<>USDC, C<>USDC with CPAHook and initial sqrtPriceX96
3. **Auction Execution**: Standard clock-proxy auction phases proceed
4. **Settlement**: Auction completes and pools return to normal operation

### Key Benefits of New Design
- **Gas Efficiency**: No need to deploy new hooks for each auction
- **Reusability**: Single CPAHook serves all asset pools
- **Scalability**: CPAManager can manage unlimited auctions
- **Simplicity**: Clear separation between auction logic and pool control
- **Flexibility**: Different auction owners can run concurrent auctions

### Price Management in Pools
- **Native V4 Pricing**: Prices stored as `sqrtPriceX96` directly in pools
- **Initial Price Setting**: Pools created with initial `sqrtPriceX96` during auction creation
- **Tick-Based Increments**: Price increments specified in ticks, not numeraire amounts
- **Doppler-Style Manipulation**: Price increases via swaps with no liquidity when excess demand exists
- **Price Formula**: `newPrice = priceFromTick(currentTick + tickIncrement)`

### Bidding System Changes
- **Bid Types**: Support for both exact output and exact input bids
- **Sign Convention**: Positive values = exact output, negative values = exact input
- **Multi-Asset Bidding**: Submit demands for multiple assets in single transaction
- **Stake Calculation**: Automatic stake calculation based on bid type and current prices
- **Example**: `[8, 0, -3]` = "8 units of asset A, nothing of asset B, 3 numeraire worth of asset C"

## Core Implementation

### Manager-Based Approach
The Clock-Proxy Auction uses a pure manager contract that interfaces with V4 pools through the CPAHook:

- **Setup phase**: Asset pools created with initial sqrtPriceX96
- **Clock phase**: Bidding through `submitBid()` with price discovery
- **Proxy phase**: Bundle submission through `submitBundle()`
- **Allocation phase**: Allocator competition through `submitAllocation()`
- **Settlement phase**: Token claiming through `claimToken()` or `claimAllTokens()`

### Stake Mechanism
- Bidders deposit numeraire tokens as stake
- Stake is used for token purchases during settlement
- Additional numeraire required if stake is insufficient
- Stake is refunded if not fully used

## Auction Phases

The auction system implements six phases:

1. **Setup**: Asset pool creation with initial sqrtPriceX96 prices
2. **Clock**: Price discovery with Doppler-style manipulation and multi-asset bidding
3. **Proxy**: Bundle submission with commit-reveal privacy system
4. **Allocation**: Allocator competition with on-chain scoring and 1% reward system
5. **Settlement**: Token claiming with batch operations
6. **Finished**: Auction completion

## Core Components

### CPAManager Contract

The CPAManager contract manages multiple concurrent auctions. Each auction has:
- Unique auction ID
- Owner with control permissions
- Isolated state storage
- Phase management

### CPAHook Contract

The CPAHook contract controls asset pools during auctions:
- Blocks trading/liquidity operations when auction is active
- Allows only CPAManager to execute operations
- Manages price manipulation via Doppler-style swaps

## Contract Structure

### CPAManager Contract
The main auction contract that:
- Manages multiple concurrent auctions with isolated state
- Handles all auction phases and transitions
- Manages commit-reveal system and proxy registration
- Controls the CPAHook during auctions
- Interfaces with V4 pools through the CPAHook

### CPAHook Contract
A hook contract that:
- Blocks trading/liquidity operations during auctions
- Controlled by CPAManager via `setAuctionState()` and `setPoolAllowed()`
- Shared across all asset pools
- Handles price manipulation via Doppler-style swaps

### Library Structure
- **CPASetup**: Handles auction creation and setup phase
- **CPAClockPhase**: Manages bidding and price discovery
- **CPAProxyPhase**: Handles bundle submission and proxy management
- **CPAAllocationPhase**: Manages allocator competition and scoring
- **CPASettlementPhase**: Handles token claiming and settlement

## Data Structures

### AuctionTypes Library

The system uses the following core data structures:

```solidity
enum AuctionPhase {
    Setup,      // Initial setup and configuration
    Clock,      // Price discovery phase
    Proxy,      // Bundle submission phase
    Allocation, // Allocator competition phase
    Settlement, // Final settlement phase
    Finished     // Auction finished
}

enum AuctionStatus {
    Active,
    Paused,
    Cancelled
}

struct AuctionInfo {
    address auctioneer;
    address commonNumeraire;
    AuctionConfig config;
    AuctionPhase currentPhase;
    AuctionStatus currentStatus;
    uint256 currentRound;
    Bid[] roundBids;
    uint256 clockOpen;
    PoolKey[] poolKeys;
    uint256 allocatorReward;
}

struct Bundle {
    AuctionId auctionId;
    bytes32 commitHash;
    uint256 value;
    uint256[] quantities;
    uint256 timestamp;
}

struct Allocation {
    AuctionId auctionId;
    address allocator;
    BundleId[] bundleIds;
    uint256 totalValue;
    uint256 timestamp;
}
```

### Storage Pattern

All auction state is stored in mappings indexed by AuctionId:
- `mapping(AuctionId => AuctionInfo) auctionInfo`
- `mapping(AuctionId => mapping(address => uint256)) bidderStake`
- `mapping(AuctionId => mapping(bytes32 => address)) revealedMappings`
- `mapping(AuctionId => mapping(BundleId => Bundle)) bundles`

## Implementation Details

### Phase Management

The auction system implements phase transitions through the following functions:

- `createAuction()`: Creates new auction and sets phase to Setup
- `endSetupPhase()`: Transitions from Setup to Clock
- `endClockPhase()`: Transitions from Clock to Proxy
- `endProxyPhase()`: Transitions from Proxy to Allocation
- `endAllocationPhase()`: Transitions from Allocation to Settlement
- `endSettlementPhase()`: Transitions from Settlement to Finished

### Bidding System

The bidding system supports two types of bids:
- **Exact Output**: Positive values indicate exact output amounts
- **Exact Input**: Negative values indicate exact input amounts

Bids are processed through `submitBid()` which:
1. Validates bidder has sufficient stake
2. Calculates required stake based on current prices
3. Updates bidder stake mapping
4. Stores bid in current round

### Commit-Reveal Privacy

The system maintains privacy through a two-salt commit-reveal system:
1. **Commit**: `generateCommitHash(bidder, proxy, saltA, saltB)` creates commit hash
2. **Registration**: Commit hash must be registered before any bids
3. **Bidding**: Bids reference commit hash, not actual bidder
4. **Reveal**: `reveal()` function discloses bidder-proxy mapping

### Allocator Competition

Allocators compete by submitting allocations:
1. **Bundle Selection**: Allocators select bundles using bundle IDs
2. **Scoring**: On-chain scoring algorithm evaluates allocations
3. **Winner Selection**: Highest scoring allocation wins
4. **Reward**: Winning allocator receives 1% of total bid value

### Settlement Process

The settlement process allows bidders to claim their allocated tokens:
1. **Individual Claims**: `claimToken()` for single asset claims (only the protocol owner is allowed here)
2. **Batch Claims**: `claimAllTokens()` for all assets at once
3. **Stake Usage**: Uses deposited stake first, additional numeraire if needed
4. **Asset Transfer**: Transfers assets directly to bidder

## Key Functions

### Auction Management
- `createAuction()`: Creates new auction with specified configuration
- `endSetupPhase()`: Transitions from Setup to Clock phase
- `endClockPhase()`: Transitions from Clock to Proxy phase
- `endProxyPhase()`: Transitions from Proxy to Allocation phase
- `endAllocationPhase()`: Transitions from Allocation to Settlement phase
- `endSettlementPhase()`: Transitions from Settlement to Finished phase

### Bidding System
- `submitBid()`: Submit bid with exact output/input amounts
- `calculateBidValue()`: Calculate required stake for bid
- `approveNumeraireForBidder()`: Approve numeraire tokens for bidder

### Privacy System
- `generateCommitHash()`: Create commit hash for privacy
- `registerCommit()`: Register commit hash before bidding
- `reveal()`: Reveal bidder-proxy mapping

### Allocation System
- `submitAllocation()`: Submit allocation for scoring
- `topAllocation()`: Get highest scoring allocation
- `claimAllocatorReward()`: Claim 1% reward for winning allocator

### Settlement System
- `claimToken()`: Claim single asset (owner only)
- `claimAllTokens()`: Claim all allocated assets
- `_handleClaimAllTokens()`: Internal callback for batch claims

## Access Control

The system implements the following access control patterns:

- **Auction Owners**: Control their specific auctions
- **CPAManager Owner**: Controls global settings and emergency functions
- **Bidders**: Can submit bids and claim tokens
- **Allocators**: Can submit allocations and claim rewards
- **CPAHook**: Only allows CPAManager to execute operations

## Error Handling

The system implements comprehensive error handling:

- **Phase Validation**: Functions check current auction phase
- **Stake Validation**: Ensures sufficient stake for operations
- **Privacy Validation**: Verifies commit-reveal integrity
- **Access Control**: Validates caller permissions
- **State Validation**: Ensures auction is in correct state for operations

## Implementation Rules

1. **Immutable Mapping**: Once a commitHash → proxy mapping exists, it cannot be overwritten
2. **Pre-Bid Registration**: Commit must be registered before any bid
3. **On-chain Scoring**: Scoring is done directly in Solidity
4. **Stake Requirement**: Bidders must deposit stake when submitting bids
5. **Allocator Competition**: Multiple allocators submit; best-scoring allocation wins
6. **Verification Priority**: Always verify commit before accepting a bid
7. **Stake Mechanism**: Bidders stake numeraire tokens for bidding
8. **Manager Control**: CPAManager manages all auction operations
