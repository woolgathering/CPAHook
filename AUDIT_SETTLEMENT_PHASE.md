# Rok CPA Protocol: Settlement Phase Audit

**Phase**: Settlement (Claims, Reveals, and Proceeds)  
**Files Audited**:
- `src/libraries/CPASettlementPhase.sol`
- `src/facets/SettlementPhaseFacet.sol` (SettlementClaimFacet)
- `src/facets/SettlementMiscFacet.sol`
- `src/facets/ProceedsFacet.sol`
- `src/libraries/NumeraireLib.sol`
- `src/utils/CommitReveal.sol`

**Date**: 2026-05-21  
**Summary**: Found 11 distinct problems. Two are critical-to-high severity and represent genuine funds-at-risk scenarios under normal usage.

---

## Problems Identified

### Problem 1: returnProceeds Drains Contract-Wide Numeraire Balance (CRITICAL)
**Severity**: CRITICAL  
**Location**: `src/facets/ProceedsFacet.sol:39-41` (returnProceeds)  
**Description**:
The proceeds calculation queries the contract's entire token balance rather than per-auction amounts:

```solidity
function returnProceeds(AuctionId auctionId) external {
    // ...
    uint256 totalNumeraire = NumeraireLib.balanceOf(numeraire, address(this));  // ENTIRE contract balance
    uint256 reserved = _settlement[auctionId].protocolAccrued;                 // Only THIS auction's reserves
    uint256 proceeds = totalNumeraire > reserved ? totalNumeraire - reserved : 0;
    // Sends almost everything to this one auctioneer
}
```

The CPAManager is a diamond proxy that hosts multiple concurrent auctions. All numeraire from all auctions accumulates in the same contract address. When `returnProceeds` is called for auction A, it:
1. Queries total USDC in contract (belongs to auctions A, B, C, ...)
2. Subtracts only auction A's `protocolAccrued`
3. Transfers everything else to auction A's auctioneer

This allows auction A's auctioneer to drain funds belonging to other auctions.

**Impact**:
- A malicious auctioneer could drain all numeraire from all concurrent auctions
- Even non-malicious use: calling returnProceeds while other auctions have staked bidders is destructive
- Affected parties: all bidders in all concurrent auctions lose their stakes
- Affects any same-token-numeraire auctions running concurrently

**Real-World Scenario**:
```
Auction A: 100 bidders × 1000 USDC stake = 100,000 USDC
Auction B: 50 bidders  × 2000 USDC stake = 100,000 USDC
Contract balance: 200,000 USDC

Auction A auctioneer calls returnProceeds():
    totalNumeraire = 200,000
    reserved = 500 (auction A's protocolAccrued)
    proceeds = 199,500 → sent to auction A's auctioneer

Auction B bidders try to claim/get refunds: contract has 500 USDC, not 100,000
```

### Problem 2: ETH Shortfall Path Permanently Breaks Claims (HIGH)
**Severity**: HIGH  
**Location**: `src/libraries/CPASettlementPhase.sol:127-130` (_settleWinner)  
**Description**:
When a winning bidder's debt exceeds their stake, the code attempts to pull the difference:

```solidity
if (totalDebt > stake) {
    uint256 shortfall = totalDebt - stake;
    NumeraireLib.transferFrom(auctionInfo.commonNumeraire, bidder, shortfall, 0);  // msgValue=0 always
    stake += shortfall;
}
```

For ETH numeraire (`address(0)`), NumeraireLib.transferFrom requires `msgValue == amount`:
```solidity
function transferFrom(address token, address from, uint256 amount, uint256 msgValue) internal {
    if (amount == 0) return;
    if (token == address(0)) {
        require(msgValue == amount, "ETH amount mismatch");  // REVERTS if shortfall > 0
    }
}
```

Since `claimAllTokens` is NOT payable, `msg.value == 0` always, and the hardcoded `0` is passed as `msgValue`. Any shortfall in an ETH auction causes a revert.

**Impact**:
- Winners in ETH auctions who have stake < totalDebt are permanently stuck
- Their claim always reverts; they can never access their allocated assets
- Their stake is also inaccessible (already zeroed before the revert, then there's no revert protection before the transfer path)
   
   Actually wait — stake is zeroed at line 116 before checking shortfall at line 127. If the revert happens at line 129, the state change at line 116 (`clockState.bidderStake[bidder] = 0`) was already made in memory but since the whole transaction reverts, the EVM rolls back state. So the stake is NOT permanently lost — the bidder can try to call again with a non-shortfall scenario or wait for Finished phase to use `reclaimStake`. But they can never claim their allocated assets.

**Impact**:
- Winning bidders in ETH auctions with stake < cost cannot claim their allocated assets
- Their allocated assets remain locked in the contract forever
- The assets can be recovered via returnProceeds (by auctioneer) but the bidder loses their allocation
- Affects the core winning-bidder settlement flow

**Conditions where shortfall occurs**:
- Proxy submits bundle with higher quantities than bidder anticipated
- Protocol fee raises total debt above staked amount
- Spending violation adds to totalDebt beyond stake

### Problem 3: returnProceeds Callable During Settlement Phase (HIGH)
**Severity**: HIGH  
**Location**: `src/facets/ProceedsFacet.sol:28-31` (returnProceeds)  
**Description**:
The function is available during both Settlement and Finished phases:
```solidity
if (
    info.currentPhase != AuctionTypes.AuctionPhase.Settlement &&
    info.currentPhase != AuctionTypes.AuctionPhase.Finished
) revert InvalidPhase(AuctionTypes.AuctionPhase.Settlement, info.currentPhase);
```

If an auctioneer calls `returnProceeds` during the Settlement phase while bidders are still claiming:
1. All remaining numeraire is transferred to the auctioneer (minus protocolAccrued)
2. Bidders who haven't claimed yet find the contract empty
3. They lose their stakes AND their refunds

**Impact**:
- Bidders who haven't yet called `reveal()` and `claimAllTokens()` lose all funds
- Non-winner bidders who rely on stake refunds are affected
- Winner bidders can't pay for their assets (ETH transferFrom fails)
- Should be restricted to Finished phase only

### Problem 4: revealedMappings Not Cleared After Claim (LOW-MEDIUM)
**Severity**: LOW-MEDIUM  
**Location**: `src/facets/SettlementPhaseFacet.sol:44-48` (claimAllTokens)  
**Description**:
After a successful claim, `winningBundleIds[commitHash]` is zeroed to prevent double-spend:
```solidity
winningBundleIds[commitHash] = BundleId.wrap(0);
```

However, `revealedMappings[commitHash]` is NOT cleared. This means:
1. Bidder reveals → `revealedMappings[commitHash] = bidder`
2. Bidder claims → stake refunded/assets transferred, `winningBundleIds` zeroed
3. Bidder claims again → `revealedMappings` still maps to bidder, passes validation
4. `winningBundleIds[commitHash] == 0` → goes to non-winner path
5. `clockState.bidderStake[bidder] == 0` → refunds nothing and returns

The double-claim is safe but silently succeeds instead of reverting. This is confusing and could mask bugs.

**Impact**:
- No funds lost (second claim is a no-op)
- But no revert on repeated claims creates confusion
- Downstream code that calls `claimAllTokens` programmatically may not detect the double-call
- Better to revert explicitly on re-claim

### Problem 5: reclaimStake Applies Penalty to Non-Claimers in Finished Phase (MEDIUM)
**Severity**: MEDIUM  
**Location**: `src/facets/SettlementMiscFacet.sol:72-92` (reclaimStake)  
**Description**:
Bidders who don't call `reveal()` and `claimAllTokens()` during Settlement phase lose access to the normal claim flow. In Finished phase, they must use `reclaimStake()` which applies a penalty:
```solidity
uint256 penaltyRate = auctionInfo[auctionId].config.minSpendRatio;
uint256 penalty = stake * penaltyRate / 10000;
uint256 refund = stake - penalty;

_settlement[auctionId].protocolAccrued += penalty;
_clock[auctionId].bidderStake[msg.sender] = 0;
NumeraireLib.transfer(numeraire, msg.sender, refund);
```

Non-winner bidders who miss the settlement window lose `minSpendRatio` percent of their entire stake as penalty.

**Impact**:
- Non-winner bidders get penalized purely for missing the time window
- The penalty is proportional to their stake, not proportional to any violation
- This may be intentional to incentivize timely reveals, but it's a significant punishment for bidders who simply didn't know the Settlement phase had ended
- No grace period or warning mechanism

**Design Question**: Is it intended that non-winners lose stake by missing the Settlement window? Or is this a bug where `reclaimStake` should not apply a penalty to non-winners?

### Problem 6: No Reentrancy Guard on claimAllTokens (MEDIUM)
**Severity**: MEDIUM  
**Location**: `src/facets/SettlementPhaseFacet.sol:31-48` (claimAllTokens)  
**Description**:
The `claimAllTokens` function does NOT have the `nonReentrant` modifier:
```solidity
function claimAllTokens(AuctionId auctionId, bytes32 commitHash)
    external
    whenAuctionActive(auctionId)
    onlyPhase(auctionId, AuctionTypes.AuctionPhase.Settlement)  // No nonReentrant!
```

The function transfers ETH and ERC20 tokens to the bidder before zeroing `winningBundleIds`:
```solidity
// Library: transfers happen first
_transferAssets(bidder, auctionId, bundle.quantities, auctionInfo.assets, settlementState);
uint256 refund = stake - totalDebt;
if (refund > 0) {
    NumeraireLib.transfer(auctionInfo.commonNumeraire, bidder, refund);  // ETH transfer here
}

// Facet: zero the bundleId AFTER library returns
winningBundleIds[commitHash] = BundleId.wrap(0);
```

If a bidder has a malicious contract that calls `claimAllTokens` again during the ETH refund transfer (via `receive()`), the reentrant call would find:
- `revealedMappings[commitHash] == bidder` ✓
- `winningBundleIds[commitHash] != 0` ✓ (not zeroed until after library returns)
- `clockState.bidderStake[bidder] == 0` (already zeroed inside library)

The reentrant call would re-enter with stake=0, but `totalCost` still computed correctly. Then `totalDebt > stake` would trigger the shortfall path, which for ETH would revert. For ERC20 it might attempt a transferFrom with amount=totalDebt.

**Impact**:
- For ETH numeraire: reentrancy would revert (shortfall path breaks it)
- For ERC20 numeraire: reentrancy would attempt to double-pull assets from the bidder
- The interaction between `winningBundleIds` zeroing being in the facet (after library call) and ETH transfer being in the library creates a TOCTOU gap

**Mitigation**: Add `nonReentrant` to `claimAllTokens`.

### Problem 7: dropoutSlashRatio Config Defined But Not Applied in Settlement (MEDIUM)
**Severity**: MEDIUM  
**Location**: `src/types/AuctionTypes.sol:79` (AuctionConfig struct)  
**Description**:
The AuctionConfig includes a `dropoutSlashRatio`:
```solidity
struct AuctionConfig {
    // ...
    uint256 dropoutSlashRatio;          // Dropout penalty ratio (basis points)
    // ...
}
```

And there's a `spendingViolationSlashRatio` too. The `_computeViolation` function only applies `minSpendRatio` as a spending violation. The `dropoutSlashRatio` is defined in the config but:
1. Not applied anywhere in Settlement phase
2. Not applied anywhere in the dropout path in Clock phase (to verify)

If `dropoutSlashRatio` is meant to penalize bidders who drop out, this is unimplemented. If it's legacy, the field creates confusion about what penalties actually apply.

**Impact**:
- Missing penalty mechanism if dropout slash was intended
- Config field misleads readers about actual enforcement
- Users setting `dropoutSlashRatio` would expect it to take effect, but it doesn't

### Problem 8: claimAllTokens Does Not Validate msg.sender Is the Bidder's Revealed Address (LOW-MEDIUM)
**Severity**: LOW-MEDIUM  
**Location**: `src/libraries/CPASettlementPhase.sol:61-66` (claimAllTokens)  
**Description**:
The claim validation checks:
```solidity
address revealedBidder = settlementState.revealedMappings[commitHash];
if (revealedBidder == address(0))
    revert IErrorsAndEvents.CommitHashNotYetRevealed(auctionId, commitHash);
if (revealedBidder != bidder) revert IErrorsAndEvents.Unauthorized();
```

Where `bidder = msg.sender` (passed from facet). The flow is:
1. Bidder reveals via `reveal(auctionId, proxy, saltA, saltB)` — reveals their identity linked to commitHash
2. Now `revealedMappings[commitHash] = bidder`
3. Anyone who knows `commitHash` can call `claimAllTokens(auctionId, commitHash)` — but it checks `msg.sender == revealedBidder`

The check is correct. However, the `commitHash` parameter is public (emitted in events), so a third party could call `claimAllTokens(auctionId, commitHash)`. This would fail at `revealedBidder != bidder` check since `msg.sender` would be the third party, not the actual bidder.

**Real concern**: After reveal, the bidder's tokens/stake refund can ONLY be claimed by calling `claimAllTokens` from the bidder address itself. There's no delegation mechanism. If a bidder's private key is lost after the reveal step, their assets are permanently locked (no proxy claim allowed).

**Impact**:
- No way to delegate claim to another address
- If bidder address is compromised after reveal, funds are at risk from the compromised address
- No mechanism for proxy-assisted claim (ironic, given the protocol's proxy model)

### Problem 9: Protocol Fee Double-Counts Violation Penalty (MEDIUM)
**Severity**: MEDIUM  
**Location**: `src/libraries/CPASettlementPhase.sol:119-124` and `142-155` (_settleWinner and _computeViolation)  
**Description**:
In `_settleWinner`, both the protocol fee and the spending violation are accumulated into `protocolAccrued`:
```solidity
uint256 totalCost = _computeTotalCost(...);
uint256 protocolFee = (totalCost * protocolFeeBps) / 10000;
uint256 violation = _computeViolation(...);  // Also adds to protocolAccrued internally
settlementState.protocolAccrued += protocolFee;
totalDebt = totalCost + protocolFee + violation;
```

Inside `_computeViolation`:
```solidity
function _computeViolation(...) private returns (uint256 violation) {
    uint256 minSpend = (minSpendRatio * stake) / 10000;
    if (totalCost < minSpend) {
        violation = minSpend - totalCost;
        settlementState.protocolAccrued += violation;  // Added inside function
        emit IErrorsAndEvents.PenaltyApplied(auctionId, bidder, violation);
    }
}
```

The issue is that `violation` is added to `protocolAccrued` inside `_computeViolation`, AND `totalDebt = totalCost + protocolFee + violation` is what the bidder actually pays. The bidder does pay the full `totalDebt`. But looking at `returnProceeds`:

```solidity
uint256 proceeds = totalNumeraire > reserved ? totalNumeraire - reserved : 0;
```

`reserved = protocolAccrued = protocolFee + violation` — so these amounts are correctly reserved for the protocol. However, if `totalDebt > stake` path is followed and the bidder pays more via `transferFrom`, that payment goes into the contract's general balance — it's not separately tracked. The accounting is:

- Contract receives: `shortfall` via transferFrom
- `proceeds = totalNumeraire - protocolAccrued` would include this shortfall in proceeds

This could cause violation/shortfall payments to partially go to the auctioneer instead of being cleanly split between auctioneer and protocol.

**Impact**:
- Ambiguous accounting when shortfall occurs
- Violation and fee payments may not fully stay in protocolAccrued

### Problem 10: Allocator Reward Not Sourced From a Tracked Fund (MEDIUM)
**Severity**: MEDIUM  
**Location**: `src/facets/SettlementMiscFacet.sol:22-34` (claimAllocatorReward)  
**Description**:
The allocator reward is set at auction creation (stored in `auctionInfo[auctionId].allocatorReward`) and claimed via:
```solidity
uint256 reward = auctionInfo[auctionId].allocatorReward;
auctionInfo[auctionId].allocatorReward = 0;
NumeraireLib.transfer(auctionInfo[auctionId].commonNumeraire, winningAllocator, reward);
```

The reward is transferred from the contract's general numeraire balance but `allocatorReward` was never formally deposited into the contract. There's no corresponding deposit step that brings `allocatorReward` worth of numeraire into the contract.

**Questions**:
- Where does the numeraire backing `allocatorReward` come from?
- Is it expected to come from the bid stakes (numeraire bidders deposit)?
- Is the auctioneer supposed to have deposited it during setup?

If the reward is purely drawn from bid stakes, it reduces proceeds to the auctioneer but creates no accounting entry. The reward amount is taken from general balance just like proceeds, creating the same multi-auction cross-contamination issue as Problem 1.

**Impact**:
- Allocator reward may pull from other auctions' funds
- No explicit deposit/tracking for the reward amount
- Reward could be over-drawn if other auctions' funds are used

### Problem 11: No Deadline for Reveal Before Claim (LOW)
**Severity**: LOW  
**Location**: `src/facets/SettlementPhaseFacet.sol:19-28` (reveal)  
**Description**:
There is no enforced ordering between `reveal()` and the phase transition to Settlement. A bidder can:
1. Reveal during Settlement phase
2. Immediately claim in the same block

But there's also no requirement that a bidder reveals before the phase ends. If they reveal and claim in the same block, this is fine. However, there's no atomicity guarantee — reveal and claim are two separate transactions.

More importantly: a bidder who hasn't yet revealed cannot claim. If the network is congested during the Settlement phase window, bidders may not have time to submit both reveal and claim transactions. There's no mechanism to pause settlement for missing reveals.

**Impact**:
- Two-transaction reveal+claim creates a timing risk under congestion
- No mechanism to extend settlement for bidders who couldn't reveal in time
- This connects to Problem 5 (penalty for late/missed claims)

---

## Summary Table

| # | Problem | Severity | Location | Issue Type |
|---|---------|----------|----------|-----------|
| 1 | returnProceeds drains all auctions | CRITICAL | ProceedsFacet:39-41 | Accounting flaw |
| 2 | ETH shortfall breaks claims | HIGH | SettlementPhase:127-130 | Logic bug |
| 3 | returnProceeds callable in Settlement | HIGH | ProceedsFacet:28-31 | Access control |
| 4 | revealedMappings not cleared | LOW-MEDIUM | SettlementClaimFacet:44-48 | State hygiene |
| 5 | reclaimStake penalizes non-claimers | MEDIUM | SettlementMiscFacet:72-92 | Design issue |
| 6 | No reentrancy guard on claimAllTokens | MEDIUM | SettlementClaimFacet:31-48 | Security gap |
| 7 | dropoutSlashRatio defined but unused | MEDIUM | AuctionTypes:79 | Dead config |
| 8 | No delegation for claim | LOW-MEDIUM | SettlementPhase:61-66 | UX limitation |
| 9 | Protocol fee accounting on shortfall | MEDIUM | SettlementPhase:119-155 | Accounting |
| 10 | Allocator reward not tracked as deposit | MEDIUM | SettlementMiscFacet:22-34 | Accounting |
| 11 | No reveal deadline before claim | LOW | SettlementClaimFacet:19-28 | Timing |

**Critical findings**: 1 (Problem 1 — contract-wide balance drain)  
**High findings**: 2 (Problems 2, 3)  
**Medium findings**: 5  
**Low findings**: 3

---

## Architectural Observations

### Settlement Phase Role
The Settlement phase handles three distinct operations:
1. **Reveal**: Bidders disclose their identity (bidder address ↔ commitHash)
2. **Claim**: Winners collect allocated assets, non-winners get stake refunds
3. **Proceeds**: Auctioneer collects numeraire and unsold assets; protocol collects fees

These operations are largely independent but share the same numeraire pool, which is the root cause of Problem 1.

### Critical Cross-Cutting Issue: Numeraire Accounting
The entire settlement phase assumes a single-auction deployment or per-auction numeraire isolation that doesn't exist. The contract-wide balance approach works for a single active auction but breaks with concurrent auctions. This suggests either:
- The protocol was designed for single-auction-at-a-time deployment (not matching diamond proxy intent)
- Or per-auction numeraire accounting was planned but not implemented

### ETH Numeraire Second-Class Support
Multiple problems interact specifically with ETH numeraire:
- Problem 2: Shortfall path breaks for ETH (non-payable claimAllTokens)
- Problem 6: Reentrancy via ETH `.call` in NumeraireLib.transfer

ERC20 numeraire does not have these issues, suggesting ETH support was added without full analysis of the settlement flow.

### Trust Model
- Bidders must trust the auctioneer not to call returnProceeds early (Problem 3)
- Bidders must trust other auctioneers not to drain their funds (Problem 1)
- No time-lock or escrow protects bidder funds post-Settlement start

### Integration Points
- **From Allocation**: `winningBundleIds` mapping set during selectWinner
- **From Clock**: `bidderStake` used for refunds/payment
- **From Proxy**: `commitProxy` and `bundles` accessed during reveal/claim
- **To Finished**: Remaining asset balances and unclaimed stakes persist
