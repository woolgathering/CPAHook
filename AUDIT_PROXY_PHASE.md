# Rok CPA Protocol: Proxy Phase Audit

**Phase**: Proxy (Bundle Submission)  
**Files Audited**: 
- `src/libraries/CPAProxyPhase.sol`
- `src/facets/ProxyPhaseFacet.sol`
- `src/base/CPAStorage.sol` (ProxyPhaseState struct)
- `src/libraries/CPAAllocationPhase.sol` (bundle usage)
- `src/libraries/CPASettlementPhase.sol` (bundle reveal/claim)

**Date**: 2026-05-21  
**Summary**: Found 11 distinct problems ranging from validation gaps to phase-transition logic issues and inefficiencies.

---

## Problems Identified

### Problem 1: Bundle Value Field Never Validated (MEDIUM)
**Severity**: MEDIUM  
**Location**: `src/libraries/CPAProxyPhase.sol:48` (submitBundle stores bundle)  
**Description**:
The `bundle.value` field is accepted at submission time and stored without validation. No check ensures that the submitted value matches the actual cost computed as `sum(quantities[i] * currentPrice[i])`. A proxy could submit:
- A bundle with value=0 while requesting expensive assets
- A bundle with value=max(uint256) while requesting cheap assets
- A bundle with an arbitrary value completely disconnected from quantities

**Impact**: 
- Allocators see the submitted value and may make decisions based on it
- During settlement, the actual cost is recomputed from quantities and prices, not from the stored value (line 120 in CPASettlementPhase.sol)
- This creates an inconsistency between what was advertised at submission and what's actually charged at settlement
- Could mislead allocators about bundle economics

**Example Scenario**:
```solidity
// Quantities: 100 units of asset priced at $10 = $1000 cost
// But bundle submitted with value = $100
// Allocators might think this is a bargain, but settlement charges actual $1000
```

### Problem 2: Phase-End Logic Inverted When No Bundles Submitted (MEDIUM-HIGH)
**Severity**: MEDIUM-HIGH  
**Location**: `src/libraries/CPAProxyPhase.sol:18-30` (shouldProxyPhaseEnd function)  
**Description**:
The phase-end logic has counterintuitive behavior:
```solidity
function shouldProxyPhaseEnd(
    ProxyPhaseState storage proxyState,
    uint256 phaseDuration0
) internal view returns (bool) {
    uint256 startTime = proxyState.proxyPhaseStartTime;
    if (startTime == 0) return true;
    
    if (proxyState.hasBundles) {
        return block.timestamp < (startTime + phaseDuration0);  // Phase ends AFTER duration
    } else {
        return true;  // Phase ends IMMEDIATELY if no bundles!
    }
}
```

If no bundles are submitted (`hasBundles == false`), the phase ends immediately. This means:
- Allocators cannot work with an empty auction
- If bundles are submitted very early and then none others follow, the phase could be perceived as "stuck" by allocators who haven't had time to submit allocations
- The intent seems to be: "if we have bundles, wait for the full duration; if we have no bundles, cancel immediately"
- But the transition code (AllocationTransitionFacet.sol:26-28) cancels the auction if no bundles exist anyway

**Impact**:
- Allocators may not have time to submit allocations if the proxy phase ends early due to no bundle submissions
- The function is not currently called in the codebase (unused function), but if it were used in phase-end logic, it would break auction flow
- Inverts the expected phase semantics: "no activity" causes early exit rather than time-based exit

**Related Code**:
- `src/facets/AllocationTransitionFacet.sol:21-32` shows transition requires bundles exist or cancels auction

### Problem 3: No Upper Bound on Number of Bundles (MEDIUM)
**Severity**: MEDIUM  
**Location**: `src/base/CPAStorage.sol:25` (bundles mapping)  
**Description**:
Bundles are stored in an unbounded mapping:
```solidity
mapping(BundleId => AuctionTypes.Bundle) bundles;
```

There is no constant `MAX_BUNDLES` or check on bundle count. A proxy could theoretically submit millions of bundles, each consuming storage. Related issues:
1. Storage bloat: each Bundle stores quantities array (dynamic) and other fields
2. Allocation scoring iterates all bundles per allocation (O(b) per allocation where b = bundle count)
3. No defense against storage-based DoS

**Impact**:
- A malicious proxy could submit extremely many bundles to inflate storage
- Each allocation scoring operation gets slower as more bundles exist
- No gas-limit protection for allocation scoring with many bundles

**Example**:
```solidity
// Proxy submits 10,000 bundles with varying quantities
// Each allocation scoring now iterates 10,000 bundles (lines 51-67 in CPAAllocationPhase.sol)
// Gas cost scales as O(bundles * allocations)
```

### Problem 4: Bundle Quantities Not Validated Against Available Supply at Submission (MEDIUM)
**Severity**: MEDIUM  
**Location**: `src/libraries/CPAProxyPhase.sol:56-88` (_isValidBundle)  
**Description**:
Bundle quantities are validated to be non-zero, but there is no check that total quantities do not exceed the deposited supply of each asset. The validation is deferred until allocation scoring:
- Line 74 in CPAProxyPhase.sol: Only checks `quantities.length == numItems`
- Line 79: Checks `hasNonZeroDemand` (at least one quantity > 0)
- Lines 73-74 in CPAAllocationPhase.sol: Checks `quantities[i] <= assetInfo[assetId].depositAmount` during scoring

This means:
- A bundle can be submitted requesting more assets than exist
- Only when an allocation tries to use that bundle does the check fail
- Wastes computation and creates failed allocations

**Impact**:
- Allocators submit allocations using invalid bundles, which fail validation
- Allocation scoring rejects valid allocations because a bundle in the allocation is invalid
- Increases computation during allocation phase

**Example Scenario**:
```solidity
// Asset1 has 100 units deposited
// Proxy submits bundle requesting 500 units of Asset1
// This passes proxy phase validation
// Later, allocator includes this bundle → allocation scoring rejects it
// Allocator's entire allocation fails due to one bad bundle
```

### Problem 5: Bundle Value Field Unused in Allocation Scoring (MEDIUM)
**Severity**: MEDIUM  
**Location**: `src/libraries/CPAAllocationPhase.sol:76-78` (_scoreAllocation)  
**Description**:
The allocation scoring function computes total value from quantities and current prices, completely ignoring the submitted bundle.value:
```solidity
uint256 price = assetInfo[assetId].currentPrice;
uint8 assetDecimals = CurrencyDecimals.getDecimals(assets[i].assetToken);
totalValue += (quantities[i] * price) / (10 ** assetDecimals);
```

The bundle.value field is submitted by the proxy but never used. This is inconsistent with Problem 1 (value validation) and creates semantic ambiguity:
- Is bundle.value meant to be a bid price? A reserve? A hint?
- Why store it at all if it's ignored?

**Impact**:
- Confusion about bundle semantics
- Wasted storage for a field that's never read
- No ability to verify allocator's computation matches proxy's advertised value

### Problem 6: No Validation of Bundle Timestamps (LOW-MEDIUM)
**Severity**: LOW-MEDIUM  
**Location**: `src/libraries/CPAProxyPhase.sol:37-38` (Bundle stores timestamp)  
**Description**:
Each bundle stores a timestamp (`bundleData.timestamp = block.timestamp` in caller, then stored at line 48). This timestamp is never validated or used:
- No check that timestamp is current (within a window)
- No check that timestamp is within proxy phase boundaries
- No check that timestamps are monotonic

The timestamp appears to be informational only, but:
- If meant as a sequencing tool, it's not enforced
- If meant as metadata for auditing, it's unused
- Adds storage overhead

**Impact**:
- Minor storage overhead
- If the intent was to timestamp bundles for ordering, it's not enforced
- Creates false impression that submission time matters when it doesn't

### Problem 7: Commit Hash to Proxy Mapping Not Indexed (LOW)
**Severity**: LOW  
**Location**: `src/base/CPAStorage.sol:24` (commitProxy mapping)  
**Description**:
Proxies commit to bundles via:
```solidity
mapping(bytes32 => address) commitProxy;
```

There is no reverse mapping from proxy → commitHashes. If you need to find all commits from a proxy or revoke all commits from a proxy, you'd need:
- Linear search through all commitHash values in the mapping (impossible on-chain)
- Or external indexing

This is not a critical issue since commit revocation isn't a feature, but it limits future functionality.

**Impact**:
- Cannot efficiently query "all commits from proxy X"
- Cannot revoke all proxy commitments for a given proxy
- Limits future extensibility

### Problem 8: Potential Duplicate Bundle ID Creation (LOW)
**Severity**: LOW  
**Location**: `src/libraries/CPAProxyPhase.sol:39` (BundleIdLibrary.createId)  
**Description**:
Bundle ID is created as:
```solidity
bundleId = BundleIdLibrary.createId(commitHash, keccak256(abi.encode(quantities)));
```

While the hash space is large, theoretically two bundles could collide if:
1. They have the same commitHash
2. They have the same quantities array (hash collision unlikely but theoretically possible)

The duplicate check at line 84 (`proxyState.bundles[bundleId].commitHash != bytes32(0)`) would catch this collision at submission time, so it's not a runtime bug. But it means:
- A collision would silently fail with a DuplicateBundle error instead of being caught during bundle creation
- The error message wouldn't clearly indicate it's a hash collision

**Impact**:
- Low: collision detection is in place
- Very unlikely with proper hash functions
- Error handling is graceful (revert with DuplicateBundle)

### Problem 9: No Reserve Price or Minimum Value Validation (LOW)
**Severity**: LOW  
**Location**: `src/libraries/CPAProxyPhase.sol:32-54` (submitBundle)  
**Description**:
Bundles are accepted with any value, including potentially:
- value = 0 (free bundles)
- Very low values relative to quantities

There is no check against a reserve price, minimum value, or expected market value. This is more of a design choice than a bug, but it means:
- Allocators could select bundles that are economically irrational
- No protection against collusion (proxies submitting artificially cheap bundles)

**Impact**:
- Allows economically irrational bundles
- No mechanism to enforce minimum bid amounts

### Problem 10: No Explicit Validation that Allocated Bundle Quantities Were Submitted (MEDIUM)
**Severity**: MEDIUM  
**Location**: `src/libraries/CPAAllocationPhase.sol:54-55` (bundle existence check)  
**Description**:
When an allocation references a bundle, the code checks:
```solidity
if (auctionBundles[bundleId].commitHash == bytes32(0))
    revert IErrorsAndEvents.InvalidBundle(auctionId, bundleId);
```

This checks bundle exists, but there's an implicit assumption that during settlement, the loaded bundle still has valid quantities. However:
- Nothing prevents the bundle from being "modified" between allocation selection and settlement (though mappings don't support this)
- The quantities in the winning bundle are used directly without re-validating against current supply

While not a practical issue (storage mappings are immutable once written), it means:
- No explicit guarantee that winning bundle quantities match what was originally submitted
- If supply changes between phases (shouldn't happen, but no explicit guard), quantities could become invalid

**Impact**:
- Medium trust assumption
- No explicit re-validation of bundle quantities at settlement time

### Problem 11: Allocation Scoring Iterates All Bundles Per Allocation (MEDIUM)
**Severity**: MEDIUM  
**Location**: `src/libraries/CPAAllocationPhase.sol:51-67` (_scoreAllocation)  
**Description**:
For each allocation submission, the scoring function iterates through all bundles in the allocation:
```solidity
for (uint256 i = 0; i < allocationData.bundleIds.length; ) {
    BundleId bundleId = allocationData.bundleIds[i];
    
    if (auctionBundles[bundleId].commitHash == bytes32(0))
        revert IErrorsAndEvents.InvalidBundle(auctionId, bundleId);
    if (_checkIfDuplicateAllocation(...))
        revert IErrorsAndEvents.DuplicateAllocation(...);
    
    AuctionTypes.Bundle memory bundle = auctionBundles[bundleId];
    for (uint256 j = 0; j < bundle.quantities.length; ) {
        quantities[j] += bundle.quantities[j];  // Accumulate quantities
        unchecked { ++j; }
    }
    ...
}
```

Nested loop structure: O(bundles_in_allocation * assets). While the allocation size is bounded (typically 1-100 bundles), the check at line 56 (`_checkIfDuplicateAllocation`) is O(i) inefficient:
```solidity
function _checkIfDuplicateAllocation(
    bytes32 commitHash,
    bytes32[] memory existingCommitHashes,
    uint256 index
) internal pure returns (bool) {
    for (uint256 i = 0; i < index; i++) {  // Linear search
        if (existingCommitHashes[i] == commitHash) return true;
    }
    return false;
}
```

For an allocation with n bundles, this is O(n²) to check for duplicates.

**Impact**:
- Each allocation submission with 100 bundles requires O(100²) = 10,000 checks in worst case
- Not critical since allocation size is typically small, but suboptimal
- Could be O(n) with a set or bitmap

**Example**:
```solidity
// Allocator submits 100 bundles
// Duplicate check: 1 + 2 + 3 + ... + 99 = ~5,000 comparisons
// With many asset types, this adds up
```

---

## Summary Table

| # | Problem | Severity | Location | Issue Type |
|---|---------|----------|----------|-----------|
| 1 | Bundle value not validated | MEDIUM | ProxyPhase:48 | Validation gap |
| 2 | Phase-end logic inverted | MEDIUM-HIGH | ProxyPhase:18-30 | Logic flaw |
| 3 | No bundle count limit | MEDIUM | Storage:25 | DoS/Bloat |
| 4 | Quantities not validated at submit | MEDIUM | ProxyPhase:74-82 | Validation gap |
| 5 | Value field unused | MEDIUM | AllocationPhase:76-78 | Design flaw |
| 6 | Bundle timestamps unused | LOW-MEDIUM | ProxyPhase:38 | Storage waste |
| 7 | Commit→proxy not indexed | LOW | Storage:24 | Efficiency |
| 8 | Duplicate bundle ID collision | LOW | ProxyPhase:39 | Theoretical |
| 9 | No reserve price validation | LOW | ProxyPhase:32-54 | Design choice |
| 10 | Allocated bundle not re-validated | MEDIUM | AllocationPhase:54-55 | Trust assumption |
| 11 | O(n²) duplicate check | MEDIUM | AllocationPhase:86-95 | Gas efficiency |

**Critical findings**: None (Problem 2 is close but the inverted logic is unused)  
**High findings**: 1 (Problem 2)  
**Medium findings**: 8  
**Low findings**: 2

---

## Architectural Observations

### Proxy Phase Role
The Proxy phase serves as an intermediate commitment layer:
1. Proxies commit to bidder identities using commit-reveal (on-chain privacy)
2. Proxies submit bundles representing bidder demand
3. Bundle values are suggestions only; actual cost determined at settlement
4. Allocators then compose bundles into allocations to maximize total value

### Trust Model
- Proxies are assumed honest (no validation of bundle value correctness)
- Allocators are assumed honest (no validation they maximize correctly)
- Bundles are immutable once submitted (no modification between phases)

### Integration Points
- **From Clock**: Prices set during clock phase are locked and used throughout proxy→allocation→settlement
- **To Allocation**: Bundles are the input; allocators must select non-overlapping combinations
- **From Settlement**: Winning bundle's quantities are applied; value field is discarded

### Design Inconsistencies
1. Bundle.value is submitted but never validated or used (Problems 1, 5)
2. Bundle timestamps are stored but never checked (Problem 6)
3. Bundle quantities are checked late in allocation phase instead of early at submission (Problem 4)
4. Phase-end logic doesn't match semantic intent (Problem 2)
