# Diamond Pattern Migration: Plan of Plans

**Project**: Rok — Clock-Proxy Auction Protocol  
**Problem solved**: CPAManager was 99.6 KB (exceeds EIP-170 24 KB limit)  
**Solution**: EIP-2535 diamond proxy — CPAManager IS the diamond  
**Upgrade strategy**: Complete redeploy per major version (no in-place upgrades)

---

## Architectural Decisions (as implemented)

### 1. CPAManager IS the diamond
CPAManager inherits CPAStorage, which defines the full storage layout. All facets also inherit CPAStorage via CPABase. This means CPAManager's storage slots already match every facet's expected layout — the correct prerequisite for delegatecall. No separate `Diamond.sol` is needed or present.

### 2. DiamondCut and DiamondLoupe are inline in CPAManager
They are small enough to live directly in the proxy shell (~175 lines total). No DiamondCutFacet or DiamondLoupeFacet contracts exist or are needed.

### 3. 25 facets (not 6)
Phase B produced 25 facets after hitting the 24 KB per-facet limit. Each facet is a clean slice of functionality:

| Facet | Contract name | Selector(s) |
|-------|--------------|-------------|
| CoreFacet | CoreFacet | setCpaAuctionHookAddr, pause, unpause, cancelAuction, forceCancelAuction |
| SetupFacet | SetupFacet | initAuction |
| SetupFinalizeFacet | SetupFinalizeFacet | finalizeAuction |
| DepositFacet | DepositFacet | moveDeposit, depositAllAndStartClock |
| ClockPhaseFacet | ClockStartFacet | startClockPhase |
| ClockBidFacet | ClockBidFacet | submitBid |
| ClockBidderFacet | ClockCommitFacet | commitToBidder, registerCommit, dropout |
| ClockEndFacet | ClockEndFacet | endClockPhase |
| ClockEndRoundFacet | ClockEndRoundFacet | processClockRoundStep |
| ClockFinalizeRoundFacet | ClockFinalizeRoundFacet | finalizeClockRound |
| ProxyPhaseFacet | ProxyPhaseFacet | submitBundle |
| AllocationPhaseFacet | AllocationTransitionFacet | transitionToAllocation |
| AllocationSubmitFacet | AllocationSubmitFacet | submitAllocation |
| SettlementTransitionFacet | SettlementTransitionFacet | selectAuctionWinner |
| SettlementTransferFacet | SettlementTransferFacet | convertAuctionAssets |
| SettlementMintFacet | SettlementMintFacet | mintSettlementPositions |
| SettlementPhaseFacet | SettlementClaimFacet | reveal, claimToken, claimAllTokens |
| SettlementMiscFacet | SettlementMiscFacet | reclaimStake, claimAllocatorReward, transitionToFinished |
| FinishedPhaseFacet | FinishedPhaseFacet | forfeit, transferPositionsToAuctioneer |
| CallbackRouterFacet | CallbackRouterFacet | unlockCallback (dispatch entry point) |
| CallbacksFacet | CallbacksClockFacet | unlockCallback (ops 0,2,3,9) — callback sub-facet |
| CallbacksDepositFacet | CallbacksDepositFacet | unlockCallback (ops 1,8) — callback sub-facet |
| CallbacksClaimTokenFacet | CallbacksClaimTokenFacet | unlockCallback (op 4) — callback sub-facet |
| CallbacksRefundFacet | CallbacksRefundFacet | unlockCallback (ops 5,6) — callback sub-facet |
| CallbacksSettlementFacet | CallbacksSettlementFacet | unlockCallback (op 7) — callback sub-facet |

### 4. unlockCallback collision resolved via CallbackRouterFacet
Five callback facets all implement `unlockCallback(bytes)` — same 4-byte selector. In EIP-2535 only one facet can own a selector. CallbackRouterFacet is the sole registered owner; it decodes the op type, reads the op→sub-facet table from LibDiamond, and chained-delegatecalls the correct sub-facet. Both hops run in diamond storage context.

### 5. CPAStorage view functions are directly on CPAManager
`getAuctionInfo`, `getPoolInfo`, `getBundle`, `getNumItems`, `getTopAllocation`, and all public mapping auto-getters (`poolInfo`, `poolToAuctionId`, `bidderStake`, `bidderBidPoints`, `protocolPenalties`, `winningBundleIds`, `activeBidders`) exist directly on CPAManager via CPAStorage inheritance. They do NOT go through the fallback — they are called directly.

### 6. No backwards compatibility
Phase B renamed several functions when splitting the monolith into facets. Phase D updates all test files to use the new names. There is no shim layer.

---

## Phase Status

### ✅ Phase A — Architecture & Planning
Complete. This document.

### ✅ Phase B — Facet Extraction (merged via PR #2 into `diamond_standard`)
- 25 facets extracted from the 99.6 KB monolith
- All facets under EIP-170 24 KB limit
- Phase libraries remain as shared libraries (not inlined into facets)

### ✅ Phase C — Diamond Proxy Wiring (PR #3 targeting `diamond_standard`)
- `src/libraries/LibDiamond.sol` — isolated keccak storage slot, selector table, callback sub-facet table
- `src/interfaces/IDiamondCut.sol`, `IDiamondLoupe.sol` — EIP-2535 standard interfaces
- `src/facets/CallbackRouterFacet.sol` — `unlockCallback` dispatch with assembly revert bubble-up
- `src/CPAManager.sol` — stripped to ~175-line proxy shell
- `src/interfaces/ICPAManager.sol` — extended to cover all callable functions; correct return types
- `test/base/CPATestBase.sol` — typed to `ICPAManager`, deploys and wires all 25 facets in `deployContracts`
- `forge build` passes (exit 0)

### 🔲 Phase D — Test Updates (current)
See detailed plan below.

### 🔲 Phase E — Deployment Script
See outline below.

### 🔲 Phase F — Documentation
See outline below.

---

## Phase D: Test Updates

**Branch**: `claude/phase-d-test-updates` (from `diamond_standard` after Phase C merges)  
**Goal**: `forge test` passes with no failures.

### Context: what broke and why

Phase B renamed functions when splitting the monolith into smaller facets. The old monolith had one function per user action; Phase B sometimes combined steps or renamed for clarity. Tests written against the monolith use old names. `createAuction` → `initAuction` (+ `finalizeAuction`), `endClockRound` → `processClockRoundStep` + `finalizeClockRound`, `transitionToSettlement` → `selectAuctionWinner` + `convertAuctionAssets` + `mintSettlementPositions`.

### Known function name mismatches (old → new)

| Old call (in tests) | New facet function(s) | Notes |
|---------------------|----------------------|-------|
| `createAuction(config, owner)` | `initAuction(config, owner)` then `finalizeAuction(id, config, owner)` | SetupFacet + SetupFinalizeFacet |
| `endClockRound(id)` | `processClockRoundStep(id)` then `finalizeClockRound(id)` | ClockEndRoundFacet + ClockFinalizeRoundFacet |
| `transitionToSettlement(id)` | `selectAuctionWinner(id)` then `convertAuctionAssets(id)` then `mintSettlementPositions(id)` | Three separate facets |
| `getBidderDemands(id, addr)` | `bids(id, addr)` | Public mapping auto-getter on CPAStorage |

### Step-by-step

**Step D1 — Audit all test files for old names**

Run:
```bash
grep -rn "createAuction\|endClockRound\|transitionToSettlement\|getBidderDemands" test/
```

For each hit, replace with the new multi-step call sequence.

**Step D2 — Update `createAuction` usages**

Old (1 call):
```solidity
AuctionId id = cpaManager.createAuction(config, owner);
```

New (2 calls):
```solidity
AuctionId id = cpaManager.initAuction(config, owner);
cpaManager.finalizeAuction(id, config, owner);
```

The CPATestBase internal helper `createAuction` already calls `initAuction`; it needs the `finalizeAuction` call added. Then individual test files that call `cpaManager.createAuction(...)` directly need to use the helper or be updated.

**Step D3 — Update `endClockRound` usages**

Old (1 call):
```solidity
cpaManager.endClockRound(id);
```

New (2 calls, must be in order):
```solidity
cpaManager.processClockRoundStep(id);
cpaManager.finalizeClockRound(id);
```

Consider adding a `endClockRound(AuctionId)` helper to CPATestBase that wraps both calls. Tests that call `cpaManager.endClockRound(...)` directly via ICPAManager need updating (ICPAManager should drop the old name once all callers are updated).

**Step D4 — Update `transitionToSettlement` usages**

Old (1 call):
```solidity
cpaManager.transitionToSettlement(id);
```

New (3 calls):
```solidity
cpaManager.selectAuctionWinner(id);
cpaManager.convertAuctionAssets(id);
cpaManager.mintSettlementPositions(id);
```

Consider a `transitionToSettlement(AuctionId)` helper in CPATestBase.

**Step D5 — Update `getBidderDemands` usages**

Replace `cpaManager.getBidderDemands(id, bidder)` with `cpaManager.bids(id, bidder)`.
Add `bids(AuctionId, address) returns (uint256[] memory)` to ICPAManager.

**Step D6 — Remove old names from ICPAManager**

Once no test calls `createAuction`, `endClockRound`, `transitionToSettlement`, or `getBidderDemands`, remove those declarations from ICPAManager. This enforces the clean break.

**Step D7 — Run `forge test` and fix any remaining failures**

Some tests may fail for reasons beyond naming — e.g., incorrect selector registration in CPATestBase (wrong hardcoded bytes4), storage getter ABI mismatches, or payable/non-payable mismatches. Fix each failure at root cause.

**Step D8 — Verify selector table accuracy**

After `forge build` passes, run `forge inspect <FacetName> methodIdentifiers` for every facet and cross-check each selector against the bytes4 literals in `CPATestBase._registerProtocolFacets`. Fix any mismatches. This is the most likely source of silent runtime failures.

**Step D9 — Gas sanity check**

Run `forge test --gas-report` and compare total gas per test against the pre-diamond baseline (save a baseline before D1). Diamond fallback overhead is ~2,600 gas per call on Arbitrum; confirm no test exceeds a reasonable threshold.

---

## Phase E: Deployment Script

**Goal**: A single `forge script` that deploys the full system to a target network.

### Steps

1. Deploy `MathFacet` (no constructor args beyond the standard 6; address goes into CPAStorage `mathFacet` slot)
2. Deploy `CPAManager` (6-arg constructor: poolManager, owner, cpaHookAddr, positionManager, protocolWallet, mathFacet)
3. Deploy all 20 protocol facets (same 6 args)
4. Build `FacetCut[]` array with hardcoded selectors (generate from `forge inspect` during development; commit the script with literal bytes4 values)
5. Call `CPAManager.diamondCut(cuts, address(0), "")`
6. Deploy 5 callback sub-facets (same 6 args)
7. Call `CPAManager.setCallbackFacets(opTypes, facetAddrs)` (ops 0–9)
8. Call `CPAHook.setAuctionManager(address(cpaManager))`
9. Emit all deployed addresses to a JSON artifact

**Note**: The constructor no longer deploys facets itself (CPAManager is a clean proxy shell). All facet registration happens via the script. This is the correct EIP-2535 pattern.

---

## Phase F: Documentation

1. Update `README.md`: replace monolith architecture diagram with diamond diagram; add "how to interact" section showing CPAManager as single entry point
2. Add `docs/FACETS.md`: table of all 25 facets, their selectors, and what they do
3. Add `docs/CALLBACK_ROUTING.md`: diagram of the double-delegatecall chain (PoolManager → diamond fallback → CallbackRouterFacet → CallbackXxxFacet)
4. Add NatDoc comments to ICPAManager for all new function names
5. Archive or update `DIAMOND_MIGRATION_PLAN_OF_PLANS.md` (this file) as a historical record

---

## Files reference (as built)

### New in Phase B
All files under `src/facets/` (25 contracts)  
Phase libraries remain in `src/libraries/`

### New in Phase C
- `src/libraries/LibDiamond.sol`
- `src/interfaces/IDiamondCut.sol`
- `src/interfaces/IDiamondLoupe.sol`
- `src/facets/CallbackRouterFacet.sol`

### Modified in Phase C
- `src/CPAManager.sol` — now a ~175-line proxy shell
- `src/interfaces/ICPAManager.sol` — extends IDiamondCut, IDiamondLoupe; correct signatures
- `test/base/CPATestBase.sol` — deploys and wires full diamond in `deployContracts`

### To be modified in Phase D
- `test/base/CPATestBase.sol` — helpers for multi-step actions
- `test/*.t.sol` — all individual test files using old function names
- `src/interfaces/ICPAManager.sol` — drop old names once tests are updated

### Unchanged
- `src/CPAHook.sol`
- `src/types/`
- `src/base/CPAStorage.sol`
- `src/utils/`
- `src/base/CPABase.sol`, `CPABaseClock.sol`
