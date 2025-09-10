# Clock-Proxy Auction Hook Implementation Roadmap

## Two-Contract Architecture Design

### Core Design Philosophy
The Clock-Proxy Auction system has been redesigned to use two main contracts for better efficiency and reusability:

1. **CPAManager**: Manager contract that handles auction logic and state management (NO LONGER A HOOK)
2. **PoolHook**: Shared hook that all asset pools attach to, controlled by the CPAManager

This design eliminates the need to deploy new hooks for each auction, making the system more gas-efficient and easier to manage. The CPAManager is now a pure manager contract that interfaces with V4 pools through the PoolHook.

### Architecture Overview
```plaintext
CPAManager (single contract) - manages multiple auctions
    ↓ controls multiple
PoolHook (single contract) - attached to all asset pools
    ↓ attached to
Asset Pool 1 (A<>USDC) - prices stored as sqrtPriceX96, swap/liquidity operations are blocked except for the CPAManager
Asset Pool 2 (B<>USDC) - prices stored as sqrtPriceX96, swap/liquidity operations are blocked except for the CPAManager
Asset Pool 3 (C<>USDC) - prices stored as sqrtPriceX96, swap/liquidity operations are blocked except for the CPAManager
```

### Initialization Process (this only happens once and is ready for all future auctions)
1. **Deploy CPAManager**: Single contract that will manage all auctions
2. **Deploy PoolHook**: With CPAManager address as constructor argument (allows CPAManager to modify state of the PoolHook)


### Multi-Auction Support
- **Auction IDs**: Each auction gets a unique auctionId
- **Auction Owners**: Each auction has its own owner (not the CPAManager owner)
- **Isolated State**: All auction variables are indexed by auctionId
- **Owner Controls**: Only the auction owner can start, pause, change phases, etc.

### PoolHook Control Mechanism
- **Centralized Control**: CPAManager controls all PoolHooks
- **State Synchronization**: CPAManager calls setAuctionState() on PoolHooks
- **Pool Allowance**: CPAManager can enable/disable specific pools via setPoolAllowed()
- **Operation Blocking**: PoolHook blocks all operations when auction is active

### Auction Creation Flow
1. **Create Auction**: Call CPAManager.createAuction(poolKeys, config, owner)
2. **Setup Phase**: Auction owner deposits assets and configures auction
  a. **Deploy Asset Pools**: Create pools A<>USDC, B<>USDC, C<>USDC with PoolHook and initial sqrtPriceX96
3. **Auction Execution**: Standard clock-proxy auction phases proceed
4. **Settlement**: Auction completes and pools return to normal operation

### Key Benefits of New Design
- **Gas Efficiency**: No need to deploy new hooks for each auction
- **Reusability**: Single PoolHook serves all asset pools
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

## Manager-Based Architecture Design

### Core Manager-Based Approach
The Clock-Proxy Auction uses a pure manager contract that interfaces with V4 pools through the PoolHook. The auction phases are managed by the CPAManager:

- Setup phase: Asset pools created with initial sqrtPriceX96
- Clock phase: Bidding through CPAManager.placeBid() with price discovery
- Proxy phase: Bundle submission through `submitBundle()` (no hook interaction)
- Allocation phase: Allocator competition through `submitAllocation()` (no hook interaction)
- Reveal phase: Identity disclosure and stake management (no hook interaction)
- Settlement phase: Bidders purchase allocations through asset pool swaps

### Item Sub-Pool Structure
- Starting price provides baseline for later price manipulation
- Final prices set through Doppler-style manipulation at clock round ends. Price at clock phase end is final price.
- Items deposited as LP position at a price <= final price to ensure sufficient liquidity at the correct price.

### Liquidity-as-Stake Mechanism
- CPAManager contract owns all deposited liquidity during auction
- LP token mapping tracks bidder->stake relationship (a mapping for now, tokens for future)
- Stake used for item purchases or penalty application
- Contract controls liquidity until auction end

### Bidding Mechanism
- Bidder calls CPAManager.placeBid()
- CPAManager captures numeraire amount and stores LP token mapping
- Bid points calculated as 1:1 ratio with deposited numeraire
- Contract owns deposited liquidity until auction end

### Settlement Mechanism
- Bidders claim through swap on asset pools
- PoolHook intercepts in `beforeSwap` and validates eligibility
- PoolHook processes claim using deposited stake first, extra numeraire as required
- Execute swaps in item pools using stake as payment
- Stake converted to liquidity in item pools on auctioneer's behalf (normal Uniswap behavior)

### Manager-Based Benefits
- Clean separation of concerns - Manager handles logic, Hook handles pool control
- Natural gas efficiency - Direct pool interactions are optimized
- Atomic operations - Bids and price updates happen atomically
- Native integration - Works seamlessly with V4's architecture
- Simplified testing - Manager contract is easier to test than hook

## Overview
This auction design ensures that:
- During the Clock Phase: The mapping between bidders and their proxies is hidden.
- Post Allocation / Reveal Phase: The mapping is disclosed, enabling verification of correctness.
- Spam resistance: Only registered proxies with staked deposits can submit bundles.
- Allocator competition: Multiple allocators propose allocations; the best one is selected and rewarded on-chain.
- Pre-bid registration: Proxies must register before any bids referencing their commitHash are accepted.
- Hook-native implementation: Auction phases map directly to V4 hook behaviors with liquidity-as-stake mechanism.

This document outlines the implementation plan for converting the clock-proxy auction system from the Python simulation into a production-ready Uniswap V4 hook. The implementation will follow the specifications outlined in `mainLogicFlow.md` and `clockProxyV4Analysis.md`.

## Architecture Plan

### 1. Core Contract Structure

#### Main Auction Contract: `CPAManager.sol`
- **NO LONGER A HOOK** - Pure manager contract
- Implements the main auction logic and state management for multiple auctions
- Handles all auction phases and transitions
- Manages commit-reveal system and proxy registration
- Controls all PoolHooks during auctions
- Supports multiple concurrent auctions with isolated state
- Interfaces with V4 pools through PoolHook

#### Pool Control Contract: `PoolHook.sol`
- Simple hook that blocks trading/liquidity operations during auctions
- Controlled by CPAManager via `setAuctionState()` and `setPoolAllowed()`
- Shared across all asset pools
- Centralized control mechanism for auction state
- Handles price manipulation via Doppler-style swaps

#### Library Contracts
- `AuctionTypes.sol` - Structs, enums, and type definitions
- `CommitReveal.sol` - Commit hash generation and validation logic
- `AllocationScoring.sol` - Allocation evaluation and scoring algorithms

### 2. Key Components Breakdown

#### A. State Management
```solidity
// Core auction state
AuctionPhase public currentPhase;
uint256 public currentRound;
mapping(bytes32 => address) public commitProxy; // commitHash -> proxyAddress
mapping(uint256 => address) public lpTokenToBidder; // LP token ID -> bidder
mapping(address => uint256[]) public bidderLpTokens; // bidder -> LP token IDs
address public commonNumeraire; // Y token shared across all pools
Allocation[] public allocations; // proposed allocations
address public winningAllocator;
PoolKey[] public itemPools; // item pool addresses
bool public poolsOpened; // trading status

// Pool information (updated structure)
struct PoolInfo {
    PoolKey key;                // Pool key
    int24 startingTick;         // Starting tick for the pool
    int24 priceIncrement;       // Price increment in ticks
    uint256 depositAmount;      // Amount deposited for auction
    uint256 excessDemand;       // Current excess demand
    AuctionId auctionId;        // ID of the auction for this pool
}
```

#### B. Hook System
- CPAManager controls multiple PoolHooks
- PoolHooks block trading/liquidity during auction except for auction hook
- CPAManager manages prices and liquidity across all pools
- Common numeraire constraint enforced across all pools

#### C. Commit-Reveal System
- Two-salt unlinkability system as described
- Pre-bid registration requirement
- ERC1155 token minting for bidder representation
- Stake binding and validation through liquidity deposits

### 3. Hook Permissions & Integration Points

#### PoolHook Permissions
- `beforeSwap`: Block all trading when auction active, allow only CPAManager
- `beforeAddLiquidity`: Block liquidity additions when auction active
- `beforeRemoveLiquidity`: Block liquidity removal when auction active

### 4. Phase-Specific Implementation

#### Setup Phase
- Factory deploys CPAManager and PoolHooks
- Auction owner (deployer) established with full control
- Configuration parameter setting
- Pause functionality enabled for emergency situations
- **Asset Pool Creation**: Create V4 asset pools with initial sqrtPriceX96 during auction creation
- **Initial Price Setting**: Pools initialized with starting prices in tick space

#### Clock Phase
- Bid submission with support for exact output and exact input bids
- Multi-asset bidding in single transaction
- Automatic stake calculation based on bid type and current prices
- Price discovery happens in auction logic using pool prices
- Dropout handling with penalties
- At clock round end: Price increases via Doppler-style swaps if excess demand exists
- **Price Manipulation**: `newPrice = priceFromTick(currentTick + tickIncrement)`
- At clock phase end, prices are final

#### Proxy Phase
- Bundle submission by registered proxies
- Bundle validation and storage
- Bundles are given a bundleId for later verification
- Privacy maintenance
- No hook interaction during this phase

#### Allocation Phase
- Allocator competition
- On-chain scoring and selection
- Winner determination
- Add full deposit amount of assets to pools at final prices
- Return any excess assets to auctioneer
- No hook interaction during this phase
- Allocators submit bundle allocations using bundleIds instead of actual bundles

#### Reveal Phase
- Identity disclosure
- Spending requirement validation
- Financial settlement
- ERC1155 token distribution

#### Settlement Phase
- **Settlement Window**: Configurable window (in blocks) for bidders to purchase allocations
- **Allocation-Based Purchases**: Bidders can purchase up to their allocated amount of each asset
- **Stake Usage**: Use deposited stake to purchase assets, transfer additional numeraire if needed
- **Forfeiture**: Bidders who don't purchase in settlement window forfeit allocation
- **Return Stake**: Bidders can return leftover stake after settlement window ends
- **Pool Opening**: Item pools opened for normal trading after settlement

#### Cancellation Phase (Emergency)
- Owner can cancel auction at any time
- Full refund of all stakes to bidders
- Return of all assets to auction owner
- PoolHooks remain blocked until manual release

### 4. Asset Custody and Settlement Strategy

#### Asset Custody Model
- **PoolHook Custody**: Assets (items to be sold) are custodied by PoolHook
- **CPAManager Control**: CPAManager has operational control over assets during auctions
- **ERC6909 Claims**: PoolManager mints claims to PoolHook for auctioned assets
- **Permission Model**: Only CPAManager can request asset transfers from PoolHook

#### Asset Flow
1. **Setup**: Assets deposited to PoolManager → Claims minted to PoolHook
2. **Auction**: PoolHook holds claims, CPAManager controls auction logic
3. **Settlement**: CPAManager requests transfers via PoolHook.transferToWinner()
4. **Distribution**: PoolHook validates and executes claim transfers to winners

#### Settlement Process
- **Winner Claims**: Bidders claim through CPAManager (not directly from PoolHook)
- **Transfer Request**: CPAManager calls `PoolHook.transferToWinner(winner, amount, auctionId)`
- **Validation**: PoolHook validates:
  - Request comes from CPAManager
  - Auction is in correct phase
  - Winner is legitimate
  - Amounts are correct
- **Execution**: PoolHook burns its claims and mints new claims to winner

#### Benefits of This Approach
- **Clean Separation**: PoolHook custodies, CPAManager controls
- **V4 Integration**: Natural fit with V4 pool mechanics
- **Efficient**: No unnecessary asset transfers
- **Secure**: Clear permission boundaries
- **Auditable**: All transfers go through validated channels

### 5. Library Separation Strategy

#### `AuctionTypes.sol`
```solidity
enum AuctionPhase { Setup, Clock, Proxy, Allocation, Reveal, Settlement }
struct Bundle { ... }
struct Allocation { ... }
struct Bid { ... }
```

#### `CommitReveal.sol`
```solidity
function generateCommitHash(...) pure returns (bytes32)
function validateReveal(...) pure returns (bool)
```

#### `AllocationScoring.sol`
```solidity
function scoreAllocation(...) pure returns (uint256)
function selectWinningAllocation(...) pure returns (uint256)
```

### 6. Security Considerations

- Reentrancy protection on all state-changing functions
- Access control for auction owner operations
- Rate limiting for bid submissions
- Stake validation and slashing mechanisms
- Commit hash collision prevention
- Pause functionality for emergency situations
- Timelock for critical operations (pause/unpause)
- Owner-only auction cancellation with full refunds
- Emergency asset recovery mechanisms

### 7. Gas Optimization Strategy

- Pack related state variables
- Use libraries for complex calculations
- Batch operations where possible
- Efficient storage patterns for bundles and allocations

### 8. Testing Strategy

- Unit tests for each library function
- Integration tests for phase transitions
- Property-based tests for auction mechanics
- Gas optimization tests
- Security tests for edge cases

### 9. Deployment Considerations

- Hook factory pattern for easy deployment
- Configuration validation at deployment
- Upgrade mechanism considerations
- Emergency pause functionality with timelock
- Pause state recovery mechanisms

## Implementation Phases

### Phase 1: Foundation (COMPLETED)
- [x] Set up project structure and dependencies
- [x] Create `AuctionTypes.sol` with all structs and enums
- [x] Implement `PoolHook.sol` - simple pool control hook
- [x] Create basic `CPAManager.sol` structure
- [x] Set up testing framework
- [x] Implement multi-auction storage pattern in `CPAStorage.sol`

### Phase 2: Core Architecture Refactoring (IN PROGRESS)
- [ ] Remove hook inheritance from CPAManager
- [ ] Update CPAManager to be pure manager contract
- [ ] Implement price management in pools (sqrtPriceX96)
- [ ] Add tick-based price increments
- [ ] Update PoolInfo structure with startingTick and priceIncrement
- [ ] Implement Doppler-style price manipulation

### Phase 3: Enhanced Bidding System (PLANNED)
- [ ] Implement exact output vs exact input bid types
- [ ] Add sign convention for bid types
- [ ] Implement multi-asset bidding in single transaction
- [ ] Add automatic stake calculation
- [ ] Update bid processing logic

### Phase 4: Auction Management (PLANNED)
- [ ] Implement auction creation and setup functions
- [ ] Add pool registration and validation
- [ ] Implement auction owner controls
- [ ] Add auction state management (pause, cancel, phase transitions)
- [ ] Create auction lifecycle management

### Phase 5: Clock Phase Implementation (PLANNED)
- [ ] Implement clock phase bidding mechanics
- [ ] Add price adjustment logic across multiple pools
- [ ] Implement bid point system with multi-auction support
- [ ] Add dropout functionality with penalties
- [ ] Create excess demand calculation for multiple items

### Phase 6: Proxy and Bundle System (PLANNED)
- [ ] Implement proxy registration system
- [ ] Add bundle submission logic
- [ ] Create bundle validation
- [ ] Implement privacy maintenance
- [ ] Add ERC1155 token integration

### Phase 7: Allocation and Scoring (PLANNED)
- [ ] Implement `AllocationScoring.sol`
- [ ] Add allocator competition mechanics
- [ ] Create on-chain scoring system
- [ ] Implement winner selection
- [ ] Add allocation validation

### Phase 8: Reveal and Settlement (PLANNED)
- [ ] Implement reveal phase logic
- [ ] Add spending requirement validation
- [ ] Create financial settlement system
- [ ] Implement penalty application
- [ ] Add final token distribution
- [ ] Implement auction cancellation with full refunds

### Phase 9: Integration and Testing (PLANNED)
- [ ] Complete deployment system
- [ ] Add comprehensive testing suite
- [ ] Implement gas optimizations
- [ ] Add security measures
- [ ] Create deployment scripts

## Key Design Decisions

### 1. CPAManager as Pure Manager Contract
**Decision**: CPAManager is no longer a hook, but a pure manager contract
**Rationale**: 
- Cleaner separation of concerns
- Easier to reason about and test
- No need for hook permissions or callbacks
- Direct interface with V4 pools through PoolHook

### 2. Price Management in Pools
**Decision**: Prices stored as sqrtPriceX96 directly in pools, not in manager
**Rationale**:
- Native V4 integration
- More efficient price manipulation
- Leverages V4's built-in price mechanisms
- Eliminates redundant price storage

### 3. Two-Contract Architecture
**Decision**: Use CPAManager (single contract) + PoolHook (shared contract)
**Rationale**: 
- Gas efficiency: No need to deploy new hooks for each auction
- Reusability: Single PoolHook serves all asset pools
- Scalability: CPAManager can manage unlimited auctions
- Simplicity: Clear separation between auction logic and pool control

### 4. Enhanced Bidding System
**Decision**: Support both exact output and exact input bids with sign convention
**Rationale**:
- More flexible bidding options for users
- Automatic stake calculation reduces user complexity
- Multi-asset bidding in single transaction improves UX
- Sign convention provides clear bid type indication similar to Uniswap V4

### 5. Multi-Auction Support
**Decision**: Single CPAManager manages multiple concurrent auctions
**Rationale**:
- Cost efficiency: One deployment serves all auctions
- Resource sharing: Common infrastructure across auctions
- Scalability: Unlimited auctions without additional deployments
- Isolation: Each auction has its own state and owner

### 6. AuctionId-Based Storage
**Decision**: All auction state indexed by AuctionId
**Rationale**:
- Clean separation: Each auction's data is isolated
- Efficient access: Direct mapping lookup for auction data
- Scalability: No storage conflicts between auctions
- Maintainability: Clear data organization

### 7. PoolHook Centralization
**Decision**: Single PoolHook controlled by CPAManager
**Rationale**:
- Simplified control: CPAManager manages all pool operations
- Consistent behavior: All pools follow same blocking rules
- Gas efficiency: Shared logic across all pools
- Easy coordination: Centralized state management

### 8. Auction Owner Model
**Decision**: Each auction has its own owner (not CPAManager owner)
**Rationale**:
- Decentralized control: Multiple auctioneers can use the system
- Isolated permissions: Auction owners only control their auctions
- Reduced centralization: No single point of control
- Flexibility: Different auctioneers can run concurrent auctions

### 9. Library Separation
**Decision**: Separate complex logic into libraries
**Rationale**:
- Gas optimization through code reuse
- Better testing and maintainability
- Clear separation of concerns
- Easier upgrades and modifications

### 10. ERC1155 Integration (planned)
**Decision**: Use ERC1155 tokens for bidder representation
**Rationale**:
- Flexible bundle representation
- Enables trading before redemption
- Standard token interface
- Composability with DeFi protocols

### 11. On-Chain vs. Off-Chain Allocation
**Decision**: Start with on-chain allocation for POC
**Rationale**:
- Simpler implementation
- Full transparency
- Easier debugging
- Can be upgraded to ZK proofs later

## Technical Challenges and Solutions

### 1. Multi-Auction State Management
**Challenge**: Managing isolated state for multiple concurrent auctions
**Solution**: 
- AuctionId-based mappings for all state variables
- Clear ownership model per auction
- Isolated function calls with auctionId parameter

### 2. PoolHook Coordination
**Challenge**: Coordinating multiple pools across different auctions
**Solution**:
- Single PoolHook with auction-aware blocking
- CPAManager controls pool states via setAuctionState()
- Pool-specific allowance via setPoolAllowed()

### 3. Gas Optimization
**Challenge**: Complex auction logic may be gas-intensive
**Solution**: 
- Use libraries for calculations
- Pack state variables efficiently
- Batch operations where possible
- Optimize storage patterns

### 4. Privacy Implementation
**Challenge**: Maintaining bidder-proxy privacy during auction
**Solution**:
- Two-salt commit-reveal system
- Pre-bid registration requirement
- No public mapping until reveal
- Stake-based spam prevention

## Success Metrics

### Technical Metrics
- Gas efficiency: < 500k gas for typical operations
- Security: Zero critical vulnerabilities
- Performance: Sub-second response times
- Scalability: Support for 100+ concurrent auctions

### Functional Metrics
- Privacy: No bidder-proxy linkability during auction
- Fairness: Competitive allocation outcomes
- Efficiency: Optimal resource allocation
- Usability: Intuitive interface for all participants

## Risk Mitigation

### Technical Risks
- **Gas limits**: Optimize code and use libraries
- **Complexity**: Modular design and extensive testing
- **Security**: Multiple audit rounds and formal verification
- **Performance**: Load testing and optimization
- **Multi-auction conflicts**: Isolated state management
- **Owner risk**: Distributed ownership model

### Business Risks
- **Adoption**: Clear documentation and examples
- **Competition**: Unique privacy and efficiency features
- **Regulation**: Compliance with relevant frameworks
- **Market conditions**: Flexible parameter configuration

## Future Enhancements

### Phase 2 Features
- ZK proof integration for privacy
- Off-chain allocation with on-chain verification
- Advanced scoring algorithms
- Multi-chain support

### Phase 3 Features
- Automated market making integration
- Advanced proxy competition
- Dynamic parameter adjustment
- Cross-protocol composability

## Conclusion

This implementation plan provides a comprehensive roadmap for building a production-ready clock-proxy auction hook for Uniswap V4. The two-contract architecture, multi-auction support, and phased implementation strategy ensure a robust and scalable system that can evolve with the ecosystem.

The key success factors will be:
1. Maintaining the privacy guarantees during auction
2. Ensuring gas efficiency for on-chain operations
3. Providing a seamless user experience
4. Creating a secure and auditable system
5. Supporting multiple concurrent auctions efficiently

This document will be updated as implementation progresses and new insights are gained.

---

## Rules
1. Immutable Mapping – Once a commitHash → proxy mapping exists, it cannot be overwritten.
2. Pre-Bid Registration – Commit must be registered before any bid.
3. On-chain Scoring – For POC, scoring is done directly in Solidity for simplicity.
4. Stake Requirement – Proxy must deposit a stake when registering commit.
5. Rate Limits – Limit commits per block to reduce spam.
6. Future Feature – Privacy Enhancements – Use ZK to hide bidder–proxy link pre-reveal.
7. Allocator Competition – Multiple allocators submit; best-scoring allocation wins.
8. Verification Priority – Always verify commit before accepting a bid.
9. Liquidity-as-Stake – Bidders stake through single-sided liquidity deposits in numeraire.
10. Manager Control – CPAManager owns all deposited liquidity during auction.

---
