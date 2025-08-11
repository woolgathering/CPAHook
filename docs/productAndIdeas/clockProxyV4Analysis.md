# Clock-Proxy Auction Implementation in Uniswap V4 Hooks
## Analysis and Design Decisions

### Project Overview
Implementing clock-proxy auctions as Uniswap V4 hooks to enable efficient, transparent token auctions with package bidding capabilities, privacy features, and allocator competition.

---

## User Walkthrough: Clock-Proxy Auction Experience

### Scenario: Token Launch Auction
Imagine a new DeFi protocol is launching and wants to auction off:
- Token A: Governance tokens (100,000 tokens available)
- Token B: Utility tokens (500,000 tokens available)
- LP Position: Special LP position with IL protection (50 positions available)

### Phase 1: Setup Phase - Privacy and Registration

#### Auction Configuration (Set by Auctioneer)
- Minimum spending ratio: x% (e.g., 50%) - bidders must spend at least x% of total bid value
- Dropout penalty: y% (e.g., 20%) - penalty for early exit
- Spending violation penalty: z% (e.g., 30%) - penalty for minimum spending violations
- BidPoints calculation: 1:1 ratio (stakeAmount = bidPoints)
- Maximum stake cap: Configurable safeguard against single-bidder dominance

#### Bidder and Proxy Selection
- Alice (large investor): Chooses Proxy Agent Alpha, shares secret salt, and commitHash
- Bob (medium investor): Chooses Proxy Agent Beta, shares secret salt, and commitHash
- Carol (small investor): Chooses Proxy Agent Gamma, shares secret salt, and commitHash
- Privacy Feature: No one can see which bidder is working with which proxy

#### Registration Process
- Proxies register commits on-chain (no stakes required for proxies)
- Bidders can participate but must add a stake on their initial bid and wait for a proxy to register with their commitHash
- System ensures: Only registered proxies can submit bundles for their bidders

### Phase 2: Clock Phase - Price Discovery

#### Round 1: Initial Prices
- Auctioneer announces: Token A = 1 tokenY, Token B = 0.5 tokenY, LP Position = 100 tokenY
- Alice submits: 50,000 Token A + 250,000 Token B + 25 LP positions (via her proxy) + stakes 50 tokenY for 50 bidPoints
- Bob submits: 30,000 Token A + 180,000 Token B + 18 LP positions (via his proxy) + stakes 30 tokenY for 30 bidPoints
- Carol submits: 25,000 Token A + 120,000 Token B + 12 LP positions (via her proxy) + stakes 25 tokenY for 25 bidPoints
- Result: Excess demand on all items → prices increase
- Note: BidPoints reset each round (not consumed by bids, allowing continued participation)

#### Round 2: Price Increases
- Auctioneer announces: Token A = 1.2 tokenY, Token B = 0.6 tokenY, LP Position = 120 tokenY
- Alice reduces: 40,000 Token A + 200,000 Token B + 20 LP positions (maintains 50 bidPoints)
- Bob reduces: 25,000 Token A + 150,000 Token B + 15 LP positions (maintains 30 bidPoints)
- Carol reduces: 20,000 Token A + 100,000 Token B + 10 LP positions (maintains 25 bidPoints)
- Result: Still excess demand on all items → prices increase again

#### Round 3: Further Increases
- Auctioneer announces: Token A = 1.5 tokenY, Token B = 0.75 tokenY, LP Position = 120 tokenY (unchanged - no excess demand)
- Alice reduces: 30,000 Token A + 150,000 Token B + 15 LP positions (maintains 50 bidPoints)
- Bob reduces: 20,000 Token A + 120,000 Token B + 12 LP positions (maintains 30 bidPoints)
- Carol reduces: 15,000 Token A + 80,000 Token B + 8 LP positions (maintains 25 bidPoints)
- Result: LP positions have no excess demand (price unchanged), tokens still have excess demand

#### Round 4: Final Clock Round
- Auctioneer announces: Token A = 1.8 tokenY, Token B = 0.9 tokenY, LP Position = 120 tokenY (unchanged - no excess demand)
- Alice: 20,000 Token A + 100,000 Token B + 10 LP positions (maintains 50 bidPoints)
- Bob: 15,000 Token A + 80,000 Token B + 8 LP positions (maintains 30 bidPoints)
- Carol: 10,000 Token A + 60,000 Token B + 6 LP positions (maintains 25 bidPoints)
- Result: No excess demand on any item → Clock phase ends
- Note: Bidders can call dropout() to exit with partial refund (y% penalty)

### Phase 3: Proxy Phase - Bundle Creation

#### Bundle Preparation
- Alice's proxy creates bundles:
  - Bundle 1: 20,000 Token A + 100,000 Token B + 10 LP positions = 55,000 tokenY value
  - Bundle 2: 25,000 Token A + 120,000 Token B + 12 LP positions = 65,000 tokenY value
  - Bundle 3: 15,000 Token A + 80,000 Token B + 8 LP positions = 45,000 tokenY value

- Bob's proxy creates bundles:
  - Bundle 1: 15,000 Token A + 80,000 Token B + 8 LP positions = 45,000 tokenY value
  - Bundle 2: 20,000 Token A + 100,000 Token B + 10 LP positions = 55,000 tokenY value

#### Bundle Submission
- Proxies submit bundles on-chain with their registered commit hashes (recall commit hashes are shared in secret by the bidder)
- System validates: Only registered proxies can submit for their bidders
- Privacy maintained: Bundles are submitted but bidder-proxy links remain hidden

### Phase 4: Allocation Phase - Allocator Competition

#### Allocator Participation
- Allocator Alpha: Submits allocation maximizing total value
- Allocator Beta: Submits allocation with fairness constraints
- Allocator Gamma: Submits allocation optimizing for small bidders
- Allocator Delta: Submits allocation with specific token distribution preferences

#### On-Chain Scoring
- System evaluates each allocation using predefined rules
- Scoring criteria: Total value, fairness, efficiency, constraint satisfaction (TBD)
- Winning allocation selected automatically on-chain
- Allocator reward paid to the winner (TBD how this is paid: auctioneer or bidders?)

### Phase 5: Reveal Phase - Privacy Disclosure

#### Identity Revelation
- Bidders reveal their identities using their secret salts and commit hash
- System validates the commit-reveal process
- Mapping becomes public: Alice ↔ Proxy Alpha, Bob ↔ Proxy Beta, etc.

#### Final Settlement
- Winning bidders receive ERC1155 tokens representing their allocations
- Tokens can be redeemed for the actual auctioned items
- Stakes returned or applied toward purchases
- Invalid reveals or unclaimed bundles by bidders forfeit their stakes
- Minimum spending requirement automatically checked: Bidders must spend at least x% of total bid value
- Minimum spending violations result in z% stake penalty and reveal failure

#### Final Outcome
- Alice wins: 25,000 Token A + 120,000 Token B + 12 LP positions for 65,000 tokenY
- Bob wins: 15,000 Token A + 80,000 Token B + 8 LP positions for 45,000 tokenY
- Allocator Alpha wins the allocation competition and receives reward
- Remaining items: Distributed to other bidders or returned to seller

---

## Key User Experience Features

### What Users See During Setup
- Auction configuration: Clear display of x% minimum spending ratio, y% dropout penalty, z% spending violation penalty
- Proxy selection interface: Choose from available proxy agents
- Privacy assurance: Clear explanation of commit-reveal system
- Stake requirements: Transparent deposit amounts and return conditions
- Registration status: Confirmation of successful proxy registration

### What Users See During Clock Phase
- Current prices for each item clearly displayed
- Excess demand indicators (e.g., "Token A: 15,000 excess demand")
- Simple interface: Just input quantities desired at current prices
- Privacy indicators: Confirmation that bidder-proxy links are hidden
- No complex strategy needed: Just express true demand at given prices

### What Users See During Proxy Phase
- Bundle builder: Create different combinations of items
- Value input: Specify maximum value for each bundle
- Proxy agent status: See what your proxy is preparing
- Submission confirmation: Verify bundles were submitted successfully

### What Users See During Allocation Phase
- Allocator proposals: View different allocation strategies
- Scoring criteria: Understand how allocations are evaluated
- Competition status: See which allocator is winning
- Real-time updates: Watch as allocators compete

### What Users See During Reveal Phase
- Identity disclosure: See who was behind which bids
- Final allocations: View winning bundles and prices
- ERC1155 tokens: Receive tokens representing allocations
- Settlement options: Choose to redeem tokens or trade them

### User Benefits
1. Privacy: Bidder-proxy relationships hidden during auction
2. Simplicity: Clock phase is straightforward - just express demand
3. Transparency: All prices and excess demand visible
4. Efficiency: No need to guess others' bids or engage in complex strategy (unless desired)
5. Fairness: Core outcome ensures competitive prices
6. Flexibility: Package bidding allows for synergies
7. Competition: Multiple allocators ensure competition toward optimal outcomes
8. Liquidity: ERC1155 tokens can be traded before redemption
9. Economic Incentives: Stake-to-bidPoints correlation prevents spurious bidders

### Bidder Responsibilities
1. Setup: Choose proxy and share secret salts securely
2. Clock Phase: Honestly express demand at given prices, submit stakes with bids
3. Proxy Phase: Work with proxy to create valuable bundles
4. Activity Rules: Follow revealed preference constraints
5. Timing: Submit bids within round deadlines
6. Reveal: Properly disclose identity with correct salts

### Proxy Responsibilities
1. Registration: Register commit hashes with stakes before bidding
2. Bundle Creation: Create optimal bundles based on bidder instructions
3. Bundle Submission: Submit bundles on-chain with registered commit hashes
4. Privacy: Maintain bidder-proxy relationship confidentiality until reveal
5. Compliance: Follow activity rules and auction constraints

### Allocator Responsibilities
1. Allocation Optimization: Propose optimal allocations based on bundles and constraints
2. Scoring Criteria: Consider total value, fairness, efficiency, and constraint satisfaction
3. Competition: Compete with other allocators for best allocation strategy
4. Submission: Submit allocations within designated time windows
5. Verification: Ensure allocations meet all auction requirements

### Auctioneer Responsibilities
1. Pool Setup: Deploy pools with common numeraire (tokenY)
2. Price Management: Announce and update prices during clock phase
3. Asset Management: Deposit auctioned items into pools
4. Constraint Enforcement: Ensure all pools share same numeraire
5. Reward Management: Determine and distribute allocator rewards

---

## Core Auction Design Understanding

### Item Definition for V4 Context
- Primary Items: ERC20 tokens (fungible, like electricity)
- Secondary Items: Special tokens (voting rights, governance tokens)
- LP Context: Limited tick spaces or tranches (IL protection, higher fees)
- Common Numeraire: All pools must share the same Y token (numeraire) for consistent pricing
- Hook-Owned Assets: Auction hook will own assets in each pool (implementation detail for later)
- Key Insight: Treat tokens as electricity - one unit is identical to another

### Auction Phases
1. Setup Phase: Privacy setup and registration with stakes
2. Clock Phase: Iterative price discovery with linear pricing
3. Proxy Phase: Bundle creation and submission
4. Allocation Phase: Allocator competition for optimal outcomes
5. Reveal Phase: Identity disclosure and final settlement

---

## Implementation Challenges - Revised Analysis

### 1. Privacy Implementation - RESOLVED
- Original Concern: Complex privacy features may be difficult to implement
- Solution: Commit-reveal system with salt-based unlinkability
- Implementation: Two-salt system prevents bidder-proxy inference
- Security: Stake-based spam prevention and validation

### 2. Multi-Item Auction Coordination - RESOLVED
- Original Concern: Clock-proxy designed for multiple related items
- Solution: Multiple pools for different token types with cross-pool coordination
- Implementation: Shared state management across pools with common numeraire
- Key Constraint: All pools must share the same Y token (numeraire) for consistent pricing
- Questions to Explore:
  - How to coordinate state across multiple pools?
  - What's the optimal pool structure for different token types?
  - How to handle package bids spanning multiple pools?

### 3. Allocator Competition - RESOLVED
- Original Concern: Complex allocation optimization may exceed gas limits
- Solution: Multiple allocators compete with on-chain scoring
- Implementation: Predefined scoring rules evaluate allocation quality
- Future Enhancement: ZK-proof verification for complex optimizations

### 4. ERC1155 Integration - RESOLVED
- Original Concern: Token tracking and redemption complexity
- Solution: ERC1155 tokens represent allocations and enable trading
- Implementation: Tokens minted upon reveal, redeemable for items
- Benefits: Liquidity, composability, and flexible settlement

### 5. State Management - NEEDS INVESTIGATION
- Original Concern: Complex state tracking may require off-chain management
- Current Understanding: Need to investigate gas costs and storage limitations
- Questions to Explore:
  - What's the actual gas cost for storing auction state?
  - Can we optimize state storage patterns?
  - What's the maximum practical auction size on-chain?

---

## Key Design Decisions

### 1. Privacy-First Architecture
- Decision: Implement commit-reveal system with salt-based privacy
- Rationale: Prevents bidder-proxy collusion and strategic manipulation
- Implementation: Two-salt system with pre-bid registration

### 2. Allocator Competition
- Decision: Multiple allocators compete for optimal outcomes
- Rationale: Ensures best allocation strategy wins
- Implementation: On-chain scoring with predefined rules

### 3. ERC1155 Token Integration
- Decision: Use ERC1155 tokens for allocation tracking
- Rationale: Enables trading, composability, and flexible settlement
- Implementation: Tokens minted upon reveal, redeemable for items

### 4. Stake-Based Security
- Decision: Require stakes from bidders and proxies
- Rationale: Prevents spam and ensures compliance
- Implementation: Deposits returned or applied toward purchases
- Stake-to-BidPoints: Higher stakes grant more bidPoints, limiting clock phase bidding power

### 5. Multi-Pool Coordination
- Decision: Multi-pool architecture with common numeraire constraint
- Rationale: Enables package bidding across different token types with consistent pricing
- Key Constraint: All pools must share the same Y token (numeraire)
- Questions: How to coordinate state and ensure atomicity?

---

## Research Questions

### Technical Implementation
1. What's the gas cost for storing auction state for different sizes?
2. How can we optimize state storage patterns for auction data?
3. What's the maximum practical auction size on-chain?
4. How to coordinate state across multiple pools efficiently?

### Privacy and Security
1. How effective is the two-salt system against various attack vectors?
2. What are the optimal stake amounts for different auction sizes?
3. How to prevent timing-based inference attacks?
4. What additional privacy enhancements are possible with ZK proofs?

### Allocator Competition
1. What scoring criteria produce the best outcomes?
2. How to incentivize allocator participation?
3. What's the optimal number of allocators for different auction sizes?
4. How to handle allocator collusion or manipulation?

### Multi-Pool Architecture
1. What's the optimal pool structure for different token types?
2. How to handle package bids spanning multiple pools?
3. How to ensure atomicity across pool operations?
4. What's the coordination mechanism between pools?
5. How to enforce common numeraire constraint across all pools?

---

## Next Steps

### Phase 1: Infrastructure Design
1. Design auction state management structures
2. Define commit-reveal privacy mechanisms
3. Plan allocator competition framework
4. Design ERC1155 token integration
5. Plan multi-pool coordination architecture with common numeraire constraint

### Phase 2: Core Implementation
1. Implement setup and registration phase
2. Build clock phase with privacy features
3. Create proxy phase bundle submission
4. Add allocator competition mechanics
5. Implement reveal and settlement phase

### Phase 3: Advanced Features
1. Add multi-pool coordination
2. Implement ZK-proof privacy enhancements
3. Add advanced allocator scoring algorithms
4. Create external algorithm integration points

---

## Privacy and Competition Mechanics

### Commit-Reveal System
The privacy system uses a two-salt commit-reveal mechanism:

1. Bidder chooses two salts: `saltA` and `saltB`
2. Bidder sends `saltB` privately to proxy
3. Commit hash is computed:
   ```
   commitHash = keccak256(abi.encode(
       keccak256(abi.encode(bidderID, saltA)),
       keccak256(abi.encode(proxyAddress, saltB))
   ))
   ```

### Allocator Competition
- Multiple allocators submit proposed allocations
- On-chain scoring evaluates each allocation using predefined rules
- Winning allocation selected automatically with reward paid to winner
- Scoring criteria: Total value, fairness, efficiency, constraint satisfaction

---

## Stake-to-BidPoints Mechanism

### Economic Incentive Structure
The stake-to-bidPoints correlation creates a sophisticated economic incentive system that rewards serious bidders while preventing spam.

### Mechanism Details
1. Stake Amount: Bidders deposit stakes with each bid submission
2. BidPoints Calculation: BidPoints = stakeAmount (1:1 ratio)
3. Dynamic Staking: Bidders can increase their stake and bidPoints in subsequent rounds
4. Clock Phase Limitation: Bidders can only bid up to their current bidPoints during clock phase
5. Dynamic Pricing Impact: Higher bidPoints allow bidders to drive prices higher
6. Stake Recovery: Stakes are returned or applied toward purchases after reveal
7. Minimum Spending: Bidders must spend at least x% of total bid value (configurable per auction)
8. Penalties: y% dropout penalty, z% spending violation penalty (configurable per auction)

### Example Scenarios
- Alice stakes 10 tokenY in Round 1: Receives 10 bidPoints, can bid up to 10 tokenY total value
- Bob stakes 5 tokenY in Round 1: Receives 5 bidPoints, can bid up to 5 tokenY total value
- Carol stakes 1 tokenY in Round 1: Receives 1 bidPoint, can bid up to 1 tokenY total value
- Alice increases stake to 15 tokenY in Round 3: Now has 15 bidPoints, can bid up to 15 tokenY total value
- Bob maintains 5 tokenY stake: Keeps 5 bidPoints throughout auction

### Benefits
- Spam Prevention: Low stakes limit bidding power of unserious participants
- Serious Bidder Rewards: Higher stakes grant more influence in price discovery
- Economic Alignment: Bidders with skin in the game have more say in outcomes
- Flexible Participation: Different stake levels accommodate different bidder types

### Implementation Considerations
- Function Design: Linear, logarithmic, or other mapping functions
- Minimum Stakes: Base requirements to prevent micro-spam
- Maximum Stakes: Caps to prevent single-bidder dominance
- Dynamic Adjustment: Ability to adjust function based on auction performance

---

## ERC1155 Token Integration

### Token Purpose
ERC1155 tokens represent allocations and enable flexible settlement and trading.

### Token Lifecycle
1. Minting: Tokens minted upon successful reveal
2. Trading: Tokens can be traded on secondary markets
3. Redemption: Tokens redeemed for actual auctioned items
4. Settlement: Price differences settled upon redemption

### Benefits
- Liquidity: Tokens can be traded before redemption
- Composability: Tokens integrate with DeFi protocols
- Flexibility: Bidders can choose when to redeem
- Transparency: Clear representation of allocations

---

## Key Insights

1. Privacy is essential - commit-reveal system prevents strategic manipulation
2. Allocator competition ensures optimal outcomes - multiple strategies compete
3. ERC1155 tokens enable liquidity and composability - flexible settlement
4. Stake-based security prevents spam - economic incentives for compliance
5. Multi-pool coordination enables complex auctions - package bidding across tokens
6. On-chain implementation preferred - transparency and trust

---

## Questions for Further Discussion

1. What specific use cases are we targeting? (Token launches, LP auctions, governance sales?)
2. How large do we expect auctions to be? (Number of bidders, number of items)
3. What's the priority: simplicity vs. full clock-proxy implementation?
4. How important is package bidding for our use cases?
5. What's the timeline and scope for this project? 