// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;


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
import { CommitReveal } from "../utils/CommitReveal.sol";
import { IErrorsAndEvents } from "../utils/IErrorsAndEvents.sol";
import { AuctionTypes } from "../types/AuctionTypes.sol";
import { AuctionId } from "../types/AuctionId.sol";
import { BundleId } from "../types/BundleId.sol";

library CPASettlementPhase {
    using StateLibrary for IPoolManager;
    using SafeCast for *;
    using CurrencySettler for Currency;

	function endSettlementPhase(CPAStorage self, AuctionId auctionId) internal {
		// any leftover stake is forfeited here
	}

    function reveal(
        CPAStorage self,
        AuctionId auctionId,
        address bidder,
        address proxy,
        bytes32 saltA,
        bytes32 saltB,
        mapping(AuctionId => mapping(bytes32 => address)) storage commitProxy,
        mapping(AuctionId => mapping(bytes32 => address)) storage revealedMappings
    ) internal {
        bytes32 computedCommitHash = CommitReveal.generateCommitHash(bidder, proxy, saltA, saltB);

        // now check if there exists a commit hash for this auction in the commit proxy mapping
        if (commitProxy[auctionId][computedCommitHash] == address(0)) revert IErrorsAndEvents.NoSuchCommitHash(auctionId, computedCommitHash);

        // now check if the commit hash has already been revealed
        if (revealedMappings[auctionId][computedCommitHash] != address(0)) revert IErrorsAndEvents.DuplicateReveal(auctionId, computedCommitHash);

        // now set the revealed mapping
        revealedMappings[auctionId][computedCommitHash] = bidder;

        emit IErrorsAndEvents.RevealProcessed(auctionId, bidder, proxy, computedCommitHash);
    }

    function claimAllTokens(
        CPAStorage self,
        address bidder,
        AuctionId auctionId,
        bytes32 commitHash,
        AuctionTypes.AuctionInfo storage auctionInfo,
        mapping(bytes32 => address) storage revealedMappings,
        mapping(address => uint256) storage bidderStake,
        mapping(BundleId => AuctionTypes.Bundle) storage bundles,
        mapping(bytes32 => BundleId) storage winningBundleIds,
        mapping(AuctionId => uint256) storage protocolPenalties
    ) internal {
        // Validate bidder authorization
        {
            address revealedBidder = revealedMappings[commitHash];
            if (revealedBidder == address(0)) revert IErrorsAndEvents.CommitHashNotYetRevealed(auctionId, commitHash);
            if (revealedBidder != bidder) revert IErrorsAndEvents.Unauthorized();
        }

        // In a future version, we should combine both calls
        // to the PoolManager into a single call to save gas.
        BundleId bundleId = winningBundleIds[commitHash];
        bytes memory data = self.manager().unlock(abi.encode(uint8(7), abi.encode(AuctionTypes.CallbackDataClaimAllTokens({
			bidder: bidder,
			numeraire: auctionInfo.commonNumeraire,
			auctionId: auctionId,
			poolKeys: auctionInfo.poolKeys,
			allocatedQuantities: bundles[bundleId].quantities
		}))));

        (uint256 numerairePaidFromStake) = abi.decode(data, (uint256));

        // Update stake balance and handle min spend penalties
        uint256 currentStake = bidderStake[bidder];
        uint256 minSpendAmount = auctionInfo.config.minSpendRatio * currentStake / 10000;
        
        if (minSpendAmount > numerairePaidFromStake) {
            // Didn't meet minimum spend - penalty applies
            protocolPenalties[auctionId] += minSpendAmount - numerairePaidFromStake;
            bidderStake[bidder] -= minSpendAmount;
        } else {
            // Met minimum spend - no penalty
            bidderStake[bidder] -= numerairePaidFromStake;
        }
        
        // Transfer any remaining stake directly to bidder
        if (bidderStake[bidder] > 0) {
            AuctionTypes.CallbackDataRefundStake memory refundData = AuctionTypes.CallbackDataRefundStake({
                numeraire: auctionInfo.commonNumeraire,
                recipient: bidder,
                amount: bidderStake[bidder]
            });
            self.manager().unlock(abi.encode(uint8(5), abi.encode(refundData)));
            
            // Zero out bidder stake
            bidderStake[bidder] = 0;
        }
    }

    function claimToken(
        CPAStorage self,
        address bidder,
        AuctionId auctionId,
        bytes32 commitHash,
        PoolId poolId,
        AuctionTypes.Allocation memory topAllocation,
        AuctionTypes.AuctionInfo storage auctionInfo,
        mapping(BundleId => AuctionTypes.Bundle) storage bundles,
        mapping(bytes32 => BundleId) storage winningBundleIds,
        mapping(address => uint256) storage bidderStake,
        mapping(bytes32 => address) storage revealedMappings
    ) internal {
        // Validate bidder authorization
        {
            address revealedBidder = revealedMappings[commitHash];
            if (revealedBidder == address(0)) revert IErrorsAndEvents.CommitHashNotYetRevealed(auctionId, commitHash);
            if (revealedBidder != bidder) revert IErrorsAndEvents.Unauthorized();
        }

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
            BundleId bundleId = winningBundleIds[commitHash];
            AuctionTypes.Bundle memory bundle = bundles[bundleId];
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
            bidderStake[bidder] -= numerairePaidByManager;
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
	 * @param self The contract instance
	 * @param auctionId The auction ID
	 * @param auctionInfo The auction info mapping
	 * @return true if settlement phase duration has expired
	 */
	function shouldSettlementPhaseEnd(
		CPAStorage self, 
		AuctionId auctionId,
		mapping(AuctionId => AuctionTypes.AuctionInfo) storage auctionInfo
	) internal view returns (bool) {
		// Check if settlement phase duration has expired
		uint256 startTime = self.settlementPhaseStartTime(auctionId);
		if (startTime == 0) return false; // Phase not started yet
		
		// Get phase duration from auction config
		return block.timestamp >= startTime + auctionInfo[auctionId].config.phaseDurations[2];
	}

}