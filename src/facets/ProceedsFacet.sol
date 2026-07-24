// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { NumeraireLib } from "../libraries/NumeraireLib.sol";

import { CPABase } from "../base/CPABase.sol";
import { AuctionTypes } from "../types/AuctionTypes.sol";
import { AuctionId } from "../types/AuctionId.sol";
import { AssetConfig, AssetIdLibrary } from "../types/AssetConfig.sol";

contract ProceedsFacet is CPABase {
    using SafeERC20 for IERC20;

    constructor(
        address _owner,
        address _protocolWallet,
        uint256 _protocolFeeBps,
        address _mathFacet
    ) CPABase(_owner, _protocolWallet, _protocolFeeBps, _mathFacet) {}

    /// @notice Return unsold assets and numeraire proceeds to the auctioneer.
    function returnProceeds(AuctionId auctionId) external {
        AuctionTypes.AuctionInfo storage info = auctionInfo[auctionId];

        if (msg.sender != info.auctionOwner) revert Unauthorized();
        if (
            info.currentPhase != AuctionTypes.AuctionPhase.Settlement &&
            info.currentPhase != AuctionTypes.AuctionPhase.Finished
        ) revert InvalidPhase(AuctionTypes.AuctionPhase.Settlement, info.currentPhase);
        if (_settlement[auctionId].proceedsClaimed) revert ProceedsAlreadyClaimed(auctionId);

        _settlement[auctionId].proceedsClaimed = true;

        if (_settlement[auctionId].createPoolOnFinish) revert World2NotImplemented();

        address numeraire = info.commonNumeraire;
        uint256 totalNumeraire = NumeraireLib.balanceOf(numeraire, address(this));
        uint256 reserved = _settlement[auctionId].protocolAccrued;
        uint256 proceeds = totalNumeraire > reserved ? totalNumeraire - reserved : 0;
        if (proceeds > 0) {
            NumeraireLib.transfer(numeraire, info.auctionOwner, proceeds);
            emit ProceedsClaimed(auctionId, info.auctionOwner, proceeds);
        }

        AssetConfig[] memory assets = info.assets;
        for (uint256 i = 0; i < assets.length; ) {
            address assetToken = assets[i].assetToken;
            uint256 remaining = _settlement[auctionId].assetBalance[assetToken];
            if (remaining > 0) {
                _settlement[auctionId].assetBalance[assetToken] = 0;
                IERC20(assetToken).safeTransfer(info.auctionOwner, remaining);
                emit AssetsWithdrawn(auctionId, AssetIdLibrary.createId(auctionId, assetToken), assetToken, remaining);
            }
            unchecked { ++i; }
        }
    }

    /// @notice Withdraw accumulated protocol fees and penalties for an auction.
    function withdrawProtocolFees(AuctionId auctionId) external {
        if (msg.sender != protocolWallet) revert Unauthorized();

        uint256 amount = _settlement[auctionId].protocolAccrued;
        if (amount == 0) return;

        _settlement[auctionId].protocolAccrued = 0;
        address numeraire = auctionInfo[auctionId].commonNumeraire;
        NumeraireLib.transfer(numeraire, protocolWallet, amount);

        emit ProtocolFeesWithdrawn(auctionId, protocolWallet, amount);
    }
}
