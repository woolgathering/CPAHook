# Rok CPA Protocol: Finished Phase Audit

**Phase**: Finished (Post-Settlement Cleanup and Stake Recovery)  
**Files Audited**:
- `src/libraries/CPAFinishedPhase.sol`
- `src/facets/FinishedPhaseFacet.sol`
- `src/facets/SettlementMiscFacet.sol` (reclaimStake)
- `src/base/CPAStorage.sol` (FORFEITURE_REWARD_RATE constant)

**Date**: 2026-05-21  
**Summary**: Found 10 distinct problems. Most are design issues around permissionless forfeit mechanics and unclaimed stake lingering. One critical issue inherited from Settlement phase.

---

## Problems Identified

### Problem 1: forfeit() Can Be Called by Anyone (MEDIUM-HIGH)
**Severity**: MEDIUM-HIGH  
**Location**: `src/facets/FinishedPhaseFacet.sol:19-42` (forfeit function)  
**Description**:
The `forfeit()` function is completely permissionless:
```solidity
function forfeit(AuctionId auctionId, address bidder)
    external
    onlyPhase(auctionId, AuctionTypes.AuctionPhase.Finished)
{
    // Only check: phase is Finished
    // No check: who is calling
    // No check: permission to forfeit this bidder
    
    uint256 stake = _clock[auctionId].bidderStake[bidder];
    // ... penalty and reward calculations ...
    NumeraireLib.transfer(numeraire, msg.sender, callerReward);  // Pay caller!
}
```

Anyone can call `forfeit(auctionId, bidder)` to:
1. Seize the bidder's entire stake
2. Collect a 5% reward (`FORFEITURE_REWARD_RATE = 500 bps`)
3. Penalize the bidder with `minSpendRatio` percent of their stake

This creates a race condition. In a Finished phase with unclaimed stakes, the first person to call `forfeit()` on each bidder collects the reward.

**Impact**:
- Bidders who miss the Settlement phase window to claim lose their stakes to the first forfeiter
- Perverse incentive: anyone can profit from bidders' missed deadlines
- Creates "stake hunters" monitoring the auction for Finished phase to call forfeit
- Bidders get griefed out of rewards-free stake recovery via `reclaimStake`

**Real-World Scenario**:
```
Auction enters Finished phase
Bidder A missed Settlement claims → still has 1000 USDC stake

Bot watches for Finished phase, immediately calls forfeit(A)
Bot collects: 50 USDC reward (5%)
Bidder A gets: 850 USDC (1000 - 100 penalty - 50 reward)

If Bidder A had called reclaimStake themselves:
Bidder A would get: 900 USDC (1000 - 100 penalty, no reward to anyone)

Bidder loses 50 USDC purely from being forfeited before they could self-claim
```

### Problem 2: Confusing Penalty Rate Reuse (MEDIUM)
**Severity**: MEDIUM  
**Location**: `src/facets/FinishedPhaseFacet.sol:28` (forfeit)  
**Description**:
The forfeit penalty uses `minSpendRatio` from the auction config:
```solidity
uint256 penaltyRate = auctionInfo[auctionId].config.minSpendRatio;
uint256 penalty = stake * penaltyRate / 10000;
```

The `minSpendRatio` is semantically the *minimum spending requirement* for bidders during the clock phase (enforced via spending violations). Using it as the *forfeit penalty* conflates two separate concepts:

- **During auction**: minSpendRatio = "if you don't spend at least X% of stake, you pay a violation fee"
- **After auction**: minSpendRatio = "if you don't claim in time, you forfeit Y% of stake"

These are different enforcement mechanisms but share a config value. A change to `minSpendRatio` for one purpose affects the other.

**Impact**:
- Confusing semantics: config parameter has dual meaning
- Risk of misconfiguration: auctioneers may not realize minSpendRatio affects both spending validation AND forfeit penalties
- If minSpendRatio is set high for spending enforcement, forfeit penalty becomes unexpectedly harsh
- Couples two independent policy decisions

**Example**:
```
minSpendRatio = 2000 (20%)
Effect 1: Bidders must spend ≥20% of stake or pay penalty
Effect 2: Unclaimed stakes forfeit 20% as penalty if anyone calls forfeit()
Setting is now 2x as important but appears once in config
```

### Problem 3: No Time Limit for Claiming Stake or Forfeiting (MEDIUM)
**Severity**: MEDIUM  
**Location**: `src/facets/FinishedPhaseFacet.sol:19` (forfeit)  
**Description**:
Both `reclaimStake()` and `forfeit()` can be called anytime after the auction enters Finished phase with no expiration:

```solidity
function forfeit(AuctionId auctionId, address bidder)
    external
    onlyPhase(auctionId, AuctionTypes.AuctionPhase.Finished)
    // No time check!
{
    // ...
}
```

This means:
1. Bidders can indefinitely delay calling `reclaimStake()` (no deadline)
2. Anyone can indefinitely delay calling `forfeit()` to hunt for rewards
3. Contract's numeraire stays locked to pay stakes/rewards forever
4. No cleanup period where unclaimed stakes are frozen or released

**Impact**:
- Contract's capital tied up in unclaimed stakes indefinitely
- Cleanup becomes impossible: don't know which stakes are "forgotten" vs "about to be claimed"
- Numeraire balance becomes unpredictable over time
- Exacerbates the multi-auction balance contamination issue (Problem 1 from Settlement phase)

**Real-World Scenario**:
```
Auction A enters Finished 1 year ago, 100 USDC unclaimed
Auction B active now, bidders deposit 100 USDC
Auctioneer can't call returnProceeds because old unclaimed stake is in contract balance
```

### Problem 4: Hardcoded Forfeiture Reward Rate (LOW-MEDIUM)
**Severity**: LOW-MEDIUM  
**Location**: `src/base/CPAStorage.sol:94` (FORFEITURE_REWARD_RATE)  
**Description**:
The forfeiture reward is hardcoded as a constant:
```solidity
uint256 public constant FORFEITURE_REWARD_RATE = 500; // 5% (basis points)
```

It cannot be customized per auction. All auctions use the same 5% reward rate. This means:
1. Auction creators cannot adjust incentives for their specific context
2. Different auction types (high-stakes vs low-stakes) pay same reward
3. If protocol wants to change the rate, it requires a contract upgrade

**Impact**:
- No flexibility for auction-specific forfeiture incentives
- 5% may be too high for some auctions, too low for others
- Creates uniform behavior that may not match all use cases

### Problem 5: forfeit() Not Guarded with nonReentrant (MEDIUM)
**Severity**: MEDIUM  
**Location**: `src/facets/FinishedPhaseFacet.sol:19-42` (forfeit)  
**Description**:
The `forfeit()` function transfers numeraire (potentially ETH) without a reentrancy guard:
```solidity
function forfeit(AuctionId auctionId, address bidder)
    external
    onlyPhase(auctionId, AuctionTypes.AuctionPhase.Finished)
    // No nonReentrant!
{
    // ...
    _clock[auctionId].bidderStake[bidder] = 0;  // Stake zeroed
    _clock[auctionId].bidderBidPoints[bidder] = 0;
    
    NumeraireLib.transfer(numeraire, msg.sender, callerReward);  // ETH transfer
    if (callerReward > 0) emit ForfeitureRewardTransferred(...);
    NumeraireLib.transfer(numeraire, bidder, remaining);  // ETH transfer
}
```

If the numeraire is ETH, the `NumeraireLib.transfer` calls use `.call{value: amount}("")`, which allows reentrancy. A malicious contract as a bidder's address could:
1. Call `forfeit(auctionId, address(this))`
2. During the `transfer` call, receive and reenter
3. The state is already modified (stake zeroed), so re-entry is safe
4. But complex interactions could cause issues

**Impact**:
- Potential reentrancy attack surface for ETH auctions
- While the state zeroing at line 34-35 happens before transfers, the pattern is vulnerable
- Better to use `nonReentrant` for consistency with other phase functions

### Problem 6: reclaimStake Only Available to Bidder Themself (LOW-MEDIUM)
**Severity**: LOW-MEDIUM  
**Location**: `src/facets/SettlementMiscFacet.sol:40-64` (reclaimStake)  
**Description**:
The `reclaimStake()` function can only be called by the bidder themself:
```solidity
function reclaimStake(AuctionId auctionId) external {
    uint256 stake = _clock[auctionId].bidderStake[msg.sender];  // msg.sender must be the bidder
    if (stake == 0) revert InvalidStakeAmount();
    // ...
}
```

There is no delegation mechanism or way for another address (e.g., a key recovery contract, or a proxy) to recover the stake. If the bidder's private key is lost after the auction ends, their stake is permanently inaccessible except via `forfeit()` (which gives them only 85% back).

**Impact**:
- Lost keys = lost stakes (unless someone calls forfeit)
- No on-chain recovery mechanism
- Bidders stuck if they lose access to their address
- Inconsistent with the proxy-based bidding model

**Real-World Scenario**:
```
Bidder A bids through proxy, wins allocation, settles, then loses private key
Bidder A cannot call reclaimStake to recover their stake from Finished phase
Only option: wait for someone else to call forfeit and get 85% back
```

### Problem 7: bidderBidPoints Unnecessarily Zeroed on Stake Recovery (LOW)
**Severity**: LOW  
**Location**: `src/facets/SettlementMiscFacet.sol:66` (reclaimStake) and `FinishedPhaseFacet.sol:35` (forfeit)  
**Description**:
Both `reclaimStake()` and `forfeit()` zero out `bidderBidPoints`:
```solidity
// In reclaimStake:
_clock[auctionId].bidderBidPoints[msg.sender] = 0;

// In forfeit:
_clock[auctionId].bidderBidPoints[bidder] = 0;
```

The `bidderBidPoints` field represents activity from the Clock phase. It's not used in Settlement or Finished phases. Zeroing it here is unnecessary and confusing.

**Impact**:
- State mutation without clear purpose
- Makes code harder to understand
- If future code references bidderBidPoints in Finished phase, it will find zeros
- No functional impact, but indicates unclear design

### Problem 8: No Validation that Finished Phase is Actually Complete (LOW)
**Severity**: LOW  
**Location**: `src/libraries/CPAFinishedPhase.sol:5-14` (validateFinishedPhase)  
**Description**:
The library has a validation function but it's never used:
```solidity
function validateFinishedPhase(
    AuctionId auctionId,
    AuctionTypes.AuctionInfo storage auctionInfo
) internal view {
    if (auctionInfo.currentPhase != AuctionTypes.AuctionPhase.Finished)
        revert IErrorsAndEvents.InvalidPhase(
            AuctionTypes.AuctionPhase.Finished,
            auctionInfo.currentPhase
        );
}
```

This function exists but is not called anywhere. The phase checks are done at the facet level with `onlyPhase()` modifier, making this function redundant.

**Impact**:
- Dead code
- Creates confusion about what validation is necessary
- If the function were called, it would be a useful helper

### Problem 9: reclaimStake Applies Penalty in Finished Phase (MEDIUM - Inherited from Settlement)
**Severity**: MEDIUM  
**Location**: `src/facets/SettlementMiscFacet.sol:55-58` (reclaimStake, Finished phase path)  
**Description**:
As noted in Settlement Phase Audit Problem 5, `reclaimStake()` applies a surprise penalty when called in Finished phase:
```solidity
if (auctionInfo[auctionId].currentPhase != AuctionTypes.AuctionPhase.Finished)
    revert InvalidPhase(AuctionTypes.AuctionPhase.Finished, auctionInfo[auctionId].currentPhase);

uint256 penaltyRate = auctionInfo[auctionId].config.minSpendRatio;
uint256 penalty = stake * penaltyRate / 10000;
uint256 refund = stake - penalty;
```

Bidders who miss the Settlement window get penalized 10% (minSpendRatio) just for missing the time window. This is particularly harsh for non-winners.

**Impact**:
- Non-winners lose stake percentage purely for missing Settlement phase deadline
- Penalty applies even if they had no choice (network congestion, unavailable)
- Contrasts with Settlement phase's design intent (immediate settlement vs delayed recovery)

### Problem 10: Cross-Auction Numeraire Contamination Persists (CRITICAL - Inherited)
**Severity**: CRITICAL  
**Location**: `src/facets/FinishedPhaseFacet.sol:37-39` (forfeit transfers)  
**Description**:
As documented in Settlement Phase Audit Problem 1, the contract uses a single shared numeraire balance for all auctions. The `forfeit()` function transfers from this pool:
```solidity
NumeraireLib.transfer(numeraire, msg.sender, callerReward);
NumeraireLib.transfer(numeraire, bidder, remaining);
```

If multiple auctions are concurrently in Finished phase, one auction's forfeit calls can drain numeraire belonging to other auctions.

**Impact**:
- Multi-auction accounting failure
- Forfeiture of bidders in Auction A could steal from Auction B's bidders
- This is the same fundamental issue as Settlement Phase Problem 1

This is not a Finished-phase-specific issue, but Finished phase participates in it.

---

## Summary Table

| # | Problem | Severity | Location | Issue Type |
|---|---------|----------|----------|-----------|
| 1 | forfeit() permissionless | MEDIUM-HIGH | FinishedPhaseFacet:19-42 | Access control |
| 2 | minSpendRatio dual semantics | MEDIUM | FinishedPhaseFacet:28 | Design flaw |
| 3 | No time limit for claims | MEDIUM | FinishedPhaseFacet:19 | Design flaw |
| 4 | Hardcoded reward rate | LOW-MEDIUM | CPAStorage:94 | Inflexibility |
| 5 | No reentrancy guard | MEDIUM | FinishedPhaseFacet:19-42 | Security gap |
| 6 | No delegation for claims | LOW-MEDIUM | SettlementMiscFacet:40-64 | UX limitation |
| 7 | bidderBidPoints zeroed unnecessarily | LOW | FinishedPhaseFacet:35 | Code clarity |
| 8 | validateFinishedPhase unused | LOW | CPAFinishedPhase:5-14 | Dead code |
| 9 | Finished phase penalty on reclaimStake | MEDIUM | SettlementMiscFacet:55-58 | Design issue |
| 10 | Cross-auction balance contamination | CRITICAL | FinishedPhaseFacet:37-39 | Accounting flaw |

**Critical findings**: 1 (Problem 10 — inherited from Settlement)  
**High findings**: 1 (Problem 1 — permissionless forfeit)  
**Medium findings**: 5  
**Low findings**: 3

---

## Architectural Observations

### Finished Phase Role
The Finished phase is designed to handle post-settlement cleanup:
1. Bidders recover unclaimed stakes via `reclaimStake()`
2. Anyone can seize unclaimed stakes via `forfeit()` for a reward
3. No time limit on either operation

This design assumes bidders will quickly move to Finished and settle, but provides an indefinite window to recover or forfeit stakes.

### Incentive Structure
The forfeiture mechanism creates interesting incentives:
- **For bidders**: Strong incentive to call `reclaimStake()` quickly (before forfeiter gets to them)
- **For stake hunters**: Reward (5%) incentivizes watching for unclaimed stakes
- **For protocol**: Penalty (10%) is collected if forfeit is called

However, the permissionless nature means bidders who *intend* to self-claim lose to whoever calls `forfeit()` first.

### Trust Model
- Bidders must trust the phase timing (Settlement → Finished transition)
- Bidders must claim quickly or risk forfeiture by any third party
- No protection against being griefed by forfeiture attacks
- Finished phase punishes inaction with penalties and rewards

### Design Inconsistencies
1. **Penalty source confusion**: `minSpendRatio` used for both spending enforcement and forfeit penalty
2. **Unlimited time**: Finished phase has no time bounds unlike other phases
3. **Dead validation**: `validateFinishedPhase()` library function is never called
4. **Dual-mode recovery**: `reclaimStake()` works in both Settlement (no reward) and Finished (with penalty)

### Relationship to Settlement Phase
The Finished phase is a safety net for Settlement, providing:
- A fallback recovery mechanism for missed claims
- A forfeiture option to prevent lost stakes from sitting indefinitely
- A cleanup mechanism for the auction lifecycle

However, it doesn't replace the core Settlement flow; it only handles spillover bidders.

---

## Real-World Impact Scenarios

### Scenario 1: Forfeiture Race (HIGH)
Settlement phase ends. Bidder A forgot to claim. First 1000 forfeiture bots race to call `forfeit(auctionId, bidderA)`. Bot wins, collects 50 USDC reward. Bidder A gets remaining 85% of stake instead of 90% if they had self-claimed. Lost: 50 USDC to a bot.

### Scenario 2: Lost Key Cascade (MEDIUM)
Bidder loses private key during Finished phase. Their 1000 USDC stake is stuck. After 6 months, someone forfeits it. Bidder recovers 850 USDC instead of 900 (if they had self-claimed) or 1000 (if they hadn't lost the key). Lost: 150 USDC.

### Scenario 3: Unclear Penalties (MEDIUM)
Auctioneer sets `minSpendRatio = 1500` to enforce 15% spending. Doesn't realize this also sets forfeit penalty to 15%. Unclaimed stakes lose 15% instead of expected 10%. Bidders are shocked.

### Scenario 4: Cross-Auction Drain (CRITICAL)
Auction A enters Finished with 100,000 USDC in unclaimed stakes. Auction B active now, bidders deposit 100,000 USDC. Auction A's auctioneer calls `forfeit()` repeatedly to collect rewards. Contract balance goes to zero. Auction B's bidders' stakes are now unrecoverable.
