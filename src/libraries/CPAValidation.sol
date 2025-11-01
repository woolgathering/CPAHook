// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { CPAStorage } from "../base/CPAStorage.sol";
import { StorageAccess } from "../utils/StorageAccess.sol";
import { IErrorsAndEvents } from "../utils/IErrorsAndEvents.sol";
import { AuctionTypes } from "../types/AuctionTypes.sol";
import { AuctionId } from "../types/AuctionId.sol";

/**
 * @title CPAValidation
 * @notice Validation functions converted from modifiers using StorageAccess
 * @dev All functions operate via DELEGATECALL in CPAManager's storage context
 */
library CPAValidation {
    using StorageAccess for *;

    /**
     * @notice Validate that caller is the auction owner
     * @param self The contract instance (CPAManager via DELEGATECALL)
     * @param auctionId The auction ID
     * @param caller The caller address
     */
    function validateAuctionOwner(
        CPAStorage self,
        AuctionId auctionId,
        address caller
    ) internal view {
        address auctionOwner = StorageAccess.getAuctionOwner(auctionId);
        if (auctionOwner == address(0)) revert IErrorsAndEvents.AuctionNotFound();
        if (auctionOwner != caller) revert IErrorsAndEvents.Unauthorized();
    }

    /**
     * @notice Validate that auction is active (not paused or cancelled)
     * @param self The contract instance (CPAManager via DELEGATECALL)
     * @param auctionId The auction ID
     */
    function validateAuctionActive(
        CPAStorage self,
        AuctionId auctionId
    ) internal view {
        AuctionTypes.AuctionStatus status = StorageAccess.getAuctionStatus(auctionId);
        if (status != AuctionTypes.AuctionStatus.Active) {
            revert IErrorsAndEvents.AuctionNotActive(auctionId, status);
        }
    }

    /**
     * @notice Validate that auction is cancelled
     * @param self The contract instance (CPAManager via DELEGATECALL)
     * @param auctionId The auction ID
     */
    function validateAuctionCancelled(
        CPAStorage self,
        AuctionId auctionId
    ) internal view {
        AuctionTypes.AuctionStatus status = StorageAccess.getAuctionStatus(auctionId);
        if (status != AuctionTypes.AuctionStatus.Cancelled) {
            revert IErrorsAndEvents.AuctionNotCancelled(auctionId);
        }
    }

    /**
     * @notice Validate that auction is in expected phase
     * @param self The contract instance (CPAManager via DELEGATECALL)
     * @param auctionId The auction ID
     * @param expectedPhase The expected phase
     */
    function validatePhase(
        CPAStorage self,
        AuctionId auctionId,
        AuctionTypes.AuctionPhase expectedPhase
    ) internal view {
        AuctionTypes.AuctionPhase currentPhase = StorageAccess.getAuctionPhase(auctionId);
        if (currentPhase != expectedPhase) {
            revert IErrorsAndEvents.InvalidPhase(expectedPhase, currentPhase);
        }
    }

    /**
     * @notice Validate that phase has expired based on duration
     * @param self The contract instance (CPAManager via DELEGATECALL)
     * @param auctionId The auction ID
     * @param phase The phase to check
     */
    function validatePhaseExpired(
        CPAStorage self,
        AuctionId auctionId,
        AuctionTypes.AuctionPhase phase
    ) internal view {
        uint256[] memory durations = StorageAccess.getAuctionPhaseDurations(auctionId);
        uint256 startTime;
        
        if (phase == AuctionTypes.AuctionPhase.Proxy) {
            startTime = StorageAccess.getProxyPhaseStartTime(auctionId);
            if (startTime == 0) revert IErrorsAndEvents.PhaseNotStarted(auctionId);
            if (block.timestamp < startTime + durations[0]) {
                revert IErrorsAndEvents.PhaseNotExpired(auctionId, phase);
            }
        } else if (phase == AuctionTypes.AuctionPhase.Allocation) {
            startTime = StorageAccess.getAllocationPhaseStartTime(auctionId);
            if (startTime == 0) revert IErrorsAndEvents.PhaseNotStarted(auctionId);
            if (block.timestamp < startTime + durations[1]) {
                revert IErrorsAndEvents.PhaseNotExpired(auctionId, phase);
            }
        } else if (phase == AuctionTypes.AuctionPhase.Settlement) {
            startTime = StorageAccess.getSettlementPhaseStartTime(auctionId);
            if (startTime == 0) revert IErrorsAndEvents.PhaseNotStarted(auctionId);
            if (block.timestamp < startTime + durations[2]) {
                revert IErrorsAndEvents.PhaseNotExpired(auctionId, phase);
            }
        } else {
            revert IErrorsAndEvents.PhaseNotExpired(auctionId, phase); // Clock phase doesn't expire
        }
    }

    /**
     * @notice Validate that phase has not expired
     * @param self The contract instance (CPAManager via DELEGATECALL)
     * @param auctionId The auction ID
     * @param phase The phase to check
     */
    function validatePhaseNotExpired(
        CPAStorage self,
        AuctionId auctionId,
        AuctionTypes.AuctionPhase phase
    ) internal view {
        // Use CPAManagerHelpers.hasPhaseExpired - but since we're in a library, we'll inline the logic
        uint256[] memory durations = StorageAccess.getAuctionPhaseDurations(auctionId);
        uint256 startTime;
        bool expired = false;
        
        if (phase == AuctionTypes.AuctionPhase.Proxy) {
            startTime = StorageAccess.getProxyPhaseStartTime(auctionId);
            if (startTime != 0) {
                expired = block.timestamp >= startTime + durations[0];
            }
        } else if (phase == AuctionTypes.AuctionPhase.Allocation) {
            startTime = StorageAccess.getAllocationPhaseStartTime(auctionId);
            if (startTime != 0) {
                expired = block.timestamp >= startTime + durations[1];
            }
        } else if (phase == AuctionTypes.AuctionPhase.Settlement) {
            startTime = StorageAccess.getSettlementPhaseStartTime(auctionId);
            if (startTime != 0) {
                expired = block.timestamp >= startTime + durations[2];
            }
        }
        // Clock phase doesn't expire based on time
        
        if (expired) {
            revert IErrorsAndEvents.PhaseExpired(auctionId, phase);
        }
    }

    /**
     * @notice Validate ETH handling for numeraire
     * @dev For ETH numeraire: requires msg.value > 0
     *      For ERC20 numeraire: requires msg.value == 0
     * @param self The contract instance (CPAManager via DELEGATECALL)
     * @param auctionId The auction ID
     * @param msgValue The msg.value to validate
     */
    function validateEthForNumeraireValue(
        CPAStorage self,
        AuctionId auctionId,
        uint256 msgValue
    ) internal view {
        address numeraire = StorageAccess.getAuctionCommonNumeraire(auctionId);
        if (numeraire == address(0) && msgValue == 0) revert IErrorsAndEvents.EthRequired();
        if (numeraire != address(0) && msgValue > 0) revert IErrorsAndEvents.EthNotAllowed();
    }
}
