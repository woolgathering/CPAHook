// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { CPAStorage } from "../base/CPAStorage.sol";
import { StorageAccess } from "../utils/StorageAccess.sol";
import { IErrorsAndEvents } from "../utils/IErrorsAndEvents.sol";
import { AuctionTypes } from "../types/AuctionTypes.sol";
import { AuctionId } from "../types/AuctionId.sol";
import { ICPAHook } from "../interfaces/ICPAHook.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";

/**
 * @title CPAAuctionControl
 * @notice External contract for auction control functions (pause, unpause, cancel, forfeit, reclaimStake)
 * @dev Functions execute via DELEGATECALL from CPAManager, operating in CPAManager's storage context
 */
contract CPAAuctionControl {
    using StorageAccess for *;
    
    uint256 public constant FORFEITURE_REWARD_RATE = 500; // 5% reward (basis points)

    /**
     * @notice Pause the auction
     * @param self The contract instance (CPAManager via DELEGATECALL)
     * @param auctionId The auction ID
     * @param caller The address calling the function (msg.sender from CPAManager)
     * @param cpaAuctionHookAddr The CPA auction hook address for state updates
     */
    function pause(
        CPAStorage self,
        AuctionId auctionId,
        address caller,
        address cpaAuctionHookAddr
    ) public {
        AuctionTypes.AuctionInfo memory auction = StorageAccess.getAuctionInfo(auctionId);
        
        // Cannot pause if already paused
        if (auction.currentStatus == AuctionTypes.AuctionStatus.Paused) {
            revert IErrorsAndEvents.AuctionNotActive(auctionId, AuctionTypes.AuctionStatus.Paused);
        }
        
        // Cannot pause in Settlement or Finished phases
        if (auction.currentPhase == AuctionTypes.AuctionPhase.Settlement || 
            auction.currentPhase == AuctionTypes.AuctionPhase.Finished) {
            revert IErrorsAndEvents.InvalidPhase(AuctionTypes.AuctionPhase.Setup, auction.currentPhase);
        }
        
        // Check if total pause duration would exceed maximum (only block when exceeded, not when equal)
        uint256 currentPauseDuration = auction.totalPauseDuration;
        if (currentPauseDuration > AuctionTypes.MAX_PAUSE_DURATION) {
            revert IErrorsAndEvents.MaxPauseDurationExceeded(currentPauseDuration, AuctionTypes.MAX_PAUSE_DURATION);
        }
        
        auction.currentStatus = AuctionTypes.AuctionStatus.Paused;
        StorageAccess.setAuctionInfo(auctionId, auction);
        StorageAccess.setPauseStartTime(auctionId, block.timestamp);
        
        _updateCPAHookStates(self, auctionId, cpaAuctionHookAddr);
        emit IErrorsAndEvents.AuctionPaused(auctionId, caller);
    }

    /**
     * @notice Unpause the auction
     * @param self The contract instance (CPAManager via DELEGATECALL)
     * @param auctionId The auction ID
     * @param caller The address calling the function (msg.sender from CPAManager)
     * @param cpaAuctionHookAddr The CPA auction hook address for state updates
     */
    function unpause(
        CPAStorage self,
        AuctionId auctionId,
        address caller,
        address cpaAuctionHookAddr
    ) public {
        AuctionTypes.AuctionInfo memory auction = StorageAccess.getAuctionInfo(auctionId);
        
        if (auction.currentStatus != AuctionTypes.AuctionStatus.Paused) {
            revert IErrorsAndEvents.AuctionNotActive(auctionId, auction.currentStatus);
        }
        
        // Calculate what total pause duration would be after unpausing
        uint256 pauseStart = StorageAccess.getPauseStartTime(auctionId);
        uint256 newTotalPauseDuration = auction.totalPauseDuration + (block.timestamp - pauseStart);
        
        // Block unpause if total pause duration would be >= MAX_PAUSE_DURATION
        // This enforces the hard limit: once you hit max, you must cancel
        if (newTotalPauseDuration >= AuctionTypes.MAX_PAUSE_DURATION) {
            revert IErrorsAndEvents.MaxPauseDurationExceeded(newTotalPauseDuration, AuctionTypes.MAX_PAUSE_DURATION);
        }
        
        // Update total pause duration
        auction.totalPauseDuration = newTotalPauseDuration;
        auction.currentStatus = AuctionTypes.AuctionStatus.Active;
        StorageAccess.setAuctionInfo(auctionId, auction);
        StorageAccess.setPauseStartTime(auctionId, 0);
        
        _updateCPAHookStates(self, auctionId, cpaAuctionHookAddr);
        emit IErrorsAndEvents.AuctionUnpaused(auctionId, caller);
    }

    /**
     * @notice Cancel the auction and refund all stakes
     * @dev Only allowed in Setup and Clock phases
     * @param self The contract instance (CPAManager via DELEGATECALL)
     * @param auctionId The auction ID
     * @param caller The address calling the function (msg.sender from CPAManager)
     * @param cpaAuctionHookAddr The CPA auction hook address for state updates
     */
    function cancelAuction(
        CPAStorage self,
        AuctionId auctionId,
        address caller,
        address cpaAuctionHookAddr
    ) public {
        AuctionTypes.AuctionPhase phase = StorageAccess.getAuctionPhase(auctionId);
        if (phase != AuctionTypes.AuctionPhase.Setup && phase != AuctionTypes.AuctionPhase.Clock) {
            revert IErrorsAndEvents.CannotCancelInThisPhase(auctionId, phase);
        }
        
        AuctionTypes.AuctionInfo memory auction = StorageAccess.getAuctionInfo(auctionId);
        auction.currentStatus = AuctionTypes.AuctionStatus.Cancelled;
        StorageAccess.setAuctionInfo(auctionId, auction);
        
        _updateCPAHookStates(self, auctionId, cpaAuctionHookAddr);
        emit IErrorsAndEvents.AuctionCancelled(auctionId, caller);
    }

    /**
     * @notice Force cancel auction when max pause duration exceeded
     * @dev Anyone can call this after 72 hours of total pause time
     * @param self The contract instance (CPAManager via DELEGATECALL)
     * @param auctionId The auction ID
     * @param caller The address calling the function (msg.sender from CPAManager)
     * @param cpaAuctionHookAddr The CPA auction hook address for state updates
     */
    function forceCancelAuction(
        CPAStorage self,
        AuctionId auctionId,
        address caller,
        address cpaAuctionHookAddr
    ) public {
        AuctionTypes.AuctionInfo memory auction = StorageAccess.getAuctionInfo(auctionId);
        
        // Calculate total pause duration including current pause
        uint256 totalPauseDuration = auction.totalPauseDuration;
        if (auction.currentStatus == AuctionTypes.AuctionStatus.Paused) {
            uint256 pauseStart = StorageAccess.getPauseStartTime(auctionId);
            totalPauseDuration += block.timestamp - pauseStart;
        }
        
        // Only allow force cancel if max pause duration exceeded
        if (totalPauseDuration < AuctionTypes.MAX_PAUSE_DURATION) {
            revert IErrorsAndEvents.PauseDurationNotExceeded(totalPauseDuration, AuctionTypes.MAX_PAUSE_DURATION);
        }
        
        auction.currentStatus = AuctionTypes.AuctionStatus.Cancelled;
        StorageAccess.setAuctionInfo(auctionId, auction);
        
        _updateCPAHookStates(self, auctionId, cpaAuctionHookAddr);
        emit IErrorsAndEvents.AuctionCancelled(auctionId, caller);
    }

    /**
     * @notice Reclaim stake by bidder
     * @param self The contract instance (CPAManager via DELEGATECALL)
     * @param auctionId The auction ID
     * @param bidder The bidder address reclaiming stake
     */
    function reclaimStake(
        CPAStorage self,
        AuctionId auctionId,
        address bidder
    ) public {
        uint256 stake = StorageAccess.getBidderStake(auctionId, bidder);
        if (stake == 0) revert IErrorsAndEvents.InvalidStakeAmount();
        
        AuctionTypes.AuctionStatus status = StorageAccess.getAuctionStatus(auctionId);
        
        // If cancelled: full refund, no penalties
        if (status == AuctionTypes.AuctionStatus.Cancelled) {
            AuctionTypes.AuctionInfo memory cancelledAuction = StorageAccess.getAuctionInfo(auctionId);
            StorageAccess.setBidderStake(auctionId, bidder, 0);
            StorageAccess.setBidderBidPoints(auctionId, bidder, 0);
            
            AuctionTypes.CallbackDataRefundStake memory refundData = AuctionTypes.CallbackDataRefundStake({
                numeraire: cancelledAuction.commonNumeraire,
                recipient: bidder,
                amount: stake
            });
            self.manager().unlock(abi.encode(uint8(5), abi.encode(refundData)));
            emit IErrorsAndEvents.StakeRefunded(auctionId, bidder, stake);
            return;
        }
        
        AuctionTypes.AuctionInfo memory auction = StorageAccess.getAuctionInfo(auctionId);
        
        // Otherwise: only allow in Finished phase (prevent loophole during Settlement)
        if (auction.currentPhase != AuctionTypes.AuctionPhase.Finished) {
            revert IErrorsAndEvents.InvalidPhase(AuctionTypes.AuctionPhase.Finished, auction.currentPhase);
        }
        
        // Apply minSpendRatio penalty for bidders who didn't claim during Settlement OR participated in the Clock but did not continue
        uint256 penaltyRate = auction.config.minSpendRatio;
        uint256 penalty = stake * penaltyRate / 10000;
        StorageAccess.addProtocolPenalty(auctionId, penalty);
        
        // Clear bidder state
        StorageAccess.setBidderStake(auctionId, bidder, 0);
        StorageAccess.setBidderBidPoints(auctionId, bidder, 0);
        
        // Transfer refund
        AuctionTypes.CallbackDataRefundStake memory data = AuctionTypes.CallbackDataRefundStake({
            numeraire: auction.commonNumeraire,
            recipient: bidder,
            amount: stake - penalty
        });
        self.manager().unlock(abi.encode(uint8(5), abi.encode(data)));
        
        emit IErrorsAndEvents.PenaltyApplied(auctionId, bidder, penalty);
        emit IErrorsAndEvents.StakeRefunded(auctionId, bidder, stake - penalty);
    }

    /**
     * @notice Forfeit bidder who didn't claim in time
     * @dev Only callable in Finished phase. Caller gets 1% reward incentive.
     * @param self The contract instance (CPAManager via DELEGATECALL)
     * @param auctionId The auction ID
     * @param bidder The bidder address to forfeit
     * @param caller The address calling the function (msg.sender from CPAManager)
     */
    function forfeit(
        CPAStorage self,
        AuctionId auctionId,
        address bidder,
        address caller
    ) public {
        uint256 stake = StorageAccess.getBidderStake(auctionId, bidder);
        if (stake == 0) revert IErrorsAndEvents.InvalidStakeAmount(); // No stake to forfeit
        
        AuctionTypes.AuctionInfo memory auction = StorageAccess.getAuctionInfo(auctionId);
        
        // Calculate penalty and reward amounts
        uint256 penaltyRate = auction.config.minSpendRatio;
        
        // Transfer penalty to protocol
        uint256 penalty = stake * penaltyRate / 10000;
        StorageAccess.addProtocolPenalty(auctionId, penalty);
        
        // Transfer reward to caller
        uint256 callerReward = stake * FORFEITURE_REWARD_RATE / 10000;
        if (callerReward > 0) {
            AuctionTypes.CallbackDataRefundStake memory data = AuctionTypes.CallbackDataRefundStake({
                numeraire: auction.commonNumeraire,
                recipient: caller,
                amount: callerReward
            });
            self.manager().unlock(abi.encode(uint8(5), abi.encode(data)));
            
            emit IErrorsAndEvents.ForfeitureRewardTransferred(auctionId, caller, callerReward);
        }
        
        // Transfer remaining stake back to bidder
        uint256 remaining = stake - (stake * (penaltyRate + FORFEITURE_REWARD_RATE) / 10000);
        if (remaining > 0) {
            AuctionTypes.CallbackDataRefundStake memory refundData = AuctionTypes.CallbackDataRefundStake({
                numeraire: auction.commonNumeraire,
                recipient: bidder,
                amount: remaining
            });
            self.manager().unlock(abi.encode(uint8(5), abi.encode(refundData)));
        }
        
        // Zero out bidder state
        StorageAccess.setBidderStake(auctionId, bidder, 0);
        StorageAccess.setBidderBidPoints(auctionId, bidder, 0);
        
        emit IErrorsAndEvents.BundleForfeited(auctionId, bidder, penalty);
    }

    /**
     * @notice Dropout from auction with penalty. Can only be done during the clock phase.
     * @param self The contract instance (CPAManager via DELEGATECALL)
     * @param auctionId The auction ID
     * @param bidder The bidder address dropping out
     */
    function dropout(
        CPAStorage self,
        AuctionId auctionId,
        address bidder
    ) public {
        uint256 stake = StorageAccess.getBidderStake(auctionId, bidder);
        if (stake == 0) revert IErrorsAndEvents.InvalidStakeAmount(); // this also covers the case where the bidder is not in the auction
        
        AuctionTypes.AuctionInfo memory auction = StorageAccess.getAuctionInfo(auctionId);
        uint256 penalty = (stake * auction.config.dropoutSlashRatio) / 10000;
        uint256 refund = stake - penalty;
        
        // Clear bidder data
        StorageAccess.setBidderStake(auctionId, bidder, 0);
        StorageAccess.setBidderBidPoints(auctionId, bidder, 0);
        
        // Remove bidder from active bidders array
        uint256 length = StorageAccess.getActiveBiddersLength(auctionId);
        for (uint256 i = 0; i < length; i++) {
            if (StorageAccess.getActiveBidder(auctionId, i) == bidder) {
                StorageAccess.setActiveBidder(auctionId, i, address(0)); // just leave it as 0, it's fine
                break;
            }
        }
        
        // Set dropped bidder status
        StorageAccess.setDroppedBidder(auctionId, bidder, true);
        
        // Accumulate penalty for protocol
        StorageAccess.addProtocolPenalty(auctionId, penalty);
        
        // Transfer refund to bidder
        AuctionTypes.CallbackDataRefundStake memory data = AuctionTypes.CallbackDataRefundStake({
            numeraire: auction.commonNumeraire,
            recipient: bidder,
            amount: refund
        });
        self.manager().unlock(abi.encode(uint8(5), abi.encode(data)));
        
        emit IErrorsAndEvents.PenaltyApplied(auctionId, bidder, penalty);
        emit IErrorsAndEvents.StakeRefunded(auctionId, bidder, refund);
    }

    /**
     * @notice Claim the allocator reward for the winning allocation.
     * @dev Only callable by the winning allocator during or after the settlement phase.
     *      This function will trigger a callback to transfer the reward to the allocator.
     * @param self The contract instance (CPAManager via DELEGATECALL)
     * @param auctionId The auction ID
     * @param allocator The allocator address claiming the reward
     */
    function claimAllocatorReward(
        CPAStorage self,
        AuctionId auctionId,
        address allocator
    ) public {
        AuctionTypes.TopAllocation memory topAlloc = StorageAccess.getTopAllocation(auctionId);
        address winningAllocator = topAlloc.allocation.allocator;
        if (allocator != winningAllocator) revert IErrorsAndEvents.Unauthorized();

        AuctionTypes.AuctionPhase phase = StorageAccess.getAuctionPhase(auctionId);
        if (
            phase != AuctionTypes.AuctionPhase.Settlement &&
            phase != AuctionTypes.AuctionPhase.Finished
        ) {
            revert IErrorsAndEvents.InvalidPhase(AuctionTypes.AuctionPhase.Settlement, phase);
        }

        AuctionTypes.AuctionInfo memory auction = StorageAccess.getAuctionInfo(auctionId);
        uint256 reward = auction.allocatorReward;

        // Call the settlement phase to handle the actual reward transfer (callback will be implemented separately)
        AuctionTypes.CallbackDataClaimAllocatorReward memory data = AuctionTypes.CallbackDataClaimAllocatorReward({
            allocator: winningAllocator,
            reward: reward,
            numeraire: auction.commonNumeraire
        });
        emit IErrorsAndEvents.AllocatorRewardClaimed(auctionId, winningAllocator, reward);
        self.manager().unlock(abi.encode(uint8(6), abi.encode(data)));
        StorageAccess.setAuctionAllocatorReward(auctionId, 0); // update their reward to 0 since it was claimed
    }

    /**
     * @notice Update pool hook states
     * @param self The contract instance (CPAManager via DELEGATECALL)
     * @param auctionId The auction ID
     * @param cpaAuctionHookAddr The CPA auction hook address
     */
    function _updateCPAHookStates(
        CPAStorage self,
        AuctionId auctionId,
        address cpaAuctionHookAddr
    ) internal {
        AuctionTypes.AuctionInfo memory auction = StorageAccess.getAuctionInfo(auctionId);
        PoolKey[] memory poolKeys = auction.poolKeys;
        AuctionTypes.AuctionPhase phase = auction.currentPhase;
        
        for (uint256 i = 0; i < poolKeys.length; i++) {
            ICPAHook(cpaAuctionHookAddr).setPoolState(poolKeys[i], phase);
        }
    }
}

