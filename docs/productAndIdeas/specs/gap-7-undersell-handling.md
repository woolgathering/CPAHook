# Gap #7: Undersell Handling Implementation Specification

## 1. Problem Statement

The current implementation does not properly track undersell conditions (demand < supply) during the clock phase. The `excessDemand` field is `uint256` and cannot represent negative values, so when demand < supply, it's set to 0, losing the distinction between undersell and exact market clearing.

When the clock phase ends, the system should revert to the last prices (ticks) at which each item was oversold (demand > supply) to ensure the proxy phase operates at economically valid market-clearing prices.

## 2. Current State

**Location:** `src/types/AuctionTypes.sol` (lines 88-97)

`PoolInfo` struct contains:
- `depositAmount` (supply)  
- `excessDemand` (uint256 - cannot represent undersell)
- No `lastOversoldTick` field

**Key Issue:** When demand < supply, `excessDemand` is set to 0, losing information about undersell vs exact clearing.

**Location:** `src/libraries/CPAClockPhase.sol` (lines 195-239)

The `processClockRound` function:
```solidity
pool.excessDemand = totalDemands[i] > pool.depositAmount ? totalDemands[i] - pool.depositAmount : 0;
```
- Cannot distinguish undersell from exact clearing
- Does NOT store last oversold prices

**Location:** `src/CPAManager.sol` (lines 260-271)

`_endClockPhase` function:
- Does NOT check for undersell
- Does NOT revert prices

## 3. Proposed Solution

### 3.1 Design Decision: Per-Item Price Tracking with Signed Excess Demand

**Change 1:** Make `excessDemand` a signed integer (`int256`) to track:
- Positive: oversell (demand > supply)
- Zero: exact clearing (demand == supply)  
- Negative: undersell (demand < supply)

**Change 2:** Track `lastOversoldTick` independently for each pool/item.

**Change 3:** When clock phase ends, revert undersold items to their `lastOversoldTick`.

### 3.2 Implementation Components

#### Component A: State Storage

**File:** `src/types/AuctionTypes.sol`

Modify `PoolInfo` struct (around line 94):

```solidity
struct PoolInfo {
    PoolKey key;
    int24 startingTick;
    int24 priceIncrement;
    uint256 depositAmount;
    int256 excessDemand;        // CHANGED: uint256 -> int256 (can be negative for undersell)
    int24 lastOversoldTick;     // NEW: Last tick where demand > supply
    AuctionId auctionId;
    bytes32 positionId;
}
```

**Rationale:**  
- Signed `excessDemand` eliminates need for separate undersell detection
- `lastOversoldTick` uses tick representation (consistent with Uniswap V4, avoids precision loss)

#### Component B: Tracking Logic

**File:** `src/libraries/CPAClockPhase.sol`

Modify `processClockRound` function (around lines 210-231):

**Current:**
```solidity
pool.excessDemand = totalDemands[i] > pool.depositAmount ? totalDemands[i] - pool.depositAmount : 0;

if (pool.excessDemand > 0) {
    _updatePoolPrice(poolId, pool.key, pool.priceIncrement, self.manager(), auction.commonNumeraire);
    auction.changedPrices[i] = true;
} else {
    auction.changedPrices[i] = false;
}
```

**New:**
```solidity
// Calculate excess demand (can be negative for undersell)
pool.excessDemand = int256(totalDemands[i]) - int256(pool.depositAmount);
poolInfo[poolId].excessDemand = pool.excessDemand;

// If there is excess demand (oversell), increase the price
if (pool.excessDemand > 0) {
    _updatePoolPrice(poolId, pool.key, pool.priceIncrement, self.manager(), auction.commonNumeraire);
    auction.changedPrices[i] = true;
    
    // Track last oversold tick for undersell handling
    (, int24 currentTick, , ) = StateLibrary.getSlot0(self.manager(), poolId);
    poolInfo[poolId].lastOversoldTick = currentTick;
} else {
    auction.changedPrices[i] = false;
}
```

**Rationale:** Update `lastOversoldTick` only when `excessDemand > 0`. On undersell/exact clearing rounds, this field retains the previous oversold tick.

#### Component C: Undersell Detection & Reversion

**File:** `src/libraries/CPAClockPhase.sol`

Add new function (after `shouldEndClockPhase`, around line 337):

```solidity
/**
 * @notice Revert prices to last oversold ticks for any items currently undersold
 * @param auctionId The auction ID
 * @param auctionInfo Storage reference to auction info
 * @param poolInfo Storage reference to pool info  
 * @param poolManager The pool manager instance
 */
function revertUndersoldPrices(
    CPAStorage self,
    AuctionId auctionId,
    AuctionTypes.AuctionInfo storage auctionInfo,
    mapping(PoolId => AuctionTypes.PoolInfo) storage poolInfo,
    IPoolManager poolManager
) internal {
    PoolKey[] memory poolKeys = auctionInfo.poolKeys;
    
    for (uint256 i = 0; i < poolKeys.length; i++) {
        PoolId poolId = poolKeys[i].toId();
        AuctionTypes.PoolInfo storage pool = poolInfo[poolId];
        
        // Check if this item is undersold (excessDemand < 0)
        if (pool.excessDemand < 0 && pool.lastOversoldTick != 0) {
            // Revert to last oversold tick
            (, int24 currentTick, , ) = StateLibrary.getSlot0(poolManager, poolId);
            int24 tickDelta = pool.lastOversoldTick - currentTick;
            
            if (tickDelta != 0) {
                // Use existing price update logic
                _handlePriceUpdateSwap(poolId, pool.key, tickDelta, poolManager, auctionInfo.commonNumeraire, self);
            }
        }
    }
}
```

**Key Change:** Use existing `_handlePriceUpdateSwap` instead of creating new function. Need to verify `_handlePriceUpdateSwap` signature and adapt call.

**Note:** Need to check if `_handlePriceUpdateSwap` exists and can accept negative tick deltas for price decreases. If not, may need to add that functionality.

#### Component D: Integration into Clock Phase Ending

**File:** `src/CPAManager.sol`

**Approach:** Pass `totalDemands` from `endClockRound` to `_endClockPhase` (cleaner, avoids recalculation).

**Modify `endClockRound` (around line 235):**

```solidity
function endClockRound(AuctionId auctionId) 
    external 
    onlyAuctionOwner(auctionId) 
    onlyPhase(auctionId, AuctionTypes.AuctionPhase.Clock) 
{
    CPAClockPhase.setClockOpen(auctionId, 1, auctionInfo);
    
    uint256[] memory totalDemands = CPAClockPhase.processClockRound(
        this, auctionId, auctionInfo, poolInfo, bids, activeBidders
    );
    
    emit IErrorsAndEvents.ClockRoundClosed(
        auctionId, 
        auctionInfo[auctionId].currentRound, 
        activeBidders[auctionId].length
    );

    uint256 currentRevenue = CPAClockPhase.calculateBidValueWithMemoryDemands(
        totalDemands, auctionId, auctionInfo[auctionId], poolInfo, manager
    );
    auctionInfo[auctionId].lastRevenue = currentRevenue;

    if (CPAClockPhase.shouldEndClockPhase(auctionId, auctionInfo[auctionId], poolInfo, totalDemands, manager)) {
        _endClockPhase(auctionId);  // Pass totalDemands no longer needed - use excessDemand instead
    } else {
        _startClockRound(auctionId);
    }
}
```

**Modify `_endClockPhase` (around line 260):**

```solidity
function _endClockPhase(AuctionId auctionId) internal {
    // Close the current clock round if still open
    if (auctionInfo[auctionId].clockOpen == 2) {
        CPAClockPhase.setClockOpen(auctionId, 1, auctionInfo);
        emit IErrorsAndEvents.ClockRoundClosed(
            auctionId, 
            auctionInfo[auctionId].currentRound, 
            activeBidders[auctionId].length
        );
    }
    
    // NEW: Handle undersell by reverting to last oversold prices
    CPAClockPhase.revertUndersoldPrices(this, auctionId, auctionInfo[auctionId], poolInfo, manager);
    
    // Transition to proxy phase
    _changePhase(auctionId, AuctionTypes.AuctionPhase.Proxy);
}
```

**Update `endClockPhase` (manual ending, around line 277):**

```solidity
function endClockPhase(AuctionId auctionId) 
    external 
    onlyAuctionOwner(auctionId) 
    onlyPhase(auctionId, AuctionTypes.AuctionPhase.Clock) 
{
    _endClockPhase(auctionId);  // No changes needed - excessDemand already calculated
}
```

**Rationale:** Since `excessDemand` is now signed and stored in `poolInfo`, we don't need to pass `totalDemands` around. The undersell condition is directly readable from `pool.excessDemand < 0`.

## 4. Implementation Checklist

### Phase 1: State Storage (1 file)
- [ ] Change `excessDemand` from `uint256` to `int256` in `PoolInfo` struct
- [ ] Add `lastOversoldTick` field to `PoolInfo` struct in `src/types/AuctionTypes.sol`

### Phase 2: Update Excess Demand Calculation (1 file)
- [ ] Modify `processClockRound` in `src/libraries/CPAClockPhase.sol` to calculate signed `excessDemand`
- [ ] Update `lastOversoldTick` when `excessDemand > 0`

### Phase 3: Undersell Detection (1 file)
- [ ] Add `revertUndersoldPrices` function to `src/libraries/CPAClockPhase.sol`
- [ ] Verify/adapt `_handlePriceUpdateSwap` for negative tick deltas (price decreases)

### Phase 4: Integration (1 file)
- [ ] Update `_endClockPhase` in `src/CPAManager.sol` to call `revertUndersoldPrices`
- [ ] No changes needed to `endClockRound` or `endClockPhase` (excessDemand now signed)

### Phase 5: Fix Type Mismatches
- [ ] Update all code that reads `excessDemand` to handle `int256` instead of `uint256`
- [ ] Update `shouldEndClockPhase` logic (if it checks `excessDemand == 0`)

### Phase 6: Testing
- [ ] Test normal flow: prices revert correctly on undersell
- [ ] Test edge case: no undersell (all items oversold or exact match)
- [ ] Test edge case: mixed state (some items undersold, some oversold)
- [ ] Test edge case: `lastOversoldTick` is zero (never had oversell)
- [ ] Test edge case: exact clearing (excessDemand == 0) should NOT revert
- [ ] Test price reversion: verify tick delta calculations
- [ ] Test integration: verify proxy phase uses reverted prices

## 5. Edge Cases & Considerations

### 5.1 First Round Undersell
If the first round ends with undersell (no excess demand ever existed):
- `lastOversoldTick` will be `0` (default value)
- `revertUndersoldPrices` checks `pool.lastOversoldTick != 0` before reverting
- **Result:** Prices stay at initial values (correct - these were the starting prices)

### 5.2 Exact Market Clearing
With signed `excessDemand`:
- `excessDemand == 0` → exact clearing, do NOT revert
- `excessDemand < 0` → undersell, revert to `lastOversoldTick`
- **Result:** Only true undersell triggers reversion, exact clearing preserves current prices

### 5.3 Price Reversion Mechanics
`_handlePriceUpdateSwap` should support negative tick deltas to decrease prices. Verify:
- Swap direction flips correctly for price decreases
- Liquidity requirements are met
- Fee handling is appropriate

### 5.4 Gas Costs
`revertUndersoldPrices` loops over all pools and may execute multiple swaps:
- Cost: ~50-100k gas per swap
- For N pools with M undersold: ~50k * M gas  
- **Acceptable:** Clock phase ending is infrequent, gas cost justified for economic correctness

### 5.5 Initialization
Ensure `lastOversoldTick` is initialized to `0` when pools are created in `src/libraries/CPASetup.sol`. Default struct initialization handles this.

### 5.6 Type Compatibility
Changing `excessDemand` from `uint256` to `int256` may affect:
- Event emissions that log `excessDemand`
- External contracts/interfaces that read `excessDemand`
- Arithmetic operations (ensure proper casting)

## 6. Files to Modify

| File | Changes | Lines Affected |
|------|---------|----------------|
| `src/types/AuctionTypes.sol` | Change `excessDemand` to `int256`, add `lastOversoldTick` | ~94-95 |
| `src/libraries/CPAClockPhase.sol` | Update `processClockRound` for signed excess demand + tracking | ~220-231 |
| `src/libraries/CPAClockPhase.sol` | Add `revertUndersoldPrices` function | New (~30 lines) |
| `src/libraries/CPAClockPhase.sol` | Update `shouldEndClockPhase` (if checks excessDemand) | ~303-312 |
| `src/CPAManager.sol` | Update `_endClockPhase` to call revert function | ~260-271 |
| Various | Fix type mismatches for `excessDemand` reads | TBD |

Total: 3-4 files, ~50 new lines, ~20 modified lines

## 7. Testing Strategy

Create new test file: `test/CPAUndersellHandling.t.sol`

Test scenarios:
1. **Normal undersell:** 2 items, round 1 oversell both, round 2 undersell both → verify reversion to round 1 ticks
2. **Mixed undersell:** 3 items, round 1 oversell all, round 2 undersell items 1&2 but not 3 → verify selective reversion
3. **No undersell:** All items remain oversold → verify no reversion
4. **Exact clearing:** Round ends with `excessDemand == 0` → verify NO reversion (keep current prices)
5. **First round undersell:** Start auction, first round undersells → verify prices stay at initial values
6. **Multiple rounds:** 3 rounds, various over/undersell patterns → verify each item tracks its own last oversold tick
7. **Signed arithmetic:** Verify negative `excessDemand` values are stored/read correctly
8. **Integration:** Full auction flow with undersell → verify proxy phase uses correct prices

Existing tests to update:
- `test/CPAClockPhase.t.sol`: Update assertions for signed `excessDemand`, add `lastOversoldTick` checks
- `test/CPACompleteFlow.t.sol`: Add undersell scenario to integration tests
- Any tests that read `excessDemand` and expect `uint256`

## 8. Open Questions

1. **Does `_handlePriceUpdateSwap` exist?** Need to verify in codebase. If not, may need to use existing price update mechanism or create helper.
2. **Can `_handlePriceUpdateSwap` accept negative tick deltas?** Need to verify logic supports price decreases.
3. **Are there events that emit `excessDemand`?** Need to update event signatures if they exist.
4. **External interfaces?** Check if `ICPAManager` or other interfaces expose `excessDemand` type.

