# Proxy Phase Implementation TODO

## Bundle Storage System Design ✅
- **Hash-based references**: Use `keccak256(commitHash, bundleIndex, subBundleIndex, subBundleContents)`
- **Single mapping approach**: `bundleToProxy[auctionId][bundleHash] = commitHash` for both storage and verification
- **Bundle contents storage**: `bundleContents[auctionId][bundleHash] = subBundleContents`

## Implementation Steps

### Core Functionality
- [ ] **Implement bundle submission** - Proxies submit bundles with sub-bundles
- [ ] **Implement bundle storage** - Add bundle storage mappings: bundleToProxy and bundleContents
- [ ] **Implement bundle verification** - Add bundle verification functions using bundleToProxy mapping
- [ ] **Implement allocation submission** - Implement allocator submission of bundle hash references
- [ ] **Implement allocation verification** - Verify allocations reference valid bundles and follow rules

### Events and Testing
- [ ] **Add bundle events** - Add events for bundle submission and allocation submission
- [ ] **Test bundle workflow** - Create tests for proxy bundle submission and allocator workflow

## Key Benefits of This Approach
- **Gas efficient**: Single mapping for verification
- **Collision resistant**: Hash includes commitHash + indices
- **Settlement ready**: Full bundle contents stored on-chain
- **Verification simple**: Empty bytes32 check for bundle existence

## Storage Mappings
```solidity
mapping(AuctionId => mapping(bytes32 => bytes32)) bundleToProxy; // Maps bundle hash to proxy commitHash
mapping(AuctionId => mapping(bytes32 => uint256[])) bundleContents; // Actual bundle contents
```

## Verification Logic
```solidity
function isValidBundle(AuctionId auctionId, bytes32 bundleHash) internal view returns (bool) {
    return bundleToProxy[auctionId][bundleHash] != bytes32(0);
}

function getBundleProxy(AuctionId auctionId, bytes32 bundleHash) internal view returns (bytes32) {
    return bundleToProxy[auctionId][bundleHash];
}
```
