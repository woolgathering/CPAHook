# Clock-Proxy Auction Hook Implementation Roadmap

## Two-Contract Architecture Design

### Core Design Philosophy
The Clock-Proxy Auction system has been redesigned to use two main contracts for better efficiency and reusability:

1. **CPAHook (ClockProxyAuctionHook)**: Single contract that manages multiple auctions
2. **PoolHook**: Shared hook that all asset pools attach to, controlled by the CPAHook

This design eliminates the need to deploy new hooks for each auction, making the system more gas-efficient and easier to manage.

### Architecture Overview
```plaintext
CPAHook (single contract) - manages multiple auctions
    ↓ controls multiple
PoolHook (single contract) - attached to all asset pools
    ↓ attached to
Asset Pool 1 (A<>USDC) - blocked during auctions
Asset Pool 2 (B<>USDC) - blocked during auctions  
Asset Pool 3 (C<>USDC) - blocked during auctions
```

### Initialization Process
1. **Deploy CPAHook**: Single contract that will manage all auctions
2. **Deploy PoolHook**: With CPAHook address as constructor argument (allows CPAHook to modify state of the PoolHook)
3. **Create Asset Pools**: Deploy pools (A<>USDC, B<>USDC, C<>USDC) with PoolHook attached
4. **Create Auction**: Call CPAHook.createAuction() with pool keys and auction parameters

### Multi-Auction Support
- **Auction IDs**: Each auction gets a unique auctionId
- **Auction Owners**: Each auction has its own owner (not the CPAHook owner)
- **Isolated State**: All auction variables are indexed by auctionId
- **Owner Controls**: Only the auction owner can start, pause, change phases, etc.

### PoolHook Control Mechanism
- **Centralized Control**: CPAHook controls all PoolHooks
- **State Synchronization**: CPAHook calls setAuctionState() on PoolHooks
- **Pool Allowance**: CPAHook can enable/disable specific pools via setPoolAllowed()
- **Operation Blocking**: PoolHook blocks all operations when auction is active

### Auction Creation Flow
1. **Deploy Asset Pools**: Create pools A<>USDC, B<>USDC, C<>USDC with PoolHook
2. **Create Auction**: Call CPAHook.createAuction(poolKeys, config, owner)
3. **Setup Phase**: Auction owner deposits assets and configures auction
4. **Auction Execution**: Standard clock-proxy auction phases proceed
5. **Settlement**: Auction completes and pools return to normal operation

### Key Benefits of New Design
- **Gas Efficiency**: No need to deploy new hooks for each auction
- **Reusability**: Single PoolHook serves all asset pools
- **Scalability**: CPAHook can manage unlimited auctions
- **Simplicity**: Clear separation between auction logic and pool control
- **Flexibility**: Different auction owners can run concurrent auctions

## Hook-Native Architecture Design

### Core Hook-Native Approach
The Clock-Proxy Auction is designed to be integral to the V4 hook system, not bolted on top. The auction phases map directly to hook behaviors:

- Setup phase: `beforeInitialize` places initial liquidity
- Clock phase: `beforeAddLiquidity` and `afterAddLiquidity` capture liquidity deposits for bidding
  - We may need a special addLiquidityAsBid function a la customAccounting in OZ. Research needed.
- Proxy phase: Bundle submission through `submitBundle()` (no hook interaction)
- Allocation phase: Allocator competition through `submitAllocation()` (no hook interaction)
- Reveal phase: Identity disclosure and stake management (no hook interaction)
- Claim phase: `beforeSwap` intercepts claims and processes item transfers
- Settlement phase: Final liquidity distribution and pool opening

### CPA Token Mechanism
- ClockProxyAuctionHook's pool trades `numeraire <-> CPA`
- Fixed supply of CPA tokens in the pool
- Fees accrue as numeraire liquidity during auction
- CPA price appreciates with auction success
- Performance-based fees: Auctioneer/allocator get fixed CPA percentages
- Auction owner benefits from fee revenue through CPA appreciation

### Item Sub-Pool Structure
- Item sub-pools created between `item<>numeraire` with starting price of 1:1
- Starting price provides baseline for later price manipulation
- Final prices set through Doppler-style manipulation at clock phase end
- Items deposited as LP positions at a price <= final price to ensure sufficient liquidity at the correct price.

### Liquidity-as-Stake Mechanism
- Bidders stake through single-sided liquidity deposits in numeraire in the ClockProxyAuctionHook
- Hook contract owns all deposited liquidity during auction
- LP token mapping tracks bidder->stake relationship
- Stake used for item purchases or penalty application
- Contract controls liquidity until auction end

### Bidding Mechanism
- Option A: Bidders call `poolManager.modifyLiquidity()` with demands encoded in `hookData`
- Option B: Custom `addLiquidityWithBid()` function with integrated bid processing
- Hook captures numeraire amount and stores LP token mapping
- Bid points calculated as 1:1 ratio with deposited numeraire
- Contract owns deposited liquidity until auction end

### Claim Mechanism
- Bidders claim through swap on ClockProxyAuctionHook pool
- Hook intercepts in `beforeSwap` and validates eligibility
- Hook processes claim using deposited stake
- Execute swaps in item pools using stake as payment
- Stake converted to liquidity in item pools on auctioneer's behalf
- Helper function provided for insufficient stake calculations

### Hook-Native Benefits
- Auction lives in V4's lifecycle - Not bolted on top
- Natural gas efficiency - Hook operations are optimized
- Atomic operations - Bids and price updates happen atomically
- Native integration - Works seamlessly with V4's architecture
- Performance-aligned fees - Auctioneer/allocator fees scale with auction success

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

#### Main Auction Contract: `ClockProxyAuctionHook.sol`
- Extends `BaseHook` from V4 periphery
- Implements the main auction logic and state management for multiple auctions
- Handles all auction phases and transitions
- Manages commit-reveal system and proxy registration
- Controls all PoolHooks during auctions
- Supports multiple concurrent auctions with isolated state

#### Pool Control Contract: `PoolHook.sol`
- Simple hook that blocks trading/liquidity operations during auctions
- Controlled by CPAHook via `setAuctionState()` and `setPoolAllowed()`
- Shared across all asset pools
- Centralized control mechanism for auction state

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
mapping(address => uint256) public prices; // item pool -> price
bool public poolsOpened; // trading status
```

#### B. Hierarchical Hook System
- AuctionHook controls multiple PoolHooks
- Each PoolHook attached to one V4 pool per auction item
- PoolHooks block trading/liquidity during auction except for auction hook
- AuctionHook manages prices and liquidity across all pools
- Common numeraire constraint enforced across all pools
- Item sub-pools start at 1:1 price ratio

#### C. Commit-Reveal System
- Two-salt unlinkability system as described
- Pre-bid registration requirement
- ERC1155 token minting for bidder representation
- Stake binding and validation through liquidity deposits

### 3. Hook Permissions & Integration Points

#### AuctionHook Permissions
- `beforeInitialize`: Control pool creation and initial liquidity placement
- `beforeAddLiquidity`: Capture liquidity deposits for stake tracking
- `afterAddLiquidity`: Track LP token mappings for bidder->stake relationship
- `beforeSwap`: Intercept claims during claim phase and process item transfers

#### PoolHook Permissions
- `beforeSwap`: Block all trading when auction active, allow only auction hook
- `beforeAddLiquidity`: Block liquidity additions when auction active
- `beforeRemoveLiquidity`: Block liquidity removal when auction active

### 4. Phase-Specific Implementation

#### Setup Phase
- Factory deploys AuctionHook and PoolHooks
- Factory deploys V4 pools with PoolHooks attached
- Factory adds initial hook-owned liquidity to pools
- AuctionHook takes control of all PoolHooks
- Auction owner (deployer) established with full control
- Configuration parameter setting
- Initial price establishment at 1:1 for item sub-pools
- Pause functionality enabled for emergency situations

#### Clock Phase
- Bid submission through liquidity deposits with commit hash validation
- Hook captures numeraire amount and stores LP token mapping
- Bid point management and stake tracking (1:1 ratio with numeraire)
- Auctioneer updates pool prices between rounds
- Dropout handling with penalties
- At clock phase end: Doppler-style price manipulation sets final prices in item pools
- Items deposited as LP positions at price <= final price to ensure sufficient liquidity

#### Proxy Phase
- Bundle submission by registered proxies
- Bundle validation and storage
- Privacy maintenance
- No hook interaction during this phase

#### Allocation Phase
- Allocator competition
- On-chain scoring and selection
- Winner determination
- No hook interaction during this phase

#### Reveal Phase
- Identity disclosure
- Spending requirement validation
- Financial settlement
- ERC1155 token distribution

#### Claim Phase
- Bidders claim through swap on ClockProxyAuctionHook pool
- Hook intercepts in beforeSwap and validates eligibility
- Hook processes claim using deposited stake
- Execute swaps in item pools using stake as payment
- Stake converted to liquidity in item pools on auctioneer's behalf
- Helper function provided for insufficient stake calculations

#### Settlement Phase
- All item pools contain auctioneer-owned liquidity from claim proceeds
- Unsold items returned to auctioneer or deposited in pools
- Item pools opened for normal trading
- Auctioneer receives all purchase proceeds as liquidity in the item pools

#### Cancellation Phase (Emergency)
- Owner can cancel auction at any time
- Full refund of all stakes to bidders
- Return of all assets to auction owner
- PoolHooks remain blocked until manual release

### 5. Library Separation Strategy

#### `AuctionTypes.sol`
```solidity
enum AuctionPhase { Setup, Clock, Proxy, Allocation, Reveal, Claim, Settlement }
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
- [x] Create basic `ClockProxyAuctionHook.sol` structure
- [x] Set up testing framework
- [x] Implement multi-auction storage pattern in `CPAStorage.sol`

### Phase 2: Core Architecture (COMPLETED)
- [x] Implement two-contract architecture (CPAHook + PoolHook)
- [ ] Add multi-auction support with AuctionId-based mappings
- [ ] Implement basic state management for multiple auctions
- [ ] Create PoolHook control mechanism
- [ ] Set up auction creation and ownership model

### Phase 3: Auction Management (IN PROGRESS)
- [ ] Implement auction creation and setup functions
- [ ] Add pool registration and validation
- [ ] Implement auction owner controls
- [ ] Add auction state management (pause, cancel, phase transitions)
- [ ] Create auction lifecycle management

### Phase 4: Clock Phase Implementation (PLANNED)
- [ ] Implement clock phase bidding mechanics
- [ ] Add price adjustment logic across multiple pools
- [ ] Implement bid point system with multi-auction support
- [ ] Add dropout functionality with penalties
- [ ] Create excess demand calculation for multiple items

### Phase 5: Proxy and Bundle System (PLANNED)
- [ ] Implement proxy registration system
- [ ] Add bundle submission logic
- [ ] Create bundle validation
- [ ] Implement privacy maintenance
- [ ] Add ERC1155 token integration

### Phase 6: Allocation and Scoring (PLANNED)
- [ ] Implement `AllocationScoring.sol`
- [ ] Add allocator competition mechanics
- [ ] Create on-chain scoring system
- [ ] Implement winner selection
- [ ] Add allocation validation

### Phase 7: Reveal and Settlement (PLANNED)
- [ ] Implement reveal phase logic
- [ ] Add spending requirement validation
- [ ] Create financial settlement system
- [ ] Implement penalty application
- [ ] Add final token distribution
- [ ] Implement auction cancellation with full refunds

### Phase 8: Integration and Testing (PLANNED)
- [ ] Complete deployment system
- [ ] Add comprehensive testing suite
- [ ] Implement gas optimizations
- [ ] Add security measures
- [ ] Create deployment scripts

## Key Design Decisions

### 1. Two-Contract Architecture
**Decision**: Use CPAHook (single contract) + PoolHook (shared contract)
**Rationale**: 
- Gas efficiency: No need to deploy new hooks for each auction
- Reusability: Single PoolHook serves all asset pools
- Scalability: CPAHook can manage unlimited auctions
- Simplicity: Clear separation between auction logic and pool control

### 2. Multi-Auction Support
**Decision**: Single CPAHook manages multiple concurrent auctions
**Rationale**:
- Cost efficiency: One deployment serves all auctions
- Resource sharing: Common infrastructure across auctions
- Scalability: Unlimited auctions without additional deployments
- Isolation: Each auction has its own state and owner

### 3. AuctionId-Based Storage
**Decision**: All auction state indexed by AuctionId
**Rationale**:
- Clean separation: Each auction's data is isolated
- Efficient access: Direct mapping lookup for auction data
- Scalability: No storage conflicts between auctions
- Maintainability: Clear data organization

### 4. PoolHook Centralization
**Decision**: Single PoolHook controlled by CPAHook
**Rationale**:
- Simplified control: CPAHook manages all pool operations
- Consistent behavior: All pools follow same blocking rules
- Gas efficiency: Shared logic across all pools
- Easy coordination: Centralized state management

### 5. Auction Owner Model
**Decision**: Each auction has its own owner (not CPAHook owner)
**Rationale**:
- Decentralized control: Multiple auctioneers can use the system
- Isolated permissions: Auction owners only control their auctions
- Reduced centralization: No single point of control
- Flexibility: Different auctioneers can run concurrent auctions

### 6. Library Separation
**Decision**: Separate complex logic into libraries
**Rationale**:
- Gas optimization through code reuse
- Better testing and maintainability
- Clear separation of concerns
- Easier upgrades and modifications

### 5. ERC1155 Integration
**Decision**: Use ERC1155 tokens for bidder representation
**Rationale**:
- Flexible bundle representation
- Enables trading before redemption
- Standard token interface
- Composability with DeFi protocols

### 6. On-Chain vs. Off-Chain Allocation
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
- CPAHook controls pool states via setAuctionState()
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
10. Hook Control – ClockProxyAuctionHook owns all deposited liquidity during auction.

---
