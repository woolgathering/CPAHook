// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { Hooks } from "@uniswap/v4-core/src/libraries/Hooks.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { SafeCast } from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { Currency, CurrencyLibrary } from "@uniswap/v4-core/src/types/Currency.sol";
import { SwapParams, ModifyLiquidityParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";
import { BalanceDelta, toBalanceDelta, BalanceDeltaLibrary } from "@uniswap/v4-core/src/types/BalanceDelta.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
// wanted to use Ownable2Step but we were getting some errors
// review this thread: https://github.com/OpenZeppelin/openzeppelin-contracts/issues/4690
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { CurrencySettler } from "@openzeppelin/uniswap-hooks/src/utils/CurrencySettler.sol";

import { CPAStorage } from "./base/CPAStorage.sol";
import { CPASetup } from "./libraries/CPASetup.sol";
import { CPAClockPhase } from "./libraries/CPAClockPhase.sol";
import { CPAProxyPhase } from "./libraries/CPAProxyPhase.sol";
import { CPAAllocationPhase } from "./libraries/CPAAllocationPhase.sol";
import { CPASettlementPhase } from "./libraries/CPASettlementPhase.sol";

import { IErrorsAndEvents } from "./utils/IErrorsAndEvents.sol";
import { CommitReveal } from "./utils/CommitReveal.sol";
import { AuctionTypes } from "./types/AuctionTypes.sol";
import { AuctionId } from "./types/AuctionId.sol";
import { BundleId } from "./types/BundleId.sol";
import { CPAHook } from "./CPAHook.sol";

/**
 * @title CPAManager
 * @notice Main auction manager implementing clock-proxy auction with commit-reveal privacy
 * @author notthatintodefi.eth
 */
contract CPAManager is IErrorsAndEvents, Ownable, CPAStorage {
	using AuctionTypes for *;
	using PoolIdLibrary for PoolKey;
	using CurrencySettler for Currency;
	using BalanceDeltaLibrary for BalanceDelta;
	using CurrencyLibrary for Currency;
	using SafeCast for *;

	// ========================================
	// CONSTANTS AND STATE VARIABLES
	// ========================================

	uint256 constant twoPow96 = 2**96;

	// ========================================
	// CONSTRUCTOR
	// ========================================

	/**
	 * @notice Constructor
	 * @param _poolManager The V4 pool manager
	 * @param _owner The auction owner
	 */
	constructor(
		IPoolManager _poolManager,
		address _owner,
		address _cpaAuctionHookAddr,
		address _protocolWallet
	) Ownable(_owner) CPAStorage(_cpaAuctionHookAddr) {
		manager = _poolManager;
		protocolWallet = _protocolWallet;
	}

	// ========================================
	// MODIFIERS
	// ========================================

	modifier onlyAuctionOwner(AuctionId auctionId) {
		if (auctionInfo[auctionId].auctionOwner == address(0)) revert IErrorsAndEvents.AuctionNotFound();
		if (auctionInfo[auctionId].auctionOwner != msg.sender) revert IErrorsAndEvents.Unauthorized();
		_;
	}

	modifier onlyPoolManager() {
		if (msg.sender != address(manager)) revert IErrorsAndEvents.Unauthorized();
		_;
	}

	/**
	 * @notice Modifier to ensure auction is active (not paused or cancelled)
	 */
	modifier whenAuctionActive(AuctionId auctionId) {
		if (auctionInfo[auctionId].currentStatus != AuctionTypes.AuctionStatus.Active) revert IErrorsAndEvents.AuctionNotActive(auctionId, auctionInfo[auctionId].currentStatus);
		_;
	}

	modifier whenAuctionCancelled(AuctionId auctionId) {
		if (auctionInfo[auctionId].currentStatus != AuctionTypes.AuctionStatus.Cancelled) revert IErrorsAndEvents.AuctionNotCancelled(auctionId);
		_;
	}

	/**
	 * @notice Modifier to ensure auction is in expected phase
	 */
	modifier onlyPhase(AuctionId auctionId, AuctionTypes.AuctionPhase phase) {
		if (auctionInfo[auctionId].currentPhase != phase) revert InvalidPhase(phase, auctionInfo[auctionId].currentPhase);
		_;
	}

	/**
	 * @notice Modifier to ensure phase has expired based on duration
	 */
	modifier onlyWhenPhaseExpired(AuctionId auctionId, AuctionTypes.AuctionPhase phase) {
		uint256[] memory durations = auctionInfo[auctionId].config.phaseDurations;
		uint256 startTime;
		
		if (phase == AuctionTypes.AuctionPhase.Proxy) {
			startTime = proxyPhaseStartTime[auctionId];
			if (startTime == 0) revert IErrorsAndEvents.PhaseNotStarted(auctionId);
			if (block.timestamp < startTime + durations[0]) revert IErrorsAndEvents.PhaseNotExpired(auctionId, phase);
		} else if (phase == AuctionTypes.AuctionPhase.Allocation) {
			startTime = allocationPhaseStartTime[auctionId];
			if (startTime == 0) revert IErrorsAndEvents.PhaseNotStarted(auctionId);
			if (block.timestamp < startTime + durations[1]) revert IErrorsAndEvents.PhaseNotExpired(auctionId, phase);
		} else if (phase == AuctionTypes.AuctionPhase.Settlement) {
			startTime = settlementPhaseStartTime[auctionId];
			if (startTime == 0) revert IErrorsAndEvents.PhaseNotStarted(auctionId);
			if (block.timestamp < startTime + durations[2]) revert IErrorsAndEvents.PhaseNotExpired(auctionId, phase);
		} else {
			revert IErrorsAndEvents.PhaseNotExpired(auctionId, phase); // Clock phase doesn't expire
		}
		_;
	}

	// ========================================
	// AUCTION MANAGEMENT FUNCTIONS
	// ========================================

	function setCpaAuctionHookAddr(address _cpaAuctionHookAddr) external onlyOwner {
		cpaAuctionHookAddr = _cpaAuctionHookAddr;
	}

	/**
	 * @notice Pause the auction
	 */
	function pause(AuctionId auctionId) external onlyAuctionOwner(auctionId) {
		auctionInfo[auctionId].currentStatus = AuctionTypes.AuctionStatus.Paused;
		_updateCPAHookStates(auctionId);
		emit IErrorsAndEvents.AuctionPaused(auctionId, msg.sender);
	}

	/**
	 * @notice Unpause the auction
	 */
	function unpause(AuctionId auctionId) external onlyAuctionOwner(auctionId) {
		auctionInfo[auctionId].currentStatus = AuctionTypes.AuctionStatus.Active;
		_updateCPAHookStates(auctionId);
		emit IErrorsAndEvents.AuctionUnpaused(auctionId, msg.sender);
	}

	/**
	 * @notice Cancel the auction and refund all stakes
	 * @dev Only allowed in Setup and Clock phases
	 */
	function cancelAuction(AuctionId auctionId) external onlyAuctionOwner(auctionId) {
		AuctionTypes.AuctionPhase phase = auctionInfo[auctionId].currentPhase;
		if (phase != AuctionTypes.AuctionPhase.Setup && phase != AuctionTypes.AuctionPhase.Clock) {
			revert IErrorsAndEvents.CannotCancelInThisPhase(auctionId, phase);
		}
		
		auctionInfo[auctionId].currentStatus = AuctionTypes.AuctionStatus.Cancelled;
		_updateCPAHookStates(auctionId);
		emit IErrorsAndEvents.AuctionCancelled(auctionId, msg.sender);
	}

	function reclaimStake(AuctionId auctionId) external whenAuctionActive(auctionId) {
		uint256 stake = bidderStake[auctionId][msg.sender];
		if (stake == 0) revert IErrorsAndEvents.InvalidStakeAmount();
		
		AuctionTypes.AuctionStatus status = auctionInfo[auctionId].currentStatus;
		
		// If cancelled: full refund, no penalties
		if (status == AuctionTypes.AuctionStatus.Cancelled) {
			bidderStake[auctionId][msg.sender] = 0;
			bidderBidPoints[auctionId][msg.sender] = 0;
			
			AuctionTypes.CallbackDataRefundStake memory refundData = AuctionTypes.CallbackDataRefundStake({
				numeraire: auctionInfo[auctionId].commonNumeraire,
				recipient: msg.sender,
				amount: stake
			});
			manager.unlock(abi.encode(uint8(5), abi.encode(refundData)));
			emit IErrorsAndEvents.StakeRefunded(auctionId, msg.sender, stake);
			return;
		}
		
		// Otherwise: only allow in Finished phase (prevent loophole during Settlement)
		if (auctionInfo[auctionId].currentPhase != AuctionTypes.AuctionPhase.Finished) {
			revert IErrorsAndEvents.InvalidPhase(AuctionTypes.AuctionPhase.Finished, auctionInfo[auctionId].currentPhase);
		}
		
		// Apply minSpendRatio penalty for bidders who didn't claim during Settlement OR particpated in the Clock but did not continue
		uint256 penaltyRate = auctionInfo[auctionId].config.minSpendRatio;
		protocolPenalties[auctionId] += stake * penaltyRate / 10000;
		
		// Clear bidder state
		bidderStake[auctionId][msg.sender] = 0;
		bidderBidPoints[auctionId][msg.sender] = 0;
		
		// Transfer refund
		AuctionTypes.CallbackDataRefundStake memory data = AuctionTypes.CallbackDataRefundStake({
			numeraire: auctionInfo[auctionId].commonNumeraire,
			recipient: msg.sender,
			amount: stake - (stake * penaltyRate / 10000)
		});
		manager.unlock(abi.encode(uint8(5), abi.encode(data)));
		
		emit IErrorsAndEvents.PenaltyApplied(auctionId, msg.sender, stake * penaltyRate / 10000);
		emit IErrorsAndEvents.StakeRefunded(auctionId, msg.sender, stake - (stake * penaltyRate / 10000));
	}

	// ========================================
	// SETUP PHASE
	// ========================================

	/**
	 * @notice Create a new auction
	 * @param config The auction configuration (includes pool keys, initial prices, and price increments)
	 * @param auctionOwner The auction owner
	 * @return The auction ID
	 */
	function createAuction(
		AuctionTypes.AuctionConfig memory config, 
		address auctionOwner
	) external returns (AuctionId) {
		AuctionId auctionId = CPASetup.createAuction(this, config, auctionOwner, auctionInfo, poolToAuctionId, poolInfo);
		_updateCPAHookStates(auctionId);
		return auctionId;
	}

	/**
	 * @notice Move deposit from auction owner to a single pool, giving ERC6909 claims to CPAHook
	 * @param auctionId The auction ID
	 * @param poolKey The pool key to deposit to
	 * @param depositAmount The amount to deposit
	 */
	function moveDeposit(
		AuctionId auctionId,
		PoolKey memory poolKey,
		uint256 depositAmount
	) external onlyAuctionOwner(auctionId) {
		CPASetup.moveDeposit(this, auctionInfo[auctionId], poolInfo, poolKey, auctionId, depositAmount);
		_updateCPAHookStates(auctionId);
	}

	// ========================================
	// CLOCK PHASE
	// ========================================


	function startClockPhase(AuctionId auctionId) external onlyAuctionOwner(auctionId) onlyPhase(auctionId, AuctionTypes.AuctionPhase.Setup) {
		_startClockRound(auctionId);
	}

	/**
	 * @notice Start the clock phase
	 * @param auctionId The auction ID
	 */
	 function _startClockRound(AuctionId auctionId) internal {
		// Handle first-time transition from Setup to Clock phase
		if (auctionInfo[auctionId].currentPhase == AuctionTypes.AuctionPhase.Setup) {
			if (!CPASetup.confirmSetupComplete(this, auctionId, auctionInfo[auctionId], poolInfo)) revert IErrorsAndEvents.SetupNotComplete();
			// Transition to Clock phase
			auctionInfo[auctionId].currentPhase = AuctionTypes.AuctionPhase.Clock;
			_updateCPAHookStates(auctionId);
		}
		CPAClockPhase.openClockRound(auctionId, auctionInfo);
	}

	/**
	 * @notice End current clock round
	 * @param auctionId The auction ID
	 */
	 function endClockRound(AuctionId auctionId) external onlyAuctionOwner(auctionId) onlyPhase(auctionId, AuctionTypes.AuctionPhase.Clock) {
		// Set the clock to closed
		CPAClockPhase.setClockOpen(auctionId, 1, auctionInfo);
		
		// Process round results (calculate excess demand and update prices)
		uint256[] memory totalDemands = CPAClockPhase.processClockRound(this, auctionId, auctionInfo, poolInfo, bids, activeBidders);
		
		// Emit event for round closure
		emit IErrorsAndEvents.ClockRoundClosed(auctionId, auctionInfo[auctionId].currentRound, activeBidders[auctionId].length);

		if (CPAClockPhase.shouldEndClockPhase(auctionId, auctionInfo[auctionId], poolInfo, totalDemands, manager)) {
			_endClockPhase(auctionId);
		} else {
			_startClockRound(auctionId);
		}

		// Note: Clock remains closed after ending a round
		// The auctioneer must manually call startClockRound to begin the next round
	}

	/**
	 * @notice End the clock phase and transition to proxy phase
	 * @param auctionId The auction ID
	 */
	function _endClockPhase(AuctionId auctionId) internal {
		// Close the current clock round if it's still open
		if (auctionInfo[auctionId].clockOpen == 2) {
			CPAClockPhase.setClockOpen(auctionId, 1, auctionInfo);
			
			// Emit event for round closure
			emit IErrorsAndEvents.ClockRoundClosed(auctionId, auctionInfo[auctionId].currentRound, activeBidders[auctionId].length);
		}
		
		// Handle undersell by reverting to last oversold prices
		CPAClockPhase.revertUndersoldPrices(this, auctionId, auctionInfo[auctionId], poolInfo, manager);
		
		// Transition to proxy phase
		_changePhase(auctionId, AuctionTypes.AuctionPhase.Proxy);
	}

	/**
	 * @notice End the clock phase and transition to proxy phase
	 * @param auctionId The auction ID
	 */
	function endClockPhase(AuctionId auctionId) external onlyAuctionOwner(auctionId) onlyPhase(auctionId, AuctionTypes.AuctionPhase.Clock) {
		_endClockPhase(auctionId);
	}

	/**
	 * @notice Submit a bid during clock phase
	 * @param auctionId The auction ID
	 * @param demands Array of item demands
	 * @param maxStakeAmount Maximum stake amount the bidder is willing to provide for this bid
	 */
	function submitBid(
		AuctionId auctionId,
		uint256[] calldata demands,
		uint256 maxStakeAmount
	) external whenAuctionActive(auctionId) onlyPhase(auctionId, AuctionTypes.AuctionPhase.Clock) {
		CPAClockPhase.processBid(
			this,
			auctionId,
			demands,
			maxStakeAmount,
			auctionInfo,
			bidderStake,
			bidderBidPoints,
			poolInfo,
			bids[auctionId],
			activeBidders[auctionId]
		);
	}
	// we should consider using whenActive(auctionId) as the modifier and just have the actuon be active or inactive. Paused or cancelled can be emitted as an event or something. Having two modifiers feels unnecessary.


	/**
	 * @notice Commit to a bidder (proxy function)
	 * @param auctionId The auction ID
	 * @param commitHash The commit hash
	 */
	function commitToBidder(AuctionId auctionId, bytes32 commitHash) external {
		commitProxy[auctionId][commitHash] = msg.sender;
	}

	/**
	 * @notice Dropout from auction with penalty. Can only be done during the clock phase.
	 * @param auctionId The auction ID
	 */
	function dropout(AuctionId auctionId) external whenAuctionActive(auctionId) onlyPhase(auctionId, AuctionTypes.AuctionPhase.Clock) {
		uint256 stake = bidderStake[auctionId][msg.sender];
		if (stake == 0) revert IErrorsAndEvents.InvalidStakeAmount(); // this also covers the case where the bidder is not in the auction
		
		uint256 penalty = (stake * auctionInfo[auctionId].config.dropoutSlashRatio) / 10000;
		uint256 refund = stake - penalty;
		
		// Clear bidder data
		bidderStake[auctionId][msg.sender] = 0;
		bidderBidPoints[auctionId][msg.sender] = 0;
		
		// Set dropped bidder status
		droppedBidders[auctionId][msg.sender] = true;
		
		// Accumulate penalty for protocol
		protocolPenalties[auctionId] += penalty;
		
		// Transfer refund to bidder
		AuctionTypes.CallbackDataRefundStake memory data = AuctionTypes.CallbackDataRefundStake({
			numeraire: auctionInfo[auctionId].commonNumeraire,
			recipient: msg.sender,
			amount: refund
		});
		manager.unlock(abi.encode(uint8(5), abi.encode(data)));
		
		emit IErrorsAndEvents.PenaltyApplied(auctionId, msg.sender, penalty);
		emit IErrorsAndEvents.StakeRefunded(auctionId, msg.sender, refund);
	}

	// ========================================
	// PROXY PHASE
	// ========================================

	/**
	 * @notice Submit bundle during proxy phase
	 * @param auctionId The auction ID
	 * @param commitHash The commit hash
	 * @param bundleData The bundle data
	 * @dev This is submitted by a proxy on behalf of a bidder
	 */
	function submitBundle(
		AuctionId auctionId,
		bytes32 commitHash,
		AuctionTypes.Bundle calldata bundleData
	) external whenAuctionActive(auctionId) onlyPhase(auctionId, AuctionTypes.AuctionPhase.Proxy) returns (BundleId bundleId) {
		bundleId = CPAProxyPhase.submitBundle(this, commitHash, bundles, commitProxy, bundleData, hasBundles);
	}

	// ========================================
	// ALLOCATION PHASE
	// ========================================


	/**
	 * @notice Submit allocation during allocation phase
	 * @param auctionId The auction ID
	 * @param allocationData The allocation data
	 */
	function submitAllocation(
		AuctionId auctionId,
		AuctionTypes.Allocation calldata allocationData
	) external whenAuctionActive(auctionId) onlyPhase(auctionId, AuctionTypes.AuctionPhase.Allocation) {
		if (msg.sender != allocationData.allocator) revert IErrorsAndEvents.Unauthorized(); // cannot submit an allocation for someone else
		CPAAllocationPhase.submitAllocation(this, allocationData, topAllocation, auctionInfo, poolInfo, bundles, hasAllocations);
	}

	// ========================================
	// REVEAL PHASE (not sure if this is necessary or if it can be incorporated into the settlement phase)
	// ========================================

	/**
	 * @notice Reveal bidder identity
	 * @param auctionId The auction ID
	 * @param proxy The proxy address
	 * @param saltA First salt
	 * @param saltB Second salt
	 * @dev This is called by the before any settlement by the bidder to reveal their identity.
	 */
	function reveal(
		AuctionId auctionId,
		address proxy,
		bytes32 saltA,
		bytes32 saltB
	) external whenAuctionActive(auctionId) onlyPhase(auctionId, AuctionTypes.AuctionPhase.Settlement) {
		CPASettlementPhase.reveal(this, auctionId, msg.sender, proxy, saltA, saltB, commitProxy, revealedMappings);
	}

	// ========================================
	// SETTLEMENT PHASE	
	// ========================================


	// start settlement phase

	// end settlement phase

	// claim item(s)

	/**
	 * @notice Claim tokens from winning allocation
	 * @param auctionId The auction ID
	 * @param commitHash The commit hash for the bidder
	 * @param poolId The pool ID to claim from
	 */
	function claimToken(AuctionId auctionId, bytes32 commitHash, PoolId poolId) external whenAuctionActive(auctionId) onlyPhase(auctionId, AuctionTypes.AuctionPhase.Settlement) onlyOwner() {
		// we only allow the owner to claim individual tokens on behalf of the bidder because in this function,
		// we do not ever remove the bundle from the winning bundle ids.
		// the owner here is NOT the auction owner, but the owner of the CPA protocol itself.
		
		// Call the settlement phase
		CPASettlementPhase.claimToken(
			this,
			msg.sender,
			auctionId,
			commitHash,
			poolId,
			topAllocation[auctionId].allocation,
			auctionInfo[auctionId],
			bundles[auctionId],
			winningBundleIds,
			bidderStake[auctionId],
			revealedMappings[auctionId]
		);
	}

	/**
	 * @notice Claim all tokens from winning allocation for a bidder.
	 * @param auctionId The auction ID
	 * @param commitHash The commit hash for the bidder
	 */
	function claimAllTokens(AuctionId auctionId, bytes32 commitHash) external whenAuctionActive(auctionId) onlyPhase(auctionId, AuctionTypes.AuctionPhase.Settlement) {
		CPASettlementPhase.claimAllTokens(
			this,
			msg.sender,
			auctionId,
			commitHash,
			auctionInfo[auctionId],
			revealedMappings[auctionId],
			bidderStake[auctionId],
			bundles[auctionId],
			winningBundleIds,
			protocolPenalties
		);

		// now that they've claimed all their tokens, delete the bundle at the commit hash from the winning bundle ids
		winningBundleIds[commitHash] = BundleId.wrap(0);
	}

	/**
	 * @notice Claim the allocator reward for the winning allocation.
	 * @dev Only callable by the winning allocator during or after the settlement phase.
	 *      This function will trigger a callback to transfer the reward to the allocator.
	 * @param auctionId The auction ID
	 */
	function claimAllocatorReward(AuctionId auctionId) external {
		// AuctionTypes.TopAllocation storage topAlloc = topAllocation[auctionId];
		address winningAllocator = topAllocation[auctionId].allocation.allocator;
		if (msg.sender != winningAllocator) revert Unauthorized();

		AuctionTypes.AuctionPhase phase = auctionInfo[auctionId].currentPhase;
		if (
			phase != AuctionTypes.AuctionPhase.Settlement &&
			phase != AuctionTypes.AuctionPhase.Finished
		) {
			revert IErrorsAndEvents.InvalidPhase(AuctionTypes.AuctionPhase.Settlement, phase);
		}

		// Call the settlement phase to handle the actual reward transfer (callback will be implemented separately)
		AuctionTypes.CallbackDataClaimAllocatorReward memory data = AuctionTypes.CallbackDataClaimAllocatorReward({
			allocator: winningAllocator,
			reward: auctionInfo[auctionId].allocatorReward,
			numeraire: auctionInfo[auctionId].commonNumeraire
		});
		manager.unlock(abi.encode(uint8(6), abi.encode(data)));
		auctionInfo[auctionId].allocatorReward = 0; // update their reward to 0 since it was claimed

		emit IErrorsAndEvents.AllocatorRewardClaimed(auctionId, winningAllocator, auctionInfo[auctionId].allocatorReward);
	}

	// ========================================
	// PERMISSIONLESS PHASE TRANSITIONS
	// ========================================

	/**
	 * @notice Transition from Proxy to Allocation phase (callable by anyone)
	 * @param auctionId The auction ID
	 */
	function transitionToAllocation(AuctionId auctionId) external whenAuctionActive(auctionId) onlyPhase(auctionId, AuctionTypes.AuctionPhase.Proxy) {
		// Check if phase has expired (no auctioneer override for bidder protection)
		if (!_hasPhaseExpired(auctionId, AuctionTypes.AuctionPhase.Proxy)) {
			revert IErrorsAndEvents.PhaseNotExpired(auctionId, AuctionTypes.AuctionPhase.Proxy);
		}
		
		// Check if any bundles were submitted
		if (!hasBundles[auctionId]) {
			_cancelAuction(auctionId);
			revert IErrorsAndEvents.NoSubmissionsReceived(auctionId, AuctionTypes.AuctionPhase.Proxy);
		}
		
		// Transition to allocation phase
		_changePhase(auctionId, AuctionTypes.AuctionPhase.Allocation);
	}

	/**
	 * @notice Transition from Allocation to Settlement phase (callable by anyone)
	 * @param auctionId The auction ID
	 */
	function transitionToSettlement(AuctionId auctionId) external whenAuctionActive(auctionId) onlyPhase(auctionId, AuctionTypes.AuctionPhase.Allocation) {
		// Check if phase has expired (no auctioneer override for bidder protection)
		if (!_hasPhaseExpired(auctionId, AuctionTypes.AuctionPhase.Allocation)) {
			revert IErrorsAndEvents.PhaseNotExpired(auctionId, AuctionTypes.AuctionPhase.Allocation);
		}
		
		// Check if any allocations were submitted
		// if not, force cancel the auction
		if (!hasAllocations[auctionId]) {
			_cancelAuction(auctionId);
			revert IErrorsAndEvents.NoSubmissionsReceived(auctionId, AuctionTypes.AuctionPhase.Allocation);
		}

		// select the winner and move the assets to the pools
		CPAAllocationPhase.selectWinner(this, auctionId, topAllocation, auctionInfo, poolInfo, bundles, winningBundleIds);
		CPAAllocationPhase.transferAssetsToPools(this, auctionId, auctionInfo, poolInfo);
		
		// Transition to settlement phase
		_changePhase(auctionId, AuctionTypes.AuctionPhase.Settlement);
	}

	/**
	 * @notice Transition from Settlement to Finished phase (callable by anyone)
	 * @param auctionId The auction ID
	 */
	function transitionToFinished(AuctionId auctionId) external whenAuctionActive(auctionId) onlyPhase(auctionId, AuctionTypes.AuctionPhase.Settlement) {
		// Check if phase has expired (no auctioneer override for bidder protection)
		if (!_hasPhaseExpired(auctionId, AuctionTypes.AuctionPhase.Settlement)) {
			revert IErrorsAndEvents.PhaseNotExpired(auctionId, AuctionTypes.AuctionPhase.Settlement);
		}
		
		// Transition to finished phase
		_changePhase(auctionId, AuctionTypes.AuctionPhase.Finished);
	}

	// ========================================
	// UTILITY FUNCTIONS
	// ========================================

	/**
	 * @notice Get the current bidder demands for an auction
	 * @param auctionId The auction ID
	 * @param bidder The bidder address
	 * @return The bidder's demand array
	 */
	function getBidderDemands(AuctionId auctionId, address bidder) external view returns (uint256[] memory) {
		return bids[auctionId][bidder];
	}

	/**
	 * @notice Register a commit hash (called by proxies)
	 * @param auctionId The auction ID
	 * @param commitHash The commit hash to register
	 * @dev This is called by proxies to register a commit hash. THis can only be submitted during the setup and clock phases.
	 */
	function registerCommit(AuctionId auctionId, bytes32 commitHash) external {
		if (commitProxy[auctionId][commitHash] != address(0)) revert InvalidCommitHash();
		commitProxy[auctionId][commitHash] = msg.sender;
	}

	// ========================================
	// INTERNAL FUNCTIONS
	// ========================================

	/**
	 * @notice Change auction phase
	 * @param auctionId The auction ID
	 * @param newPhase The new phase
	 */
	function _changePhase(AuctionId auctionId, AuctionTypes.AuctionPhase newPhase) internal {
		auctionInfo[auctionId].currentPhase = newPhase;
		
		// Track phase start times for duration checks
		if (newPhase == AuctionTypes.AuctionPhase.Proxy) {
			proxyPhaseStartTime[auctionId] = block.timestamp;
		} else if (newPhase == AuctionTypes.AuctionPhase.Allocation) {
			allocationPhaseStartTime[auctionId] = block.timestamp;
		} else if (newPhase == AuctionTypes.AuctionPhase.Settlement) {
			settlementPhaseStartTime[auctionId] = block.timestamp;
		}
		
		_updateCPAHookStates(auctionId);
		emit IErrorsAndEvents.AuctionPhaseChanged(auctionId, newPhase);
	}

	/**
	 * @notice Check if a phase has expired based on duration
	 * @param auctionId The auction ID
	 * @param phase The phase to check
	 * @return true if phase has expired
	 */
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
		
		return false; // Clock phase doesn't use time-based expiration
	}

	/**
	 * @notice Update pool hook states
	 * @param auctionId The auction ID
	 */
	function _updateCPAHookStates(AuctionId auctionId) internal {
		PoolKey[] memory poolKeys = auctionInfo[auctionId].poolKeys;
		for (uint256 i = 0; i < poolKeys.length; i++) {
			// Get the pool hook address from the pool key
			// address cpaHookAddress = address(poolKeys[i].hooks);
			
			// Update the pool hook state
			CPAHook(cpaAuctionHookAddr).setPoolState(
				poolKeys[i],
				auctionInfo[auctionId].currentPhase
			);
		}
	}

	function _cancelAuction(AuctionId auctionId) internal {
		auctionInfo[auctionId].currentStatus = AuctionTypes.AuctionStatus.Cancelled;
		_updateCPAHookStates(auctionId);
		emit IErrorsAndEvents.AuctionCancelled(auctionId, msg.sender);
	}

	// ========================================
	// CALLBACK HANDLERS
	// ========================================

	/**
	 * @dev Unified unlock callback to handle multiple operation types
	 * @param rawData The callback data containing operation type and operation-specific data
	 * @return returnData The encoded balance deltas
	 */
	function unlockCallback(bytes calldata rawData)
		external
		onlyPoolManager
		returns (bytes memory returnData)
	{
		// Decode the operation type and operation-specific data
		(uint8 operationType, bytes memory operationData) = abi.decode(rawData, (uint8, bytes));
		
		if (operationType == 0) {
			// Bid as liquidity add
			return _handleBid(operationData);
		} else if (operationType == 1) {
			// Deposit transfer (setup)
			return _handleDepositTransfer(operationData);
		} else if (operationType == 2) {
			// Price update swap
			return _handlePriceUpdateSwap(operationData);
		} else if (operationType == 3) {
			// Mint position after allocation
			return _handleMintPosition(operationData);
		} else if (operationType == 4) {
			// Claim token settlement
			return _handleClaimToken(operationData);
		} else if (operationType == 5) {
			// Simulate swap
			return _refundStake(operationData);
		} else if (operationType == 6) {
			// Claim allocator reward
			return _handleClaimAllocatorReward(operationData);
		} else if (operationType == 7) {
			// Claim all tokens
			return _handleClaimAllTokens(operationData);
		} else {
			revert("Invalid operation type");
		}
	}

	/**
	 * @dev Handle deposit transfer operation (setup)
	 * @param operationData The encoded operation data
	 * @return returnData The encoded balance deltas
	 */
	function _handleDepositTransfer(bytes memory operationData) internal returns (bytes memory returnData) {
		(, , , AuctionId auctionId, ) = 
			abi.decode(operationData, (PoolKey, Currency, uint256, AuctionId, address));
		return CPASetup.handleDepositTransfer(this, auctionInfo[auctionId], poolInfo, operationData);
	}
	
	/**
	 * @dev Handle bid as liquidity add operation
	 * @param operationData The encoded operation data containing (int128 amount0, int128 amount1)
	 * @return returnData The encoded balance deltas
	 */
	function _handleBid(bytes memory operationData) internal returns (bytes memory returnData) {
		// Decode the callback data
		(AuctionTypes.CallbackDataBid memory data) = abi.decode(operationData, (AuctionTypes.CallbackDataBid));
		address sender = data.sender;
		address numeraire = data.numeraire;
		int128 stake = data.stake;
		
		// Validate deadline
		require(block.timestamp <= data.deadline, "Bid deadline expired");
		
		// Transfer numeraire from bidder to pool manager
		Currency.wrap(numeraire).settle(manager, sender, uint256(int256(stake)), false);
		
		// Mint ERC6909 claims to this hook (bypassing V3 curve)
		Currency.wrap(numeraire).take(manager, address(this), uint256(int256(stake)), true);
		
		// Return the balance deltas
		return abi.encode(
			toBalanceDelta(0, -stake), // callerDelta
			BalanceDeltaLibrary.ZERO_DELTA // feesAccrued
		);
	}

	/**
	 * @notice Handle price update swap in callback
	 */
	function _handlePriceUpdateSwap(bytes memory operationData) internal returns (bytes memory) {
		// Decode the swap parameters
		(PoolKey memory poolKey, SwapParams memory swapParams) = abi.decode(operationData, (PoolKey, SwapParams)); 
		
		// Execute the swap to update the price
		BalanceDelta delta = manager.swap(poolKey, swapParams, "");

		// Return the delta
		return abi.encode(delta);
	}
	
	/**
	 * @dev Handle mint position after allocation
	 * @param operationData The encoded operation data
	 * @return returnData The encoded balance deltas
	 */
	function _handleMintPosition(bytes memory operationData) internal returns (bytes memory returnData) {
		// decode the operation data
		(AuctionTypes.CallbackDataMintPosition memory data) = abi.decode(operationData, (AuctionTypes.CallbackDataMintPosition));

		(BalanceDelta callerDelta, BalanceDelta feesAccrued) = manager.modifyLiquidity(
			data.poolKey,
			ModifyLiquidityParams({
				tickLower: data.tickLower,
				tickUpper: data.tickUpper,
				liquidityDelta: data.liquidity.toInt128(),
				salt: AuctionId.unwrap(data.auctionId)
			}),
			data.hookData
		);

		// handle the deltas
		if (callerDelta.amount0() < 0) {
			// If amount0 is negative, send tokens from the sender to the pool
			data.poolKey.currency0.settle(manager, address(this), uint256(int256(-callerDelta.amount0())), true);
		}

		if (callerDelta.amount1() < 0) {
			// If amount1 is negative, send tokens from the sender to the pool
			data.poolKey.currency1.settle(manager, address(this), uint256(int256(-callerDelta.amount1())), true);
		}

		return abi.encode(callerDelta, feesAccrued);
	}

	/**
	 * @notice Handle claim token settlement operation
	 * @param operationData The encoded operation data
	 * @return returnData The encoded balance deltas
	 */
	function _handleClaimToken(bytes memory operationData) internal returns (bytes memory returnData) {
		// Decode the operation data
		AuctionTypes.CallbackDataClaimToken memory callbackData = abi.decode(operationData, (AuctionTypes.CallbackDataClaimToken));
		
		// now that we have everything, we need to call swap on the pool manager
		BalanceDelta delta = manager.swap(callbackData.poolKey, callbackData.swapParams, "");

		Currency numeraire = Currency.wrap(callbackData.numeraire);
		uint256 numeraireOwed;
		uint256 assetGained;
		{
			Currency asset;
			if (callbackData.swapParams.zeroForOne) {
				// if zeroForOne is true, this means that the numeraire is token0
				if (delta.amount1() < 0) revert("Should not owe asset");
				numeraireOwed = uint256((-delta.amount0()).toUint128());
				assetGained = uint256((delta.amount1()).toUint128());
				asset = callbackData.poolKey.currency1;
			} else {
				// if zeroForOne is false, this means that the numeraire is token1
				if (delta.amount0() < 0) revert("Should not owe asset");
				numeraireOwed = uint256((-delta.amount1()).toUint128());
				assetGained = uint256((delta.amount0()).toUint128());
				asset = callbackData.poolKey.currency0;
			}
			asset.take(manager, callbackData.bidder, assetGained, false);
		}

		uint256 bidderStake = bidderStake[callbackData.auctionId][callbackData.bidder];
		uint256 numerairePaidByManager = 0;
		if (bidderStake >= numeraireOwed) {
			// since they have enough to cover, we can settle directly
			numeraire.settle(manager, address(this), numeraireOwed, true); // might need to be true since the manager has ERC6909 claims
			numerairePaidByManager = numeraireOwed;
		} else {
			//since they don't have enough, we need to do two settles
			numeraire.settle(manager, address(this), bidderStake, true); // might need to be true since the manager has ERC6909 claims
			numeraire.settle(manager, callbackData.bidder, numeraireOwed - bidderStake, false); // the bidder pays in ERC20
			numerairePaidByManager = bidderStake;
		}
		
		// Return the balance delta
		return abi.encode(numerairePaidByManager, assetGained);
	}


	/**
	 * @notice Handle claim token settlement operation
	 * @param operationData The encoded operation data
	 * @return returnData The encoded balance deltas
	 */
	function _handleClaimAllTokens(bytes memory operationData) internal returns (bytes memory returnData) {
		// Decode the operation data
		AuctionTypes.CallbackDataClaimAllTokens memory callbackData = abi.decode(operationData, (AuctionTypes.CallbackDataClaimAllTokens));
		
		Currency numeraire = Currency.wrap(callbackData.numeraire);
		uint256 totalNumeraireOwed = 0;
		
		// Loop through all pool keys and execute swaps for tokens the bidder is owed
		for (uint256 i = 0; i < callbackData.poolKeys.length; i++) {
			uint256 amountOwed = callbackData.allocatedQuantities[i];
			if (amountOwed > 0) {
				PoolKey memory poolKey = callbackData.poolKeys[i];
				bool numeraireIsCurrency0 = (Currency.unwrap(poolKey.currency0) == callbackData.numeraire);

				SwapParams memory params = SwapParams({
					zeroForOne: numeraireIsCurrency0,
					amountSpecified: (amountOwed.toInt256()),
					sqrtPriceLimitX96: numeraireIsCurrency0
						? TickMath.MIN_SQRT_PRICE + 1
						: TickMath.MAX_SQRT_PRICE - 1
				});
				
				// Execute swap on this pool
				BalanceDelta delta = manager.swap(poolKey, params, "");

				uint256 numeraireOwed;
				{
					Currency asset;
					if (params.zeroForOne) {
						// if zeroForOne is true, this means that the numeraire is token0
						if (delta.amount1() < 0) revert("Should not owe asset");
						numeraireOwed = uint256((-delta.amount0()).toUint128());
						uint256 assetGained = uint256((delta.amount1()).toUint128());
						asset = poolKey.currency1;
						asset.take(manager, callbackData.bidder, assetGained, false);
					} else {
						// if zeroForOne is false, this means that the numeraire is token1
						if (delta.amount0() < 0) revert("Should not owe asset");
						numeraireOwed = uint256((-delta.amount1()).toUint128());
						uint256 assetGained = uint256((delta.amount0()).toUint128());
						asset = poolKey.currency0;
						asset.take(manager, callbackData.bidder, assetGained, false);
					}
				}
				
				// Add to total numeraire owed
				totalNumeraireOwed += numeraireOwed;
			}
		}

		uint256 bidderStake = bidderStake[callbackData.auctionId][callbackData.bidder];
		uint256 numerairePaidByManager = 0;
		uint256 protocolPenalty = 0;
		if (bidderStake >= totalNumeraireOwed) {
			// since they have enough to cover, we can settle directly
			numeraire.settle(manager, address(this), totalNumeraireOwed, true); // might need to be true since the manager has ERC6909 claims
			numerairePaidByManager = totalNumeraireOwed;

			// since they had enough, we need to check if they met the minimum spend ratio and refund any leftover numeraire
			uint256 minSpendAmount = auctionInfo[callbackData.auctionId].config.minSpendRatio * bidderStake / 10000;
			if (minSpendAmount > numerairePaidByManager) {
				// Didn't meet minimum spend - penalty applies
				protocolPenalty = minSpendAmount - numerairePaidByManager;
				protocolPenalties[callbackData.auctionId] += protocolPenalty;
				bidderStake -= minSpendAmount;
			} // else they met the minimum spend ratio so no penalty applies

			// refund the leftover numeraire after applying the penalty
			manager.burn(address(this), CurrencyLibrary.toId(numeraire), bidderStake - totalNumeraireOwed - protocolPenalty);
			numeraire.take(manager, callbackData.bidder, bidderStake - totalNumeraireOwed - protocolPenalty, false);
		} else {
			//since they don't have enough numeraire to cover the bundle price, we need to do two settles
			numeraire.settle(manager, address(this), bidderStake, true); // might need to be true since the manager has ERC6909 claims
			numeraire.settle(manager, callbackData.bidder, totalNumeraireOwed - bidderStake, false); // the bidder pays in ERC20
			numerairePaidByManager = bidderStake;

			// bidder has no leftover stake so there is no need to refund anything
		}
		
		// Return the balance delta
		return abi.encode(numerairePaidByManager);
	}

	function _refundStake(bytes memory operationData) internal returns (bytes memory returnData) {
		// Decode the operation data
		(AuctionTypes.CallbackDataRefundStake memory data) = abi.decode(operationData, (AuctionTypes.CallbackDataRefundStake));
		
		// Refund the stake
		manager.burn(address(this), CurrencyLibrary.toId(Currency.wrap(data.numeraire)), data.amount);
		
		// Return the balance delta
		return abi.encode(data.amount);
	}

	function _handleClaimAllocatorReward(bytes memory operationData) internal returns (bytes memory returnData) {
		// Decode the operation data
		(AuctionTypes.CallbackDataClaimAllocatorReward memory data) = abi.decode(operationData, (AuctionTypes.CallbackDataClaimAllocatorReward));
		
		// we are already unlocked here so we just need to transfer tokens from the CPAManager to the allocator
		Currency.wrap(data.numeraire).take(manager, data.allocator, data.reward, false); // give ERC20 to the allocator
		manager.burn(address(this), CurrencyLibrary.toId(Currency.wrap(data.numeraire)), data.reward); // burn ERC6909 from the CPAManager
		
		return abi.encode(data.reward);
	}

	/**
	 * @notice Forfeit bidder who didn't claim in time
	 * @dev Only callable in Finished phase. Caller gets 1% reward incentive.
	 * @param auctionId The auction ID
	 * @param bidder The bidder address to forfeit
	 */
	function forfeit(AuctionId auctionId, address bidder) external onlyPhase(auctionId, AuctionTypes.AuctionPhase.Finished) {
		uint256 stake = bidderStake[auctionId][bidder];
		if (stake == 0) revert IErrorsAndEvents.InvalidStakeAmount(); // No stake to forfeit
		
		// Calculate penalty and reward amounts
		uint256 penaltyRate = auctionInfo[auctionId].config.minSpendRatio;
		
		// Transfer penalty to protocol
		protocolPenalties[auctionId] += stake * penaltyRate / 10000;
		
		// Transfer reward to caller
		uint256 callerReward = stake * FORFEITURE_REWARD_RATE / 10000;
		if (callerReward > 0) {
			AuctionTypes.CallbackDataRefundStake memory data = AuctionTypes.CallbackDataRefundStake({
				numeraire: auctionInfo[auctionId].commonNumeraire,
				recipient: msg.sender,
				amount: callerReward
			});
			manager.unlock(abi.encode(uint8(5), abi.encode(data)));
			
			emit IErrorsAndEvents.ForfeitureRewardTransferred(auctionId, msg.sender, callerReward);
		}
		
		// Transfer remaining stake back to bidder
		uint256 remaining = stake - (stake * (penaltyRate + FORFEITURE_REWARD_RATE) / 10000);
		if (remaining > 0) {
			AuctionTypes.CallbackDataRefundStake memory refundData = AuctionTypes.CallbackDataRefundStake({
				numeraire: auctionInfo[auctionId].commonNumeraire,
				recipient: bidder,
				amount: remaining
			});
			manager.unlock(abi.encode(uint8(5), abi.encode(refundData)));
		}
		
		// Zero out their stake
		bidderStake[auctionId][bidder] = 0;
		
		emit IErrorsAndEvents.BundleForfeited(auctionId, bidder, stake * penaltyRate / 10000);
	}

}