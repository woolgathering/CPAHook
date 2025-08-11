# Running Notes

## Overview

This document outlines a blockchain-compatible architecture for implementing a Clock-Proxy auction with competitive proxies and meta-proxies. The blockchain smart contract plays the role of theauctionee, managing item pricing, bundle submissions, allocation proposals, and final settlement. Allocations can be cryptographically verified via zero-knowledge proofs to ensure correctness without revealing sensitive information.

## Key Auction Phases

1.Clock Phas: Iterative item price adjustments based on excess demand.
2.Proxy Phas: Proxies submit bundles for bidders based on final prices.
3.Meta-Proxy (Allocation) Phas: Meta-proxies compete to propose valid allocations.
4.Verification Phas: Allocations are validated on-chain for correctness.

---

## Actors and Roles

| Actor                | Role                                                            |
| -------------------- | --------------------------------------------------------------- |
| **Auction Contract** | On-chain logic coordinating the auction and enforcing rules.    |
| **Bidders**          | Entities with private value functions over item bundles.        |
| **Proxies**          | 3rd parties submitting bundles on behalf of bidders.            |
| **Meta-Proxies**     | Submit full candidate allocations using reported bundles.       |
| **Verifiers**        | Optional actors who validate or challenge proposed allocations. |

---

## High-Level Architecture Diagram

```text
                        +---------------------------+
                        |   Bidder Value Functions  |
                        |     (off-chain/private)   |
                        +------------+--------------+
                                     |
                            (via proxy agents)
                                     |
                +--------------------v--------------------+
                |                 Proxies                 |
                |   Submit candidate bundles per bidder   |
                +--------------------+--------------------+
                                     |
                      (bundle submission window)
                                     |
                        +------------v------------+
                        |    Auction Smart Contract |
                        |    - Stores bundles       |
                        |    - Tracks clock prices  |
                        +------------+-------------+
                                     |
                        (after proxy phase ends)
                                     |
                   +-----------------v------------------+
                   |           Meta-Proxies             |
                   |  Submit full candidate allocations |
                   +-----------------+------------------+
                                     |
                           (evaluation phase)
                                     |
                 +-------------------v------------------+
                 |         Auction Smart Contract        |
                 |  - Validates allocations              |
                 |  - Selects winner                     |
                 |  - Final settlement                   |
                 +---------------------------------------+
```

---

## Phase Details

### 1. Clock Phase

* The contract starts with prices = 0 for all items.
* Iteratively increases prices for items with excess demand.
* Ends when there is no over-demand.
* Prices are now fixed.

### 2. Proxy Phase

* Each proxy may submit one or more bundles for a given bidder.
* Bundles must include:

  * Bidder ID
  * Item set (bundle)
  * Claimed value (not verified on-chain)
* Bundles are stored on-chain and indexed by bidder.

### 3. Meta-Proxy Phase

* Meta-proxies construct conflict-free allocations using submitted bundles.
* A valid allocation must:

  * Assign at most one bundle per bidder
  * Not reuse any item across multiple bundles
* Each allocation includes:

  * Set of selected bundles
  * Meta-proxy ID
  * Optional claimed utility score

### 4. Verification Phase

* Each allocation is subject to verification checks:

  * Are bundles conflict-free?
  * Is it the highest-utility allocation seen so far?

---

## Verification Techniques

| Technique       | Purpose                                                                            |
| --------------- | ---------------------------------------------------------------------------------- |
| On-Chain Checks | Validate bundle disjointness and unique bidder assignment                          |
| ZK-SNARK Proofs | Prove that allocation meets global properties without revealing bidder preferences |
| Challenges      | Verifiers can challenge allocations; contract may reward correct challenges        |

Meta-proxies may be required to provide a ZK proof that their allocation is:

* **Feasible** (no overlaps)
* **Maximizing** (or within epsilon of best known total value)
* **Core-selecting**, meaning no group of bidders could deviate profitably

The contract will accept the first valid allocation, or select the best-scoring valid allocation after a deadline.

---

## zk-SNARK-Based Verification Feasibility

This step is very feasible with today's tooling. Meta-proxies can submit:

* The allocation itself (as a list of bundles)
* A zk-SNARK proving one or more of the following:

  * No items are duplicated across bundles
  * No bidder is assigned more than one bundle
  * Total value is maximal (or within some margin)
  * No blocking coalition exists (core condition)

Proof systems: Groth16, Plonk, Halo2 — all capable of proving such claims efficiently. Circom, Noir, or Leo can be used to build the circuits. On-chain verification is possible with existing precompiles for Groth16, and efficient verification libraries for others on rollups.

Benefits:

* Privacy: Bidder valuations are never revealed.
* Trustless: Allocation claims can be verified without trusting the meta-proxy.
* Competitive: Allocator-proposers compete to generate the best allocation and proof.

---

## Determining the Most Optimal Allocation On-Chain

Because computing the exact optimal allocation (e.g., one that maximizes total value or satisfies core constraints) is NP-hard, we rely on a combination of:

* Programmatically verifiable conditions (no conflicts, proper assignment)
* Relative comparison among allocations submitted by meta-proxies
* ZK proofs certifying optimality (or epsilon-approximation)

### Option 1: Hard Guarantees

Meta-proxies submit:

* A bundle list
* A zk-SNARK proof showing optimality (max value, or closest to core)
* A claimed score (e.g., total value or dual price surplus)

The contract accepts the first valid proof or chooses the highest score among verified proofs after a timeout.

### Option 2: Competitive Challenge Model

Meta-proxies submit allocations.

* Each new allocation is accepted only if:

  * It is valid (conflict-free)
  * It has a higher claimed score than the current best
  * It includes a zk-proof certifying this fact
* Other actors may challenge weak or invalid submissions.

This enables a trustless race-to-the-top for allocation quality, without the chain needing to compute the optimal allocation directly.

---

## Design Properties

| Property              | Achieved By                                  |
| --------------------- | -------------------------------------------- |
| Privacy of Valuations | Proxies act as intermediaries                |
| Open Participation    | Anyone may act as a proxy or meta-proxy      |
| Verifiability         | On-chain rules + optional ZKPs               |
| Incentive Alignment   | Rewards for accepted bundles and allocations |

---

## On-Chain Storage Requirements

* Item Prices: Final prices after clock phase
* Bundles: Mapping of bidder → proxy-submitted bundles
* Allocations:

  * Meta-proxy ID
  * List of selected bundles
  * Claimed score
  * (Optional) ZK proof hash and verification key reference

---

## Future Enhancements

* Allow iterative meta-proxy submissions with refinement
* Integration of SNARK-verifying precompiles for efficient validation
* Use of decentralized identity (DID) for pseudonymous participation
* Slashing or staking system for invalid submissions
* zk-rollup integration for scaling high-throughput bundle and proof submissions

---

🧪 Example:

Let’s say there are items A, B, C, D and prices {A: $10, B: $15, C: $5, D: $20}

Bidder says:

    "I value A+B = $35, A+C = $32, B+D = $38, but I don’t want A without B."

Rather than submit bundles explicitly, the bidder gives:

    A value function (possibly approximate)

    A constraint: “No A without B”

The proxy:

    Builds candidate bundles

    Scores them: A+B ($35-$25), A+C ($32-$15), B+D ($38-$35)

    Filters out A+C due to the A-without-B constraint

    Submits only A+B and B+D

🤝 But... What About Competition Between Proxies?

This is a legitimate design goal — and you can enable it without assigning multiple proxies simultaneously.
✅ Option 1: Bidders Choose Among Competing Proxies Before Submitting

    Bidders can shop around for proxies based on:

        Fees

        Historical performance

        Auditable algorithms

    They choose one proxy, and that proxy submits bundles.

You get competition, just at the selection level, not submission level.

✅ Option 2: Proxy-as-a-Service Model

    Proxies publish algorithms or interfaces

    Bidders submit their valuation functions (or approximations)

    The bidder signs off on the output

    The selected proxy submits the final bundles

Still single-proxy submission, but with more transparency and competition in how bundles are generated.

Topic: ERC-1155 Bid Representation & Stake Binding
Why ERC-1155?

    Flexible, fungible-per-bundle representation.

    Easy to handle multiple winning bundles per bidder.

    Potential integration into claiming/settlement after allocation.

Problem: Transferability

    Pro: ERC-1155s can be freely traded — maximizes composability.

    Con: Transfer reveals control of a winning bid to a new address, but that address may have no stake or commitment to execute.

Two Models Considered
A – “Bidder-Risk” Model (POC Choice)

    Stake is tied to original bidder account in auction contract.

    ERC-1155 fully transferable — anyone can hold or execute if they have the token.

    If execution fails, the original staked bidder is slashed.

    Selling the token is purely at the bidder’s own risk.

    Chosen for POC: minimal extra logic, keeps contract simple.

B – “Stake-Bound” Model (Better for Production)

    ERC-1155 execution requires holder to also have an active stake.

    Prevents “dead” tokens in circulation.

    Avoids allocators working with non-settleable bundles.

    Added complexity, but better UX and risk control for allocators.

Key Notes

    Allocators could be partially compensated from slashed stakes in either model.

    Stake-bound approach better aligns incentives and ensures settlement readiness.

    For the POC, A is fine — allocators just need to be aware of the possibility of dead tokens.

    For production, B should be considered to streamline the allocation pipeline.

ZK Proof of Proxy Membership

    Bundle submission includes a ZK proof:

        "I am one of the registered proxies who was chosen by a bidder, and I signed this bundle"

        Without revealing which proxy.

    This way, the relayer can forward it, and the contract verifies membership without public mapping.



////

My thought to allow the bidder to both designate a proxy and hide the their identity from the allocators:

The bidder publicly submits, along with their updated demands, a hash of an encoded message of their own address, their preferred proxy's address, and a salt. In other words, the bidder takes their own address, their preferred proxy's address, and a salt, concatenates them, encodes the result using the proxy's public key, and hashes the result. 

The bidder would need to transmit the un-hashed encoded message to the proxy (on or off chain is unclear to me) along with their value functions. This is a non-issue if the bidder and the proxy are the same entity.

The proxy then publicly submits a set of bundles on behalf of the bidder, a zk-proof that they are the one that can indeed decode the message, and a zk-proof that the bundles are consistent with the inventory. (We can also check that the bundles are consistent with inventory in the auction contract but I don't know how hard this would be to do.)

The allocators then gather the bundles and submit allocations. The different bundles in the allocations are mapped to the proxy's address which is then mapped back to the bidder's address. The last mapping, from bidder to allocator assigned bundle is the part I'm not sure about. Would some sort of commit-reveal scheme be good?


The onchain privacy crux is one of the following:

- bidders selecting their proxy in secret, then the proxies submitting bundles in public (but not showing what bidders they are bidding for), then after allocation, the proxy or the bidder reveals the identity of the bidder, and the bidder claims their bundle.
- bidders selecting their proxy in public, then the proxy submitting bundles in public WITHOUT REVEALING THEIR ADDRESS (otherwise you could just cross reference the proxy's address to the bidder's address), then after allocation, the bidder or proxy reveals the identity of the bidder, then the bidder claims their bundle.

