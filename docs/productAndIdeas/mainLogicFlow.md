# UniV4 Hook Clock-Proxy Auction System – Commit–Reveal with Proxies and Allocator Competition

This is for the most open design of the clock proxy. There are other designs that can be closed (i.e. whitelist of bidders, proxies, etc.).

## Overview
This auction design ensures that:
- During the Clock Phase: The mapping between bidders and their proxies is hidden.
- Post Allocation / Reveal Phase: The mapping is disclosed, enabling verification of correctness.
- Spam resistance: Only registered proxies with staked deposits can submit bundles.
- Allocator competition: Multiple allocators propose allocations; the best one is selected and rewarded on-chain.
- Pre-bid registration: Proxies must register before any bids referencing their commitHash are accepted.

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

---

## Auction Phases

### 1. Setup Phase
On-chain
- Auction contract is deployed with:
  - Any address can be a bidder and cannot submit bids without initial stakes.
- Any address can be a proxy but must register via `registerCommit` before associated bids are accepted.
- Stake-to-BidPoints: Bidders receive bidPoints based on their stake amount with each bid, limiting their clock phase bidding power.
- Configurable parameters: bid submission window, proxy registration window, allocation window, reveal window, stake amounts, rate limits, max possible stake (future safeguard).
  - As a UniV4 hook, auctioned items are tokens in linked pools.
  - Auctioneer deploys pools and deposits items.
  - Common Numeraire Constraint: All pools must share the same Y token (numeraire) for consistent pricing.
  - Auction contract controls pool pricing.
  - Hook-Owned Assets: Auction hook will own assets in each pool (implementation detail for later).
- Future feature: Instead of `transferFrom`, bidders could be ERC-6909 contracts that mint claims to the auction contract.

Off-chain
- Bidders and proxies establish communication channels.
- Bidders select a proxy and share a secret salt.

---

### 2. Clock Phase (Bidding + Commit Registration)

#### Commit–reveal unlinkability improvement
Instead of committing directly to `(bidderID, proxyAddress, salt)`:
1. Bidder chooses two salts: `saltA` and `saltB`.
2. Bidder send `saltB` privately to the proxy.
3. Commit hash is:
   ```
   commitHash = keccak256(abi.encode(
       keccak256(abi.encode(bidderID, saltA)),
       keccak256(abi.encode(proxyAddress, saltB))
   ))
   ```
   - During clock phase, only `commitHash` is public.
   - Neither inner hash can be inverted to reveal the other party’s ID.

#### Off-chain
1. Bidder computes `commitHash` as above.
2. Bidder sends `commitHash` and `saltB` to proxy.
3. Proxy calls `registerCommit(commitHash)` before any bids referencing it can be placed.
  a. This pre-mints an ERC1155 bidderToken BUT DOES NOT TRANSFER IT.

#### On-chain
- Clock loop:
  - Auctioneer announces prices.
  - Bidders submit `bid([] demands, bidderId, commitHash, stakeAmount)`.
    - Contract enforces: `commitHash` exists in `commitProxy` mapping before accepting bid.
    - Contract calculates: bidPoints = stakeAmount (1:1 ratio) and updates bidder's total bidPoints.
    - Contract enforces: Total bid value does not exceed bidder's current bidPoints.
    - BidPoints reset each round (not consumed by bids, allowing continued participation).
    - BidPoints are equivalent to the cost of the bid; that is, for the fully open auction, a bidder cannot bid on more items than they can pay for
  - Auctioneer updates pool prices.
  - Bidders may call `dropout(bidderId)` to exit with partial refund (80% refund, 20% penalty).
  - Process repeats until there is no excess demand for any item or time runs out.
- Proxy registration:
  ```
  registerCommit(commitHash)
  ```
  - Stakes deposit.
  - Checks:
    - Not previously registered.
    - `msg.sender` is proxy.
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
- Only registered proxy for `commitHash` may call.
- Bundles limited to one per commitHash.

Off-chain
- Proxy may prepare bundle using bidder’s instructions.

---

### 4. Allocation Phase (Allocator Competition)

On-chain
- Allocators submit proposed allocations:
  ```
  submitAllocation(allocationData)
  ```
- Contract scores each allocation using predefined rules (e.g. total value maximization, fairness constraints).
- Winning allocation computed on-chain and stored:
  ```
  winningAllocator = allocators[bestIndex]
  ```

Off-chain
- Allocators simulate and optimize before submission.

---

### 5. Reveal Phase

On-chain
```
reveal(
  bidderID, saltA,
  proxyAddress, saltB
)
```
- Checks:
  ```
  keccak256(abi.encode(
      keccak256(abi.encode(bidderID, saltA)),
      keccak256(abi.encode(proxyAddress, saltB))
  )) == commitHash
  ```
- Links bidder ↔ proxy publicly.
- Returns stakes or applies them toward purchases.
- Invalid reveals forfeit stake.
- Allocator reward is paid out.
- Upon reveal, the bidderToken is transferred to the bidder who has placed it.
  - This allows the bidder to redeem the ERC1155 bidderToken for the bundle they have been allocated, paying or being refunded whatever is necessary to settle the books.
  - Minimum spending requirement automatically checked: Bidders must spend at least x% of their total bid value on final purchases.
  - Minimum spending violations result in y% stake penalty and reveal failure.

Off-chain
- Mapping becomes public for verification.

---

## On-chain Data Structures

```solidity
mapping(bytes32 => address) public commitProxy; // commitHash → proxyAddress
mapping(address => uint256) public proxyStake;  // proxy → staked amount
mapping(address => uint256) public bidderStake; // bidder → staked amount
mapping(address => uint256) public bidderBidPoints; // bidder → bidPoints
address public commonNumeraire;                 // Y token shared across all pools
Allocation[] public allocations;                // proposed allocations
address public winningAllocator;
```

---

## On-chain vs Off-chain Summary

On-chain:
- `registerCommit(commitHash)`
- `bid(demands, bidderId, commitHash, stakeAmount)` (requires commit registered, calculates bidPoints, respects bidPoints limit)
- `dropout(bidderId)` (allows bidder to exit with partial refund, default 80% refund, 20% penalty)
- `submitBundle(commitHash, bundleData)`
- `submitAllocation(allocationData)`
- Allocation scoring & selection (best allocation chosen on-chain)
- `reveal(bidderID, saltA, proxyAddress, saltB)`
- `dropout(bidderId)` (partial refund with penalty)
- `enforceMinimumSpending(bidderId, purchaseAmount)` (automatically checked during reveal)
- Stake management & reward payout

Off-chain:
- Proxy–bidder selection & salt exchange
- Commit computation
- Bundle creation
- Allocation simulation

---

## Security / Anti-spam Features
- Commit hash must be registered before bidding.
- Proxies and bidders stake deposits.
- Bundles accepted only from registered proxies.
- Stakes slashed for spam or invalid reveals.
- Dropout penalty: 20% stake forfeiture for early exit (discourages strategic withdrawal).
- BidPoints reset each round (allows continued bidding as prices rise).
- Minimum spending requirement: Bidders must spend at least 50% of their total bid value on final purchases (prevents gaming with large deposits but small bundles).
- Max stake cap possible as configurable safeguard.
- Common numeraire constraint enforced across all pools.
- Future features:
  - ERC-6909 claims minting instead of token transfers.
  - ZK proofs for privacy even after allocation.
  - Timing/pattern obfuscation to mitigate bidder–proxy inference.

---

## Future Scaling & ZK Integration

Phase 1 – POC (Current)
- Full allocation submitted and scored on-chain.
- Suitable for small datasets.

Phase 2 – Off-chain Allocation + On-chain Commitment
- Allocators submit `keccak(allocationData)` or Merkle root on-chain.
- Allocation stored off-chain (IPFS, Arweave).
- Reveal phase includes full allocation; contract re-hashes for verification.

Phase 3 – ZK-Proof Verification
- Allocator computes optimal allocation off-chain.
- Generates ZK proof that:
  - The allocation matches the committed root.
  - It satisfies all auction constraints.
  - It achieves claimed welfare score.
- On-chain verifier checks proof in O(1) time, reducing gas costs and removing need to store large allocations.
