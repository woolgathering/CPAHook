// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { CPAStorage } from "../base/CPAStorage.sol";
import { StorageAccess } from "../utils/StorageAccess.sol";
import { IErrorsAndEvents } from "../utils/IErrorsAndEvents.sol";
import { AuctionTypes } from "../types/AuctionTypes.sol";
import { AuctionId } from "../types/AuctionId.sol";

/**
 * @title CPAUtilities
 * @notice Utility functions using StorageAccess
 * @dev All functions operate via DELEGATECALL in CPAManager's storage context
 */
contract CPAUtilities {
    using StorageAccess for *;

    /**
     * @notice Get the current bidder demands for an auction
     * @param self The contract instance (CPAManager via DELEGATECALL)
     * @param auctionId The auction ID
     * @param bidder The bidder address
     * @return The bidder's demand array
     */
    function getBidderDemands(
        CPAStorage self,
        AuctionId auctionId,
        address bidder
    ) internal view returns (uint256[] memory) {
        return StorageAccess.getBids(auctionId, bidder);
    }

    /**
     * @notice Register a commit hash (called by proxies)
     * @param self The contract instance (CPAManager via DELEGATECALL)
     * @param auctionId The auction ID
     * @param commitHash The commit hash to register
     * @param caller The caller address (proxy)
     */
    function registerCommit(
        CPAStorage self,
        AuctionId auctionId,
        bytes32 commitHash,
        address caller
    ) internal {
        if (StorageAccess.getCommitProxy(auctionId, commitHash) != address(0)) {
            revert IErrorsAndEvents.InvalidCommitHash();
        }
        StorageAccess.setCommitProxy(auctionId, commitHash, caller);
    }

    /**
     * @notice Commit to a bidder (proxy function)
     * @param self The contract instance (CPAManager via DELEGATECALL)
     * @param auctionId The auction ID
     * @param commitHash The commit hash
     * @param caller The caller address (proxy)
     */
    function commitToBidder(
        CPAStorage self,
        AuctionId auctionId,
        bytes32 commitHash,
        address caller
    ) internal {
        StorageAccess.setCommitProxy(auctionId, commitHash, caller);
    }
}
