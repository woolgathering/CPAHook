# Rok

Rok is a privacy-preserving auction protocol built on Uniswap V4 hooks that enables efficient multi-item token auctions with commit-reveal privacy and allocator competition.

## Overview

Rok implements a Clock-Proxy Auction (CPA) system that leverages hooks and the singleton architecture of Uniswap V4. Clock-proxy auctions are established systems for combinatorial price discovery, proven in complex asset distributions across traditional finance. See [The Clock-Proxy Auction: A Practical Combinatorial Auction Design](https://web.stanford.edu/~milgrom/publishedarticles/clock-proxy-auction.pdf) or [Clock Auctions, Proxy Auctions, and Possible Hybrids](https://wireless.fcc.gov/auctions/conferences/combin2003/presentations/ausubel-hybrid-clock-proxy-auctions.ppt) for more information.

The system addresses the need for institutional-grade auction mechanisms in DeFi by providing combinatorial price discovery through iterative bidding with privacy-preserving commit-reveal mechanisms and competitive allocation determination. The architecture uses two contracts: **CPAManager** (an EIP-2535 Diamond) handles all auction logic and state, while **CPAHook** controls Uniswap V4 pool access during active auctions.

A proper whitepaper is forthcoming.

### Key Features

- **Privacy-Preserving Bidding**: Two-salt commit-reveal scheme maintains bidder–proxy anonymity throughout the auction
- **Multi-Asset Auctions**: Support for auctions spanning multiple token pairs sharing a single numeraire
- **Allocator Competition**: On-chain scoring rewards the allocator that submits the highest-value bundle assignment
- **Batch Settlement**: Single-call `claimAllTokens()` claims all allocated tokens in one transaction
- **Uniswap V4 Integration**: CPAHook gates pool operations by auction phase; assets settle as Uniswap V4 LP positions

## Architecture

Rok is composed of two contracts that work together: **CPAManager** and **CPAHook**.

### CPAManager — EIP-2535 Diamond Proxy

`CPAManager` is an [EIP-2535 Diamond](https://eips.ethereum.org/EIPS/eip-2535) proxy. All shared protocol state (auction info, bids, bundles, allocations, settlement data) lives in the diamond's storage via `CPAStorage`. Incoming calls are dispatched at runtime to one of **21 registered facets** via `delegatecall` through the fallback function, so each facet executes against the diamond's own storage. Ownership controls the facet set via `diamondCut`; renouncing ownership permanently locks it. A separate `setCallbackFacets` mechanism registers **5 callback sub-facets** that are dispatched by `CallbackRouterFacet` based on an operation-type byte, keeping the Uniswap V4 `unlockCallback` path modular.

### CPAHook — Uniswap V4 Hook

`CPAHook` is a standalone `BaseHook` whose address is mined at deploy time so the required permission flag bits are encoded directly in the contract address. It registers `beforeInitialize`, `beforeSwap`, `beforeAddLiquidity`, `beforeRemoveLiquidity`, and `beforeDonate` hooks. While a pool is under an active auction (phase is not `Settlement` or `Finished`), the hook blocks all external swaps and liquidity changes, reserving those operations for CPAManager. Once Settlement or Finished is reached the pool opens to normal trading.

### Facet Groups

The 21 diamond facets cover the full auction lifecycle:

| Group | Facets | Responsibility |
|---|---|---|
| **Admin** | `CoreFacet` | Pause/unpause auctions, cancel, update hook address |
| **Setup** | `SetupFacet`, `SetupFinalizeFacet`, `DepositFacet` | Auction creation, pool registration, asset deposits |
| **Clock** | `ClockPhaseFacet`, `ClockBidFacet`, `ClockBidderFacet`, `ClockEndFacet`, `ClockEndRoundFacet`, `ClockFinalizeRoundFacet` | Iterative clock-auction bidding: submit bids, process round demand, finalize prices |
| **Proxy** | `ProxyPhaseFacet` | Proxy bundle submission |
| **Allocation** | `AllocationPhaseFacet`, `AllocationSubmitFacet` | Allocator competition; select winning bundle set |
| **Settlement** | `SettlementTransitionFacet`, `SettlementTransferFacet`, `SettlementMintFacet`, `SettlementPhaseFacet`, `SettlementMiscFacet`, `FinishedPhaseFacet` | Asset conversion, LP position minting, token claiming, penalties |
| **Callbacks** | `CallbackRouterFacet` + 5 sub-facets | Handle Uniswap V4 `unlockCallback` for deposits, bids, claims, refunds, settlement |
| **Orchestration** | `AuctionFlowFacet` | Single-call convenience wrappers: `createAuction`, `endClockRound`, `transitionToSettlement` |
| **Math** | `MathFacet` | Pure computation contract (deployed separately; address stored in diamond storage) |

## Commit-Reveal Privacy System

The auction uses a **two-salt commit-reveal** scheme to maintain bidder–proxy anonymity. The commit hash is computed off-chain as:

```solidity
bytes32 innerHash1 = keccak256(abi.encode(bidderAddress, saltA)); // saltA: secret to bidder
bytes32 innerHash2 = keccak256(abi.encode(proxyAddress,  saltB)); // saltB: shared with proxy
bytes32 commitHash = keccak256(abi.encode(innerHash1, innerHash2));
```

`saltA` is kept private by the bidder; `saltB` is shared only with the chosen proxy. This two-layer construction means that neither party can derive the other's address from the on-chain hash alone. The bidder–proxy mapping is disclosed only during the Settlement reveal step.

## Auction Mechanics

The auction follows a seven-phase lifecycle:

```
Setup Phase  →  Clock Phase  →  Proxy Phase  →  Allocation Phase
                                                        ↓
                              Finished Phase  ←  Settlement Phase
```

### Setup Phase

The Setup phase registers auction parameters and the associated Uniswap V4 pools, initialises each pool at its configured starting price, and then transitions to the Clock phase once the auction owner deposits the item (non-numeraire) tokens. Auction creation is permissionless — the `auctionOwner` address is a parameter, not derived from `msg.sender`. Depositing assets and starting the clock (`depositAllAndStartClock`) is restricted to the `auctionOwner`.

```solidity
import { ICPAManager } from "src/interfaces/ICPAManager.sol";
import { AuctionTypes } from "src/types/AuctionTypes.sol";
import { AuctionId }    from "src/types/AuctionId.sol";
import { PoolKey }      from "@uniswap/v4-core/src/types/PoolKey.sol";

// ── 1. Build config ───────────────────────────────────────────────────────────
PoolKey[] memory poolKeys = new PoolKey[](1);
poolKeys[0] = PoolKey({
    currency0:   numeraireCurrency,
    currency1:   itemCurrency,
    fee:         0,
    tickSpacing: 60,
    hooks:       IHooks(cpaHookAddress)
});

uint160[] memory initialSqrtPricesX96 = new uint160[](1);
initialSqrtPricesX96[0] = /* starting sqrtPriceX96 */;

int24[] memory priceIncrements = new int24[](1);
priceIncrements[0] = 60; // ticks raised per round when excess demand exists

uint256[] memory phaseDurations = new uint256[](4);
phaseDurations[0] = 1 hours;   // Clock phase
phaseDurations[1] = 30 minutes; // Proxy phase
phaseDurations[2] = 30 minutes; // Allocation phase
phaseDurations[3] = 1 hours;   // Settlement phase

AuctionTypes.AuctionConfig memory config = AuctionTypes.AuctionConfig({
    commonNumeraire:             address(usdc),
    minSpendRatio:               5_000,  // 50% in basis points
    dropoutSlashRatio:           1_000,  // 10%
    spendingViolationSlashRatio: 500,    // 5%
    maxRounds:                   10,
    allocatorRewardPct:          200,    // 2%
    phaseDurations:              phaseDurations,
    poolKeys:                    poolKeys,
    initialSqrtPricesX96:        initialSqrtPricesX96,
    priceIncrements:             priceIncrements
});

// ── 2. Create auction (permissionless) ────────────────────────────────────────
ICPAManager cpa = ICPAManager(cpaDiamondAddress);
AuctionId auctionId = cpa.createAuction(config, auctionOwner);
// Two-step equivalent: cpa.initAuction(config, auctionOwner) then cpa.finalizeAuction(...)

// ── 3. Deposit items and start Clock phase (onlyAuctionOwner) ─────────────────
// ERC-20 approval to CPAManager required before calling.
uint256[] memory amounts = new uint256[](1);
amounts[0] = 1_000e18;
cpa.depositAllAndStartClock(auctionId, poolKeys, amounts);
```

### Clock Phase

The Clock phase is a multi-round ascending-price auction. In each round, bidders submit demand vectors; the protocol tallies total demand per pool and raises the price by `priceIncrements[i]` ticks wherever demand exceeds supply (Doppler-style: a minimal swap moves the `sqrtPrice`). Rounds continue until no pool has excess demand, `maxRounds` is reached, or the exponential moving average of revenue improvement falls below 0.5%.

```solidity
// ── Off-chain: generate salts and commit hash ─────────────────────────────────
bytes32 saltA      = /* private to bidder */;
bytes32 saltB      = /* shared with proxy */;
bytes32 innerHash1 = keccak256(abi.encode(bidderAddress, saltA));
bytes32 innerHash2 = keccak256(abi.encode(proxyAddress,  saltB));
bytes32 commitHash = keccak256(abi.encode(innerHash1, innerHash2));

// ── Auction owner: start Clock phase ─────────────────────────────────────────
cpa.startClockPhase(auctionId);

// ── Commit registration (choose one path) ────────────────────────────────────
// Path A — proxy registers on behalf of bidder (called by proxy)
cpa.commitToBidder(auctionId, commitHash);
// Path B — bidder self-proxies (called by bidder; reverts if slot already taken)
cpa.registerCommit(auctionId, commitHash);

// ── Round N: bidder submits demand vector ─────────────────────────────────────
uint256[] memory demands = new uint256[](numItems);
demands[0] = 10;
demands[1] = 5;
uint256 maxStakeAmount = 1_000e18; // max numeraire the bidder is willing to stake
cpa.submitBid{value: ethIfNumeraire}(auctionId, demands, maxStakeAmount);

// ── Auction owner: end each round ────────────────────────────────────────────
cpa.endClockRound(auctionId); // one-call wrapper: processClockRoundStep + finalizeClockRound

// ── Optional: force-end the phase at any time (onlyAuctionOwner) ─────────────
cpa.endClockPhase(auctionId);

// ── Optional: bidder voluntarily exits; stake returned minus dropoutSlashRatio ─
cpa.dropout(auctionId);
```

| Function | Caller |
|---|---|
| `startClockPhase` | Auction owner |
| `commitToBidder` | Proxy |
| `registerCommit` | Bidder (self-proxy) |
| `submitBid` | Any active bidder |
| `dropout` | Any active bidder |
| `endClockRound` | Auction owner |
| `endClockPhase` | Auction owner |

### Proxy Phase

During the Proxy phase, each registered proxy submits one or more `Bundle` structs on behalf of their bidder, expressing the bidder's true demand preferences at the prices that emerged from clock-round price discovery. The `msg.sender` must be the address registered as proxy for the given `commitHash`. Multiple bundles may be submitted for the same `commitHash` as long as their `quantities` vectors differ.

```solidity
import { AuctionTypes }            from "src/types/AuctionTypes.sol";
import { BundleId, BundleIdLibrary } from "src/types/BundleId.sol";

// Build a bundle — quantities.length must equal the number of auctioned pools
AuctionTypes.Bundle memory bundleA = AuctionTypes.Bundle({
    auctionId:  auctionId,
    commitHash: commitHash,   // must match the proxy's registered commitHash
    value:      1_500e18,     // bidder's valuation (informational)
    quantities: new uint256[](2),
    timestamp:  block.timestamp
});
bundleA.quantities[0] = 10; // 10 units of item 0
bundleA.quantities[1] = 0;  // 0 units of item 1

AuctionTypes.Bundle memory bundleB = AuctionTypes.Bundle({
    auctionId:  auctionId,
    commitHash: commitHash,
    value:      800e18,
    quantities: new uint256[](2),
    timestamp:  block.timestamp
});
bundleB.quantities[0] = 0;
bundleB.quantities[1] = 5;  // 5 units of item 1 only

// Called by the address registered as proxy for commitHash
BundleId idA = cpa.submitBundle(auctionId, commitHash, bundleA);
BundleId idB = cpa.submitBundle(auctionId, commitHash, bundleB);
```

The phase ends automatically when its duration elapses. There is no explicit end-phase call; `transitionToAllocation` (below) enforces the time check.

### Allocation Phase

During the Allocation phase, off-chain agents called *allocators* compete to submit the best assignment of proxy bundles to the available inventory. Each allocation proposes a set of `BundleId`s — at most one bundle per unique bidder (duplicate `commitHash` entries are rejected). The protocol scores each submission on-chain as the total numeraire value of the selected bundles at current pool prices. Only the highest-scoring submission is retained; a later submission must strictly outscore the current leader to replace it.

`transitionToAllocation` and `submitAllocation` are both **permissionless**. However, the caller of `submitAllocation` must equal `allocationData.allocator`.

```solidity
// ── Transition Proxy → Allocation (permissionless) ───────────────────────────
cpa.transitionToAllocation(auctionId);

// ── Reconstruct BundleIds (must match exactly what was submitted in Proxy phase) ─
BundleId bundle1 = BundleIdLibrary.createId(commitHashA, contentsHashA);
BundleId bundle2 = BundleIdLibrary.createId(commitHashB, contentsHashB);
BundleId bundle3 = BundleIdLibrary.createId(commitHashC, contentsHashC);

// ── Allocator A submits a 2-bundle allocation ─────────────────────────────────
AuctionTypes.Allocation memory allocA = AuctionTypes.Allocation({
    auctionId:  auctionId,
    allocator:  allocatorA,  // must equal msg.sender
    bundleIds:  new BundleId[](2),
    totalValue: 0,           // informational; on-chain scoring is authoritative
    timestamp:  block.timestamp
});
allocA.bundleIds[0] = bundle1;
allocA.bundleIds[1] = bundle2;
cpa.submitAllocation(auctionId, allocA); // called by allocatorA

// ── Allocator B submits a competing 3-bundle allocation ──────────────────────
AuctionTypes.Allocation memory allocB = AuctionTypes.Allocation({
    auctionId:  auctionId,
    allocator:  allocatorB,
    bundleIds:  new BundleId[](3),
    totalValue: 0,
    timestamp:  block.timestamp
});
allocB.bundleIds[0] = bundle1;
allocB.bundleIds[1] = bundle2;
allocB.bundleIds[2] = bundle3;
cpa.submitAllocation(auctionId, allocB); // replaces allocA only if score is strictly higher

// ── Transition Allocation → Settlement (permissionless one-call orchestrator) ──
// Internally calls: selectAuctionWinner + convertAuctionAssets + mintSettlementPositions
cpa.transitionToSettlement(auctionId);
```

### Settlement Phase

The Settlement phase is the final active window. Bidders reveal their commit preimages, claim allocated tokens, and the winning allocator collects its reward. After the phase window expires the auction transitions to Finished.

```solidity
// ── Each bidder reveals their preimage ───────────────────────────────────────
// Parameters must reproduce the original commitHash:
//   keccak256(abi.encode(keccak256(abi.encode(msg.sender, saltA)),
//                        keccak256(abi.encode(proxy, saltB))))
cpa.reveal(auctionId, proxy, saltA, saltB); // called by each bidder

// ── Claim allocated tokens (bidder must have revealed first) ─────────────────
cpa.claimAllTokens(auctionId, commitHash); // swaps stake → tokens for all allocated pools

// ── Winning allocator collects reward ────────────────────────────────────────
cpa.claimAllocatorReward(auctionId); // callable in Settlement or Finished phase

// ── Advance to Finished after phase window expires (permissionless) ──────────
cpa.transitionToFinished(auctionId);

// ── Reclaim stake after Finished (penalty applied per minSpendRatio) ─────────
cpa.reclaimStake(auctionId); // callable by any bidder with remaining stake

// ── Auction owner transfers LP positions to themselves ───────────────────────
cpa.transferPositionsToAuctioneer(auctionId);
```

| Actor | Call |
|---|---|
| Anyone | `transitionToSettlement(auctionId)` |
| Bidder | `reveal(auctionId, proxy, saltA, saltB)` |
| Bidder | `claimAllTokens(auctionId, commitHash)` |
| Winning allocator | `claimAllocatorReward(auctionId)` |
| Anyone | `transitionToFinished(auctionId)` |
| Bidder | `reclaimStake(auctionId)` |
| Auction owner | `transferPositionsToAuctioneer(auctionId)` |
| Anyone | `forfeit(auctionId, bidder)` — forfeits an unclaimed bidder and pays a bounty to caller |

## Installation

### Requirements

- [Foundry](https://book.getfoundry.sh/getting-started/installation) (stable channel — `foundryup`)
- Solidity `0.8.26` (installed automatically via `foundry.toml`)

### Setup

```bash
git clone https://github.com/woolgathering/Rok.git
cd Rok
forge install
forge build
forge test
```

### Deploy

```bash
export PRIVATE_KEY=...
export POOL_MANAGER_ADDRESS=...       # Uniswap V4 PoolManager on target chain
export POSITION_MANAGER_ADDRESS=...   # Uniswap V4 PositionManager on target chain
export PROTOCOL_OWNER=...             # optional, defaults to deployer
export PROTOCOL_WALLET=...            # optional, defaults to PROTOCOL_OWNER

forge script script/DeployCPA.s.sol \
  --rpc-url $RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast
```

The script mines the CPAHook address, deploys MathFacet and CPAManager, registers all 21 facets and 5 callback sub-facets, and wires CPAHook to the diamond. Deployed addresses are written to `deployments.txt`. Inspect registered facets post-deploy:

```bash
cast call <CPAManager_address> "facets()"
```

## Testing

```bash
# Run all tests
forge test

# Run specific test files
forge test --match-path test/CPACompleteFlow.t.sol
forge test --match-path test/CPAClockPhase.t.sol
forge test --match-path test/CPASettlementPhase.t.sol
```

### Test Coverage

| File | Focus |
|---|---|
| `CPACompleteFlow.t.sol` | End-to-end auction scenarios |
| `CPASetupPhase.t.sol` | Auction creation and pool registration |
| `CPAClockPhase.t.sol` | Clock round bidding, activity rule, price discovery |
| `CPAClock6Decimals.t.sol` | Clock phase with 6-decimal numeraire |
| `CPAClockETH.t.sol` | Clock phase with ETH as numeraire |
| `CPAProxyPhase.t.sol` | Bundle submission |
| `CPAAllocationPhase.t.sol` | Allocator competition and scoring |
| `CPASettlementPhase.t.sol` | Reveal, token claiming, stake refunds |
| `CPAFinishedPhase.t.sol` | Position transfer and forfeiture |
| `CPAPhaseTransition.t.sol` | Phase transition guards |
| `CPAManager.t.sol` | Diamond admin (diamondCut, loupe) |
| `CPAHook.t.sol` | Hook permission enforcement |
| `PriceUtils.t.sol` | Price utility functions |

## Documentation

High-level documentation is available in the `docs/` directory. Note: These docs are not technical and may be out of date.

- Implementation Specification: `docs/productAndIdeas/clockProxyHookImplementation.md`
- Logic Flow: `docs/productAndIdeas/mainLogicFlow.md`
- V4 Analysis: `docs/productAndIdeas/clockProxyV4Analysis.md`

For the most accurate information, refer to code comments and test files.

## Development

### Project Structure

```
src/
├── CPAManager.sol                  # EIP-2535 diamond proxy; entry point for all calls
├── CPAHook.sol                     # Uniswap V4 hook; gates pool access by auction phase
├── base/
│   ├── CPABase.sol                 # Abstract base for all facets (modifiers, helpers)
│   ├── CPABaseClock.sol            # Clock-phase helpers shared across clock facets
│   └── CPAStorage.sol              # All diamond storage variables
├── facets/
│   ├── AuctionFlowFacet.sol        # Orchestrators: createAuction, endClockRound, transitionToSettlement
│   ├── AllocationPhaseFacet.sol    # transitionToAllocation
│   ├── AllocationSubmitFacet.sol   # submitAllocation
│   ├── CallbackRouterFacet.sol     # Dispatches unlockCallback by operation type
│   ├── CallbacksClaimTokenFacet.sol
│   ├── CallbacksDepositFacet.sol
│   ├── CallbacksFacet.sol          # Clock-phase callbacks
│   ├── CallbacksRefundFacet.sol
│   ├── CallbacksSettlementFacet.sol
│   ├── ClockBidFacet.sol           # submitBid
│   ├── ClockBidderFacet.sol        # commitToBidder, registerCommit, dropout
│   ├── ClockEndFacet.sol           # endClockPhase
│   ├── ClockEndRoundFacet.sol      # processClockRoundStep
│   ├── ClockFinalizeRoundFacet.sol # finalizeClockRound
│   ├── ClockPhaseFacet.sol         # startClockPhase
│   ├── CoreFacet.sol               # pause, unpause, cancel, forceCancelAuction
│   ├── DepositFacet.sol            # moveDeposit, depositAllAndStartClock
│   ├── FinishedPhaseFacet.sol      # transferPositionsToAuctioneer, forfeit
│   ├── MathFacet.sol               # Pure math (deployed standalone, not in diamond selectors)
│   ├── ProxyPhaseFacet.sol         # submitBundle
│   ├── SettlementMintFacet.sol     # mintSettlementPositions
│   ├── SettlementMiscFacet.sol     # claimAllocatorReward, reclaimStake, transitionToFinished
│   ├── SettlementPhaseFacet.sol    # reveal, claimToken, claimAllTokens
│   ├── SettlementTransferFacet.sol # convertAuctionAssets
│   ├── SettlementTransitionFacet.sol # selectAuctionWinner
│   ├── SetupFacet.sol              # initAuction
│   └── SetupFinalizeFacet.sol      # finalizeAuction
├── interfaces/
│   ├── ICPAHook.sol
│   ├── ICPAManager.sol
│   ├── IDiamondCut.sol
│   ├── IDiamondLoupe.sol
│   └── IMathFacet.sol
├── libraries/
│   ├── CPAAllocationPhase.sol
│   ├── CPAClockPhase.sol
│   ├── CPAComputationLibrary.sol
│   ├── CPAFinishedPhase.sol
│   ├── CPALibraryUtils.sol
│   ├── CPAProxyPhase.sol
│   ├── CPASettlementPhase.sol
│   ├── CPASetup.sol
│   └── LibDiamond.sol
├── types/
│   ├── AllocationId.sol
│   ├── AuctionId.sol
│   ├── AuctionTypes.sol            # Core struct definitions
│   └── BundleId.sol
└── utils/
    ├── CPAIntegratorUtils.sol      # Off-chain integration helpers
    ├── Callbacks.sol               # Uniswap V4 callback utilities
    ├── CommitReveal.sol            # Commit-reveal hash utilities
    ├── CurrencyDecimals.sol
    ├── IErrorsAndEvents.sol        # Centralized errors and events
    └── PriceUtils.sol

script/
├── DeployCPA.s.sol                 # Production deployment script
└── base/
    ├── BaseScript.sol
    ├── DiamondDeployHelper.sol     # Registers all 21 facets + 5 callback sub-facets
    └── LiquidityHelpers.sol
```

### Known Issues

These issues will be mitigated in future versions. There is nothing in the architecture that precludes solutions.

- The numeraire is currently required to be in 18-decimal precision. Future versions will eliminate this requirement.
- Bidder dropout is partially implemented: if a proxy does not submit a bundle or the bidder is not included in the final allocation, their stake is subject to the `minSpendRatio` penalty.
- The auction owner must manually advance most phase transitions (except `transitionToAllocation`, `transitionToSettlement`, and `transitionToFinished` which are permissionless).
- Stakes are unrefundable if an auction is cancelled (full refund via `reclaimStake` is a planned addition).

## License

This project is licensed under the BUSL-1.1 License — see the LICENSE file for details.
