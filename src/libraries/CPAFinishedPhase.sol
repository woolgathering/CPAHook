// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { IPositionManager } from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";

import { CPAStorage } from "../base/CPAStorage.sol";
import { StorageAccess } from "../utils/StorageAccess.sol";
import { IErrorsAndEvents } from "../utils/IErrorsAndEvents.sol";
import { AuctionTypes } from "../types/AuctionTypes.sol";
import { AuctionId } from "../types/AuctionId.sol";

/**
 * @title CPAFinishedPhase
 * @notice Library for handling operations in the Finished phase of the auction
 * @dev Contains functions for transferring positions to the auctioneer
 */
contract CPAFinishedPhase {
	using StorageAccess for *;
    using PoolIdLibrary for PoolKey;

    /**
     * @notice Transfer all NFT positions from CPAManager to the auctioneer
     * @dev Iterates through all pools in the auction and transfers their position NFTs
     * @param self The contract instance (CPAManager via DELEGATECALL)
     * @param auctionId The auction identifier
     * @dev Storage mappings are accessed via helpers since DELEGATECALL executes in CPAManager's storage context
     */
    function transferPositionsToAuctioneer(
        CPAStorage self,
        AuctionId auctionId
    ) public {
        // Get auctionInfo via helper
        AuctionTypes.AuctionInfo memory auctionInfo = StorageAccess.getAuctionInfo(auctionId);
        address auctionOwner = auctionInfo.auctionOwner;
        PoolKey[] memory poolKeys = auctionInfo.poolKeys;
        IPositionManager positionManager = self.positionManager();
        
        // Transfer each position NFT to the auctioneer
        for (uint256 i = 0; i < poolKeys.length; i++) {
            PoolId poolId = poolKeys[i].toId();
            // Get poolInfo via helper
            AuctionTypes.PoolInfo memory pool = StorageAccess.getPoolInfo(poolId);
            uint256 tokenId = pool.positionId;
            
            // Transfer the position NFT from CPAManager to auctioneer
            // Cast to IERC721 to access safeTransferFrom method
            IERC721(address(positionManager)).safeTransferFrom(
                address(self),
                auctionOwner,
                tokenId
            );
            
            // Emit event for tracking
            emit IErrorsAndEvents.PositionTransferred(
                auctionId,
                poolId,
                tokenId,
                auctionOwner
            );
        }
    }
}

