// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IPositionManager } from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";

import { CPAStorage } from "./CPAStorage.sol";
import { CPASetup } from "../libraries/CPASetup.sol";
import { CPAClockPhase } from "../libraries/CPAClockPhase.sol";
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
		address _protocolWallet
	) CPAStorage(_cpaAuctionHookAddr, _positionManager) Ownable(_owner) {
		manager = _poolManager;
		protocolWallet = _protocolWallet;
	}

	// ========================================
	// MODIFIERS
	// ========================================

	modifier onlyAuctionOwner(AuctionId auctionId) {
		if (auctionInfo[auctionId].auctionOwner == address(0)) revert AuctionNotFound();
		if (auctionInfo[auctionId].auctionOwner != msg.sender) revert Unauthorized();
		_;
	}

	modifier onlyPoolManager() {
		if (msg.sender != address(manager)) revert Unauthorized();
		_;
	}

	modifier whenAuctionActive(AuctionId auctionId) {
		if (auctionInfo[auctionId].currentStatus != AuctionTypes.AuctionStatus.Active)
			revert AuctionNotActive(auctionId, auctionInfo[auctionId].currentStatus);
		_;
	}

	modifier whenAuctionCancelled(AuctionId auctionId) {
		if (auctionInfo[auctionId].currentStatus != AuctionTypes.AuctionStatus.Cancelled)
			revert AuctionNotCancelled(auctionId);
		_;
	}

	modifier onlyPhase(AuctionId auctionId, AuctionTypes.AuctionPhase phase) {
		if (auctionInfo[auctionId].currentPhase != phase)
			revert InvalidPhase(phase, auctionInfo[auctionId].currentPhase);
		_;
	}

	modifier onlyWhenPhaseExpired(AuctionId auctionId, AuctionTypes.AuctionPhase phase) {
		uint256[] memory durations = auctionInfo[auctionId].config.phaseDurations;
		uint256 startTime;

		if (phase == AuctionTypes.AuctionPhase.Proxy) {
			startTime = proxyPhaseStartTime[auctionId];
			if (startTime == 0) revert PhaseNotStarted(auctionId);
			if (block.timestamp < startTime + durations[0]) revert PhaseNotExpired(auctionId, phase);
		} else if (phase == AuctionTypes.AuctionPhase.Allocation) {
			startTime = allocationPhaseStartTime[auctionId];
			if (startTime == 0) revert PhaseNotStarted(auctionId);
			if (block.timestamp < startTime + durations[1]) revert PhaseNotExpired(auctionId, phase);
		} else if (phase == AuctionTypes.AuctionPhase.Settlement) {
			startTime = settlementPhaseStartTime[auctionId];
			if (startTime == 0) revert PhaseNotStarted(auctionId);
			if (block.timestamp < startTime + durations[2]) revert PhaseNotExpired(auctionId, phase);
		} else {
			revert PhaseNotExpired(auctionId, phase);
		}
		_;
	}

	modifier onlyWhenPhaseNotExpired(AuctionId auctionId, AuctionTypes.AuctionPhase phase) {
		if (_hasPhaseExpired(auctionId, phase)) revert PhaseExpired(auctionId, phase);
		_;
	}

	modifier validateEthForNumeraire(AuctionId auctionId) {
		address numeraire = auctionInfo[auctionId].commonNumeraire;
		if (numeraire == address(0) && msg.value == 0) revert EthRequired();
		if (numeraire != address(0) && msg.value > 0) revert EthNotAllowed();
		_;
	}

	// ========================================
	// INTERNAL HELPERS
	// ========================================

	function _startClockRound(AuctionId auctionId) internal {
		if (auctionInfo[auctionId].currentPhase == AuctionTypes.AuctionPhase.Setup) {
			if (!CPASetup.confirmSetupComplete(this, auctionId, auctionInfo[auctionId], poolInfo))
				revert SetupNotComplete();
			auctionInfo[auctionId].currentPhase = AuctionTypes.AuctionPhase.Clock;
			_updateCPAHookStates(auctionId);
			emit AuctionPhaseChanged(auctionId, AuctionTypes.AuctionPhase.Clock);
		}
		CPAClockPhase.openClockRound(auctionId, auctionInfo);
	}

	function _endClockPhase(AuctionId auctionId) internal {
		if (auctionInfo[auctionId].clockOpen == 2) {
			CPAClockPhase.setClockOpen(auctionId, 1, auctionInfo);
			emit ClockRoundClosed(auctionId, auctionInfo[auctionId].currentRound, activeBidders[auctionId].length);
		}
		CPAClockPhase.revertUndersoldPrices(auctionInfo[auctionId], poolInfo, manager);
		_changePhase(auctionId, AuctionTypes.AuctionPhase.Proxy);
	}

	function removeBidder(AuctionId auctionId, address bidder) internal {
		address[] storage activeBiddersInThisAuction = activeBidders[auctionId];
		for (uint256 i = 0; i < activeBiddersInThisAuction.length; i++) {
			if (activeBiddersInThisAuction[i] == bidder) {
				activeBiddersInThisAuction[i] = address(0);
				break;
			}
		}
	}

	function _changePhase(AuctionId auctionId, AuctionTypes.AuctionPhase newPhase) internal {
		auctionInfo[auctionId].currentPhase = newPhase;

		if (newPhase == AuctionTypes.AuctionPhase.Proxy) {
			proxyPhaseStartTime[auctionId] = block.timestamp;
		} else if (newPhase == AuctionTypes.AuctionPhase.Allocation) {
			allocationPhaseStartTime[auctionId] = block.timestamp;
		} else if (newPhase == AuctionTypes.AuctionPhase.Settlement) {
			settlementPhaseStartTime[auctionId] = block.timestamp;
		}

		_updateCPAHookStates(auctionId);
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

	function _updateCPAHookStates(AuctionId auctionId) internal {
		PoolKey[] memory poolKeys = auctionInfo[auctionId].poolKeys;
		for (uint256 i = 0; i < poolKeys.length; i++) {
			ICPAHook(cpaAuctionHookAddr).setPoolState(poolKeys[i], auctionInfo[auctionId].currentPhase);
		}
	}

	function _cancelAuction(AuctionId auctionId) internal {
		auctionInfo[auctionId].currentStatus = AuctionTypes.AuctionStatus.Cancelled;
		_updateCPAHookStates(auctionId);
		emit AuctionCancelled(auctionId, msg.sender);
	}
}
