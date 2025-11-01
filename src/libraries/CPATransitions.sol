// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { CPAStorage } from "../base/CPAStorage.sol";
import { StorageAccess } from "../utils/StorageAccess.sol";
import { IErrorsAndEvents } from "../utils/IErrorsAndEvents.sol";
import { AuctionTypes } from "../types/AuctionTypes.sol";
import { AuctionId } from "../types/AuctionId.sol";

/**
 * @title CPATransitions
 * @notice Phase transition logic using StorageAccess
 * @dev All functions operate via DELEGATECALL in CPAManager's storage context
 */
contract CPATransitions {
    using StorageAccess for *;

    /**
     * @notice Transition from Proxy to Allocation phase (callable by anyone)
     * @param self The contract instance (CPAManager via DELEGATECALL)
     * @param auctionId The auction ID
     * @param caller The address calling the function (msg.sender from CPAManager)
     */
    function transitionToAllocation(
        CPAStorage self,
        AuctionId auctionId,
        address caller
    ) internal {
        // Check if phase has expired (no auctioneer override for bidder protection)
        uint256[] memory durations = StorageAccess.getAuctionPhaseDurations(auctionId);
        uint256 startTime = StorageAccess.getProxyPhaseStartTime(auctionId);
        if (startTime == 0 || block.timestamp < startTime + durations[0]) {
            revert IErrorsAndEvents.PhaseNotExpired(auctionId, AuctionTypes.AuctionPhase.Proxy);
        }
        
        // Check if any bundles were submitted
        if (!StorageAccess.getHasBundles(auctionId)) {
            StorageAccess.setAuctionStatus(auctionId, AuctionTypes.AuctionStatus.Cancelled);
            // Note: Hook states update will be handled by CPAManager if needed
            // Since we're reverting, the status change won't persist, which is correct behavior
            emit IErrorsAndEvents.AuctionCancelled(auctionId, caller);
            revert IErrorsAndEvents.NoSubmissionsReceived(auctionId, AuctionTypes.AuctionPhase.Proxy);
        }
        
        // Transition to allocation phase - delegate to helpersLib
        // This will be handled by CPAManager calling _changePhase
    }

    /**
     * @notice Transition from Allocation to Settlement phase (callable by anyone)
     * @param self The contract instance (CPAManager via DELEGATECALL)
     * @param auctionId The auction ID
     * @param allocationPhaseLib Address of the allocation phase library
     * @param caller The address calling the function (msg.sender from CPAManager)
     */
    function transitionToSettlement(
        CPAStorage self,
        AuctionId auctionId,
        address allocationPhaseLib,
        address caller
    ) internal {
        // Check if phase has expired (no auctioneer override for bidder protection)
        uint256[] memory durations = StorageAccess.getAuctionPhaseDurations(auctionId);
        uint256 startTime = StorageAccess.getAllocationPhaseStartTime(auctionId);
        if (startTime == 0 || block.timestamp < startTime + durations[1]) {
            revert IErrorsAndEvents.PhaseNotExpired(auctionId, AuctionTypes.AuctionPhase.Allocation);
        }
        
        // Check if any allocations were submitted
        // if not, force cancel the auction
        if (!StorageAccess.getHasAllocations(auctionId)) {
            StorageAccess.setAuctionStatus(auctionId, AuctionTypes.AuctionStatus.Cancelled);
            // Note: Hook states update will be handled by CPAManager if needed
            // Since we're reverting, the status change won't persist, which is correct behavior
            emit IErrorsAndEvents.AuctionCancelled(auctionId, caller);
            revert IErrorsAndEvents.NoSubmissionsReceived(auctionId, AuctionTypes.AuctionPhase.Allocation);
        }

        // select the winner and move the assets to the pools
        // This will be handled via delegatecall in CPAManager to allocationPhaseLib
        
        // Transition to settlement phase - delegate to helpersLib
        // This will be handled by CPAManager calling _changePhase
    }

    /**
     * @notice Transition from Settlement to Finished phase (callable by anyone)
     * @param self The contract instance (CPAManager via DELEGATECALL)
     * @param auctionId The auction ID
     */
    function transitionToFinished(
        CPAStorage self,
        AuctionId auctionId
    ) internal {
        // Check if phase has expired (no auctioneer override for bidder protection)
        uint256[] memory durations = StorageAccess.getAuctionPhaseDurations(auctionId);
        uint256 startTime = StorageAccess.getSettlementPhaseStartTime(auctionId);
        if (startTime == 0 || block.timestamp < startTime + durations[2]) {
            revert IErrorsAndEvents.PhaseNotExpired(auctionId, AuctionTypes.AuctionPhase.Settlement);
        }
        
        // Transition to finished phase - delegate to helpersLib
        // This will be handled by CPAManager calling _changePhase
    }
}
