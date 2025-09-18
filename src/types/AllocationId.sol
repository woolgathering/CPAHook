// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

type AllocationId is bytes32;

using {equals as ==, notEquals as !=} for AllocationId global;

function equals(AllocationId allocationId, AllocationId other) pure returns (bool) {
    return AllocationId.unwrap(allocationId) == AllocationId.unwrap(other);
}

function notEquals(AllocationId allocationId, AllocationId other) pure returns (bool) {
    return AllocationId.unwrap(allocationId) != AllocationId.unwrap(other);
}

library AllocationIdLibrary {

    function createId(address allocator, bytes32 bundleContentsHash) internal pure returns (AllocationId) {
        bytes32 allocationId = keccak256(abi.encode(allocator, bundleContentsHash));
        return AllocationId.wrap(allocationId);
    }

}