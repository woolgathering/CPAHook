// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { PoolId } from "@uniswap/v4-core/src/types/PoolId.sol";

type AuctionId is bytes32;

using {equals as ==} for AuctionId global;

function equals(AuctionId auctionId, AuctionId other) pure returns (bool) {
    return AuctionId.unwrap(auctionId) == AuctionId.unwrap(other);
}

library AuctionIdLibrary {

    function createId(PoolKey[] memory poolKeys) internal pure returns (AuctionId) {
        // first we need to sort the pool keys.
        // the easiest way to do it will be to convert the pool keys to pool ids,
        // then sort, then hash

        // get pool ids
        PoolId[] memory poolIds = new PoolId[](poolKeys.length);
        for (uint256 i = 0; i < poolKeys.length; i++) {
            poolIds[i] = poolKeys[i].toId();
        }

        // sort the pool ids (simple bubble sort for small arrays)
        _sortPoolIds(poolIds);

        // now hash the sorted pool ids
        return AuctionId.wrap(keccak256(abi.encode(poolIds)));
    }

    function _sortPoolIds(PoolId[] memory poolIds) internal pure {
        uint256 n = poolIds.length;
        for (uint256 i = 0; i < n - 1; i++) {
            for (uint256 j = 0; j < n - i - 1; j++) {
                if (PoolId.unwrap(poolIds[j]) > PoolId.unwrap(poolIds[j + 1])) {
                    // swap
                    PoolId temp = poolIds[j];
                    poolIds[j] = poolIds[j + 1];
                    poolIds[j + 1] = temp;
                }
            }
        }
    }
}