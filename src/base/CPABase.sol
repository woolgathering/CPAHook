// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IPositionManager } from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";

import { CPAStorage } from "./CPAStorage.sol";
import { IErrorsAndEvents } from "../utils/IErrorsAndEvents.sol";
import { ICPAHook } from "../interfaces/ICPAHook.sol";
import { AuctionTypes } from "../types/AuctionTypes.sol";
import { AuctionId } from "../types/AuctionId.sol";

abstract contract CPABase is IErrorsAndEvents, Ownable, CPAStorage, ReentrancyGuard {

	constructor(
		IPoolManager _poolManager,
		address _owner,
		address _cpaAuctionHookAddr,
		IPositionManager _positionManager,
		address _protocolWallet,
		address _mathFacet
	) CPAStorage(_mathFacet, _cpaAuctionHookAddr, _positionManager) Ownable(_owner) {
		manager = _poolManager;
		protocolWallet = _protocolWallet;
	}

	// ========================================
	// MODIFIERS
	// ========================================

	modifier onlyAuctionOwner(AuctionId auctionId) {
		_onlyAuctionOwner(auctionId);
		_;
	}

	// Allows the diamond to call onlyAuctionOwner-gated sub-steps from an orchestrating function
	// that has already verified the real caller is the auction owner.
	modifier onlyAuctionOwnerOrSelf(AuctionId auctionId) {
		_onlyAuctionOwnerOrSelf(auctionId);
		_;
	}

	modifier onlyPoolManager() {
		_onlyPoolManager();
		_;
	}

	modifier whenAuctionActive(AuctionId auctionId) {
		_whenAuctionActive(auctionId);
		_;
	}

	modifier whenAuctionCancelled(AuctionId auctionId) {
		_whenAuctionCancelled(auctionId);
		_;
	}

	modifier onlyPhase(AuctionId auctionId, AuctionTypes.AuctionPhase phase) {
		_onlyPhase(auctionId, phase);
		_;
	}

	modifier onlyWhenPhaseNotExpired(AuctionId auctionId, AuctionTypes.AuctionPhase phase) {
		_onlyWhenPhaseNotExpired(auctionId, phase);
		_;
	}

	modifier validateEthForNumeraire(AuctionId auctionId) {
		_validateEthForNumeraire(auctionId);
		_;
	}

	// ========================================
	// MODIFIER IMPLEMENTATION FUNCTIONS
	// ========================================

	function _onlyAuctionOwner(AuctionId auctionId) internal view {
		if (auctionInfo[auctionId].auctionOwner == address(0)) revert AuctionNotFound();
		if (auctionInfo[auctionId].auctionOwner != msg.sender) revert Unauthorized();
	}

	function _onlyAuctionOwnerOrSelf(AuctionId auctionId) internal view {
		if (auctionInfo[auctionId].auctionOwner == address(0)) revert AuctionNotFound();
		if (auctionInfo[auctionId].auctionOwner != msg.sender && msg.sender != address(this))
			revert Unauthorized();
	}

	function _onlyPoolManager() internal view {
		if (msg.sender != address(manager)) revert Unauthorized();
	}

	function _whenAuctionActive(AuctionId auctionId) internal view {
		if (auctionInfo[auctionId].currentStatus != AuctionTypes.AuctionStatus.Active)
			revert AuctionNotActive(auctionId, auctionInfo[auctionId].currentStatus);
	}

	function _whenAuctionCancelled(AuctionId auctionId) internal view {
		if (auctionInfo[auctionId].currentStatus != AuctionTypes.AuctionStatus.Cancelled)
			revert AuctionNotCancelled(auctionId);
	}

	function _onlyPhase(AuctionId auctionId, AuctionTypes.AuctionPhase phase) internal view {
		if (auctionInfo[auctionId].currentPhase != phase)
			revert InvalidPhase(phase, auctionInfo[auctionId].currentPhase);
	}

	function _onlyWhenPhaseNotExpired(AuctionId auctionId, AuctionTypes.AuctionPhase phase) internal view {
		if (_hasPhaseExpired(auctionId, phase)) revert PhaseExpired(auctionId, phase);
	}

	function _validateEthForNumeraire(AuctionId auctionId) internal view {
		address numeraire = auctionInfo[auctionId].commonNumeraire;
		if (numeraire == address(0) && msg.value == 0) revert EthRequired();
		if (numeraire != address(0) && msg.value > 0) revert EthNotAllowed();
	}

	// ========================================
	// INTERNAL HELPERS
	// ========================================

	function _changePhase(AuctionId auctionId, AuctionTypes.AuctionPhase newPhase) internal {
		auctionInfo[auctionId].currentPhase = newPhase;

		if (newPhase == AuctionTypes.AuctionPhase.Proxy) {
			proxyPhaseStartTime[auctionId] = block.timestamp;
		} else if (newPhase == AuctionTypes.AuctionPhase.Allocation) {
			allocationPhaseStartTime[auctionId] = block.timestamp;
		} else if (newPhase == AuctionTypes.AuctionPhase.Settlement) {
			settlementPhaseStartTime[auctionId] = block.timestamp;
		}

		_updateCpaHookStates(auctionId);
		emit AuctionPhaseChanged(auctionId, newPhase);
	}

	function _hasPhaseExpired(AuctionId auctionId, AuctionTypes.AuctionPhase phase) internal view returns (bool) {
		uint256[] memory durations = auctionInfo[auctionId].config.phaseDurations;

		if (phase == AuctionTypes.AuctionPhase.Proxy) {
			uint256 startTime = proxyPhaseStartTime[auctionId];
			if (startTime == 0) return false;
			return block.timestamp >= startTime + durations[0];
		}

		if (phase == AuctionTypes.AuctionPhase.Allocation) {
			uint256 startTime = allocationPhaseStartTime[auctionId];
			if (startTime == 0) return false;
			return block.timestamp >= startTime + durations[1];
		}

		if (phase == AuctionTypes.AuctionPhase.Settlement) {
			uint256 startTime = settlementPhaseStartTime[auctionId];
			if (startTime == 0) return false;
			return block.timestamp >= startTime + durations[2];
		}

		return false;
	}

	function _updateCpaHookStates(AuctionId auctionId) internal {
		PoolKey[] memory poolKeys = auctionInfo[auctionId].poolKeys;
		for (uint256 i = 0; i < poolKeys.length; i++) {
			ICPAHook(cpaAuctionHookAddr).setPoolState(poolKeys[i], auctionInfo[auctionId].currentPhase);
		}
	}

	function _cancelAuction(AuctionId auctionId) internal {
		auctionInfo[auctionId].currentStatus = AuctionTypes.AuctionStatus.Cancelled;
		_updateCpaHookStates(auctionId);
		emit AuctionCancelled(auctionId, msg.sender);
	}
}
