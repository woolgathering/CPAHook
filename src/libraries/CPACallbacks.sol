// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { Currency, CurrencyLibrary } from "@uniswap/v4-core/src/types/Currency.sol";
import { BalanceDelta, toBalanceDelta, BalanceDeltaLibrary } from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import { SwapParams, ModifyLiquidityParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { SafeCast } from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { CurrencySettler } from "@openzeppelin/uniswap-hooks/src/utils/CurrencySettler.sol";

import { CPAStorage } from "../base/CPAStorage.sol";
import { StorageAccess } from "../utils/StorageAccess.sol";
import { IErrorsAndEvents } from "../utils/IErrorsAndEvents.sol";
import { AuctionTypes } from "../types/AuctionTypes.sol";
import { AuctionId } from "../types/AuctionId.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";

/**
 * @title CPACallbacks
 * @notice External contract for handling all PoolManager unlock callbacks
 * @dev Functions execute via DELEGATECALL from CPAManager, operating in CPAManager's storage context
 */
contract CPACallbacks {
    using CurrencySettler for Currency;
    using BalanceDeltaLibrary for BalanceDelta;
    using SafeCast for *;
    using PoolIdLibrary for PoolKey;
    using StorageAccess for *;

    /**
     * @notice Handle bid as liquidity add operation
     * @param self The contract instance (CPAManager via DELEGATECALL)
     * @param operationData The encoded operation data containing (int128 amount0, int128 amount1)
     * @return returnData The encoded balance deltas
     */
    function handleBid(
        CPAStorage self,
        bytes memory operationData
    ) public returns (bytes memory returnData) {
        // Decode the callback data
        (AuctionTypes.CallbackDataBid memory data) = abi.decode(operationData, (AuctionTypes.CallbackDataBid));
        address sender = data.sender;
        address numeraire = data.numeraire;
        int128 stake = data.stake;
        
        // Validate deadline
        require(block.timestamp <= data.deadline, "Bid deadline expired");
        
        // Transfer numeraire from bidder to pool manager
        Currency.wrap(numeraire).settle(self.manager(), sender, uint256(int256(stake)), false);
        
        // Mint ERC6909 claims to this hook (bypassing V3 curve)
        Currency.wrap(numeraire).take(self.manager(), address(this), uint256(int256(stake)), true);
        
        // Return the balance deltas
        return abi.encode(
            toBalanceDelta(0, -stake), // callerDelta
            BalanceDeltaLibrary.ZERO_DELTA // feesAccrued
        );
    }

    /**
     * @notice Handle price update swap in callback
     * @param self The contract instance (CPAManager via DELEGATECALL)
     * @param operationData The encoded swap parameters
     * @return returnData The encoded balance delta
     */
    function handlePriceUpdateSwap(
        CPAStorage self,
        bytes memory operationData
    ) public returns (bytes memory) {
        // Decode the swap parameters
        (PoolKey memory poolKey, SwapParams memory swapParams) = abi.decode(operationData, (PoolKey, SwapParams)); 
        
        // Execute the swap to update the price
        BalanceDelta delta = self.manager().swap(poolKey, swapParams, "");

        // Return the delta
        return abi.encode(delta);
    }
    
    /**
     * @dev Handle mint position after allocation
     * @param self The contract instance (CPAManager via DELEGATECALL)
     * @param operationData The encoded operation data
     * @return returnData The encoded balance deltas
     */
    function handleMintPosition(
        CPAStorage self,
        bytes memory operationData
    ) public returns (bytes memory returnData) {
        // decode the operation data
        (AuctionTypes.CallbackDataMintPosition memory data) = abi.decode(operationData, (AuctionTypes.CallbackDataMintPosition));

        (BalanceDelta callerDelta, BalanceDelta feesAccrued) = self.manager().modifyLiquidity(
            data.poolKey,
            ModifyLiquidityParams({
                tickLower: data.tickLower,
                tickUpper: data.tickUpper,
                liquidityDelta: data.liquidity.toInt128(),
                salt: AuctionId.unwrap(data.auctionId)
            }),
            data.hookData
        );

        // handle the deltas
        if (callerDelta.amount0() < 0) {
            // If amount0 is negative, send tokens from the sender to the pool
            data.poolKey.currency0.settle(self.manager(), address(this), uint256(int256(-callerDelta.amount0())), true);
        }

        if (callerDelta.amount1() < 0) {
            // If amount1 is negative, send tokens from the sender to the pool
            data.poolKey.currency1.settle(self.manager(), address(this), uint256(int256(-callerDelta.amount1())), true);
        }

        return abi.encode(callerDelta, feesAccrued);
    }

    /**
     * @notice Handle claim token settlement operation
     * @param self The contract instance (CPAManager via DELEGATECALL)
     * @param operationData The encoded operation data
     * @return returnData The encoded balance deltas
     */
    function handleClaimToken(
        CPAStorage self,
        bytes memory operationData
    ) public returns (bytes memory returnData) {
        // Decode the operation data
        AuctionTypes.CallbackDataClaimToken memory callbackData = abi.decode(operationData, (AuctionTypes.CallbackDataClaimToken));
        
        // now that we have everything, we need to call swap on the pool manager
        BalanceDelta delta = self.manager().swap(callbackData.poolKey, callbackData.swapParams, "");

        Currency numeraire = Currency.wrap(callbackData.numeraire);
        uint256 numeraireOwed;
        uint256 assetGained;
        {
            Currency asset;
            if (callbackData.swapParams.zeroForOne) {
                // if zeroForOne is true, this means that the numeraire is token0
                if (delta.amount1() < 0) revert("Should not owe asset");
                numeraireOwed = uint256((-delta.amount0()).toUint128());
                assetGained = uint256((delta.amount1()).toUint128());
                asset = callbackData.poolKey.currency1;
            } else {
                // if zeroForOne is false, this means that the numeraire is token1
                if (delta.amount0() < 0) revert("Should not owe asset");
                numeraireOwed = uint256((-delta.amount1()).toUint128());
                assetGained = uint256((delta.amount0()).toUint128());
                asset = callbackData.poolKey.currency0;
            }
            asset.take(self.manager(), callbackData.bidder, assetGained, false);
        }

        uint256 bidderStake = StorageAccess.getBidderStake(callbackData.auctionId, callbackData.bidder);
        uint256 numerairePaidByManager = 0;
        if (bidderStake >= numeraireOwed) {
            // since they have enough to cover, we can settle directly
            numeraire.settle(self.manager(), address(this), numeraireOwed, true); // might need to be true since the manager has ERC6909 claims
            numerairePaidByManager = numeraireOwed;
        } else {
            //since they don't have enough, we need to do two settles
            numeraire.settle(self.manager(), address(this), bidderStake, true); // might need to be true since the manager has ERC6909 claims
            numeraire.settle(self.manager(), callbackData.bidder, numeraireOwed - bidderStake, false); // the bidder pays in ERC20
            numerairePaidByManager = bidderStake;
        }
        
        // Return the balance delta
        return abi.encode(numerairePaidByManager, assetGained);
    }

    /**
     * @notice Handle claim all tokens settlement operation
     * @param self The contract instance (CPAManager via DELEGATECALL)
     * @param operationData The encoded operation data
     * @return returnData The encoded balance deltas
     */
    function handleClaimAllTokens(
        CPAStorage self,
        bytes memory operationData
    ) public returns (bytes memory returnData) {
        // Decode the operation data
        AuctionTypes.CallbackDataClaimAllTokens memory callbackData = abi.decode(operationData, (AuctionTypes.CallbackDataClaimAllTokens));
        
        Currency numeraire = Currency.wrap(callbackData.numeraire);
        uint256 totalNumeraireOwed = 0;
        
        // Loop through all pool keys and execute swaps for tokens the bidder is owed
        for (uint256 i = 0; i < callbackData.poolKeys.length; i++) {
            uint256 amountOwed = callbackData.allocatedQuantities[i];
            if (amountOwed > 0) {
                PoolKey memory poolKey = callbackData.poolKeys[i];
                bool numeraireIsCurrency0 = (Currency.unwrap(poolKey.currency0) == callbackData.numeraire);

                SwapParams memory params = SwapParams({
                    zeroForOne: numeraireIsCurrency0,
                    amountSpecified: (amountOwed.toInt256()),
                    sqrtPriceLimitX96: numeraireIsCurrency0
                        ? TickMath.MIN_SQRT_PRICE + 1
                        : TickMath.MAX_SQRT_PRICE - 1
                });
                
                // Execute swap on this pool
                BalanceDelta delta = self.manager().swap(poolKey, params, "");

                uint256 numeraireOwed;
                {
                    Currency asset;
                    if (params.zeroForOne) {
                        // if zeroForOne is true, this means that the numeraire is token0
                        if (delta.amount1() < 0) revert("Should not owe asset");
                        numeraireOwed = uint256((-delta.amount0()).toUint128());
                        uint256 assetGained = uint256((delta.amount1()).toUint128());
                        asset = poolKey.currency1;
                        asset.take(self.manager(), callbackData.bidder, assetGained, false);
                    } else {
                        // if zeroForOne is false, this means that the numeraire is token1
                        if (delta.amount0() < 0) revert("Should not owe asset");
                        numeraireOwed = uint256((-delta.amount1()).toUint128());
                        uint256 assetGained = uint256((delta.amount0()).toUint128());
                        asset = poolKey.currency0;
                        asset.take(self.manager(), callbackData.bidder, assetGained, false);
                    }
                }
                
                // Add to total numeraire owed
                totalNumeraireOwed += numeraireOwed;
            }
        }

        uint256 bidderStake = StorageAccess.getBidderStake(callbackData.auctionId, callbackData.bidder);
        uint256 numerairePaidByManager = 0;
        uint256 protocolPenalty = 0;
        
        // Get auction info for minSpendRatio check
        AuctionTypes.AuctionInfo memory auction = StorageAccess.getAuctionInfo(callbackData.auctionId);
        
        if (bidderStake >= totalNumeraireOwed) {
            // since they have enough to cover, we can settle directly
            numeraire.settle(self.manager(), address(this), totalNumeraireOwed, true); // might need to be true since the manager has ERC6909 claims
            numerairePaidByManager = totalNumeraireOwed;

            // since they had enough, we need to check if they met the minimum spend ratio and refund any leftover numeraire
            uint256 minSpendAmount = auction.config.minSpendRatio * bidderStake / 10000;
            if (minSpendAmount > numerairePaidByManager) {
                // Didn't meet minimum spend - penalty applies
                protocolPenalty = minSpendAmount - numerairePaidByManager;
                StorageAccess.addProtocolPenalty(callbackData.auctionId, protocolPenalty);
                bidderStake -= minSpendAmount;
            } // else they met the minimum spend ratio so no penalty applies

            // refund the leftover numeraire after applying the penalty
            self.manager().burn(address(this), CurrencyLibrary.toId(numeraire), bidderStake - totalNumeraireOwed - protocolPenalty);
            numeraire.take(self.manager(), callbackData.bidder, bidderStake - totalNumeraireOwed - protocolPenalty, false);
        } else {
            //since they don't have enough numeraire to cover the bundle price, we need to do two settles
            numeraire.settle(self.manager(), address(this), bidderStake, true); // might need to be true since the manager has ERC6909 claims
            numeraire.settle(self.manager(), callbackData.bidder, totalNumeraireOwed - bidderStake, false); // the bidder pays in ERC20
            numerairePaidByManager = bidderStake;

            // bidder has no leftover stake so there is no need to refund anything
        }
        
        // Return the balance delta
        return abi.encode(numerairePaidByManager);
    }

    /**
     * @notice Handle refund stake operation
     * @param self The contract instance (CPAManager via DELEGATECALL)
     * @param operationData The encoded operation data
     * @return returnData The encoded amount refunded
     */
    function refundStake(
        CPAStorage self,
        bytes memory operationData
    ) public returns (bytes memory returnData) {
        // Decode the operation data
        (AuctionTypes.CallbackDataRefundStake memory data) = abi.decode(operationData, (AuctionTypes.CallbackDataRefundStake));
        
        // Refund the stake
        self.manager().burn(address(this), CurrencyLibrary.toId(Currency.wrap(data.numeraire)), data.amount);

        // now that we are credited, transfer the tokens to the address
        Currency.wrap(data.numeraire).take(self.manager(), data.recipient, data.amount, false);

        // Return the balance delta
        return abi.encode(data.amount);
    }

    /**
     * @notice Handle claim allocator reward operation
     * @param self The contract instance (CPAManager via DELEGATECALL)
     * @param operationData The encoded operation data
     * @return returnData The encoded reward amount
     */
    function handleClaimAllocatorReward(
        CPAStorage self,
        bytes memory operationData
    ) public returns (bytes memory returnData) {
        // Decode the operation data
        (AuctionTypes.CallbackDataClaimAllocatorReward memory data) = abi.decode(operationData, (AuctionTypes.CallbackDataClaimAllocatorReward));
        
        // we are already unlocked here so we just need to transfer tokens from the CPAManager to the allocator
        Currency.wrap(data.numeraire).take(self.manager(), data.allocator, data.reward, false); // give ERC20 to the allocator
        self.manager().burn(address(this), CurrencyLibrary.toId(Currency.wrap(data.numeraire)), data.reward); // burn ERC6909 from the CPAManager
        
        return abi.encode(data.reward);
    }

    /**
     * @notice Handle batch ERC6909 to ERC20 conversion for position minting
     * @dev Converts all asset ERC6909 claims to ERC20 in single unlock callback
     * @param self The contract instance (CPAManager via DELEGATECALL)
     * @param operationData The encoded batch conversion data
     * @return returnData Empty bytes (no balance deltas needed)
     */
    function handleBatchERC6909ToERC20Conversion(
        CPAStorage self,
        bytes memory operationData
    ) public returns (bytes memory) {
        AuctionTypes.CallbackDataBatchERC6909ToERC20 memory data = abi.decode(
            operationData, 
            (AuctionTypes.CallbackDataBatchERC6909ToERC20)
        );
        
        // Convert all ERC6909 claims to ERC20 for each asset
        for (uint256 i = 0; i < data.assetCurrencies.length; i++) {
            self.manager().burn(address(this), CurrencyLibrary.toId(data.assetCurrencies[i]), data.amounts[i]);
            data.assetCurrencies[i].take(self.manager(), address(this), data.amounts[i], false);
        }
        
        return "";
    }

    /**
     * @notice Handle batch deposit transfer operation (setup)
     * @param self The contract instance (CPAManager via DELEGATECALL)
     * @param operationData The encoded batch deposit data
     * @return returnData The encoded balance deltas
     */
    function handleBatchDepositTransfer(
        CPAStorage self,
        bytes memory operationData
    ) public returns (bytes memory returnData) {
        // Decode batch deposit data
        AuctionTypes.CallbackDataBatchDeposit memory batchData = 
            abi.decode(operationData, (AuctionTypes.CallbackDataBatchDeposit));
        
        // Verify this is a legitimate auction owner
        AuctionTypes.AuctionInfo memory auction = StorageAccess.getAuctionInfo(batchData.auctionId);
        require(batchData.originalCaller == auction.auctionOwner, "Not auction owner");
        
        // Process each deposit
        BalanceDelta[] memory deltas = new BalanceDelta[](batchData.poolKeys.length);
        
        for (uint256 i = 0; i < batchData.poolKeys.length; i++) {
            // Update pool info deposit amount via StorageAccess
            StorageAccess.setPoolInfoDepositAmount(batchData.poolKeys[i].toId(), batchData.depositAmounts[i]);
            
            // Transfer assets using V4's settle/take mechanism
            batchData.itemCurrencies[i].settle(self.manager(), batchData.originalCaller, batchData.depositAmounts[i], false);
            batchData.itemCurrencies[i].take(self.manager(), address(this), batchData.depositAmounts[i], true);
            
            // Create balance delta for this pool
            int128 amount0 = 0;
            int128 amount1 = 0;
            
            if (address(Currency.unwrap(batchData.poolKeys[i].currency0)) == address(Currency.unwrap(batchData.itemCurrencies[i]))) {
                amount0 = int128(uint128(batchData.depositAmounts[i]));
            } else {
                amount1 = int128(uint128(batchData.depositAmounts[i]));
            }
            
            deltas[i] = toBalanceDelta(amount0, amount1);
            
            // Emit event for each deposit
            emit IErrorsAndEvents.AssetsDeposited(
                batchData.auctionId, 
                batchData.poolKeys[i].toId(), 
                address(Currency.unwrap(batchData.itemCurrencies[i])), 
                batchData.depositAmounts[i], 
                StorageAccess.getCpaAuctionHookAddr()
            );
        }
        
        // Return all balance deltas
        return abi.encode(deltas, BalanceDeltaLibrary.ZERO_DELTA);
    }
}

