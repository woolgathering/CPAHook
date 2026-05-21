# Setup Phase Audit Report

**Date:** 2026-05-21  
**Scope:** Setup phase implementation across CPASetup.sol, SetupFacet.sol, SetupFinalizeFacet.sol, DepositFacet.sol, and related integration points  
**Purpose:** Identify inefficiencies, limitations, gas issues, and areas for improvement

---

## Executive Summary

The Setup phase successfully registers assets and collects deposits, but has several notable limitations and inefficiencies:

1. **Structural redundancy** in `AuctionInfo` storage (duplicates config data)
2. **No upper bound** on number of assets (potential for unbounded loops)
3. **Two-step initialization** with artificial gate (poolsRegistered flag)
4. **Missing validations** (asset uniqueness, supply constraints)
5. **O(n) confirmation check** (confirmSetupComplete) with no optimization path
6. **No bulk deposit validation** (amounts could mismatch declared supplies)

---

## Phase Overview

### Flow
1. **Create Auction** (`createAuction` in AuctionFlowFacet):
   - Calls `initAuction()` → registers assets
   - Calls `finalizeAuction()` → creates AuctionInfo
2. **Deposit Assets** (DepositFacet):
   - Option A: `moveDeposit()` per asset, one call per asset
   - Option B: `depositAllAndStartClock()` all assets in one call + transitions to Clock phase

### Files Involved
- `src/libraries/CPASetup.sol` - Core logic
- `src/facets/{SetupFacet,SetupFinalizeFacet,DepositFacet,AuctionFlowFacet}.sol` - Facet implementations
- `src/types/{AuctionTypes,AssetConfig}.sol` - Data structures
- `src/base/CPAStorage.sol` - Storage getters

---

## Issues & Limitations

### 1. **Data Redundancy in AuctionInfo** ⚠️ CRITICAL

**Location:** `src/types/AuctionTypes.sol:98-111`

```solidity
struct AuctionInfo {
    // ... other fields ...
    AuctionTypes.AuctionConfig config;  // Line 101 — FULL COPY
    AssetConfig[] assets;               // Line 106 — MIRRORS config.assets
}
```

**Problem:**
- `AuctionInfo.config` stores the entire `AuctionConfig` struct passed at creation
- `AuctionInfo.assets` duplicates `config.assets` — same array, stored twice
- This doubles storage for the same data

**Cost:**
- Extra SSTORE operations during `finalizeAuctionCreation()` (line 63-76 in CPASetup.sol)
- Extra SLOAD operations every time code accesses `auctionInfo[id].config` vs `auctionInfo[id].assets`
- Storage waste: ~32 bytes per asset (for array reference) + all asset data

**Fix Options:**
- Store only the config hash or metadata, not the full struct
- OR: Store assets separately and reference by ID
- OR: Accept the redundancy but make it explicit (gas cost trade-off for convenience)

**Severity:** Medium — correctness is fine, but efficiency is poor

---

### 2. **No Upper Bound on Number of Assets** ⚠️ HIGH

**Location:** `src/libraries/CPASetup.sol:21-52` (registerAssetsForAuction)

```solidity
function registerAssetsForAuction(
    AuctionTypes.AuctionConfig memory config,
    // ...
) internal returns (AuctionId auctionId) {
    if (config.assets.length == 0) revert IErrorsAndEvents.InvalidBidsLength();

    // NO CHECK: if (config.assets.length > MAX_ASSETS) revert TooManyAssets();

    for (uint256 i = 0; i < config.assets.length; ) {
        // ... validate and register each asset ...
    }
}
```

**Problem:**
- No maximum asset count enforced
- Clock phase's `processClockRound()` does O(n×m) where n = assets, m = active bidders
- Confirmation loop `confirmSetupComplete()` is O(n)
- Unknown scaling limit leads to surprise OOG errors in production

**Impact:**
- With 100 assets and 1000 active bidders, clock round is already risky
- With 1000 assets, even setup becomes expensive

**Recommended Limit:** 50-100 assets (typical auctions use 1-10)

**Fix:**
```solidity
if (config.assets.length == 0) revert IErrorsAndEvents.InvalidBidsLength();
if (config.assets.length > MAX_ASSETS) revert IErrorsAndEvents.TooManyAssets(config.assets.length);
```

**Severity:** High — unbounded loops are a classic DoS vector

---

### 3. **Two-Step Initialization with Artificial Gate** ⚠️ MEDIUM

**Location:**
- SetupFacet.sol:18-25 (initAuction)
- SetupFinalizeFacet.sol:18-27 (finalizeAuction)
- AuctionFlowFacet.sol:22-29 (createAuction)

**Problem:**
```solidity
// SetupFacet.initAuction
_proxy[auctionId].poolsRegistered = true;  // Sets flag
return auctionId;

// SetupFinalizeFacet.finalizeAuction
require(_proxy[auctionId].poolsRegistered, "Assets not registered");  // Checks flag
_proxy[auctionId].poolsRegistered = false;  // Clears flag
CPASetup.finalizeAuctionCreation(config, auctionId, auctionOwner, auctionInfo);
```

The pattern reuses `_proxy[auctionId].poolsRegistered` (a proxy-phase field) as a setup-phase guard. While this works, it:
- Uses a phase-specific field during a different phase (semantic confusion)
- Requires an extra storage write and check
- Could break if poolsRegistered logic ever changes

**Why Separate?**
The comment says "step 1 of 2-step creation" but there's no reason for this separation — `createAuction()` always calls both.

**Fix:**
- Combine into single atomic operation if always called together
- OR: Use a dedicated setup-phase flag (e.g., in ClockPhaseState or a new SetupPhaseState)
- OR: Accept this design but document why 2 steps exist

**Severity:** Low — works correctly, but design could be cleaner

---

### 4. **Missing Validations** ⚠️ MEDIUM

#### 4.1: Asset Uniqueness Not Enforced

**Location:** `src/libraries/CPASetup.sol:30-51`

Currently, the same asset token could be registered multiple times:
```solidity
// No check: if assetToAuctionId[assetId] already exists
AssetId assetId = AssetIdLibrary.createId(auctionId, asset.assetToken);
assetToAuctionId[assetId] = auctionId;  // Would just overwrite
assetInfo[assetId] = ...                 // Would just overwrite
```

While `assetToAuctionId[assetId]` being a simple mapping means overwriting is safe, it's semantically wrong to allow duplicate assets.

**Fix:**
```solidity
if (assetToAuctionId[assetId] != AuctionId.wrap(0)) {
    revert IErrorsAndEvents.DuplicateAsset(assetToken);
}
```

#### 4.2: No Validation of Deposit Amounts vs. Declared Supply

**Location:** `src/libraries/CPASetup.sol:123-143` (depositAllAndStartClock)

```solidity
function depositAllAndStartClock(
    AuctionTypes.AuctionInfo storage info,
    mapping(AssetId => AuctionTypes.AssetInfo) storage assetInfo,
    SettlementPhaseState storage settlementState,
    uint256[] memory amounts,  // <-- NO VALIDATION
    AuctionId auctionId
) internal {
    if (info.assets.length != amounts.length) revert IErrorsAndEvents.InvalidBidsLength();

    for (uint256 i = 0; i < info.assets.length; ) {
        _depositSingleAsset(auctionId, assetInfo, settlementState, 
                           info.assets[i].assetToken, amounts[i]);
        unchecked { ++i; }
    }
```

**Problem:** No check that `amounts[i] == info.assets[i].supply`

If auctioneer deposits less than promised supply:
- Clock phase would calculate demand based on the deposit, not the declared supply
- Could lead to price discovery on a subset of assets

If auctioneer deposits more than promised supply:
- Extra funds locked in contract with no settlement logic

**Current Behavior:** Relies on auctioneer honesty

**Fix:**
```solidity
for (uint256 i = 0; i < info.assets.length; ) {
    if (amounts[i] != info.assets[i].config.supply) {
        revert IErrorsAndEvents.AmountMismatch(i, amounts[i], info.assets[i].config.supply);
    }
    _depositSingleAsset(...);
    unchecked { ++i; }
}
```

**Severity:** Medium — allows misconfiguration but not exploitation

---

### 5. **confirmSetupComplete is O(n) with No Optimization** ⚠️ MEDIUM

**Location:** `src/libraries/CPASetup.sol:106-118`

```solidity
function confirmSetupComplete(
    AuctionId auctionId,
    AuctionTypes.AuctionInfo storage info,
    mapping(AssetId => AuctionTypes.AssetInfo) storage assetInfo
) internal view returns (bool) {
    if (info.currentPhase != AuctionTypes.AuctionPhase.Setup) return false;
    
    for (uint256 i = 0; i < info.assets.length; ) {
        AssetId assetId = AssetIdLibrary.createId(auctionId, info.assets[i].assetToken);
        if (assetInfo[assetId].depositAmount == 0) return false;
        unchecked { ++i; }
    }
    return true;
}
```

**Problem:**
- Called by code that needs to verify all deposits are complete
- Requires iterating all assets (O(n) SLOAD per asset)
- With 100 assets, this is 100 SLOAD operations (~2000 gas)
- No caching or early exit optimization

**Usage:** Likely called before transitioning to Clock phase

**Fix Option 1 — Counter:**
```solidity
struct SetupPhaseState {
    uint256 depositsCompleted;  // Incremented each moveDeposit, checked against assets.length
}
confirmSetupComplete: return setupState.depositsCompleted == info.assets.length;
```

**Fix Option 2 — Flag:**
```solidity
// In depositAllAndStartClock, set a flag instead of checking
if (info.assets.length != amounts.length) revert;
info.setupComplete = true;  // Single SSTORE
```

**Severity:** Low — works fine at small scale, but doesn't scale elegantly

---

### 6. **No Bulk Deposit Consistency Check** ⚠️ MEDIUM

**Location:** `src/libraries/CPASetup.sol:145-157` (_depositSingleAsset)

```solidity
function _depositSingleAsset(
    AuctionId auctionId,
    mapping(AssetId => AuctionTypes.AssetInfo) storage assetInfo,
    SettlementPhaseState storage settlementState,
    address assetToken,
    uint256 amount
) private {
    AssetId assetId = AssetIdLibrary.createId(auctionId, assetToken);
    assetInfo[assetId].depositAmount = amount;  // <-- Overwrites any previous deposit
    settlementState.assetBalance[assetToken] = amount;
    IERC20(assetToken).safeTransferFrom(msg.sender, address(this), amount);
}
```

**Problem:**
1. Each call to `_depositSingleAsset` **overwrites** the previous deposit (doesn't accumulate)
2. If called via `moveDeposit()` twice with different amounts for the same asset, only the last amount is stored

**Example:**
```
moveDeposit(auctionId, assetToken, 100); // depositAmount[assetId] = 100
moveDeposit(auctionId, assetToken, 50);  // depositAmount[assetId] = 50 (overwrote 100!)
```

Funds sent: 150 total
Recorded: 50
**Result:** 100 tokens unaccounted for in settlement

**Fix:**
```solidity
if (assetInfo[assetId].depositAmount != 0) {
    revert IErrorsAndEvents.AssetAlreadyDeposited(assetToken);
}
assetInfo[assetId].depositAmount = amount;
```

OR (if multiple deposits per asset are intended):
```solidity
assetInfo[assetId].depositAmount += amount;
```

**Current Workaround:** Always use `depositAllAndStartClock()` instead of multiple `moveDeposit()` calls

**Severity:** High — could lose track of deposits if misused, though current tests avoid this

---

### 7. **NumeraireLib ETH Support Not Fully Utilized** ⚠️ LOW

**Location:** `src/libraries/CPASetup.sol:98, 155` (IERC20.safeTransferFrom)

**Issue:**
- Uses raw IERC20.safeTransferFrom for all transfers
- Doesn't use NumeraireLib for ETH (`address(0)`) support
- Only the numeraire (ETH or ERC20) is special; other asset tokens are always ERC20

**Current Assumption:** All assets are ERC20 tokens; only numeraire can be ETH

**Correct Behavior:** Should be fine as-is (assets are not numeraire)

**Severity:** None — this is actually correct (assets are always ERC20)

---

### 8. **No Protection Against Reentrancy in moveDeposit** ⚠️ LOW

**Location:** `src/facets/DepositFacet.sol:18-24`

```solidity
function moveDeposit(
    AuctionId auctionId,
    address assetToken,
    uint256 depositAmount
) external nonReentrant onlyAuctionOwner(auctionId) {
    CPASetup.moveDeposit(auctionInfo[auctionId], assetInfo, _settlement[auctionId], auctionId, assetToken, depositAmount);
}
```

**Good:** Has `nonReentrant` guard

**Potential Issue:** The guard only protects against reentrancy into the same function. If an asset token has a callback (not ERC20 standard, but possible in crafted tokens), it could potentially interact with other phases.

**Actual Risk:** Low, since:
- SafeERC20.safeTransferFrom is atomic
- No state mutation after the transfer
- Auction is in Setup phase (can't interact with other phases)

**Severity:** None — reentrancy guard is sufficient

---

## Summary Table

| Issue | Type | Severity | Effort | Impact |
|-------|------|----------|--------|--------|
| 1. Data Redundancy in AuctionInfo | Design | Medium | Medium | Storage efficiency, gas costs |
| 2. No Upper Bound on Assets | Limitation | High | Low | Unbounded loops, DoS risk |
| 3. Two-Step Init w/ Artificial Gate | Design | Medium | Medium | Cleanness, maintainability |
| 4.1 Asset Uniqueness Not Enforced | Validation | Medium | Low | Semantic correctness |
| 4.2 No Deposit vs. Supply Check | Validation | Medium | Low | Configuration validation |
| 5. confirmSetupComplete is O(n) | Performance | Medium | Medium | Scales poorly with assets |
| 6. Bulk Deposit Overwrites | Design | High | Low | Data loss if misused |
| 7. NumeraireLib Not Used (Assets) | Design | Low | N/A | Actually correct (no change needed) |
| 8. Reentrancy Guard | Security | None | N/A | Already protected |

---

## Recommendations (Prioritized)

### Priority 1 — High Impact, Low Effort

1. **Add MAX_ASSETS constant** and enforce in registerAssetsForAuction
   - Prevents unbounded loops in Clock phase
   - One revert condition

2. **Fix deposit overwrite bug** — prevent re-depositing same asset
   - Prevents silent data loss
   - One check in _depositSingleAsset

3. **Add deposit-supply validation** — require amounts[i] == config.supply
   - Prevents misconfiguration
   - One loop in depositAllAndStartClock

### Priority 2 — Medium Impact, Medium Effort

4. **Refactor data redundancy** — eliminate config/assets duplication
   - Store only config hash or extract on-demand
   - Multiple touchpoints but straightforward

5. **Consolidate two-step initialization** — merge initAuction and finalizeAuction
   - If always called together, make atomic
   - Cleaner design

6. **Add SetupPhaseState struct** — track setup progress with counter
   - Replaces O(n) confirmSetupComplete with O(1)
   - New struct + state tracking

### Priority 3 — Lower Priority

7. **Enforce asset uniqueness** — validate no duplicate assets
   - Semantic correctness
   - One check

---

## Next Steps

Recommend auditing Clock phase next, which has the O(n×m) iteration problem you mentioned. Setup phase is relatively contained; the real scaling issues appear once bidding begins.

---

## Files Requiring Changes

- `src/types/AuctionTypes.sol` — Add MAX_ASSETS, remove redundant storage
- `src/libraries/CPASetup.sol` — Add validations, fix overwrite, optimize confirmSetupComplete
- `src/facets/{SetupFacet,SetupFinalizeFacet}.sol` — Consolidate if merging init steps
- `src/base/CPAStorage.sol` — Add SetupPhaseState if implemented
- Tests — Update setup tests to cover new validations
