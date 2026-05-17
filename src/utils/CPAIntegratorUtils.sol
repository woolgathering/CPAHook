// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { IERC20 } from "forge-std/interfaces/IERC20.sol";

import { CurrencyDecimals } from "./CurrencyDecimals.sol";
import { PriceUtils } from "./PriceUtils.sol";
import { AuctionTypes } from "../types/AuctionTypes.sol";
import { CPAComputationLibrary } from "../libraries/CPAComputationLibrary.sol";

/**
 * @title CPAIntegratorUtils
 * @notice Utility library for CPA integrators - provides all calculation and query functions
 * @dev This library contains pure view functions that can be used off-chain or by other contracts
 *      without requiring external calls to CPAManager. Essential for dApp integration.
 *      Uses CPAComputationLibrary for all core computation functions to ensure consistency.
 * @author Clock-Proxy Auction Team
 */
library CPAIntegratorUtils {
    using PriceUtils for IPoolManager;

    /**
     * @notice Calculate the additional stake required for a bid
     * @param demands Array of demand amounts for each pool
     * @param numeraire The numeraire currency address (address(0) for ETH)
     * @param allocatorRewardPct Allocator reward percentage (in basis points)
     * @param existingStake Current stake held by bidder
     * @param poolManager The pool manager instance
     * @param poolKeys Array of pool keys for the auction
     * @return additionalRequired Additional amount to send (0 if existing stake sufficient)
     * @return totalRequired Total stake needed (bid value + allocator fee)
     * @return bidValue The base bid value
     * @return allocatorFee The allocator fee amount
     * @dev This function helps users determine exactly how much ETH/tokens to send.
     *      For first bid: existingStake = 0, so additionalRequired = totalRequired
     *      For subsequent bids: only send the difference if more stake is needed
     *      If existing stake is sufficient: additionalRequired = 0
     */
    function computeRequiredStake(
        uint256[] calldata demands,
        address numeraire,
        uint256 allocatorRewardPct,
        uint256 existingStake,
        IPoolManager poolManager,
        PoolKey[] memory poolKeys,
        address mathFacetAddr
    ) internal view returns (
        uint256 additionalRequired,
        uint256 totalRequired,
        uint256 bidValue,
        uint256 allocatorFee
    ) {
        bidValue = CPAComputationLibrary.calculateBidValue(demands, numeraire, poolManager, poolKeys, mathFacetAddr);
        
        // Calculate allocator fee
        allocatorFee = (bidValue * allocatorRewardPct) / 10000;
        
        // Total required stake
        totalRequired = bidValue + allocatorFee;
        
        // Calculate additional required (only if existing stake is insufficient)
        additionalRequired = (totalRequired > existingStake) ? (totalRequired - existingStake) : 0;
    }

    /**
     * @notice Calculate total value of multiple demands across pools
     * @param demands Array of demand amounts for each pool
     * @param numeraire The numeraire currency address (address(0) for ETH)
     * @param poolManager The pool manager instance
     * @param poolKeys Array of pool keys for the auction
     * @return totalValue Total value across all demands in numeraire terms
     * @dev Useful for calculating total portfolio value or checking constraints
     */
    function calculateTotalValue(
        uint256[] calldata demands,
        address numeraire,
        IPoolManager poolManager,
        PoolKey[] memory poolKeys,
        address mathFacetAddr
    ) internal view returns (uint256 totalValue) {
        return CPAComputationLibrary.calculateBidValue(demands, numeraire, poolManager, poolKeys, mathFacetAddr);
    }

    /**
     * @notice Check if a bidder has sufficient stake for their demands
     * @param demands Array of demand amounts for each pool
     * @param numeraire The numeraire currency address (address(0) for ETH)
     * @param allocatorRewardPct Allocator reward percentage (in basis points)
     * @param existingStake Current stake held by bidder
     * @param poolManager The pool manager instance
     * @param poolKeys Array of pool keys for the auction
     * @return hasSufficientStake True if existing stake is sufficient
     * @return requiredStake Total stake needed (bid value + allocator fee)
     * @return additionalNeeded Additional stake needed (0 if sufficient)
     * @dev Convenience function for checking stake sufficiency
     */
    function checkStakeSufficiency(
        uint256[] calldata demands,
        address numeraire,
        uint256 allocatorRewardPct,
        uint256 existingStake,
        IPoolManager poolManager,
        PoolKey[] memory poolKeys,
        address mathFacetAddr
    ) internal view returns (
        bool hasSufficientStake,
        uint256 requiredStake,
        uint256 additionalNeeded
    ) {
        (additionalNeeded, requiredStake, , ) = computeRequiredStake(
            demands,
            numeraire,
            allocatorRewardPct,
            existingStake,
            poolManager,
            poolKeys,
            mathFacetAddr
        );
        
        hasSufficientStake = (additionalNeeded == 0);
    }
}
