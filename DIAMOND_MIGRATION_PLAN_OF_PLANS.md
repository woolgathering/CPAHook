# Diamond Pattern Migration: Plan of Plans

**Project**: Rok - Clock-Proxy Auction Protocol  
**Current Status**: CPAManager is 99.6 KB (exceeds 24 KB bytecode limit)  
**Goal**: Migrate to EIP-2535 diamond pattern to stay within deployment limits  
**Approach**: Complete redeploy for v2 (no in-place upgrades)

---

## Architectural Decisions

### 1. Why Diamond Pattern?
- **Problem**: CPAManager is 99.6 KB initcode, exceeds 24 KB limit
- **Solution**: Break into facets (one per phase + core)
- **Current facet sizes** (reference):
  - CPAAllocationPhase library: 8.1 KB
  - CPAHook: 7.8 KB
  - Each phase library is small; CPAManager bulk is the aggregation

### 2. No In-Place Upgrades
- Each major version (v1, v2, v3) is a **complete separate deployment**
- No facet version tracking within auctions
- Simplifies the architecture enormously
- UI/users point to latest version; early versions stay deployed for historical data

### 3. Diamond Standard: EIP-2535
- Use **full EIP-2535** (not custom routing)
- Selector-based facet routing
- Standard `diamondCut()` for future facet changes (even if v2 is a "fresh start")
- Rationale: Similar complexity/gas to custom routing, and maintains standards compatibility

### 4. Single Entry Point for Users
- **CPAManager** remains the only contract users interact with
- All phase functions (bidding, commit, bundle submission, etc.) called on CPAManager
- CPAManager is the diamond proxy (or implements the diamond pattern)
- Internal routing to phase facets is transparent

### 5. Storage Model: Inheritance + Shared CPAStorage
- All phase facets **inherit from CPAStorage**
- Direct access to auction state variables (`auctionInfo`, `bidders`, `bundles`, etc.)
- No storage layout version mismatch (v2 is a complete redeploy anyway)
- Rationale: Simplest, cheapest gas, and sufficient given "no upgrades" approach

### 6. CPAHook: External, Unchanged
- CPAHook remains a separate contract
- CPAManager (diamond) address is registered as `auctionManager` in CPAHook
- Each phase facet can call CPAHook as needed (e.g., Clock phase calls to set pool prices)
- Permissioning: Only CPAManager can call `setPoolState()`
- Hook interface stays identical; only the caller address changes

### 7. Phase Facets: One Per Phase (Initially)
Planned facet structure:
- **CoreFacet**: Auction creation, general state queries, owner/permissioning
- **ClockPhaseFacet**: Bidding, commit registration
- **ProxyPhaseFacet**: Bundle submission
- **AllocationPhaseFacet**: Allocator competition
- **SettlementPhaseFacet**: Token claiming, reveal
- **FinishedPhaseFacet**: Transition to finished state

Rationale: Phases are sequential, non-overlapping, and map cleanly to responsibility boundaries. If a facet becomes too large, we can sub-divide later.

### 8. Diamond Cut Strategy
- Use standard EIP-2535 `diamondCut()` function
- Owner (protocol owner) only
- For v2 deployment: Deploy all facets fresh, cut them in
- For future facet changes: Add/replace individual facets as needed
- No restrictions on cutting (v2 is a new system anyway)

### 9. Library Dependencies
- Phase libraries (CPAClockPhase, CPAProxyPhase, etc.) become **part of facets**
- Not standalone libraries (they're not currently called externally anyway)
- Facets use them internally via library calls or inline them

### 10. Test Preservation
- All existing test logic is preserved
- Tests import and call `CPAManager` as before (same interface)
- Internally, CPAManager routes to facets (transparent to tests)
- Test setup may need minor refactoring (e.g., deploying facets + diamond cut)

### 11. Deployment Sequence (v2)
1. Deploy CPAManager (diamond proxy/delegate)
2. Deploy all phase facets (CoreFacet, ClockPhaseFacet, etc.)
3. Execute `diamondCut()` to connect all facets
4. Set CPAManager address in CPAHook as `auctionManager`
5. Run full test suite to verify behavior

---

## Decision Summary: Key Questions & Answers

| Question | Decision | Rationale |
|----------|----------|-----------|
| Upgrade strategy? | Complete redeploy per version | Simpler, no version tracking needed |
| Diamond standard? | Full EIP-2535 | Standards compliance, similar complexity |
| Single entry point? | Yes, CPAManager | Consistency for users |
| Storage access? | Facets inherit CPAStorage | Simplest, cheapest, sufficient |
| CPAHook integration? | External, permissioned | No change to interface, tight V4 requirements |
| Phase boundaries? | One facet per phase | Clean mapping, can sub-divide if needed |
| Version tracking? | None (v1, v2 are separate) | Simplified architecture |

---

## High-Level Milestones

### Phase A: Architecture & Planning (THIS DOCUMENT)
- [x] Identify bottleneck (CPAManager size)
- [x] Decide on EIP-2535 diamond pattern
- [x] Document all architectural decisions
- [x] Create detailed implementation plan

### Phase B: Facet Refactoring (COMPLETE — merged to `diamond_standard` via PR #2)
- [x] Extract CoreFacet (pause/unpause/cancel)
- [x] Extract SetupFacet + SetupFinalizeFacet (`initAuction` / `finalizeAuction`)
- [x] Extract DepositFacet (`moveDeposit` / `depositAllAndStartClock`)
- [x] Extract ClockStartFacet, ClockBidFacet, ClockCommitFacet, ClockEndFacet, ClockEndRoundFacet, ClockFinalizeRoundFacet
- [x] Extract ProxyPhaseFacet
- [x] Extract AllocationTransitionFacet + AllocationSubmitFacet
- [x] Extract SettlementTransitionFacet, SettlementTransferFacet, SettlementMintFacet, SettlementClaimFacet, SettlementMiscFacet
- [x] Extract FinishedPhaseFacet
- [x] Extract 5 callback sub-facets (CallbacksClockFacet, CallbacksDepositFacet, CallbacksClaimTokenFacet, CallbacksRefundFacet, CallbacksSettlementFacet)
- [x] Extract MathFacet (standalone pure-math helper)
- [x] All 25 facets under 24 KB bytecode limit

### Phase C: Diamond Integration (COMPLETE — merged to `diamond_standard` via PR #3)
- [x] Implement `LibDiamond` with isolated storage slot (`keccak256("rok.diamond.storage") - 1`)
- [x] Implement `diamondCut()` and DiamondLoupe directly in CPAManager (no extra facets needed)
- [x] Create `CallbackRouterFacet` to resolve `unlockCallback` selector collision across 5 callback facets
- [x] Convert CPAManager to EIP-2535 diamond proxy (fallback routing via delegatecall)
- [x] Fix storage layout: CPAManager inheritance order aligned with CPABase (`Ownable` first, so `_owner` is at slot 0 matching all facets)
- [x] Add `IDiamondCut` and `IDiamondLoupe` standard interfaces
- [x] CPAManager shell < 10 KB; all 25 facets still under 24 KB

### Phase D: Testing & Validation (COMPLETE — branch `claude/phase-d-test-updates`)
- [x] Update `ICPAManager` interface: remove old names (`createAuction`, `endClockRound`, `transitionToSettlement`, `getBidderDemands`), add new facet function declarations
- [x] Update `CPATestBase` helpers: `createAuction` (adds `finalizeAuction` call), `endClockRound`, `transitionToSettlement`, `getBidderDemands`
- [x] Update 9 test files: replace 58 old-name calls with helpers (CPASetupPhase, CPAClockPhase, CPACompleteFlow, CPAFinishedPhase, CPAAllocationPhase, CPAPhaseTransition, CPASettlementPhase, CPAClockETH, CPAClock6Decimals)
- [x] Fix storage layout mismatch: `CPAManager` inheritance reordered (`Ownable` before `CPAStorage`) so slots align with all facets
- [x] All test cases pass (`forge test` green)
- [x] Storage layout verified via `forge inspect` (slots 0/7/8/30 match between diamond and facets)

### Phase E: Integration & Deployment (Plan to be created)
- [ ] Integrate with CPAHook
- [ ] Set auctionManager in CPAHook
- [ ] Deploy to testnet
- [ ] Deploy to mainnet (or final network)

### Phase F: Documentation (Plan to be created)
- [ ] Update README.md with new architecture
- [ ] Document diamond cut interface
- [ ] Document migration notes (if v1 exists)

---

## Future Decisions (To Be Made in Implementation Plans)

1. **CoreFacet scope**: Exactly which functions go in CoreFacet vs. phase facets?
2. **Library inlining**: Do we inline phase libraries or keep them separate?
3. **Error handling**: Do errors stay in IErrorsAndEvents or move to facets?
4. **Gas optimization**: Any gas optimizations specific to facet routing?
5. **Deployment script**: Hardcode facet selectors or generate them dynamically?
6. **Facet size monitoring**: At what size do we consider splitting a facet?

---

## Files That Will Change

### New Files
- `src/facets/CoreFacet.sol`
- `src/facets/ClockPhaseFacet.sol`
- `src/facets/ProxyPhaseFacet.sol`
- `src/facets/AllocationPhaseFacet.sol`
- `src/facets/SettlementPhaseFacet.sol`
- `src/facets/FinishedPhaseFacet.sol`
- `src/diamond/Diamond.sol` (if separate from CPAManager)
- `script/DeployDiamond.s.sol` (new deployment script)

### Modified Files
- `src/CPAManager.sol` → Becomes diamond or thin routing layer
- `src/CPAHook.sol` → Update `auctionManager` to new diamond address
- `test/*.t.sol` → Minor updates for facet-based deployment

### Unchanged Files
- `src/types/` → No changes
- `src/base/CPAStorage.sol` → No changes (inherited by all facets)
- `src/utils/` → No changes (used by facets)
- `src/interfaces/` → Minimal changes (interfaces stay same)
- Library files → Incorporated into facets

---

## Constraints & Notes

1. **Solidity version**: Stay on 0.8.24 (current)
2. **Uniswap V4**: Hook interface must remain compatible
3. **Foundry**: Use `forge` for all builds/tests
4. **Storage**: No new storage slots added (v2 is fresh deployment)
5. **Bytecode limit**: Target: All facets + diamond < 24 KB each (should be easy)
6. **Test preservation**: All test cases must pass with same logic
7. **Owner-only functions**: Stay owner-only (Ownable pattern)

---

## Success Criteria

- [x] CPAManager deploys without bytecode size warnings
- [x] All phase facets deploy without warnings
- [x] Diamond cut executes successfully
- [x] All existing tests pass
- [x] Users interact with CPAManager as before (transparent facet routing)
- [ ] Gas costs are comparable or better than library model (to be measured)
- [x] CPAHook integration works correctly

---

## Next Steps

1. **Create Phase B plan**: "Refactor to Facets"
   - Detailed breakdown of which functions go in which facet
   - Storage access patterns per facet
   - Dependency map between facets

2. **Create Phase C plan**: "Implement Diamond Pattern"
   - Diamond proxy implementation (using standard or custom)
   - Selector routing logic
   - DiamondCut interface

3. **Execute plans incrementally** with testing after each phase
