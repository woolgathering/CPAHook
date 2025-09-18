# Clock-Proxy Auction System – Commit–Reveal with Proxies and Allocator Competition

## Two-Contract Architecture

### Design Overview
The system uses two main contracts for efficiency and reusability:

1. **CPAManager**: Manager contract that handles auction logic and state management
2. **PoolHook**: Shared hook that all asset pools attach to, controlled by the CPAManager

### Initialization Process
1. Deploy CPAManager (single contract for all auctions)
2. Deploy PoolHook with CPAManager address as constructor argument
3. Create asset pools (A<>USDC, B<>USDC, C<>USDC) with PoolHook attached
4. Create auction via CPAManager.createAuction() with pool keys and parameters

### Multi-Auction Support
- Each auction gets a unique auctionId
- Each auction has its own owner (not the CPAManager owner)
- All auction variables are indexed by auctionId
- Only the auction owner can control their specific auction

### PoolHook Control
- CPAManager controls the single PoolHook via setAuctionState() and setPoolAllowed()
- PoolHook blocks all operations when auction is active
- Centralized control mechanism for auction state

## Overview
This auction design ensures that:
- During the Clock Phase: The mapping between bidders and their proxies is hidden.
- Post Allocation / Reveal Phase: The mapping is disclosed, enabling verification of correctness.
- Spam resistance: Only registered proxies with staked deposits can submit bundles.
- Allocator competition: Multiple allocators propose allocations; the best one is selected and rewarded on-chain.
- Pre-bid registration: Proxies must register before any bids referencing their commitHash are accepted.
- Manager-based implementation: Auction phases map directly to V4 pool behaviors with stake mechanism.

---

## Rules
1. Immutable Mapping – Once a commitHash → proxy mapping exists, it cannot be overwritten.
2. Pre-Bid Registration – Commit must be registered before any bid.
3. On-chain Scoring – Scoring is done directly in Solidity.
4. Stake Requirement – Bidders must deposit stake when submitting bids.
5. Allocator Competition – Multiple allocators submit; best-scoring allocation wins.
6. Verification Priority – Always verify commit before accepting a bid.
7. Stake Mechanism – Bidders stake numeraire tokens for bidding.
8. Manager Control – CPAManager manages all auction operations.

---

## Auction Phases

### 1. Setup Phase
On-chain
- **System Deployment**:
  - CPAManager is deployed as a single contract that will manage all auctions
  - PoolHook is deployed with CPAManager address as constructor argument
  - PoolHook will be attached to all asset pools for auction control

- **Auction Creation**:
  - Auctioneer calls `CPAManager.createAuction(poolKeys, config, owner)` to create a new auction
  - Each auction gets a unique auctionId
  - Each auction has its own owner (not the CPAManager owner)
  - Auction configuration includes: bid submission window, proxy registration window, allocation window, settlement window, stake amounts, rate limits

- **Pool Setup**:
  - Asset pools (A<>commonNumeraire, B<>commonNumeraire, C<>commonNumeraire) are created with PoolHook attached
  - Common Numeraire Constraint: All pools must share the same numeraire for consistent pricing
  - CPAManager controls pool pricing and operations through PoolHook

- **Auction Configuration**:
  - Any address can be a bidder and must deposit stake to submit bids
  - Any address can be a proxy but must register via `registerCommit` before associated bids are accepted
  - Stake Mechanism: Bidders deposit numeraire tokens as stake for bidding
  - CPAManager manages all auction operations and state

Off-chain
- Bidders and proxies establish communication channels
- Bidders select a proxy and share a secret salt

---

### 2. Clock Phase (Bidding + Commit Registration)

#### Commit–reveal unlinkability improvement
Instead of committing directly to `(bidderID, proxyAddress, salt)`:
1. Bidder chooses two salts: `saltA` and `saltB`.
2. Bidder sends `saltB` privately to the proxy.
3. Commit hash is:
   ```
   commitHash = keccak256(abi.encode(
       keccak256(abi.encode(bidderID, saltA)),
       keccak256(abi.encode(proxyAddress, saltB))
   ))
   ```
   - During clock phase, only `commitHash` is public.
   - Neither inner hash can be inverted to reveal the other party's ID.

#### Off-chain
1. Bidder computes `commitHash` as above.
2. Bidder sends `commitHash` and `saltB` to proxy.
3. Proxy calls `registerCommit(commitHash)` before any bids referencing it can be placed.

#### On-chain
- Clock loop:
  - Bidders submit bids through `submitBid()`:
    - Call `CPAManager.submitBid(auctionId, demands, stakeAmount)`
    - Contract enforces: `commitHash` exists in `revealedMappings` mapping before accepting bid
    - Contract calculates: required stake based on current prices and bid type
    - Contract enforces: bidder has sufficient stake for the bid
    - Stake is deducted from bidder's balance
  - Price discovery happens through Doppler-style manipulation
  - Bidders may call `dropout()` to exit with partial refund
  - Process repeats until there is no excess demand for any item or time runs out
  - At clock phase end: Final prices are set through price manipulation
- Proxy registration:
  ```
  registerCommit(commitHash)
  ```
  - Checks:
    - Not previously registered
    - `msg.sender` is proxy
  - Records:
    ```
    commitProxy[commitHash] = proxyAddress
    ```

---

### 3. Proxy Phase (Bundle Submission)

On-chain
```
submitBundle(commitHash, bundleData)
```
- Only registered proxy for `commitHash` may call
- Bundles limited to one per commitHash
- Bundle data includes quantities for each asset
- No hook interaction during this phase

Off-chain
- Proxy may prepare bundle using bidder's instructions

---

### 3.5. Reveal Phase (Identity Disclosure)

On-chain
```
reveal(bidderID, saltA, proxyAddress, saltB)
```
- Bidder calls `reveal()` to disclose their identity
- Contract verifies the commit hash matches the revealed values
- Links bidder ↔ proxy publicly in `revealedMappings`
- Enables verification of bidder-proxy relationship
- Required before settlement phase

Off-chain
- Mapping becomes public for verification

---

### 4. Allocation Phase (Allocator Competition)

On-chain
- Allocators submit proposed allocations:
  ```
  submitAllocation(allocationData)
  ```
- Allocators select bundles using bundle IDs from the proxy phase
- Contract scores each allocation using predefined rules (e.g. total value maximization, fairness constraints)
- Winning allocation computed on-chain and stored:
  ```
  winningAllocator = allocators[bestIndex]
  ```
- **Allocator Reward System**: Winning allocator receives 1% of total bid value
  - Reward is calculated as: `totalBidValue * 0.01`
  - Claimed through `claimAllocatorReward(auctionId)`
  - Distributed from the 1% fee taken from each bid
- No hook interaction during this phase

Off-chain
- Allocators simulate and optimize before submission
- Allocators analyze available bundles and select optimal combinations

---

### 5. Settlement Phase

On-chain
- Bidders claim their allocated tokens:
  ```
  claimToken(auctionId, commitHash, poolId)  // Single asset claim (owner only)
  claimAllTokens(auctionId, commitHash)      // Batch claim all assets
  ```
- **Stake Mechanism**: Contract validates bidder eligibility and allocation
  - Uses deposited stake first for token purchases
  - If stake is insufficient, requires additional numeraire from bidder
  - If stake exceeds required amount, refunds excess to bidder
  - Stake is used to execute swaps in asset pools on behalf of bidder
- Transfers assets directly to bidder
- **Batch Operations**: `claimAllTokens()` allows claiming all allocated assets in single transaction
- **Efficient Settlement**: Reduces gas costs compared to individual claims

Off-chain
- Mapping becomes public for verification

---

### 6. Finished Phase

On-chain
- Auction is marked as finished
- All operations are blocked
- Final state is recorded

---

## On-chain Data Structures

```solidity
// Core auction state
mapping(AuctionId => AuctionInfo) public auctionInfo;           // auctionId → auction info
mapping(AuctionId => mapping(address => uint256)) public bidderStake; // auctionId → bidder → stake
mapping(AuctionId => mapping(bytes32 => address)) public revealedMappings; // auctionId → commitHash → bidder
mapping(AuctionId => mapping(BundleId => Bundle)) public bundles; // auctionId → bundleId → bundle
mapping(AuctionId => mapping(bytes32 => BundleId)) public winningBundleIds; // auctionId → commitHash → bundleId

// Auction info structure
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

// Bundle structure
struct Bundle {
    AuctionId auctionId;
    bytes32 commitHash;
    uint256 value;
    uint256[] quantities;
    uint256 timestamp;
}

// Allocation structure
struct Allocation {
    AuctionId auctionId;
    address allocator;
    BundleId[] bundleIds;
    uint256 totalValue;
    uint256 timestamp;
}
```

---

## On-chain vs Off-chain Summary

On-chain:
- `registerCommit(commitHash)` - Register commit hash for privacy
- `submitBid(auctionId, demands, stakeAmount)` - Submit bid with stake
- `submitBundle(commitHash, bundleData)` - Submit bundle for allocation
- `reveal(bidderID, saltA, proxyAddress, saltB)` - Reveal bidder-proxy identity
- `submitAllocation(allocationData)` - Submit allocation for scoring
- `claimToken(auctionId, commitHash, poolId)` - Claim single asset (owner only)
- `claimAllTokens(auctionId, commitHash)` - Claim all allocated assets
- `claimAllocatorReward(auctionId)` - Claim 1% reward for winning allocator
- Allocation scoring & selection (best allocation chosen on-chain)
- Stake management & reward payout
- Price manipulation using Doppler mechanism

Off-chain:
- Proxy–bidder selection & salt exchange
- Commit computation
- Bundle creation
- Allocation simulation

---

## Security / Anti-spam Features
- Commit hash must be registered before bidding
- Bidders must deposit stake for bidding
- Bundles accepted only from registered proxies
- Stakes used for token purchases during settlement
- Common numeraire constraint enforced across all pools
- PoolHook controls all operations during auction
- Item pools blocked except for CPAManager operations
- Price manipulation at clock phase end
- **Allocator Reward System**: 1% fee taken from each bid, distributed to winning allocator
  - Incentivizes optimal allocation strategies
  - Rewards allocators for finding best bundle combinations
  - Fee is calculated and distributed automatically
- Batch claiming for efficient settlement
- Identity disclosure required before settlement

---

## Technical Implementation Challenges

### Multi-Auction State Management
- Challenge: Managing isolated state for multiple concurrent auctions
- Solution: AuctionId-based mappings for all state variables with clear ownership model

### PoolHook Coordination
- Challenge: Coordinating multiple pools across different auctions
- Solution: Single PoolHook with auction-aware blocking controlled by CPAManager

### Gas Optimization
- Challenge: Complex auction logic may be gas-intensive
- Solution: Use libraries for calculations, pack state variables efficiently, batch operations where possible

### Privacy Implementation
- Challenge: Maintaining bidder-proxy privacy during auction
- Solution: Two-salt commit-reveal system with pre-bid registration requirement

---

## Future Enhancements

### Phase 1 – Current Implementation
- Full allocation submitted and scored on-chain
- Suitable for small to medium datasets
- Complete privacy through commit-reveal system

### Phase 2 – Off-chain Allocation + On-chain Commitment
- Allocators submit `keccak(allocationData)` or Merkle root on-chain
- Allocation stored off-chain (IPFS, Arweave)
- Reveal phase includes full allocation; contract re-hashes for verification

### Phase 3 – ZK-Proof Verification
- Allocator computes optimal allocation off-chain
- Generates ZK proof that:
  - The allocation matches the committed root
  - It satisfies all auction constraints
  - It achieves claimed welfare score
- On-chain verifier checks proof in O(1) time, reducing gas costs and removing need to store large allocations
