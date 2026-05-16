# CPA Contract Size & Deployment Status Report

**Date:** 2026-03-06
**Working branch:** `cpa-after-atrium`
**Goal:** Deploy CPAManager to a testnet (Arbitrum Sepolia or similar L2)

---

## TL;DR

**You cannot deploy `cpa-after-atrium` as-is, even on Arbitrum.** The contract's initcode (101KB) exceeds EIP-3860's 49KB limit, which Arbitrum Nitro enforces. The size-optimization work on `size-optimization-no-via-IR` solves the CPAManager deployment problem (initcode drops to 45KB) but has broken tests and leaves the external library contracts themselves over the 24KB EIP-170 runtime limit (not an L2 deployment blocker, but a mainnet one). The fix to get `size-optimization-no-via-IR` working is small (~30min).

---

## Contract Sizes by Branch

### `cpa-after-atrium` (clean, all tests pass)

| Contract | Runtime (bytes) | Initcode (bytes) | EIP-170 limit (24,576) | EIP-3860 limit (49,152) |
|---|---|---|---|---|
| CPAManager | 99,634 | 101,092 | ❌ 4x over | ❌ 2x over |
| CPAAllocationPhase | 8,107 | 8,156 | ✅ | ✅ |
| CPAClockPhase | 62 (stub) | 106 | ✅ | ✅ |
| CPASetup | 62 (stub) | 106 | ✅ | ✅ |

CPAManager is 99KB because all phase libraries (`CPASetup`, `CPAClockPhase`, `CPAAllocationPhase`, `CPASettlementPhase`, `CPAProxyPhase`, `CPAFinishedPhase`) are **internal Solidity libraries**. The compiler inlines their bytecode directly into CPAManager. There are 38 functions in CPAManager and ~28 more in the phase libraries, all landing in a single ~948-line contract (`src/CPAManager.sol`).

### `size-optimization-no-via-IR` (compile errors in tests, source builds fine)

Each phase library is redeployed as a standalone contract. CPAManager calls them via `delegatecall` (31 call sites), holding their addresses as `immutable` constructor parameters (`setupLib`, `clockPhaseLib`, `allocationPhaseLib`, etc. — see `src/CPAManager.sol:58–82`).

| Contract | Runtime (bytes) | Initcode (bytes) | EIP-170 | EIP-3860 |
|---|---|---|---|---|
| **CPAManager** | **43,818** | **45,629** | ❌ still over | **✅ under 49,152** |
| CPASetupExternal | 34,171 | 35,017 | ❌ | ✅ |
| CPAClockPhaseExternal | 32,953 | 33,799 | ❌ | ✅ |
| CPAAllocationPhaseExternal | 32,228 | 33,074 | ❌ | ✅ |
| CPACallbacks | 30,704 | 31,550 | ❌ | ✅ |
| CPASettlementPhaseExternal | 22,225 | 23,071 | ✅ | ✅ |
| CPAProxyPhaseExternal | 19,269 | 20,115 | ✅ | ✅ |
| CPAFinishedPhaseExternal | 17,192 | 18,038 | ✅ | ✅ |

**Key win:** CPAManager's initcode goes from 101KB → 45KB, crossing below the EIP-3860 threshold. Every contract's initcode is now under 49KB.

**Remaining problem for mainnet:** CPASetupExternal (34KB), CPAClockPhaseExternal (32KB), CPAAllocationPhaseExternal (32KB), and CPACallbacks (30KB) are all over the 24KB EIP-170 runtime limit. These are fine on Arbitrum/L2s but cannot be deployed to Ethereum mainnet.

---

## EIP Limits Reference

| Limit | Value | Since | Applies to |
|---|---|---|---|
| EIP-170 | 24,576 bytes **runtime** | Spurious Dragon (2016) | Ethereum mainnet + chains that enforce it |
| EIP-3860 | 49,152 bytes **initcode** | Shanghai (2023) | Ethereum mainnet; Arbitrum Nitro has implemented this |

Arbitrum does **not** enforce EIP-170 on runtime size. It **does** implement EIP-3860 on initcode. This means `cpa-after-atrium` fails to deploy (101KB initcode), but `size-optimization-no-via-IR` would succeed on Arbitrum (all initcodes ≤ 45KB).

---

## Branch Status

| Branch | Last Updated | CPAManager Size | Tests | Deployable on Arbitrum |
|---|---|---|---|---|
| `cpa-after-atrium` | Oct 31, 2025 | 99,634B runtime / 101KB initcode | ✅ All pass | ❌ Fails EIP-3860 |
| `externalize-auction-control-and-callbacks` | Oct 31, 2025 | 43,909B runtime / 45KB initcode | ❌ 53 failures (AuctionNotFound in setUp) | ✅ Probably yes |
| `size-optimization-no-via-IR` | Jan 16, 2026 | 43,818B runtime / 45KB initcode | ❌ Compile error (test only) | ✅ Yes (once test fixed) |

---

## What's Broken on `size-optimization-no-via-IR`

Two issues, both in test code only — no production code changes needed:

### 1. `getAuctionInfo` removed but tests still call it

`CPAStorage` previously had a `getAuctionInfo(AuctionId)` view function that returned a full `AuctionTypes.AuctionInfo` struct. It was removed as part of the storage flattening work. The tests in `CPAAllocationPhase.t.sol`, `CPAClockPhase.t.sol`, and `CPASetupPhase.t.sol` still call it (~20 call sites across 3 files).

**Error:**
```
Error (9582): Member "getAuctionInfo" not found or not visible after argument-dependent lookup in contract CPAManager.
  --> test/CPAAllocationPhase.t.sol:140
```

**Fix:** Add `getAuctionInfo` back to `src/base/CPAStorage.sol` as a view-only function that reconstructs `AuctionInfo` from the flat mappings. This does not change any storage layout or production logic. The fields needed are all available in the existing mappings (`auctionOwner`, `auctionPhase`, `auctionPhaseDurations`, etc. — see `src/base/CPAStorage.sol:29–120`).

### 2. Shadowing warning treated as error

```
Warning (2519): This declaration shadows an existing declaration.
  --> test/base/CPATestBase.sol:386
    AuctionId auctionId = createAuction(...)  // shadows class member on line 76
```

**Fix:** Rename the local variable in `setupCompleteAuction()` from `auctionId` to `newAuctionId`.

---

## Path to Testnet Deployment

### Shortest path (Arbitrum Sepolia, ~1–2 days)

1. Switch to `size-optimization-no-via-IR`
2. Fix the two test issues above
3. Verify all tests pass
4. Deploy in order: CPASetupExternal → CPAClockPhaseExternal → CPAAllocationPhaseExternal → CPASettlementPhaseExternal → CPAProxyPhaseExternal → CPAFinishedPhaseExternal → CPACallbacks → CPAManager (passing library addresses to constructor)
5. CPAHook is separate and small (7,800 bytes) — deploys fine anywhere

The deployment script (`script/DeployCPA.sol`) was already updated on this branch to handle the multi-contract deploy (commit `10e9a31`).

### Path to Ethereum mainnet (significant additional work)

The four external libraries over 24KB need further splitting:
- `CPASetupExternal` (34KB) — likely needs 2 sub-contracts
- `CPAClockPhaseExternal` (32KB) — likely needs 2 sub-contracts
- `CPAAllocationPhaseExternal` (32KB) — complex; stash history shows Yul stack depth issues when trying this (`stash@{2}: WIP: Attempting to fix Yul stack depth error in CPAAllocationPhaseExternal`)
- `CPACallbacks` (30KB) — likely needs 2 sub-contracts

The `viaIR = false` setting in `foundry.toml` is intentional — `via-IR` was tried and caused stack-too-deep errors, hence this branch's name.

Alternative worth exploring: **EIP-2535 Diamond proxy pattern** — a single dispatcher contract routes calls to multiple facet contracts. Could replace the current ad-hoc delegatecall approach with a standard pattern and solve all size issues at once, but requires significant refactoring.

---

## Stash Notes

There is uncommitted work in the stash that may be relevant:

- `stash@{0}`: WIP on `size-optimization-no-via-IR` — changes to `CPAStorage`, `CPAManager`, and several external libraries (459 insertions). This appears to be a storage-flattening attempt (individual mappings instead of `AuctionInfo` struct). May address the `getAuctionInfo` issue differently, but was abandoned. Review before discarding.
- `stash@{1}`: WIP on `size-optimization`: "Reverting to AuctionInfo struct approach" — confirms the struct vs flat-mapping approach was actively being debated.
- `stash@{2}`: WIP on `size-optimization`: "Attempting to fix Yul stack depth error in CPAAllocationPhaseExternal" — relevant if splitting that library further.
