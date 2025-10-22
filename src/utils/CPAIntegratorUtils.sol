// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { IERC20 } from "forge-std/interfaces/IERC20.sol";

import { CurrencyDecimals } from "./CurrencyDecimals.sol";
import { PriceUtils } from "./PriceUtils.sol";
import { AuctionTypes } from "../types/AuctionTypes.sol";

/**
 * @title CPAIntegratorUtils
 * @notice Utility library for CPA integrators - provides all calculation and query functions
 * @dev This library contains pure view functions that can be used off-chain or by other contracts
 *      without requiring external calls to CPAManager. Essential for dApp integration.
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
        PoolKey[] memory poolKeys
    ) internal view returns (
        uint256 additionalRequired,
        uint256 totalRequired,
        uint256 bidValue,
        uint256 allocatorFee
    ) {
        // Calculate bid value using the same logic as CPAClockPhase
        bidValue = calculateBidValue(demands, numeraire, poolManager, poolKeys);
        
        // Calculate allocator fee
        allocatorFee = (bidValue * allocatorRewardPct) / 10000;
        
        // Total required stake
        totalRequired = bidValue + allocatorFee;
        
        // Calculate additional required (only if existing stake is insufficient)
        additionalRequired = (totalRequired > existingStake) ? (totalRequired - existingStake) : 0;
    }

    /**
     * @notice Calculate bid value using demands and current prices
     * @param demands Array of demand amounts for each pool
     * @param numeraire The numeraire currency address (address(0) for ETH)
     * @param poolManager The pool manager instance
     * @param poolKeys Array of pool keys for the auction
     * @return totalValue Total value of the bid in numeraire terms
     * @dev This is the core calculation used throughout the CPA system
     */
    function calculateBidValue(
        uint256[] calldata demands,
        address numeraire,
        IPoolManager poolManager,
        PoolKey[] memory poolKeys
    ) internal view returns (uint256 totalValue) {
        // Calculate inner product: sum(demands[i] * prices[i])
        for (uint256 i = 0; i < demands.length && i < poolKeys.length; i++) {
            // Get the pool ID and its current price from the pool
            uint256 price;
            if (Currency.unwrap(poolKeys[i].currency0) == numeraire) {
                // Since the numeraire is currency0, we need to get the price of currency1
                price = poolManager.getPriceOfCurrency1(poolKeys[i]);
            } else {
                // Since the numeraire is currency1, we need to get the price of currency0
                price = poolManager.getPriceOfCurrency0(poolKeys[i]);
            }
            
            // Get asset decimals for this pool
            address assetCurrency;
            if (Currency.unwrap(poolKeys[i].currency0) == numeraire) {
                assetCurrency = Currency.unwrap(poolKeys[i].currency1);
            } else {
                assetCurrency = Currency.unwrap(poolKeys[i].currency0);
            }
            
            // Convert: (demand in asset decimals) * (price in 18 decimals) => value in numeraire decimals
            // Formula: (quantity * price * 10^numeraireDecimals) / (10^(18 + assetDecimals))
            totalValue += (demands[i] * price * (10**CurrencyDecimals.getDecimals(numeraire))) / (10**(18 + CurrencyDecimals.getDecimals(assetCurrency)));
        }
    }

    /**
     * @notice Calculate bid value using memory demands array
     * @param demands Array of demands (memory parameter - used when demands are already in memory)
     * @param numeraire The numeraire currency address (address(0) for ETH)
     * @param poolManager The pool manager instance
     * @param poolKeys Array of pool keys for the auction
     * @return totalValue Total value of the bid in numeraire terms
     * @dev This function is identical to calculateBidValue() but takes memory demands instead of calldata.
     *      Used when demands are already loaded into memory (e.g., from totalDemands array).
     *      Avoids unnecessary data copying between calldata and memory.
     */
    function calculateBidValueWithMemoryDemands(
        uint256[] memory demands,
        address numeraire,
        IPoolManager poolManager,
        PoolKey[] memory poolKeys
    ) internal view returns (uint256 totalValue) {
        // Calculate inner product: sum(demands[i] * prices[i])
        for (uint256 i = 0; i < demands.length && i < poolKeys.length; i++) {
            // Get the pool ID and its current price from the pool
            uint256 price;
            if (Currency.unwrap(poolKeys[i].currency0) == numeraire) {
                // Since the numeraire is currency0, we need to get the price of currency1
                price = poolManager.getPriceOfCurrency1(poolKeys[i]);
            } else {
                // Since the numeraire is currency1, we need to get the price of currency0
                price = poolManager.getPriceOfCurrency0(poolKeys[i]);
            }
            
            // Get asset decimals for this pool
            address assetCurrency;
            if (Currency.unwrap(poolKeys[i].currency0) == numeraire) {
                assetCurrency = Currency.unwrap(poolKeys[i].currency1);
            } else {
                assetCurrency = Currency.unwrap(poolKeys[i].currency0);
            }
            
            // Convert: (demand in asset decimals) * (price in 18 decimals) => value in numeraire decimals
            // Formula: (quantity * price * 10^numeraireDecimals) / (10^(18 + assetDecimals))
            totalValue += (demands[i] * price * (10**CurrencyDecimals.getDecimals(numeraire))) / (10**(18 + CurrencyDecimals.getDecimals(assetCurrency)));
        }
    }

    /**
     * @notice Convert stake amount to bid points
     * @param stakeAmount The stake amount in numeraire terms
     * @param numeraire The numeraire currency address (address(0) for ETH)
     * @return bidPoints The equivalent bid points (always in 18 decimals)
     * @dev Bid points are always in 18 decimals for consistency across different numeraires
     */
    function computeBidPoints(uint256 stakeAmount, address numeraire) internal view returns (uint256 bidPoints) {
        bidPoints = stakeAmount * 10**18 / (10**CurrencyDecimals.getDecimals(numeraire));
    }

    /**
     * @notice Get current price of an asset in terms of numeraire
     * @param poolKey The pool key for the asset/numeraire pair
     * @param numeraire The numeraire currency address (address(0) for ETH)
     * @param poolManager The pool manager instance
     * @return price The current price in 18-decimal precision
     * @dev Prices are always returned in 18-decimal precision for consistency
     */
    function getCurrentPrice(
        PoolKey memory poolKey,
        address numeraire,
        IPoolManager poolManager
    ) internal view returns (uint256 price) {
        if (Currency.unwrap(poolKey.currency0) == numeraire) {
            return poolManager.getPriceOfCurrency1(poolKey);
        } else {
            return poolManager.getPriceOfCurrency0(poolKey);
        }
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
        PoolKey[] memory poolKeys
    ) internal view returns (uint256 totalValue) {
        return calculateBidValue(demands, numeraire, poolManager, poolKeys);
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
        PoolKey[] memory poolKeys
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
            poolKeys
        );
        
        hasSufficientStake = (additionalNeeded == 0);
    }
}
