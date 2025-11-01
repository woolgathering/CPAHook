// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { console } from "forge-std/console.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { SafeCast } from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { Currency, CurrencyLibrary } from "@uniswap/v4-core/src/types/Currency.sol";
import { SwapParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";
import { BalanceDelta } from "@uniswap/v4-core/src/types/BalanceDelta.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { CurrencySettler } from "@openzeppelin/uniswap-hooks/src/utils/CurrencySettler.sol";

import { CPAStorage } from "../base/CPAStorage.sol";
import { StorageAccess } from "../utils/StorageAccess.sol";
import { CommitReveal } from "../utils/CommitReveal.sol";
import { IErrorsAndEvents } from "../utils/IErrorsAndEvents.sol";
import { AuctionTypes } from "../types/AuctionTypes.sol";
import { AuctionId } from "../types/AuctionId.sol";
import { BundleId } from "../types/BundleId.sol";

contract CPASettlementPhase {
	using StorageAccess for *;
    using StateLibrary for IPoolManager;
    using SafeCast for *;
    using CurrencySettler for Currency;

    function reveal(
        CPAStorage self,
        AuctionId auctionId,
        address bidder,
        address proxy,
        bytes32 saltA,
        bytes32 saltB
    ) public {
        bytes32 computedCommitHash = CommitReveal.generateCommitHash(bidder, proxy, saltA, saltB);

        // now check if there exists a commit hash for this auction in the commit proxy mapping
        address commitProxyAddr = StorageAccess.getCommitProxy(auctionId, computedCommitHash);
        if (commitProxyAddr == address(0)) revert IErrorsAndEvents.NoSuchCommitHash(auctionId, computedCommitHash);

        // now check if the commit hash has already been revealed
        address revealedBidder = StorageAccess.getRevealedMapping(auctionId, computedCommitHash);
        if (revealedBidder != address(0)) revert IErrorsAndEvents.DuplicateReveal(auctionId, computedCommitHash);

        // now set the revealed mapping
        StorageAccess.setRevealedMapping(auctionId, computedCommitHash, bidder);

        emit IErrorsAndEvents.RevealProcessed(auctionId, bidder, proxy, computedCommitHash);
    }

    function claimAllTokens(
        CPAStorage self,
        address bidder,
        AuctionId auctionId,
        bytes32 commitHash
    ) public {
        // Validate bidder authorization
        {
            address revealedBidder = StorageAccess.getRevealedMapping(auctionId, commitHash);
            if (revealedBidder == address(0)) revert IErrorsAndEvents.CommitHashNotYetRevealed(auctionId, commitHash);
            if (revealedBidder != bidder) revert IErrorsAndEvents.Unauthorized();
        }

        BundleId bundleId = StorageAccess.getWinningBundleId(commitHash);

        // Get auctionInfo
        AuctionTypes.AuctionInfo memory auctionInfo = StorageAccess.getAuctionInfo(auctionId);
        
        // Check if bidder was allocated
        if (BundleId.unwrap(bundleId) == 0) {
            // Non-allocated bidder - refund full stake (no penalty)
            uint256 stake = StorageAccess.getBidderStake(auctionId, bidder);
            if (stake > 0) {
                AuctionTypes.CallbackDataRefundStake memory refundData = AuctionTypes.CallbackDataRefundStake({
                    numeraire: auctionInfo.commonNumeraire,
                    recipient: bidder,
                    amount: stake
                });
                self.manager().unlock(abi.encode(uint8(5), abi.encode(refundData)));
                
                StorageAccess.setBidderStake(auctionId, bidder, 0);
                emit IErrorsAndEvents.StakeRefunded(auctionId, bidder, stake);
            }
            return; // Exit early, no allocation to process
        }

        // If the bidder was allocated, we need to claim the tokens from the pool
        // In a future version, we should combine both calls
        // to the PoolManager into a single call to save gas.
        bytes memory data = self.manager().unlock(abi.encode(uint8(7), abi.encode(AuctionTypes.CallbackDataClaimAllTokens({
			bidder: bidder,
			numeraire: auctionInfo.commonNumeraire,
			auctionId: auctionId,
			poolKeys: auctionInfo.poolKeys,
			allocatedQuantities: StorageAccess.getBundle(auctionId, bundleId).quantities
		}))));

        (uint256 numerairePaidFromStake) = abi.decode(data, (uint256));

        StorageAccess.setBidderStake(auctionId, bidder, 0);
    }

    function claimToken(
        CPAStorage self,
        address bidder,
        AuctionId auctionId,
        bytes32 commitHash,
        PoolId poolId
    ) public {
        // Validate bidder authorization
        {
            address revealedBidder = StorageAccess.getRevealedMapping(auctionId, commitHash);
            if (revealedBidder == address(0)) revert IErrorsAndEvents.CommitHashNotYetRevealed(auctionId, commitHash);
            if (revealedBidder != bidder) revert IErrorsAndEvents.Unauthorized();
        }

        // Get auctionInfo
        AuctionTypes.AuctionInfo memory auctionInfo = StorageAccess.getAuctionInfo(auctionId);

        // Get amount owed and pool info
        uint256 amountOwed;
        PoolKey memory poolKey;
        {
            // Find pool index
            uint256 poolIndex = type(uint256).max;
            for (uint256 i = 0; i < auctionInfo.poolKeys.length; i++) {
                if (PoolId.unwrap(auctionInfo.poolKeys[i].toId()) == PoolId.unwrap(poolId)) {
                    poolIndex = i;
                    break;
                }
            }
            if (poolIndex == type(uint256).max) {
                revert IErrorsAndEvents.PoolNotFound(auctionId, poolId);
            }

            // Get bundle and amount owed
            BundleId bundleId = StorageAccess.getWinningBundleId(commitHash);
            AuctionTypes.Bundle memory bundle = StorageAccess.getBundle(auctionId, bundleId);
            amountOwed = bundle.quantities[poolIndex];
            poolKey = auctionInfo.poolKeys[poolIndex];
        }

        // Calculate cost and execute trade
        {
            bool numeraireIsCurrency0 = (Currency.unwrap(poolKey.currency0) == auctionInfo.commonNumeraire);

            SwapParams memory params = SwapParams({
                zeroForOne: numeraireIsCurrency0,
                amountSpecified: (amountOwed.toInt256()),
                sqrtPriceLimitX96: numeraireIsCurrency0
                    ? TickMath.MIN_SQRT_PRICE + 1 // TickMath.MIN_SQRT_PRICE + 1
                    : TickMath.MAX_SQRT_PRICE - 1 // TickMath.MAX_SQRT_PRICE - 1
            });
            
            // Execute trade
            bytes memory data = _executeTrade(self.manager(), poolKey, params, bidder, auctionInfo.commonNumeraire, auctionId);
            (uint256 numerairePaidByManager, uint256 assetGained) = abi.decode(data, (uint256, uint256));
            
            // Update stake balance
            uint256 currentStake = StorageAccess.getBidderStake(auctionId, bidder);
            StorageAccess.setBidderStake(auctionId, bidder, currentStake - numerairePaidByManager);
        }
    }

    function _executeTrade(
        IPoolManager manager,
        PoolKey memory key,
        SwapParams memory params,
        address bidder,
        address numeraire,
        AuctionId auctionId
    ) internal returns (bytes memory) {
        AuctionTypes.CallbackDataClaimToken memory callbackDataStruct = AuctionTypes.CallbackDataClaimToken({
            bidder: bidder,
            numeraire: numeraire,
            auctionId: auctionId,
            poolKey: key,
            swapParams: params
        });
        bytes memory callbackData = abi.encode(uint8(4), abi.encode(callbackDataStruct));
        return manager.unlock(callbackData);
    }

	/**
	 * @notice Check if settlement phase should end based on duration
	 * @param self The contract instance (CPAManager via DELEGATECALL)
	 * @param auctionId The auction ID
	 * @return true if settlement phase duration has expired
	 * @dev Storage mappings are accessed via helpers since DELEGATECALL executes in CPAManager's storage context
	 */
	function shouldSettlementPhaseEnd(
		CPAStorage self, 
		AuctionId auctionId
	) public view returns (bool) {
		// Check if settlement phase duration has expired
		uint256 startTime = self.settlementPhaseStartTime(auctionId);
		if (startTime == 0) return false; // Phase not started yet
		
		// Get auctionInfo and phase duration from auction config
		AuctionTypes.AuctionInfo memory auctionInfoData = StorageAccess.getAuctionInfo(auctionId);
		return block.timestamp >= startTime + auctionInfoData.config.phaseDurations[2];
	}

}