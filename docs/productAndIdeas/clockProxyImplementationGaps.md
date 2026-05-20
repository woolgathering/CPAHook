# Clock-Proxy Auction Implementation Gaps

## Academic Clock-Proxy Auction vs CPAManager Implementation Analysis

### What's Correctly Implemented

1. Clock Phase: 
   - Price discovery with price tracking in Uniswap pools
   - Multi-asset bidding (FEATURE TO BE ADDED: with exact output/input support)
   - Price increments via tick manipulation
   - Excess demand calculation and naive price updates

2. Proxy Phase:
   - Bundle submission with commit-reveal privacy
   - Proxy registration system
   - Bundle validation and storage

3. Allocation Phase:
   - Allocator competition with on-chain scoring
   - Revenue maximization scoring algorithm
   - Winner selection mechanism

4. Settlement Phase:
   - Token claiming with stake management
   - Batch operations for multiple assets
   - Allocator reward system (1%) -- currently auction-specific percentage of deposits

### Key Gaps from Academic Implementation

## 1. ✅ IMPLEMENTED: Revealed Preference Activity Rule

Academic Requirement: The paper emphasizes a "revealed preference activity rule" to prevent gaming (Section 2.2, pages 6-9):

$$
(RP) \quad (p^t - p^s) \cdot (x^t - x^s) \leq 0
$$

where:
- $p^s, p^t$ = price vectors at times s and t (s < t)
- $x^s, x^t$ = corresponding demand vectors at times s and t
- The rule ensures bidders cannot increase demand when prices rise

The paper states "A sincere bidder prefers $x^s$ to $x^t$ when prices are $p^s$" and "prefers $x^t$ to $x^s$ when prices are $p^t$". Adding these inequalities yields the revealed preference constraint. The revealed preference activity rule eliminates "parking" strategies where bidders bid on underpriced items to maintain activity, prevents demand reduction and collusive strategies, and works for both substitutes and complements as described in Section 2.2 of the paper.

**✅ IMPLEMENTED**: Activity rule enforcement in CPAManager. Bidders cannot increase demand when prices have increased.

**Implementation Details:**
- ✅ Activity rule validation in `processBid()` function (CPAClockPhase.sol lines 58-63)
- ✅ Historical bid tracking via `bids[msg.sender]` mapping
- ✅ Price change tracking via `changedPrices[]` array
- ✅ Cross-round constraint validation with `ActivityRuleViolation` error
- ✅ Comprehensive test coverage in `test_ActivityRule_ViolationOnPriceIncrease()` and `test_ActivityRule_ValidDemandReduction()`

**Rule Implementation:**
```solidity
for(uint256 i = 0; i < changedPrices.length; i++) {
    // If price increased (changedPrices[i] is true), new demand must be <= previous demand
    if(changedPrices[i] && demands[i] > previousDemands[i]) {
        revert IErrorsAndEvents.ActivityRuleViolation();
    }
}
```

This correctly implements: $x^n \geq x^{n+1} \quad \text{if } p^n < p^{n+1}$

## 2. Missing Intra-Round Bidding

Academic Requirement: The paper describes "intra-round bids" where bidders can express demands at multiple price points within a single round.

Current Implementation: Only supports single price point bidding per round.

Missing:
- `submitIntraRoundBid()` function
- Price interpolation logic
- Multi-point demand expression

### Discussion

I don't think we will implement this in this version. The purpose is to increase revenue, aid price discovery, and reduce total clock rounds but not having it does not compromise the auction as a whole.

## 3. ✅ IMPLEMENTED: Clock Phase Termination Logic

Academic Requirement: Clock phase should end when "there is no excess demand on any item" OR when "revenue improvements are less than ½ percent for two consecutive rounds."

**✅ IMPLEMENTED**: Automatic termination detection with three conditions implemented in `shouldEndClockPhase()`.

Missing:
- Automatic termination detection
- Revenue improvement tracking
- Early termination logic

### Discussion

This will be important to implement. There will be three conditions under which clock phase termination occurs:
1. No excess demand on any item (natural rule)
2. Max clock rounds exceeded (Rok-specific)
3. Revenue improvement is less than 1/2 percent for two consecutive rounds

The first two are easy. The last can be simplified using an Exponential Moving Average (EMA) approach that requires only 1 storage slot instead of 2.

#### Proposition: Simplified Revenue Tracking Implementation

Mathematical Equivalence:
- Stagnation Counter Logic: Terminate if $r_t / r_{t-1} \leq 0.005$ for 2 consecutive rounds
- EMA Equivalent: Terminate if $r_t < R_t \times 0.005$

EMA Formula:
$$
R_t = \alpha \cdot r_t + (1-\alpha) \cdot R_{t-1}
$$

Termination Condition:
$$
r_t < R_t \times 0.005
$$

Benefits:
- Single storage slot instead of tracking last revenue + stagnation counter
- Mathematically equivalent to the stagnation counter approach (I think, need to confirm)
- Configurable weight $\alpha$ (0.5-0.8? err higher) for different auction characteristics. Will probably hardcode.
- Fixed threshold 0.005 (0.5%) regardless of EMA weight

This approach maintains the economic benefits of the stagnation detection while reducing gas costs and storage requirements.

## 4. Missing Proxy Phase Activity Rule

Academic Requirement: "Relaxed revealed-preference activity rule" in proxy phase (Section 4.1, pages 15-16):

$$
(RRP) \quad \alpha[P^t(S) - P^s(S)] \geq P^t(T) - P^s(T)
$$

where
- $P^s(S), P^t(S)$ = package prices for package S at times s and t
- $P^s(T), P^t(T)$ = package prices for package T at times s and t  
- $\alpha > 1$ = relaxation parameter chosen by auctioneer based on competitiveness

Context: The paper states this rule is "too strict when comparing a time s in the clock phase with a time t in the proxy phase" because "bidders have an incentive to reduce demands below their true demands" in the clock phase. The relaxation allows bidders to "undo any inefficient demand reduction" in the proxy phase.

Key Benefits:
- Allows bidders to expand demands in proxy phase to correct clock phase demand reduction
- Prevents collusive splits established in clock phase from being maintained
- Parameter α can be adjusted based on auction competitiveness

Current Implementation: No activity rule in proxy phase.

Missing:
- Relaxed activity rule enforcement
- Parameter α configuration
- Cross-phase constraint validation

### Discussion

We currently do not prohibit demand increases in the proxy phase since the bids submitted during the clock are not kept as viable bundles during the proxy phase. I'm not sure how to approach this yet so for now, we will drop it.

## 5. Missing Bundle Validation Against Clock Bids

Academic Requirement: "All bids in the clock phase are kept live in the proxy round" and bundles must be consistent with clock phase bidding.

Current Implementation: No validation that bundles are consistent with clock phase bids.

Missing:
- Clock bid consistency checking
- Live bid maintenance across phases
- Bundle-to-clock-bid validation

### Discussion

The academic paper's requirement for bundle validation against clock bids represents a technical solution to prevent gaming between phases but this approach fundamentally conflicts with the privacy-preserving nature of the proxy mechanism. The paper's validation scheme would require maintaining explicit connections between clock phase bids and proxy bundles, thereby revealing the hidden relationship between bidders and their proxy agents.

Our current implementation addresses the underlying economic concerns through a more sophisticated mechanism: deposit-based economic incentives. Rather than technical validation, we enforce economic constraints through the deposit system where $D = \max(B_i)$ represents the maximum bid value across all clock phase bids, and the minimum spend ratio $\rho_{min}$ ensures serious participation. If a bidder submits bundles totaling only $\alpha \cdot D$ where $\alpha < \rho_{min}$, they remain liable for the full deposit amount upon allocation, creating stronger incentives than the paper's validation approach.

This economic mechanism is mathematically equivalent to the paper's constraint but operates through financial penalties rather than technical validation. The deposit mechanism ensures that $E[\text{penalty}] \geq (1-\alpha) \cdot D$ when $\alpha < \rho_{min}$, where the expected penalty scales with the degree of gaming. This approach maintains the privacy-preserving properties of the proxy mechanism while providing stronger economic incentives than the paper's technical validation scheme.

## 6. Missing Revenue Maximization in Clock Phase

Academic Requirement: "Find the revenue maximizing assignment and prices from all the bids in the clock phase" when clock phase ends.

Current Implementation: Uses final prices directly.

Missing:
- Revenue maximization algorithm
- Historical bid evaluation
- Optimal price point selection

### Discussion

The academic requirement for revenue maximization represents a combinatorial optimization problem that is computationally intractable for on-chain implementation. The problem requires evaluating all possible price combinations from historical bids and solving the assignment problem for each combination, resulting in exponential complexity that would exceed block gas limits.

For now, we accept suboptimality by using final prices as a reasonable approximation. However, this presents opportunities for future enhancement through two potential approaches:

**Off-chain Integration**: Implement the revenue maximization algorithm off-chain and submit the optimal prices on-chain. This approach maintains the academic specification while avoiding gas constraints, but requires trusted off-chain computation and secure price submission mechanisms.

**Competitive Revenue Maximization Market**: Create an additional competitive phase where "revenue maximizers" compete to submit the optimal revenue-maximizing assignment. This approach leverages market forces to solve the optimization problem, but requires maintaining cryptographic proofs of all historical bids (e.g., through Merkle trees or hash chains) to verify that submitted bids and prices were actually submitted during the clock phase. The challenge lies in balancing the storage costs of maintaining these proofs against the economic benefits of revenue maximization.

Both approaches represent significant implementation complexity beyond the current scope, making the suboptimal final-price approach a pragmatic interim solution.

## 7. Missing Undersell Handling

Academic Requirement: Handle cases where "demand is less than supply" (undersell) in clock phase.

Current Implementation: No undersell detection or handling.

Missing:
- Undersell detection logic
- Supply-demand balance checking
- Undersell resolution mechanism

### Discussion

The academic paper requires undersell detection as a signal to transition from clock phase to proxy phase, not as a problem to solve within the clock phase. When undersell occurs (demand < supply), the auction should use the last valid prices that caused oversell (demand > supply) as the final prices for the proxy phase.

The mechanism works as follows: during normal clock phase operation, track the last prices that caused oversell. At auction close, if the current prices caused undersell, revert to the stored last oversell prices and use these as fixed prices for the proxy phase. This ensures the proxy phase operates at economically sensible prices rather than the failed high prices that caused undersell.

Implementation requires updating the `endClockRound` function to track the last oversell prices during normal operation and checking for undersell at auction close. This approach maintains the normal clock phase flow while cleanly handling the undersell case at the end, requiring minimal changes to the existing codebase while providing the economic benefits of proper undersell handling.

## 8. Missing Price Increment Strategy

Academic Requirement: "Percentage increment could vary linearly with the extent of excess demand, subject to a lower and upper limit."

Current Implementation: Fixed tick increments.

Missing:
- Dynamic increment calculation
- Excess demand-based adjustments
- Min/max increment limits

### Discussion

The academic paper suggests dynamic price increments based on excess demand, but this represents a significant tuning challenge in practice. The implementation would be straightforward but requires careful parameter selection to avoid either too-aggressive price increases (causing premature termination) or too-conservative increases (causing excessive rounds).

The mathematical relationship between excess demand and price increments can be expressed as:

$$\Delta p = \alpha \cdot \text{excess\_demand} + \beta$$

where $\alpha$ is the linear scaling factor and $\beta$ is the base increment, subject to constraints:

$$\Delta p_{min} \leq \Delta p \leq \Delta p_{max}$$

However, since our implementation operates in tick-space rather than price-space, the relationship becomes logarithmic:

$$\Delta \text{tick} = \log_{1.0001}\left(\frac{p + \Delta p}{p}\right)$$

This logarithmic relationship between tick increments and price changes adds complexity to the tuning process, as the relationship between excess demand and tick increments is already non-linear. The parameter space for optimal tuning includes the linear scaling factor $\alpha$, base increment $\beta$, minimum and maximum increment bounds, and the relationship between excess demand measurement and tick-space.

This represents an area for future research as the optimal parameter selection depends on the specific auction characteristics, bidder behavior patterns, and desired auction duration. The academic paper provides the theoretical framework but leaves the practical implementation details as an open research question.

## 9. Missing Collusion Prevention

Academic Requirement: The paper emphasizes preventing "collusive bidding strategies" and "demand reduction."

Current Implementation: No specific collusion prevention measures.

Missing:
- Demand reduction detection
- Collusion prevention mechanisms
- Strategic bidding constraints

### Discussion

This is similar to the bundle validation issue (#5) in that both address gaming prevention but this focuses on collusion within the clock phase rather than between phases. While our deposit mechanism provides economic incentives for truthful bidding across phases, preventing other forms of collusion (such as demand reduction, bid coordination, or strategic demand manipulation) remains an open area for research.

The academic paper provides theoretical frameworks for collusion prevention but the practical implementation of effective anti-collusion mechanisms in decentralized auction systems represents an ongoing research challenge that extends beyond the scope of the current implementation.

## 10. Missing Multi-Round Proxy Phase

Academic Requirement: "Multi-round implementation of the proxy phase" with "fixed dollar increase in all of their bids."

Current Implementation: Single-round proxy phase only.

Missing:
- Multi-round proxy bidding
- Incremental bid authorization
- Ascending proxy auction mechanics

### Discussion

The academic paper's description of the multi-round proxy phase is ambiguous and lacks technical implementation details. While the paper mentions a "multi-round implementation" with "fixed dollar increase in all of their bids," it provides no specification for:

- Number of rounds or termination criteria
- Mechanism for bid updates across rounds
- Process for winner selection in multi-round context
- Relationship between rounds and bundle submission

The paper appears to treat this as a theoretical framework rather than a practical specification and leaves the implementation details as an open question. The concept suggests an ascending proxy auction where bidders can incrementally increase their bundle values but the specific mechanics for how this operates, how rounds are structured, and how the auction terminates remain undefined.

This represents a significant gap between the academic theory and practical implementation, requiring substantial research and design work to develop a concrete multi-round proxy mechanism that maintains the economic properties described in the paper while being implementable in a decentralized system.

## 11. Stuck Auctioneer Deposit on Cancellation

### Problem

When the auctioneer calls `depositAllAndStartClock`, the item tokens are pulled from the auctioneer via `itemCurrency.settle(manager, auctionOwner, depositAmount, false)` and credited to CPAManager as ERC-6909 claim tokens inside the PoolManager (`itemCurrency.take(manager, address(self), depositAmount, true)`). At that point CPAManager holds the ERC-6909 claims; the auctioneer no longer holds the tokens.

If the auction is subsequently cancelled — via `cancelAuction` (onlyAuctionOwner) or `forceCancelAuction` (permissionless after a timeout) — the ERC-6909 claims remain inside the PoolManager with no withdrawal path. The only existing refund mechanism is `reclaimStake`, which returns **bidder** numeraire only and has nothing to do with the auctioneer's deposited items.

The LP positions that would contain the items (minted by `mintSettlementPositions`) have not been created yet at cancel time, so `transferPositionsToAuctioneer` (which transfers LP NFTs) cannot help either.

**Net result**: auctioneer loses deposited items if they cancel after the deposit step.

### Affected code

- `src/libraries/CPASetup.sol` — deposit callback that mints ERC-6909 claims to CPAManager
- `src/facets/CoreFacet.sol` — `cancelAuction` / `forceCancelAuction` set status to Cancelled but do nothing with deposits
- `src/libraries/CPAFinishedPhase.sol` — `transferPositionsToAuctioneer` transfers LP NFTs; only callable in Finished phase; does not cover pre-settlement cancellations
- `src/base/CPAStorage.sol` — `poolInfo[poolId].depositAmount` tracks the deposited amounts

### Fix required

Add a `reclaimDeposit(AuctionId auctionId)` function (callable by auction owner, only when status is Cancelled) that:
1. Iterates `auctionInfo[auctionId].poolKeys`
2. For each pool with a non-zero `poolInfo[poolId].depositAmount`, opens a PoolManager unlock callback to `burn` the ERC-6909 claims and `take` the ERC-20 tokens back to the auction owner
3. Zeroes `poolInfo[poolId].depositAmount` to prevent double-withdrawal

Edge cases to handle:
- Cancel after `transitionToSettlement` has already converted ERC-6909 → ERC-20 and minted LP positions: in this state the LP NFTs exist; `transferPositionsToAuctioneer` already handles this path (called in Finished phase), but it requires being in Finished phase. May need to either (a) allow `transferPositionsToAuctioneer` in Cancelled state too, or (b) add a separate path. Practically, cancellation post-settlement is not currently possible because there is no cancel function that operates in Allocation/Settlement/Finished phases, so this is lower priority.
- Cancel before any deposit: `depositAmount == 0` for all pools, so the function is a no-op.

### Tests needed

- `test_CancelBeforeDeposit_NoStuck`: cancel in Setup phase before deposit → no action needed, verify no revert
- `test_CancelAfterDeposit_ReclaimReturnsItems`: deposit then cancel → `reclaimDeposit` returns exact `depositAmount` of item tokens to auctioneer
- `test_ReclaimDeposit_OnlyWhenCancelled`: calling `reclaimDeposit` in Active auction reverts
- `test_ReclaimDeposit_IdempotentAfterFirstCall`: calling `reclaimDeposit` twice does not double-return

---

## 12. Settlement Pool Open to External Trading; Non-Uniform Claim Price

### Problem — part A: external trading during Settlement

`CPAHook.setPoolState` sets `allowedPools[poolId] = true` when the auction phase is `Settlement` **or** `Finished`:

```solidity
allowedPools[poolId] = (state == AuctionTypes.AuctionPhase.Settlement || state == AuctionTypes.AuctionPhase.Finished);
```

This means from the moment `transitionToSettlement` is called, external users can swap through the pool freely. During Settlement, the LP holds the full item inventory and all bidder claims are still pending. External traders (or MEV bots) can:

- Buy items ahead of bidder claims, raising the price bidders pay
- Sandwich individual `claimAllTokens` transactions
- Drain inventory that bidders are entitled to

The correct behaviour is: the pool should only open to external trading in the **Finished** phase, after all claims are complete and the auctioneer owns the LP positions.

**Fix**: Change the `setPoolState` condition to `allowedPools[poolId] = (state == AuctionTypes.AuctionPhase.Finished)`.

### Problem — part B: non-uniform claim price within the tick

Even with external trading removed, settlement claims are not executed at a perfectly uniform price. The LP position is minted as a **single-tick-spacing-wide** concentrated position (see `CPAAllocationPhase._calculateLiquidityParams`: `tickUpper = tickLower + poolKey.tickSpacing`). Within that one-tick range the standard AMM constant-product curve still applies, so each `claimAllTokens` swap marginally moves the sqrtPrice.

For a pool with `tickSpacing = 60`, the price band across the full tick is approximately `(1.0001)^60 − 1 ≈ 0.6%`. The first bidder to claim pays the price at the bottom of the tick; the last pays up to ~0.6% more (for that tick spacing). Larger tick spacings widen the band proportionally.

This is a minor, bounded deviation from the ideal uniform price that is accepted for now given the single-tick constraint. It is documented here so future versions can consider mitigation (e.g. donate-based price pinning, or minting at an exact sqrtPrice without tick rounding).

### Combined impact of part A + part B

External trading during Settlement compounds the non-uniformity arbitrarily: an arbitrageur front-running a claim can move price far more than the 0.6% intra-tick drift. Part A is the more urgent fix.

### Affected code

- `src/CPAHook.sol` line ~148: `allowedPools[poolId] = (state == AuctionTypes.AuctionPhase.Settlement || state == AuctionTypes.AuctionPhase.Finished)`
- `src/libraries/CPAAllocationPhase.sol` lines ~376–389: `_calculateLiquidityParams` tick range calculation (part B, lower priority)

### Tests needed (Part A — fix external trading gate)

- `test_SettlementPhase_ExternalSwapReverts`: external EOA attempting a swap during Settlement phase should revert with `AuctionOngoing`
- `test_FinishedPhase_ExternalSwapSucceeds`: same EOA attempting a swap after `transitionToFinished` should succeed
- `test_SettlementPhase_AuctionManagerSwapSucceeds`: `claimAllTokens` (which triggers an auctionManager swap) should still work during Settlement after the fix
- `test_SettlementPhase_ExternalAddLiquidityReverts`: confirm `beforeAddLiquidity` also blocks external callers during Settlement (note: currently the `_beforeAddLiquidity` hook body is commented-out for non-auctionManager callers — should be checked and restored or the comment explained)

---

## Summary of Missing Features

1. Activity Rules: Both strict (clock) and relaxed (proxy) revealed preference rules
2. Intra-Round Bidding: Multi-point demand expression within rounds
3. Automatic Termination: Revenue-based and excess demand-based termination
4. Revenue Maximization: Optimal price selection from historical bids
5. Undersell Handling: Supply-demand imbalance resolution
6. Dynamic Pricing: Excess demand-based price increments
7. Collusion Prevention: Anti-gaming and anti-collusion measures
8. Multi-Round Proxy: Ascending proxy auction mechanics
9. Cross-Phase Consistency: Bundle validation against clock bids (superseded by deposit mechanism)
10. Live Bid Maintenance: Keeping all clock bids active in proxy phase (superseded by deposit mechanism)
11. Stuck Auctioneer Deposit on Cancellation: no refund path for deposited items if auction is cancelled post-deposit
12. Settlement Pool External Trading + Non-Uniform Claim Price: pool opens to external traders during Settlement; intra-tick price drift means later claimers pay slightly more

## Implementation Priority

### High Priority (Core Economic Mechanisms)
1. ✅ COMPLETED: Revealed Preference Activity Rule
2. ✅ COMPLETED: Clock Phase Termination Logic
3. Revenue Maximization
4. Undersell Handling

### Medium Priority (Enhanced Functionality)
5. Intra-Round Bidding
6. Dynamic Price Increments
7. Proxy Phase Activity Rule

### Low Priority (Advanced Features)
8. Collusion Prevention
9. Multi-Round Proxy Phase