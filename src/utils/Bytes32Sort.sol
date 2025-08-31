// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

library Bytes32Sort {
    /// @notice Sorts an array of bytes32 in ascending order (in-memory)
    /// @dev Uses insertion sort, which is efficient for small arrays
    function sort(bytes32[] memory arr) internal pure returns (bytes32[] memory) {
        uint256 n = arr.length;
        for (uint256 i = 1; i < n; i++) {
            bytes32 key = arr[i];
            uint256 j = i;
            while (j > 0 && arr[j - 1] > key) {
                arr[j] = arr[j - 1];
                j--;
            }
            arr[j] = key;
        }
        return arr;
    }
}
