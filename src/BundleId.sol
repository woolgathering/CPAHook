// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";

type BundleId is bytes32;

using {equals as ==} for BundleId global;

function equals(BundleId bundleId, BundleId other) pure returns (bool) {
    return BundleId.unwrap(bundleId) == BundleId.unwrap(other);
}

library BundleIdLibrary {

    function createId(bytes32 commitHash, bytes32 bundleContentsHash) internal pure returns (BundleId) {
        bytes32 bundleId = keccak256(abi.encode(commitHash, bundleContentsHash));
        return BundleId.wrap(bundleId);
    }

}