# Clock-Proxy Auction Hook Implementation Roadmap

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

### Architecture Overview
```plaintext
ClockProxyAuctionHook (hook contract) - pool: numeraire <-> CPA
    ↓ controls
PoolHook1 (for Item1) - blocks operations, allows auction hook only. Uses Doppler mechanism to update prices after clock phase.
PoolHook2 (for Item2) - blocks operations, allows auction hook only. Uses Doppler mechanism to update prices after clock phase.
PoolHook3 (for Item3) - blocks operations, allows auction hook only. Uses Doppler mechanism to update prices after clock phase.
```

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

#### Factory Contract: `ClockProxyFactory.sol`
- Deploys the complete auction system
- Creates AuctionHook and PoolHooks
- Deploys V4 pools with PoolHooks attached
- Adds initial hook-owned liquidity to pools

#### Main Auction Contract: `ClockProxyAuctionHook.sol`
- Extends `BaseHook` from V4 periphery
- Implements the main auction logic and state management
- Handles all auction phases and transitions
- Manages commit-reveal system and proxy registration
- Controls all PoolHooks during auction

#### Pool Control Contracts: `PoolHook.sol`
- Simple hook that blocks trading/liquidity operations during auction
- Controlled by AuctionHook via `setAuctionActive()`
- One PoolHook per auction item pool

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

### Phase 1: Foundation (Week 1-2)
- [ ] Set up project structure and dependencies
- [ ] Create `AuctionTypes.sol` with all structs and enums
- [ ] Implement `PoolHook.sol` - simple pool control hook
- [ ] Create basic `ClockProxyFactory.sol` structure
- [ ] Set up testing framework

### Phase 2: Core Auction Logic (Week 3-4)
- [ ] Implement commit-reveal system in `CommitReveal.sol`
- [ ] Add state management to main AuctionHook contract
- [ ] Implement phase transition logic
- [ ] Add basic bid submission and validation
- [ ] Create AuctionHook control over PoolHooks
- [ ] Implement pause functionality with timelock

### Phase 3: Clock Phase Implementation (Week 5-6)
- [ ] Implement clock phase bidding mechanics
- [ ] Add price adjustment logic
- [ ] Implement bid point system
- [ ] Add dropout functionality with penalties
- [ ] Create excess demand calculation

### Phase 4: Proxy and Bundle System (Week 7-8)
- [ ] Implement proxy registration system
- [ ] Add bundle submission logic
- [ ] Create bundle validation
- [ ] Implement privacy maintenance
- [ ] Add ERC1155 token integration

### Phase 5: Allocation and Scoring (Week 9-10)
- [ ] Implement `AllocationScoring.sol`
- [ ] Add allocator competition mechanics
- [ ] Create on-chain scoring system
- [ ] Implement winner selection
- [ ] Add allocation validation

### Phase 6: Reveal and Settlement (Week 11-12)
- [ ] Implement reveal phase logic
- [ ] Add spending requirement validation
- [ ] Create financial settlement system
- [ ] Implement penalty application
- [ ] Add final token distribution
- [ ] Implement auction cancellation with full refunds
- [ ] Add emergency asset recovery mechanisms

### Phase 7: Integration and Testing (Week 13-14)
- [ ] Complete factory deployment system
- [ ] Add comprehensive testing suite
- [ ] Implement gas optimizations
- [ ] Add security measures
- [ ] Create deployment scripts

### Phase 8: Documentation and Audit (Week 15-16)
- [ ] Complete documentation
- [ ] Security audit preparation
- [ ] Performance testing
- [ ] Final optimizations
- [ ] Production deployment preparation

## Key Design Decisions

### 1. Hierarchical Hook Architecture
**Decision**: Use AuctionHook controlling multiple PoolHooks
**Rationale**: 
- Clean separation of concerns
- Simple PoolHook logic (just block operations)
- AuctionHook focuses on auction coordination
- Easy to reason about security and control

### 2. Owner Control Model
**Decision**: Auction deployer has full control over auction operations
**Rationale**:
- Clear accountability for auction management
- Emergency cancellation capability
- Full refund guarantees for participants
- Asset recovery in case of issues

### 3. Factory Deployment Pattern
**Decision**: Use ClockProxyFactory to deploy entire system
**Rationale**:
- Single deployment transaction
- Proper initialization order
- Clean ownership setup
- Easier testing and deployment

### 4. Library Separation
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

### 1. Gas Optimization
**Challenge**: Complex auction logic may be gas-intensive
**Solution**: 
- Use libraries for calculations
- Pack state variables efficiently
- Batch operations where possible
- Optimize storage patterns

### 2. Privacy Implementation
**Challenge**: Maintaining bidder-proxy privacy during auction
**Solution**:
- Two-salt commit-reveal system
- Pre-bid registration requirement
- No public mapping until reveal
- Stake-based spam prevention

### 3. Hierarchical Hook Coordination
**Challenge**: Coordinating multiple PoolHooks with common numeraire
**Solution**:
- AuctionHook controls all PoolHooks
- Centralized price management across pools
- Numeraire constraint enforcement
- Simple PoolHook logic for easy coordination

### 4. Allocation Complexity
**Challenge**: NP-hard allocation optimization
**Solution**:
- Multiple allocator competition
- On-chain scoring with predefined rules
- Future ZK proof integration
- Iterative improvement mechanisms

## Success Metrics

### Technical Metrics
- Gas efficiency: < 500k gas for typical operations
- Security: Zero critical vulnerabilities
- Performance: Sub-second response times
- Scalability: Support for 100+ bidders

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
- **Pause abuse**: Timelock and governance controls
- **Owner risk**: Single point of failure for auction control

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

This implementation plan provides a comprehensive roadmap for building a production-ready clock-proxy auction hook for Uniswap V4. The modular architecture, security-first approach, and phased implementation strategy ensure a robust and maintainable system that can evolve with the ecosystem.

The key success factors will be:
1. Maintaining the privacy guarantees during auction
2. Ensuring gas efficiency for on-chain operations
3. Providing a seamless user experience
4. Creating a secure and auditable system

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
