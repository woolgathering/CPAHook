# Clock Phase Redesign: Eliminating O(n×m)

**Status**: Design — not yet implemented  
**Date**: 2026-05-23  
**Context**: Identified during audit (AUDIT_CLOCK_PHASE.md, Problem 4). The current
`processClockRound` loops all m bidders × all n assets every round to aggregate demand.
On mainnet this is a hard gas ceiling; on L2 it is manageable at small scale but still
an architectural smell worth fixing.

---

## The Two-Part Problem

### Part 1: Bid Submission — O(n) per bidder
Bidders submit a full demand vector of length n (one entry per asset). Unavoidable if
expressed as a dense array, but improvable with sparse representation. Whether this is
a real problem depends on typical auction sizes — **market research pending**.

### Part 2: Round-End Aggregation — O(n×m) per round  
Every clock round, the protocol re-aggregates demand from scratch by iterating all
bidders × all assets. This is the critical issue; it is entirely avoidable.

---

## Agreed Solution

### Core Principle: Running Counters + Bids Don't Persist Between Rounds

Bids resetting each round is standard clock auction behavior and is already implicit in
the current design (`activeBidders` is deleted after each round). Formalising this
enables the counter approach below.

---

### 1. Sparse Bid Adjustments (replaces dense vector submission)

```solidity
function adjustBid(AuctionId auctionId, AssetId assetId, uint256 newQuantity) external
```

- O(1) per asset — bidder only touches assets they care about
- Multiple calls allowed throughout a round (set, not delta)
- Natural for ERC721/ERC1155 auctions (bidder wants 5 of 1,000 parcels)
- Replaces `processBid` which required a full-length demands array

### 2. Running Demand Counter (eliminates O(n×m) at round-end)

On each `adjustBid` call:

```solidity
uint256 oldDemand = (bidderDemandRound[bidder][assetId] == currentRound)
    ? bidderDemand[bidder][assetId]
    : 0;  // Stale — previous round

int256 delta = int256(newQuantity) - int256(oldDemand);
totalDemand[assetId] = uint256(int256(totalDemand[assetId]) + delta);

bool wasOversold = excessDemand[assetId];
bool isOversold  = totalDemand[assetId] > assetSupply[assetId];

if (!wasOversold && isOversold)  assetsWithExcessDemand++;
if (wasOversold  && !isOversold) assetsWithExcessDemand--;

excessDemand[assetId]              = isOversold;
bidderDemand[bidder][assetId]      = newQuantity;
bidderDemandRound[bidder][assetId] = currentRound;

// Update running stake cost for this bidder this round
if (bidderLastBidRound[bidder] < currentRound) {
    bidderStakeUsed[bidder] = 0;  // Reset for new round
    bidderLastBidRound[bidder] = currentRound;
}
bidderStakeUsed[bidder] = uint256(int256(bidderStakeUsed[bidder]) + delta * int256(currentPrice[assetId]));
// require bidderStake[bidder] >= bidderStakeUsed[bidder] (or collect shortfall)
```

Round-end check becomes O(1):
```solidity
if (assetsWithExcessDemand == 0 || currentRound >= maxRounds) → end clock
```

### 3. Between-Round Window (not a new phase)

Uses existing `clockOpen` signal (already 1/2 state) rather than a new variable.

- `endRound`: freezes bidding (`clockOpen = 1`), increments `currentRound`
  (already exists in `AuctionInfo`)
- Between-round: price updates happen
- `startRound`: requires `assetsWithExcessDemand == 0`, opens bidding (`clockOpen = 2`)

### 4. Per-Asset Price Updates — O(1) each

```solidity
// External entry point
function incrementPrice(AuctionId auctionId, AssetId assetId) external {
    _incrementPrice(auctionId, assetId);
}

// Convenience batch for small auctions
function incrementAllOversoldPrices(AuctionId auctionId) external {
    for (uint i = 0; i < auctionAssets[auctionId].length; i++) {
        _incrementPrice(auctionId, auctionAssets[auctionId][i]);
    }
}

function _incrementPrice(AuctionId auctionId, AssetId assetId) internal {
    if (!excessDemand[assetId]) return;  // Not oversold — also prevents double-call

    assetInfo[assetId].currentPrice += assetInfo[assetId].config.priceIncrement;
    totalDemand[assetId] = 0;       // Bids don't persist between rounds
    excessDemand[assetId] = false;
    assetsWithExcessDemand--;
}
```

`incrementPrice` is **permissionless** — anyone can call it. Auctioneer has the
strongest incentive (missed updates = less revenue). No explicit reward mechanism
needed for v1; the incentive alignment is sufficient.

### 5. O(1) Safety Valve at Round Start

```solidity
function startRound(AuctionId auctionId) external {
    require(assetsWithExcessDemand == 0, "Oversold assets not yet price-updated");
    clockOpen = 2;
}
```

Hard block: the round cannot advance until all oversold assets have been updated.
Enforced on-chain, O(1). No loop required.

---

## Variables: New vs Eliminated

### New storage required

| Variable | Type | Purpose |
|----------|------|---------|
| `totalDemand[assetId]` | `uint256` per asset | Running aggregate demand — replaces per-bidder loop |
| `excessDemand[assetId]` | `bool` per asset | Replaces `int256 excessDemand` — only oversold/not matters |
| `assetsWithExcessDemand` | `uint256` per auction | O(1) round-end and startRound gate |
| `bidderDemand[bidder][assetId]` | `uint256` 2D mapping | Sparse demand per bidder per asset |
| `bidderDemandRound[bidder][assetId]` | `uint256` 2D mapping | Per-asset epoch to detect stale demand |
| `bidderStakeUsed[bidder]` | `uint256` per bidder | Running cost of current-round bids |
| `bidderLastBidRound[bidder]` | `uint256` per bidder | Epoch reset for `bidderStakeUsed` |

### Eliminated

| Variable | Reason |
|----------|--------|
| `bids[bidder][]` (dense array) | Replaced by sparse `bidderDemand` mapping |
| `activeBidders[]` | No longer needed — demand tracked by counter |
| `pendingRoundDemands[]` | Replaced by `totalDemand[assetId]` per-asset |
| `roundPendingFinalize` | Replaced by `assetsWithExcessDemand == 0` check |
| `assetsAwaitingPriceUpdate` | Eliminated — `assetsWithExcessDemand` doubles as this |
| `lastPriceUpdateRound[assetId]` | Eliminated — `excessDemand` flag is sufficient |

### Reused unchanged

| Variable | Where |
|----------|-------|
| `clockOpen` (1/2 state) | Already signals between-round vs open |
| `currentRound` | Already in `AuctionInfo` |
| `maxRounds` | Already in auction config |
| `bidderStake[bidder]` | Persists across rounds as before |

---

## Complexity After Redesign

| Operation | Before | After |
|-----------|--------|-------|
| Bid submission | O(n) full array | O(1) per asset touched |
| Round-end demand check | O(n×m) | O(1) via counter |
| Price increment (single asset) | O(n) all assets | O(1) |
| Price increment (all assets) | O(n) — same call | O(n) — convenience batch only |
| `startRound` gate | None | O(1) counter check |
| Hard asset ceiling | ~50 practical | None |

---

## Open Questions / Deferred Decisions

### 1. Proxy Bundle Submission (DEFERRED — pending market research)

Proxies submit bundles with a quantities array of length n (same dense-array problem as
bids). Whether this needs the same sparse treatment depends on typical auction size.

**Market research needed**: What is the typical number of assets in a real CPA auction?
(ERC20 vs ERC721 vs ERC1155 contexts differ significantly.)

If n is small (< 50), dense arrays are fine throughout. If n is large (hundreds for
ERC721 grid auctions), bundles need the same sparse treatment as bids.

Decision point: after market research, revisit whether to:
- Keep dense bundle arrays (simple, works for small n)
- Add sparse bundle component submissions (complex, necessary for large n)

### 2. Activity Rule

The current activity rule (`_validateActivityRule`) uses stored previous bids to
enforce that demand cannot increase for assets whose price rose. In the new design,
previous bids are gone at round start.

Options:
- Store `lastRoundDemand[bidder][assetId]` (another per-asset mapping, populated at
  round end before reset)
- Or fold into `bidderDemandRound` — if round is previous round, value is last bid
- Needs design work before implementation

### 3. Timed Rounds (nice-to-have for v1)

Making clock rounds time-bounded (not just auctioneer-controlled) plus making
`incrementPrice` permissionless ensures bidders are protected against an incompetent
or unresponsive auctioneer. The safety valve (`assetsWithExcessDemand == 0` gate on
`startRound`) already provides a hard guarantee without timed rounds, but timed rounds
add another layer of protection.

Defer unless required for v1.

---

## Implementation Order (when ready)

1. Storage layout changes (`ClockPhaseState`, `AssetInfo`)
2. `_incrementPrice` internal function
3. `adjustBid` replacing `processBid`
4. `endRound` / `startRound` replacing `openClockRound` / `processClockRound`
5. `incrementPrice` / `incrementAllOversoldPrices` external functions
6. Activity rule redesign
7. Test rewrite

---

## Hybrid On/Off-Chain Architecture (Future Work)

### Key Insight: Allocation Phase Already Uses This Pattern

The allocation phase is already an optimistic off-chain model:
- Combinatorial optimization runs off-chain (allocators run their own algorithms)
- Result is submitted on-chain
- Protocol verifies the submitted score but cannot verify optimality — it accepts the
  highest-scoring submission
- Permissionless — any allocator can compete

This is Alternative 1 (Optimistic Aggregation) already in practice. The protocol
already trusts off-chain computation for the hardest problem (combinatorial
optimization), and verifies only what it can cheaply verify on-chain (the score).

### Extending the Pattern to Clock Phase

The gap between the current system and a full Alternative 1 hybrid is smaller than it
appears. What's needed is:

1. Auctioneer posts aggregated demand + new prices on-chain each round
2. A challenge window where anyone can submit a fraud proof
3. Fraud proof: "bidder X has on-chain bid Y for asset Z, but your aggregate for asset Z
   is wrong" — trivially verifiable in O(1) against stored bids
4. Auctioneer stakes a bond slashed on successful challenge

The on-chain bid record (from `adjustBid`) is what makes fraud proofs cheap. As long
as bids are on-chain, anyone can recompute the correct aggregate and challenge a lie.

### Dual-Mode Design (Recommended)

Maintain both modes:

**Mode A: Full On-Chain** (current architecture, with O(n×m) fix applied)
- No off-chain infrastructure required
- Auctioneer calls `endRound` which checks `assetsWithExcessDemand` counter (O(1))
- Auctioneer calls `incrementPrice` per asset between rounds
- Suitable for small auctions (< ~200 assets) or auctions where simplicity matters
- Basically done once the O(n×m) fix is implemented

**Mode B: Optimistic Off-Chain** (future, for large auctions)
- Bids still submitted on-chain via `adjustBid` (same interface as Mode A)
- Auctioneer aggregates off-chain, posts `endRound(demands[], newPrices[])` assertion
- Challenge window (e.g., 15 minutes) before prices are accepted
- Fraud proof contract verifies disputes in O(1)
- Suitable for large auctions (hundreds/thousands of ERC721 assets)
- Requires bond from auctioneer, challenge infrastructure

The same `adjustBid` interface works for both modes. Mode selection could be per-auction
at setup time, or determined by asset count threshold.

### What Stays On-Chain in Both Modes

| Component | On-Chain? | Notes |
|-----------|-----------|-------|
| Stake deposits/withdrawals | Always | Financial |
| Asset deposits/transfers | Always | Financial |
| Individual bids | Always | Enables fraud proofs in Mode B |
| Locked clearing prices | Always | All downstream phases depend on these |
| Commit hashes (proxy phase) | Always | Privacy layer |
| Winning allocation | Always | Financial finality |
| Settlement | Always | Financial |
| Demand aggregation | Mode A only | Moves off-chain in Mode B |
| Price update computation | Mode A only | Moves off-chain in Mode B |
| Allocation scoring | Neither | Already off-chain in both |

### Long-Term: ZK Proofs (Not Near-Term)

ZK-proven aggregation would eliminate the challenge window and trust assumption
entirely. Auctioneer proves correct computation cryptographically; on-chain verifier
checks in O(1). Suitable for private bids (bids never revealed publicly). This is the
ideal end state but requires substantial ZK circuit work — not a v1 or v2 concern.

### Recommended Sequencing

1. **Now**: Implement O(n×m) fix (Mode A). Full on-chain, no new trust assumptions.
   After market research on typical auction sizes, decide if Mode A is sufficient.
2. **If large auctions needed**: Implement Mode B (optimistic). Same `adjustBid`
   interface, add assertion + challenge logic.
3. **Long-term**: ZK proofs for Mode B, eliminating challenge latency and trust
   assumptions entirely.
