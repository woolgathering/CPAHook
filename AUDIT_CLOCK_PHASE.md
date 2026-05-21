# Clock Phase Audit Report

**Date:** 2026-05-21  
**Scope:** Clock phase implementation across CPAClockPhase.sol, ClockBidFacet.sol, ClockBidderFacet.sol, ClockEndRoundFacet.sol, ClockFinalizeRoundFacet.sol, and CPABaseClock.sol  
**Purpose:** Identify inefficiencies, limitations, logic bugs, and gas issues — problems only, no solutions proposed

---

## Executive Summary

The Clock phase implements ascending-price discovery through iterative rounds of bidding. However, the implementation has **critical gas scaling issues and logic bugs** that limit practical auction sizes and enable demand manipulation:

1. **O(n×m) nested loop in processClockRound** — quadratic scaling with assets and bidders, can exceed block gas limits
2. **Duplicate bidder tracking** — same bidder can appear multiple times in activeBidders array, causing demand overcounting
3. **Linear search for bidder removal** — inefficient dropout operation, O(m) cost per dropout
4. **Activity rule bypassed on first bid** — no validation that demand increase is within rules
5. **Stale state validation** — changedPrices persists across rounds, used for validation in wrong round context
6. **No bidder count limits** — unbounded array growth, no MAX_BIDDERS constant
7. **Multiple performance inefficiencies** — full array iterations, redundant data structures

---

## Phase Overview

### Flow
1. **submitBid()** (ClockBidFacet) — bidder submits demand for each asset
2. **processClockRoundStep()** (ClockEndRoundFacet) — aggregates demands, updates prices
3. **finalizeClockRound()** (ClockFinalizeRoundFacet) — checks if phase should end, opens next round or transitions
4. **dropout()** (ClockBidderFacet) — bidder can withdraw with penalty

### Key Data Structure
```solidity
struct ClockPhaseState {
    mapping(address => uint256) bidderStake;      
    mapping(address => uint256) bidderBidPoints;
    mapping(address => uint256[]) bids;           // Per-bidder demand array
    address[] activeBidders;                       // Unbounded array of bidders
    mapping(address => bool) droppedBidders;
    uint256[] pendingRoundDemands;
    bool roundPendingFinalize;
}
```

---

## Problems Found

### PROBLEM 1: Unbounded O(n×m) Nested Loop — Quadratic Gas Explosion 🔴 **CRITICAL**

**Location:** `src/libraries/CPAClockPhase.sol:70-107` (processClockRound function)

**Code:**
```solidity
function processClockRound(
    AuctionId auctionId,
    AuctionTypes.AuctionInfo storage auctionInfo,
    mapping(AssetId => AuctionTypes.AssetInfo) storage assetInfo,
    ClockPhaseState storage clockState
) internal returns (uint256[] memory) {
    uint256 numAssets = auctionInfo.assets.length;
    uint256[] memory totalDemands = new uint256[](numAssets);
    address[] storage currentActiveBidders = clockState.activeBidders;

    for (uint256 i = 0; i < numAssets; ) {                           // O(n): assets
        AssetId assetId = AssetIdLibrary.createId(auctionId, auctionInfo.assets[i].assetToken);

        for (uint256 j = 0; j < currentActiveBidders.length; ) {      // O(m): bidders
            address bidder = currentActiveBidders[j];
            if (bidder != address(0)) {
                totalDemands[i] += clockState.bids[bidder][i];        // SLOAD + add
            }
            unchecked { ++j; }
        }

        AuctionTypes.AssetInfo storage asset = assetInfo[assetId];
        asset.excessDemand = int256(totalDemands[i]) - int256(asset.depositAmount);
        // ... price updates ...
        unchecked { ++i; }
    }

    delete clockState.activeBidders;
    return totalDemands;
}
```

**Problem:**
- **O(n × m) complexity** where n = number of assets, m = number of active bidders
- Called every clock round (ClockEndRoundFacet.sol:27-29, processClockRoundStep)
- Each iteration performs:
  - Array length read: ~3 gas
  - Address comparison and SLOAD: ~2,100 gas
  - Addition and storage write: ~50 gas
  - Total per iteration: ~2,150 gas

**Gas Cost Analysis:**
```
Iterations = n * m
Cost per iteration = 2,150 gas
Total = n * m * 2,150

Examples:
- 10 assets × 100 bidders = 1,000 iterations = 2.15M gas ✓ OK
- 50 assets × 500 bidders = 25,000 iterations = 53.75M gas 🔴 EXCEEDS BLOCK LIMIT (30M)
- 100 assets × 1,000 bidders = 100,000 iterations = 215M gas 💀 FAR EXCEEDS
```

**Real-world impact:**
- With moderate auction size (50 assets, 500 bidders), clock round processing **exceeds block gas limit**
- Entire round gets stuck
- State becomes inconsistent
- Auction cannot progress

**Severity:** **CRITICAL** — blocks realistic auction sizes

---

### PROBLEM 2: Duplicate Bidder Array Entries — Silent Demand Overcounting 🔴 **HIGH**

**Location:** `src/libraries/CPAClockPhase.sol:21-65` (processBid function), lines 61-62

**Code:**
```solidity
function processBid(
    AuctionId auctionId,
    uint256[] calldata demands,
    uint256 maxStakeAmount,
    AuctionTypes.AuctionInfo storage auctionInfo,
    mapping(AssetId => AuctionTypes.AssetInfo) storage assetInfo,
    ClockPhaseState storage clockState
) internal {
    address bidder = msg.sender;
    // ... validations ...
    
    clockState.bids[bidder] = demands;              // Line 61: Updates mapping (overwrites)
    clockState.activeBidders.push(bidder);          // Line 62: ALWAYS PUSHES - NO DEDUP!
    
    emit IErrorsAndEvents.BidSubmitted(auctionId, bidder, requiredAdditionalStake, auctionInfo.currentRound);
}
```

**Problem:**
- Same bidder can submit multiple bids in the **same clock round**
- Each submission:
  - Updates the mapping `clockState.bids[bidder]` (overwrites previous bid)
  - **ALSO pushes bidder to activeBidders array** (no check for duplicates)
- Result: activeBidders array contains **same address multiple times**

**Attack Scenario:**
```solidity
// Round 1, bidder1 submits 3 times:
bidder1.submitBid(auctionId, [100, 200], maxStake);  
// activeBidders = [bidder1]
// bids[bidder1] = [100, 200]

bidder1.submitBid(auctionId, [150, 250], maxStake);  
// activeBidders = [bidder1, bidder1]
// bids[bidder1] = [150, 250] (overwrites previous)

bidder1.submitBid(auctionId, [200, 300], maxStake);  
// activeBidders = [bidder1, bidder1, bidder1]
// bids[bidder1] = [200, 300] (overwrites previous)

// When processClockRound runs:
// Inner loop processes activeBidders = [bidder1, bidder1, bidder1]
// Line 86: totalDemands[i] += clockState.bids[bidder1][i]
// Asset 0 demand: 200 + 200 + 200 = 600
// Asset 1 demand: 300 + 300 + 300 = 900
// Should be: Asset 0 = 200, Asset 1 = 300
// ACTUAL DEMAND COUNTED 3X!
```

**Impact on Price Discovery:**
- Artificially inflated total demand
- Causes false excess demand conditions
- Triggers unnecessary price increases
- Distorts market signals

**Severity:** **HIGH** — logic bug that corrupts auction state

---

### PROBLEM 3: Linear Search in removeBidder() — Inefficient Dropout Operation ⚠️ **MEDIUM**

**Location:** `src/base/CPABaseClock.sol:64-72`

**Code:**
```solidity
function removeBidder(AuctionId auctionId, address bidder) internal {
    address[] storage activeBiddersInThisAuction = _clock[auctionId].activeBidders;
    for (uint256 i = 0; i < activeBiddersInThisAuction.length; i++) {  // Linear search: O(m)
        if (activeBiddersInThisAuction[i] == bidder) {
            activeBiddersInThisAuction[i] = address(0);
            break;
        }
    }
}
```

**Problem:**
- Called from `dropout()` (ClockBidderFacet.sol:42)
- Performs full linear scan of activeBidders array to find matching address
- Gas cost: O(m) where m = number of active bidders
- Worst case: bidder is last in array = full scan

**Gas Cost Analysis:**
```
Cost per iteration: SLOAD + comparison + potential write = ~800 gas
Examples:
- 100 bidders: 50 iterations average = 40k gas (acceptable)
- 500 bidders: 250 iterations average = 200k gas (expensive)
- 1,000 bidders: 500 iterations average = 400k gas (very expensive)
```

**Related Issue:** If bidder appears multiple times in array (Problem #2), removal only finds and zeros first occurrence, leaving duplicates.

**Severity:** **MEDIUM** — inefficient but not blocking

---

### PROBLEM 4: address(0) Placeholder Pattern — Dead Slots Accumulate ⚠️ **MEDIUM**

**Location:** `src/base/CPABaseClock.sol:68`, `src/libraries/CPAClockPhase.sol:83-89`

**Code:**
```solidity
// In removeBidder:
activeBiddersInThisAuction[i] = address(0);  // Just sets to null, doesn't remove

// In processClockRound:
for (uint256 j = 0; j < currentActiveBidders.length; ) {
    address bidder = currentActiveBidders[j];
    if (bidder != address(0)) {  // Skip nullified entries
        totalDemands[i] += clockState.bids[bidder][i];
    }
    unchecked { ++j; }
}
```

**Problem:**
- When bidder drops out, slot is set to `address(0)` but **array is not shrunk**
- activeBidders array keeps growing with dead slots
- Wasted iterations in processClockRound for each dead address(0)
- Array only cleaned when explicitly deleted (line 105: `delete clockState.activeBidders` at end of round)

**Scenario:**
```
Round 1: 100 bidders submit → activeBidders.length = 100

50 bidders dropout:
- activeBidders = [addr1, addr2, ..., addr50, 0x0, 0x0, ..., 0x0]  (50 zeros)
- activeBidders.length still = 100

Round 2: All 50 remaining bidders submit again:
- New bidders added: activeBidders.length = 150 (50 previous + 50 new + 50 zeros)
- processClockRound must iterate 150 times to find 50 valid bidders
- Overhead: 50 wasted iterations per asset

Example with 100 assets:
- 50 bidders × 100 assets = 5,000 useful iterations
- 50 zeros × 100 assets = 5,000 wasted iterations
- Total: 10,000 iterations instead of 5,000
```

**Severity:** **MEDIUM** — compounds with Problem #1

---

### PROBLEM 5: Activity Rule Validation Bypassed on First Bid ⚠️ **MEDIUM**

**Location:** `src/libraries/CPAClockPhase.sol:203-214`

**Code:**
```solidity
function _validateActivityRule(
    uint256[] calldata demands,
    uint256[] memory previousDemands,
    bool[] memory changedPrices
) private pure {
    if (previousDemands.length == 0) return;  // EARLY EXIT - No validation!
    
    for (uint256 i = 0; i < changedPrices.length; i++) {
        if (changedPrices[i] && demands[i] > previousDemands[i]) {
            revert IErrorsAndEvents.ActivityRuleViolation();
        }
    }
}
```

**Problem:**
- Activity rule is meant to prevent demand increase on price-increased assets
- **First bid from any bidder is not validated** (previousDemands.length == 0)
- Rule only applies starting from bidder's second bid onward

**Scenario:**
```
Round 1:
- Asset1: price = 100
- Bidder1 submits first bid: [0, 0] (zero bid) → accepted, no validation
- Asset1 price increases (undersold during round?)
- Bidder1 submits second bid: [1000, 0] → validation would apply now
- BUT: due to Problem #2, activeBidders = [bidder1, bidder1]

Effect: Bidder can submit large demand on price-changed asset in first bid,
before activity rule restriction applies
```

**Combined with Problem #2:**
Bidder can submit multiple "first bids" by calling submitBid repeatedly, bypassing activity rule each time.

**Severity:** **MEDIUM** — allows circumvention of activity rule

---

### PROBLEM 6: changedPrices State Persists Across Rounds — Stale Validation Context ⚠️ **MEDIUM-HIGH**

**Location:** `src/libraries/CPAClockPhase.sol:34` (read), `97-100` (write)

**Code:**
```solidity
// In processBid (called during bidding):
_validateActivityRule(demands, clockState.bids[bidder], auctionInfo.changedPrices);

// In processClockRound (called at round end):
if (asset.excessDemand > 0) {
    asset.lastOversoldPrice = asset.currentPrice;
    asset.currentPrice += asset.config.priceIncrement;
    auctionInfo.changedPrices[i] = true;  // Updated once per round
} else {
    auctionInfo.changedPrices[i] = false;
}
```

**Problem:**
- `changedPrices` array is updated during round processing
- But it's **used during bid validation in the next round**
- Between end of Round N and start of Round N+1, `changedPrices` still contains prices from Round N
- When bidders submit in Round N+1, validation uses stale `changedPrices` from Round N

**Timeline:**
```
End of Round 1:
- processClockRound updates changedPrices[0] = true (asset had excess demand)
- Clock round closes

Start of Round 2:
- Bidders submit bids
- _validateActivityRule checks changedPrices[0] = true (from Round 1!)
- But this is now Round 2, asset prices have moved
- Activity rule validation is happening in WRONG round's context
```

**No evidence that changedPrices is cleared between rounds** — it persists in auctionInfo.

**Severity:** **MEDIUM-HIGH** — validation logic applied in wrong temporal context

---

### PROBLEM 7: No Upper Bound on Active Bidders Array ⚠️ **HIGH**

**Location:** `src/base/CPAStorage.sol:17`, `src/libraries/CPAClockPhase.sol:62`

**Data Structure:**
```solidity
struct ClockPhaseState {
    // ...
    address[] activeBidders;  // Unbounded dynamic array
    // ...
}
```

**Problem:**
- No `require` statement limiting array size
- No `MAX_BIDDERS` constant in config
- Array can grow indefinitely with each bidder submission
- Combined with Problem #1 (O(n×m) loop), creates quadratic blowup

**Scaling Analysis:**
```
activeB idders.length = m (bidders)
processClockRound cost = n * m * 2150 gas

Block limit = 30M gas
n=50 assets: 50 * m * 2150 ≤ 30M
             m ≤ 279 bidders (safe limit)

n=100 assets: 100 * m * 2150 ≤ 30M
              m ≤ 139 bidders (safe limit)

n=200 assets: 200 * m * 2150 ≤ 30M
              m ≤ 70 bidders (very restrictive)
```

**No mechanism to enforce limits** — auction can accept unlimited bidders until transaction fails.

**Severity:** **HIGH** — enables resource exhaustion

---

### PROBLEM 8: Full Array Iteration with No Early Termination ⚠️ **MEDIUM**

**Location:** `src/libraries/CPAClockPhase.sol:80-103`

**Code:**
```solidity
for (uint256 i = 0; i < numAssets; ) {
    // ... for each asset ...
    for (uint256 j = 0; j < currentActiveBidders.length; ) {
        address bidder = currentActiveBidders[j];
        if (bidder != address(0)) {
            totalDemands[i] += clockState.bids[bidder][i];  // Must process every bidder
        }
        unchecked { ++j; }
    }
    // ... price update ...
}

delete clockState.activeBidders;  // Complete reset after use
```

**Problem:**
- **No early termination condition** — must iterate all m bidders for all n assets
- No aggregation optimization
- No batching or partial processing
- Array is **completely deleted at end of round** (line 105), so must rebuild in next round
- High redundancy: same bidder processed for every asset

**Severity:** **MEDIUM** — inefficient but necessary for correctness

---

### PROBLEM 9: Missing Array Length Validations ⚠️ **MEDIUM**

**Location:** `src/libraries/CPAClockPhase.sol:32`

**Code:**
```solidity
function processBid(...) internal {
    if (demands.length != auctionInfo.assets.length) revert IErrorsAndEvents.InvalidBidsLength();
    _validateActivityRule(demands, clockState.bids[bidder], auctionInfo.changedPrices);
    // ...
}
```

**Problem:**
- Validates `demands.length == auctionInfo.assets.length`
- Does NOT validate:
  - `auctionInfo.assets.length > 0` (could be zero-asset auction)
  - `changedPrices.length == auctionInfo.assets.length` (implicit assumption)
  - `demands[i] >= 0` (zero demands allowed but unclear if intended)

**In processClockRound (line 209):**
```solidity
for (uint256 i = 0; i < changedPrices.length; i++) {
    // Assumes changedPrices.length == numAssets
}
```

If `changedPrices.length != auctionInfo.assets.length`, array bounds issues possible.

**Severity:** **MEDIUM** — potential for array misalignment bugs

---

### PROBLEM 10: shouldEndClockPhase() Also Has O(n) Operations ⚠️ **MEDIUM**

**Location:** `src/libraries/CPAClockPhase.sol:112-146`

**Code:**
```solidity
function shouldEndClockPhase(...) internal returns (bool) {
    // 1. No excess demand on any asset
    bool hasExcessDemand = false;
    for (uint256 i = 0; i < auctionInfo.assets.length; ) {  // O(n) loop
        AssetId assetId = AssetIdLibrary.createId(auctionId, auctionInfo.assets[i].assetToken);
        if (assetInfo[assetId].excessDemand > 0) {
            hasExcessDemand = true;
            break;
        }
        unchecked { ++i; }
    }
    if (!hasExcessDemand) return true;

    // ... max rounds check ...

    // 3. Revenue EMA improvement < 0.5%
    uint256 revenue = CPAComputationLibrary.calculateBidValueWithMemoryDemands(  // Also O(n)!
        totalDemands, auctionInfo.commonNumeraire, auctionInfo.assets, auctionId, assetInfo
    );
    // ...
}
```

**Problem:**
- Loop at lines 120-127: iterates all assets (O(n))
- Called every `finalizeClockRound` (ClockFinalizeRoundFacet.sol:29)
- `calculateBidValueWithMemoryDemands` call (line 135) also contains O(n) loop
- Combined: **O(n) + O(n) = O(n)** per round finalization
- Early break on first positive excess demand helps, but worst case is still O(n)

**Severity:** **MEDIUM** — adds O(n) cost to round finalization

---

### PROBLEM 11: Data Redundancy Mirrors Setup Phase ⚠️ **LOW**

**Location:** `src/types/AuctionTypes.sol:98-111`, referenced throughout Clock phase

**Problem:**
- `auctionInfo.config` and `auctionInfo.assets` both store the same assets
- Same pattern as identified in Setup phase audit
- Makes unclear which is source of truth
- Potential for sync issues if one is modified without other

**Severity:** **LOW** — design issue, not a blocking problem

---

### PROBLEM 12: Misleading Event Emission — Counts Include Dead Slots ⚠️ **MEDIUM**

**Location:** `src/facets/ClockEndRoundFacet.sol:25`, 32

**Code:**
```solidity
function processClockRoundStep(AuctionId auctionId) external ... {
    require(!_clock[auctionId].roundPendingFinalize, "Round already processed - finalize first");
    uint256 activeBidderCount = _clock[auctionId].activeBidders.length;  // Line 25
    CPAClockPhase.setClockOpen(auctionId, 1, auctionInfo);
    uint256[] memory totalDemands = CPAClockPhase.processClockRound(
        auctionId, auctionInfo[auctionId], assetInfo, _clock[auctionId]
    );
    // ...
    emit ClockRoundClosed(auctionId, auctionInfo[auctionId].currentRound, activeBidderCount);  // Line 32
}
```

**Problem:**
- `activeBidderCount` captured BEFORE round processing
- Count includes **address(0) slots from previous dropouts** (Problem #4)
- Count includes **duplicate bidder addresses** (Problem #2)
- Event emitted with inflated count
- Off-chain listeners see incorrect bidder count for round

**Severity:** **MEDIUM** — misleading event data, not a critical bug

---

### PROBLEM 13: No Gas Limit Protection for Round Processing 🔴 **HIGH**

**Location:** `src/libraries/CPAClockPhase.sol:70-107`

**Problem:**
- `processClockRound()` must complete in single transaction
- No mechanism to limit or check gas consumption beforehand
- If n×m is too large, transaction **will exceed block gas limit**
- Transaction fails partway through, state becomes inconsistent
- No fallback mechanism or partial processing capability

**Failure Mode:**
```
Attempt: process 100 assets × 1000 bidders = 100k iterations
Required gas: 215M gas
Block limit: 30M gas
Result: Transaction reverts, state inconsistent
Retry: Attempt again, same failure
Outcome: Auction permanently stuck
```

**Recovery Nightmare:**
- If `roundPendingFinalize` was set during partial execution (implementation dependent), state is corrupted
- Cannot skip to next round without processing
- Cannot roll back manually
- Entire auction stuck in Clock phase

**Severity:** **HIGH** — can cause permanent auction freeze

---

## Summary Table

| Problem | Location | Severity | Type | Impact |
|---------|----------|----------|------|--------|
| **1. O(n×m) nested loop** | CPAClockPhase.sol:80-103 | 🔴 CRITICAL | Gas | Exceeds block limit at realistic sizes |
| **2. Duplicate bidder entries** | CPAClockPhase.sol:62 | 🔴 HIGH | Logic | Demand overcounting, corrupted prices |
| **3. Linear search removeBidder** | CPABaseClock.sol:66 | ⚠️ MEDIUM | Gas | O(m) per dropout, expensive |
| **4. address(0) placeholder pattern** | CPABaseClock.sol:68, CPAClockPhase.sol:85 | ⚠️ MEDIUM | Gas | Dead slots accumulate, wasted iterations |
| **5. Activity rule bypass first bid** | CPAClockPhase.sol:208 | ⚠️ MEDIUM | Logic | Can spike demand without validation |
| **6. Stale changedPrices across rounds** | CPAClockPhase.sol:34, 97-100 | ⚠️ MEDIUM-HIGH | Logic | Wrong round validation context |
| **7. No bidder count limits** | CPAClockPhase.sol:62 | 🔴 HIGH | Design | Unbounded array, resource exhaustion |
| **8. Full array iteration, no early exit** | CPAClockPhase.sol:80-103 | ⚠️ MEDIUM | Gas | Inefficient, no optimization |
| **9. Missing length validations** | CPAClockPhase.sol:32 | ⚠️ MEDIUM | Logic | Potential array bounds issues |
| **10. shouldEndClockPhase O(n)** | CPAClockPhase.sol:120-135 | ⚠️ MEDIUM | Gas | Additional O(n) per round end |
| **11. Redundant assets storage** | AuctionTypes.sol:98-111 | ⚠️ LOW | Design | Data duplication, clarity |
| **12. Misleading event counts** | ClockEndRoundFacet.sol:25, 32 | ⚠️ MEDIUM | Logic | Inflated bidder count in events |
| **13. No gas limit protection** | CPAClockPhase.sol:70-107 | 🔴 HIGH | Design | Can cause permanent auction freeze |

---

## Severity Breakdown

### 🔴 CRITICAL (1 issue)
- Problem 1: O(n×m) nested loop blocks realistic auction sizes

### 🔴 HIGH (3 issues)
- Problem 2: Duplicate bidder entries corrupt demand calculations
- Problem 7: No bidder limits enable resource exhaustion
- Problem 13: No gas protection can freeze auction permanently

### ⚠️ MEDIUM-HIGH (1 issue)
- Problem 6: Stale validation context

### ⚠️ MEDIUM (8 issues)
- Problems 3, 4, 5, 8, 9, 10, 12: Performance, logic, and design issues

### ⚠️ LOW (1 issue)
- Problem 11: Design clarity issue

---

## Related Issues from Setup Phase

The Clock phase exhibits similar structural problems:
- **Similar to Setup Problem #2 (No Asset Bounds):** Problem 7 here is the bidder equivalent
- **Similar to Setup Problem #6 (Deposit Overwrite):** Problem 2 here duplicates instead of overwrites, with similar logic corruption
- **Similar to Setup Problem #0 (O(n²) bubble sort):** Problem 1 is O(n×m), a different form of quadratic scaling
- **Similar to Setup Problem #5 (O(n) confirmation):** Problem 10 is O(n) for phase-end checks

---

## Worst-Case Scenarios

### Scenario 1: Realistic Auction Becomes Unprocessable
```
Auction config: 50 assets, accepts unlimited bidders
After bidding: 500 active bidders
processClockRound cost: 50 * 500 * 2,150 = 53.75M gas
Block limit: 30M gas
Result: CANNOT PROCESS ROUND, auction frozen
```

### Scenario 2: Demand Manipulation via Duplicate Bidding
```
Bidder wants to boost demand for Asset1
Submits 10 bids in same round with increasing demand
activeBidders = [bidder, bidder, bidder, ..., bidder] (10x)
processClockRound counts demand 10x
Price increases due to artificial demand
Bidder exits with profits from manipulated price
```

### Scenario 3: Permanent Dropout Starvation
```
100 bidders join auction
80 bidders dropout in round 5
activeBidders = [0x0, 0x0, ..., 0x0, bidder1, ..., bidder20] (80 zeros)
80 new bidders join in round 6
activeBidders = [0x0, ..., 0x0, bidder1, ..., bidder20, new1, ..., new80] (160 total)
processClockRound: 160 iterations per asset instead of 100
Each round gets slower as dead slots accumulate
Eventually exceeds gas limit
```

---

## Notes on Problems Not Proposed for Immediate Solution

These problems are interconnected:
- Problem 1 (O(n×m)) is the root cause limiting auction size
- Problems 2, 4, 7 exacerbate Problem 1
- Problems 5, 6 are logic validation issues that could cause incorrect price discovery
- Problems 3, 8, 9, 10 are performance issues that compound with Problem 1
- Problem 13 is the failure mode when Problem 1 exceeds gas limits

Addressing Problem 1 requires rethinking the demand aggregation architecture. Problems 2, 4, 7 should be fixed as prerequisite guards.

---

## Files Involved

- `src/libraries/CPAClockPhase.sol` — Core logic (Problems 1, 2, 5, 6, 8, 9, 10)
- `src/base/CPABaseClock.sol` — Bidder management (Problems 3, 4)
- `src/facets/ClockBidFacet.sol` — Bid submission
- `src/facets/ClockBidderFacet.sol` — Dropout (Problem 3)
- `src/facets/ClockEndRoundFacet.sol` — Round processing (Problems 1, 12)
- `src/facets/ClockFinalizeRoundFacet.sol` — Phase transition (Problem 10)
- `src/types/AuctionTypes.sol` — Data structures (Problem 11)
- `src/base/CPAStorage.sol` — Storage definition (Problem 7)
