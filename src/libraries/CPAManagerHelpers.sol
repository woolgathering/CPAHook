// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { CPAStorage } from "../base/CPAStorage.sol";
import { StorageAccess } from "../utils/StorageAccess.sol";
import { IErrorsAndEvents } from "../utils/IErrorsAndEvents.sol";
import { AuctionTypes } from "../types/AuctionTypes.sol";
import { AuctionId } from "../types/AuctionId.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { ICPAHook } from "../interfaces/ICPAHook.sol";

/**
 * @title CPAManagerHelpers
 * @notice Internal helper functions for CPAManager using StorageAccess
 * @dev All functions operate via DELEGATECALL in CPAManager's storage context
 */
contract CPAManagerHelpers {
    using StorageAccess for *;

    /**
     * @notice Change auction phase
     * @param self The contract instance (CPAManager via DELEGATECALL)
     * @param auctionId The auction ID
     * @param newPhase The new phase
     */
    function changePhase(
        CPAStorage self,
        AuctionId auctionId,
        AuctionTypes.AuctionPhase newPhase
    ) internal {
        StorageAccess.setAuctionPhase(auctionId, newPhase);
        
        // Track phase start times for duration checks
        if (newPhase == AuctionTypes.AuctionPhase.Proxy) {
            StorageAccess.setProxyPhaseStartTime(auctionId, block.timestamp);
        } else if (newPhase == AuctionTypes.AuctionPhase.Allocation) {
            StorageAccess.setAllocationPhaseStartTime(auctionId, block.timestamp);
        } else if (newPhase == AuctionTypes.AuctionPhase.Settlement) {
            StorageAccess.setSettlementPhaseStartTime(auctionId, block.timestamp);
        }
        
        updateCPAHookStates(self, auctionId);
        emit IErrorsAndEvents.AuctionPhaseChanged(auctionId, newPhase);
    }

    /**
     * @notice Check if a phase has expired based on duration
     * @param self The contract instance (CPAManager via DELEGATECALL)
     * @param auctionId The auction ID
     * @param phase The phase to check
     * @return true if phase has expired
     */
    function hasPhaseExpired(
        CPAStorage self,
        AuctionId auctionId,
        AuctionTypes.AuctionPhase phase
    ) internal view returns (bool) {
        uint256[] memory durations = StorageAccess.getAuctionPhaseDurations(auctionId);
        
        if (phase == AuctionTypes.AuctionPhase.Proxy) {
            uint256 startTime = StorageAccess.getProxyPhaseStartTime(auctionId);
            if (startTime == 0) return false;
            return block.timestamp >= startTime + durations[0];
        }
        
        if (phase == AuctionTypes.AuctionPhase.Allocation) {
            uint256 startTime = StorageAccess.getAllocationPhaseStartTime(auctionId);
            if (startTime == 0) return false;
            return block.timestamp >= startTime + durations[1];
        }
        
        if (phase == AuctionTypes.AuctionPhase.Settlement) {
            uint256 startTime = StorageAccess.getSettlementPhaseStartTime(auctionId);
            if (startTime == 0) return false;
            return block.timestamp >= startTime + durations[2];
        }
        
        // Clock phase doesn't use time-based expiration
        return false;
    }

    /**
     * @notice Start the clock round
     * @param self The contract instance (CPAManager via DELEGATECALL)
     * @param auctionId The auction ID
     * @param setupLib Address of the setup library
     * @param clockPhaseLib Address of the clock phase library
     */
    function startClockRound(
        CPAStorage self,
        AuctionId auctionId,
        address setupLib,
        address clockPhaseLib
    ) internal {
        // Handle first-time transition from Setup to Clock phase
        if (StorageAccess.getAuctionPhase(auctionId) == AuctionTypes.AuctionPhase.Setup) {
            // This would need to call setupLib, but we'll handle that in CPAManager
            // For now, just transition to Clock phase
            StorageAccess.setAuctionPhase(auctionId, AuctionTypes.AuctionPhase.Clock);
            updateCPAHookStates(self, auctionId);
            emit IErrorsAndEvents.AuctionPhaseChanged(auctionId, AuctionTypes.AuctionPhase.Clock);
        }
        // The actual clock round opening is handled by clockPhaseLib via delegatecall in CPAManager
    }

    /**
     * @notice End the clock phase
     * @param self The contract instance (CPAManager via DELEGATECALL)
     * @param auctionId The auction ID
     * @param clockPhaseLib Address of the clock phase library
     * @param manager The pool manager address
     */
    function endClockPhase(
        CPAStorage self,
        AuctionId auctionId,
        address clockPhaseLib,
        address manager
    ) internal {
        // Close the current clock round if it's still open
        if (StorageAccess.getAuctionClockOpen(auctionId) == 2) {
            // This would need to call clockPhaseLib, but we'll handle that in CPAManager
            // For now, just note that the clock needs to be closed
        }
        
        // Handle undersell by reverting to last oversold prices
        // This would need to call clockPhaseLib, but we'll handle that in CPAManager
        
        // Transition to proxy phase
        changePhase(self, auctionId, AuctionTypes.AuctionPhase.Proxy);
    }

    /**
     * @notice Update pool hook states
     * @param self The contract instance (CPAManager via DELEGATECALL)
     * @param auctionId The auction ID
     */
    function updateCPAHookStates(
        CPAStorage self,
        AuctionId auctionId
    ) internal {
        AuctionTypes.AuctionInfo memory auction = StorageAccess.getAuctionInfo(auctionId);
        PoolKey[] memory poolKeys = auction.poolKeys;
        address cpaAuctionHookAddr = StorageAccess.getCpaAuctionHookAddr();
        for (uint256 i = 0; i < poolKeys.length; i++) {
            ICPAHook(cpaAuctionHookAddr).setPoolState(poolKeys[i], auction.currentPhase);
        }
    }
}
