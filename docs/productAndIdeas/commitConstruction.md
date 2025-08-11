## Commit Construction

Final commit hash:

    commitHash = keccak(
        keccak(bidderID || salt1) ||
        proxyAddress ||
        salt2
    )

- salt1: known only to bidder until reveal.  
- salt2: known only to bidder and proxy until reveal.  
- proxyAddress: public and on-chain.

---

### What the proxy sees in the clock phase

When the bidder sends their off-chain message to the proxy, they send:

    partialCommit = keccak(bidderID || salt1)
    partialSalt2  = ???   (could be withheld entirely)

Proxy learns:
- `partialCommit` — but without `salt2`, the proxy can’t recreate the final `commitHash`.
- `proxyAddress` — their own address (obvious).
- `stake amount` — if that’s required for commit registration.

The proxy then calls:

    registerCommit(commitHash, stake)

Subtlety:  
The bidder pre-computes `commitHash` (using both salts) and gives that `commitHash` to the proxy. The proxy does not derive the final hash; it simply registers the provided `commitHash` on-chain. The `partialCommit` is only for the proxy’s private bookkeeping.

---

### Why partial salt?

- Without either salt, an observer can't recover `bidderID`.  
- Even with `partialCommit`, without `salt2` an observer (or the proxy) can't map to the final `commitHash`.  
- The proxy cannot front-run or replace the bidder’s commit because it does not know the salts and the bidder provided the final `commitHash` in advance.

---

### Reveal Phase

Bidder reveals:

    bidderID, proxyAddress, salt1, salt2

Auction contract recomputes:

    recomputedHash = keccak(
        keccak(bidderID || salt1) ||
        proxyAddress ||
        salt2
    )

If `recomputedHash` matches the stored `commitHash`, the reveal is valid.
