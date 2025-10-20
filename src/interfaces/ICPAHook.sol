// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { Hooks } from "@uniswap/v4-core/src/libraries/Hooks.sol";
import { AuctionTypes } from "../types/AuctionTypes.sol";

/**
 * @title ICPAHook
 * @notice Minimal interface for CPAHook contract
 * @author notthatintodefi.eth
 */
interface ICPAHook {
    /**
     * @notice Get the auction manager address
     * @return The auction manager address
     */
    function getAuctionManager() external view returns (address);

    /**
     * @notice Set the auction manager address
     * @param _auctionManager The new auction manager address
     */
    function setAuctionManager(address _auctionManager) external;

    /**
     * @notice Set the pool state for a specific pool
     * @param poolKey The pool key
     * @param state The auction phase state
     */
    function setPoolState(PoolKey calldata poolKey, AuctionTypes.AuctionPhase state) external;

    /**
     * @notice Returns the hook permissions configuration
     * @return permissions The hook permissions configuration
     */
    function getHookPermissions() external pure returns (Hooks.Permissions memory);
}
