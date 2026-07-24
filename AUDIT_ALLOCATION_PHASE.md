# Rok CPA Protocol: Allocation Phase Audit

**Phase**: Allocation (Allocator Competition)  
**Files Audited**: 
- `src/libraries/CPAAllocationPhase.sol`
- `src/facets/AllocationSubmitFacet.sol`
- `src/facets/AllocationPhaseFacet.sol` (actually AllocationTransitionFacet)
- `src/base/CPAStorage.sol` (AllocationPhaseState struct)
- `test/CPAAllocationPhase.t.sol`

**Date**: 2026-05-21  
**Summary**: Found 10 distinct problems, including a critical validation gap, unused data fields, and unbounded scaling issues.

---

## Problems Identified

### Problem 1: Allocation AuctionId Not Validated (HIGH)
**Severity**: HIGH  
**Location**: `src/facets/AllocationSubmitFacet.sol:18-31` (submitAllocation function)  
**Description**:
The `submitAllocation` function takes `auctionId` as a parameter but the `allocationData` struct also contains an `auctionId` field. There is no validation that these match:

```solidity
function submitAllocation(
    AuctionId auctionId,              // Parameter auctionId
    AuctionTypes.Allocation calldata allocationData  // Has allocationData.auctionId
)
{
    // ... NO CHECK that auctionId == allocationData.auctionId ...
    
    CPAAllocationPhase.submitAllocation(
        allocationData,                   // Passes allocation data (wrong auctionId!)
        _alloc[auctionId],                // Uses parameter auctionId for state access
        auctionInfo[auctionId],           // Uses parameter auctionId
        assetInfo,                         // Global mapping, used with auctionId from allocationData
        _proxy[auctionId]                 // Uses parameter auctionId
    );
}
```

Inside the library function (_scoreAllocation, line 71-72):
```solidity
AssetId assetId = AssetIdLibrary.createId(auctionId, assets[i].assetToken);
// Looks up assetInfo using the auctionId extracted from allocationData!
uint256 price = assetInfo[assetId].currentPrice;
```

An attacker could submit:
```solidity
submitAllocation(
    auctionId = 123,                  // Target auction
    allocationData = {
        auctionId: 456,                // Wrong auction!
        allocator: msg.sender,
        bundleIds: [...],
        ...
    }
)
```

**Impact**:
- Creates AssetIds with wrong auctionId prefix (456 instead of 123)
- These AssetIds likely don't exist in assetInfo mapping
- Lookups return default/zero values: `price = 0`
- Scoring uses `price = 0`, causing `totalValue = 0` regardless of bundle quantities
- An allocation with value=0 could become the top allocation
- Allocator's allocation could be invalid without them knowing
- Could cause unexpected behavior if assetInfo somehow has keys from allocationData.auctionId (unlikely but possible)

**Real-World Scenario**:
```solidity
// Auction 123 has assets with prices set
// Auction 456 might not exist or have different assets
// Allocator submits allocation for 123, but provides auctionId=456 in data
// Scoring computes price for auctionId=456 assets → price=0
// Allocation value becomes 0, but might still be selected if no other allocations exist
```

### Problem 2: Allocation totalValue Field Is Ignored (MEDIUM)
**Severity**: MEDIUM  
**Location**: `src/libraries/CPAAllocationPhase.sol:24-30` (_scoreAllocation and submitAllocation)  
**Description**:
Allocators submit an allocation with a `totalValue` field (line 155 in test shows: `totalValue: 1800 * 10**18`), but this value is completely ignored:

```solidity
// Allocator provides this:
AuctionTypes.Allocation memory allocationData = {
    ...
    totalValue: 1800 * 10**18,   // Supplied by allocator
    ...
}

// But the library recomputes it:
(uint256 score, uint256 totalValue) = _scoreAllocation(...);
// Line 30: allocState.topAllocation.totalValue = totalValue;  // Computed, not supplied!
```

The supplied `allocationData.totalValue` is never used or validated. Instead, scoring recomputes `totalValue` from bundle quantities and current prices (line 69-81):
```solidity
uint256 totalValue = 0;
for (uint256 i = 0; i < assets.length; ) {
    // ...
    totalValue += (quantities[i] * price) / (10 ** assetDecimals);
    // ...
}
return (totalValue, totalValue);
```

**Impact**:
- Allocator's estimate of value is discarded
- No ability to validate allocator's computation matches actual cost
- Unused storage overhead
- Creates semantic ambiguity: why supply a value that's never used?
- No mechanism to detect scoring computation errors

**Example**:
```solidity
// Allocator claims: "My allocation is worth 1800"
// But actually: quantities * prices = 1500
// The mismatch is never detected; code just uses 1500
```

### Problem 3: Allocation Timestamp Field Is Unused (LOW-MEDIUM)
**Severity**: LOW-MEDIUM  
**Location**: `src/types/AuctionTypes.sol:48` (Allocation struct)  
**Description**:
Each allocation includes a timestamp field:
```solidity
struct Allocation {
    AuctionId auctionId;
    address allocator;
    BundleId[] bundleIds;
    uint256 totalValue;
    uint256 timestamp;              // Never used
}
```

This timestamp is stored in `TopAllocation.allocation.timestamp` but never validated or used. Unlike bundles where timestamp might serve an ordering purpose, allocations have no ordering requirement, so the timestamp serves no function.

**Impact**:
- Unused storage overhead
- Creates false impression that submission time is tracked/important
- If future code relies on this field without validation, could introduce bugs

### Problem 4: No Upper Bound on Bundle Count Per Allocation (MEDIUM)
**Severity**: MEDIUM  
**Location**: `src/libraries/CPAAllocationPhase.sol:51-67` (_scoreAllocation loop)  
**Description**:
Allocations can include an unbounded number of bundles:
```solidity
for (uint256 i = 0; i < allocationData.bundleIds.length; ) {  // No bound!
    BundleId bundleId = allocationData.bundleIds[i];
    
    if (auctionBundles[bundleId].commitHash == bytes32(0))
        revert IErrorsAndEvents.InvalidBundle(auctionId, bundleId);
    if (_checkIfDuplicateAllocation(auctionBundles[bundleId].commitHash, existingCommitHashes, i))
        revert IErrorsAndEvents.DuplicateAllocation(auctionId, auctionBundles[bundleId].commitHash);
    
    AuctionTypes.Bundle memory bundle = auctionBundles[bundleId];
    for (uint256 j = 0; j < bundle.quantities.length; ) {
        quantities[j] += bundle.quantities[j];
        unchecked { ++j; }
    }
    ...
}
```

An allocator could submit an allocation with 10,000 bundles, forcing O(10,000 × assets) computation.

**Impact**:
- Unbounded gas cost for allocation scoring
- Each allocation submission with n bundles uses O(n × assets) gas
- Could cause transactions to exceed block gas limit
- Allocators could be griefed if they submit large allocations (OOG revert)
- No DoS protection

**Example**:
```solidity
// 50 assets in auction
// Allocator submits allocation with 10,000 bundles
// Scoring loops: 10,000 × 50 = 500,000 iterations
// Gas cost: ~5-10M gas just for the scoring loop
```

### Problem 5: O(n²) Duplicate Bundle Check in Scoring (MEDIUM)
**Severity**: MEDIUM  
**Location**: `src/libraries/CPAAllocationPhase.sol:56-57` and `86-95` (_checkIfDuplicateAllocation)  
**Description**:
The duplicate check inside scoring is O(n²):
```solidity
for (uint256 i = 0; i < allocationData.bundleIds.length; ) {
    // ...
    if (_checkIfDuplicateAllocation(auctionBundles[bundleId].commitHash, existingCommitHashes, i))
        revert IErrorsAndEvents.DuplicateAllocation(...);
    // ...
}

function _checkIfDuplicateAllocation(
    bytes32 commitHash,
    bytes32[] memory existingCommitHashes,
    uint256 index
) internal pure returns (bool) {
    for (uint256 i = 0; i < index; i++) {  // O(index) = O(i)
        if (existingCommitHashes[i] == commitHash) return true;
    }
    return false;  // For n bundles, total: 1+2+3+...+n = n²/2
}
```

For an allocation with n bundles, total comparisons: 1+2+3+...+n = O(n²).

**Impact**:
- Quadratic scaling with bundle count
- For 100 bundles: 5,000 comparisons
- For 1,000 bundles: 500,000 comparisons
- Combined with bundle loop, total: O(n² × assets)
- Could easily exceed gas limits for moderate bundle counts

### Problem 6: Score Ties Broken Arbitrarily (LOW)
**Severity**: LOW  
**Location**: `src/libraries/CPAAllocationPhase.sol:27` (submitAllocation)  
**Description**:
When two allocations have the same score, the comparison uses `>` instead of `>=`:
```solidity
if (score > allocState.topAllocation.score) {  // Strict greater than
    allocState.topAllocation.allocation = allocationData;
    allocState.topAllocation.score = score;
    allocState.topAllocation.totalValue = totalValue;
}
```

This means:
- If allocation A has score=1000 and is selected as top
- If allocation B also has score=1000, it is NOT selected (1000 is not > 1000)
- First allocation wins on a tie

**Impact**:
- Deterministic but potentially unfair tiebreaking
- Allocators submitting later with same score cannot replace earlier allocations
- No tie-breaking by allocator reputation, stake, or submission order
- Could be seen as favoring early submissions

**Note**: This may be intentional behavior, but it's worth noting that ties have no explicit handling or documentation.

### Problem 7: Bundle Quantity Validation Relies on Proxy Phase Checks (MEDIUM)
**Severity**: MEDIUM  
**Location**: `src/libraries/CPAAllocationPhase.sol:60-63`  
**Description**:
The scoring loop assumes bundles have exactly `assets.length` quantities:
```solidity
uint256[] memory quantities = new uint256[](assets.length);  // Line 48

for (uint256 i = 0; i < allocationData.bundleIds.length; ) {
    // ...
    AuctionTypes.Bundle memory bundle = auctionBundles[bundleId];
    for (uint256 j = 0; j < bundle.quantities.length; ) {  // Loop uses bundle.quantities.length!
        quantities[j] += bundle.quantities[j];
        unchecked { ++j; }
    }
    // ...
}
```

There is no explicit check that `bundle.quantities.length == assets.length`. The code relies on proxy phase validation (ProxyPhase.sol:74) which checks `bundleData.quantities.length == numItems`. However:

1. This is an implicit cross-phase dependency
2. No explicit re-validation in allocation phase
3. If this assumption is violated, array access is undefined behavior

**Impact**:
- Implicit trust in proxy phase validation
- No defense-in-depth
- Makes code harder to reason about
- Could cause silent bugs if proxy validation is bypassed

### Problem 8: Empty Allocations Are Rejected But No Reason Provided (LOW)
**Severity**: LOW  
**Location**: `src/libraries/CPAAllocationPhase.sol:45`  
**Description**:
Empty allocations are rejected with a revert:
```solidity
if (allocationData.bundleIds.length == 0) revert IErrorsAndEvents.EmptyAllocation(auctionId);
```

While this is correct, there's no way for allocators to recover from this error gracefully. The error doesn't provide guidance on minimum bundle count or expected structure.

**Impact**:
- Allocators who submit empty bundles get a revert with no helpful message
- Not a critical issue, but UX concern

### Problem 9: No Validation of Allocator Address in Library Function (MEDIUM)
**Severity**: MEDIUM  
**Location**: `src/libraries/CPAAllocationPhase.sol:15-36` (submitAllocation)  
**Description**:
The library function `submitAllocation` accepts an allocator address from the allocation data but doesn't validate it's the actual caller:

```solidity
function submitAllocation(
    AuctionTypes.Allocation calldata allocationData,  // Contains allocator address
    // ...
) internal {
    // No check that msg.sender == allocationData.allocator
    // Only validated at facet level (AllocationSubmitFacet.sol:27)
}
```

The validation exists at the facet level, but the library function itself doesn't enforce it. If the library is called from a different facet or entry point without this check, an allocator could submit allocations on behalf of another allocator.

**Impact**:
- Reliance on facet-level validation is fragile
- Defense-in-depth principle violated
- If library is reused elsewhere, could introduce bugs
- Other allocator addresses could be impersonated

### Problem 10: Bundle Duplicate Check Only Validates commit Hashes, Not BundleIds (LOW-MEDIUM)
**Severity**: LOW-MEDIUM  
**Location**: `src/libraries/CPAAllocationPhase.sol:56-57`  
**Description**:
The duplicate check validates that no two bundles have the same `commitHash` (from the same proxy):
```solidity
if (_checkIfDuplicateAllocation(auctionBundles[bundleId].commitHash, existingCommitHashes, i))
    revert IErrorsAndEvents.DuplicateAllocation(auctionId, auctionBundles[bundleId].commitHash);
```

However, two bundles could have the same commitHash but different BundleIds if they have different quantities. The check only prevents including multiple bundles from the same proxy in one allocation, which is the intended behavior. But the check is by commitHash, not by BundleId.

**Example**:
```solidity
// Proxy1 submits two bundles:
// Bundle A: commitHash=H1, quantities=[100, 50]
// Bundle B: commitHash=H1, quantities=[200, 75]  // Different quantities!

// An allocator can include:
// - Bundle A (commitHash=H1) ✓
// - Bundle B (commitHash=H1) ✗ Duplicate commit hash rejected

// This is correct behavior; the note is just documenting the mechanism
```

This is actually the correct intended behavior (no multiple bundles from same proxy per allocation), so it's more of a design documentation note than a bug.

---

## Summary Table

| # | Problem | Severity | Location | Issue Type |
|---|---------|----------|----------|-----------|
| 1 | AuctionId not validated | HIGH | AllocationSubmitFacet:18-31 | Validation gap |
| 2 | TotalValue field ignored | MEDIUM | AllocationPhase:24-30 | Unused field |
| 3 | Timestamp field unused | LOW-MEDIUM | AuctionTypes:48 | Storage waste |
| 4 | No bundle count limit | MEDIUM | AllocationPhase:51-67 | Unbounded scaling |
| 5 | O(n²) duplicate check | MEDIUM | AllocationPhase:86-95 | Gas inefficiency |
| 6 | Score ties arbitrary | LOW | AllocationPhase:27 | Design choice |
| 7 | Quantity validation cross-phase | MEDIUM | AllocationPhase:60-63 | Implicit dependency |
| 8 | Empty allocation no reason | LOW | AllocationPhase:45 | UX issue |
| 9 | No allocator validation in lib | MEDIUM | AllocationPhase:15-36 | Defense-in-depth |
| 10 | Duplicate check by commitHash | LOW-MEDIUM | AllocationPhase:56-57 | Design note |

**Critical findings**: None  
**High findings**: 1 (Problem 1 - AuctionId validation)  
**Medium findings**: 6  
**Low findings**: 3

---

## Architectural Observations

### Allocation Phase Role
The Allocation phase serves as the competition layer:
1. Allocators receive bundles submitted by proxies in the proxy phase
2. Each allocator independently proposes a combination of bundles
3. The highest-scoring allocation is selected as the winner
4. Winner's bundles determine what assets the bidders receive

### Scoring Mechanics
- Score = `sum(quantity[i] * price[i])` for all assets in the allocation
- Price is locked at the end of the clock phase
- Higher score always wins (except ties, which favor first submission)
- No allocator reward or reputation mechanism in scoring

### Critical Data Flow
1. Allocation references BundleIds (not bundles themselves)
2. Bundles looked up from ProxyPhaseState during scoring
3. Winner's BundleIds → commitHashes mapped in winningBundleIds
4. Settlement phase uses winning bundles to transfer assets

### Trust Model
- Allocators are assumed to submit valid bundle combinations
- No validation of allocator's computation accuracy
- Bundle values and allocator value estimates are not cross-checked
- Only bundle existence and non-duplication is validated

### Integration Points
- **From Proxy**: Bundles and their bundle IDs
- **To Settlement**: Winning allocation's bundle IDs mapped to commitHashes
- **Phase Transition**: Requires at least one allocation submission

### Design Inconsistencies
1. Two AuctionId fields with no validation of consistency (Problem 1)
2. Allocator supplies totalValue but it's discarded (Problem 2)
3. Timestamp field stored but never used (Problem 3)
4. No allocation size bounds despite gas implications (Problem 4)

---

## Potential Real-World Impact Scenarios

### Scenario 1: Wrong Auction Scoring (HIGH)
Allocator A submits allocation for auctionId=123, but puts auctionId=456 in calldata. Scoring computes assets with IDs from auction 456 (which don't exist). Price lookups return 0. Allocation scores 0 value. If no other allocations exist, this 0-value allocation wins. Settlement fails or allocates nothing.

### Scenario 2: Grief Attack via Bundle Count (MEDIUM)
Allocator submits allocation with 10,000 bundles. Transaction OOGs during scoring. Allocator's transaction fails but gas is spent. If done repeatedly, can throttle allocation phase submissions.

### Scenario 3: TotalValue Mismatch (MEDIUM)
Allocator supplies totalValue=2000 but actual quantities * prices=1500. No detection of this discrepancy. Allocator thinks their allocation is worth 2000, but it's actually 1500. Silent failure of allocator's economic assumptions.
