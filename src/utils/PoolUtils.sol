// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";

library PoolUtils {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    function poolExists(IPoolManager poolManager, PoolKey memory key) external view returns (bool) {
        PoolId poolId = PoolIdLibrary.toId(key);
        (uint160 sqrtPriceX96, , , ) = poolManager.getSlot0(poolId);
        return sqrtPriceX96 != 0;
    }
}