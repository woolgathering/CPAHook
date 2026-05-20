// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IPositionManager } from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

import { CPABase } from "./CPABase.sol";
import { CPASetup } from "../libraries/CPASetup.sol";
import { CPAClockPhase } from "../libraries/CPAClockPhase.sol";
import { AuctionTypes } from "../types/AuctionTypes.sol";
import { AuctionId } from "../types/AuctionId.sol";

abstract contract CPABaseClock is CPABase {

	constructor(
		IPoolManager _poolManager,
		address _owner,
		address _cpaAuctionHookAddr,
		IPositionManager _positionManager,
		address _protocolWallet,
		address _mathFacet
	) CPABase(_poolManager, _owner, _cpaAuctionHookAddr, _positionManager, _protocolWallet, _mathFacet) {}

	modifier onlyWhenPhaseExpired(AuctionId auctionId, AuctionTypes.AuctionPhase phase) {
		_onlyWhenPhaseExpired(auctionId, phase);
		_;
	}

	function _onlyWhenPhaseExpired(AuctionId auctionId, AuctionTypes.AuctionPhase phase) internal view {
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
	}

	function _startClockRound(AuctionId auctionId) internal {
		if (auctionInfo[auctionId].currentPhase == AuctionTypes.AuctionPhase.Setup) {
			if (!CPASetup.confirmSetupComplete(this, auctionId, auctionInfo[auctionId], poolInfo))
				revert SetupNotComplete();
			auctionInfo[auctionId].currentPhase = AuctionTypes.AuctionPhase.Clock;
			_updateCpaHookStates(auctionId);
			emit AuctionPhaseChanged(auctionId, AuctionTypes.AuctionPhase.Clock);
		}
		CPAClockPhase.openClockRound(auctionId, auctionInfo);
	}

	function _endClockPhase(AuctionId auctionId) internal {
		if (auctionInfo[auctionId].clockOpen == 2) {
			CPAClockPhase.setClockOpen(auctionId, 1, auctionInfo);
			emit ClockRoundClosed(auctionId, auctionInfo[auctionId].currentRound, activeBidders[auctionId].length);
		}
		CPAClockPhase.revertUndersoldPrices(auctionInfo[auctionId], poolInfo, manager, mathFacet);
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
}
