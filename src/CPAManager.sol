// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { console } from "forge-std/console.sol";

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { Hooks } from "@uniswap/v4-core/src/libraries/Hooks.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { BalanceDelta } from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, toBalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { CurrencySettler } from "@openzeppelin/uniswap-hooks/src/utils/CurrencySettler.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { SafeCast } from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import { CurrencyLibrary } from "@uniswap/v4-core/src/types/Currency.sol";

// wanted to use Ownable2Step but we were getting some errors
// review this thread: https://github.com/OpenZeppelin/openzeppelin-contracts/issues/4690
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol"; 

import { CPAStorage } from "./base/CPAStorage.sol";
import { CPASetup } from "./libraries/CPASetup.sol";
import { CPAClockPhase } from "./libraries/CPAClockPhase.sol";
import { CPAProxyPhase } from "./libraries/CPAProxyPhase.sol";
import { CPAAllocationPhase } from "./libraries/CPAAllocationPhase.sol";
import { CPASettlementPhase } from "./libraries/CPASettlementPhase.sol";

import { IErrorsAndEvents } from "./utils/IErrorsAndEvents.sol";
import { AuctionTypes } from "./types/AuctionTypes.sol";
import { AuctionId } from "./types/AuctionId.sol";
import { CommitReveal } from "./utils/CommitReveal.sol";
import { CPAHook } from "./CPAHook.sol";
import { BundleId } from "./types/BundleId.sol";

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
		address _cpaAuctionHookAddr
	) Ownable(_owner) CPAStorage(_cpaAuctionHookAddr) {
		manager = _poolManager;
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
	 */
	function cancelAuction(AuctionId auctionId) external onlyAuctionOwner(auctionId) {
		auctionInfo[auctionId].currentStatus = AuctionTypes.AuctionStatus.Cancelled;
		_updateCPAHookStates(auctionId);
		_refundAllStakes(auctionId);
		emit IErrorsAndEvents.AuctionCancelled(auctionId, msg.sender);
	}

	function reclaimStake(AuctionId auctionId) external {
		// Allow reclaiming if auction is cancelled, finished, or bidder has dropped out
		if (auctionInfo[auctionId].currentStatus != AuctionTypes.AuctionStatus.Cancelled &&
			auctionInfo[auctionId].currentPhase != AuctionTypes.AuctionPhase.Finished &&
			availableToReclaim[auctionId][msg.sender] == 0) {
			revert IErrorsAndEvents.AuctionNotActive(auctionId, auctionInfo[auctionId].currentStatus);
		}
		
		uint256 refund =_reclaimStake(auctionId, msg.sender);

		// then we need to do a callback to reclaim what they are owed
		// manager.unlock(abi.encode(
		// 	uint8(5),
		// 	abi.encode(AuctionTypes.CallbackDataRefundStake({
		// 	numeraire: auctionInfo[auctionId].commonNumeraire,
		// 	bidder: msg.sender,
		// 	auctionId: auctionId,
		// 	amount: refund
		// }))));
	}

	function _reclaimStake(AuctionId auctionId, address bidder) internal returns (uint256 stake) {
		stake = bidderStake[auctionId][bidder];
		if (stake == 0) revert IErrorsAndEvents.InvalidStakeAmount();
		bidderStake[auctionId][bidder] = 0;
		bidderBidPoints[auctionId][bidder] = 0;
		availableToReclaim[auctionId][bidder] = stake;
		return stake;
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

	/**
	 * @notice Start the clock phase
	 * @param auctionId The auction ID
	 */
	 function startClockRound(AuctionId auctionId) external onlyAuctionOwner(auctionId) {
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
		// Close the current clock round
		CPAClockPhase.setClockOpen(auctionId, 1, auctionInfo);
		
		// Process round results (calculate excess demand and update prices)
		CPAClockPhase.processClockRound(this, auctionId, auctionInfo, poolInfo);
		
		// Emit event for round closure
		emit IErrorsAndEvents.ClockRoundClosed(auctionId, auctionInfo[auctionId].currentRound, auctionInfo[auctionId].roundBids.length);
		
		// Note: Clock remains closed after ending a round
		// The auctioneer must manually call startClockRound to begin the next round
	}

	/**
	 * @notice Manually end the clock phase and transition to proxy phase
	 * @param auctionId The auction ID
	 */
	function endClockPhase(AuctionId auctionId) external onlyAuctionOwner(auctionId) onlyPhase(auctionId, AuctionTypes.AuctionPhase.Clock) {
		// Close the current clock round if it's still open
		if (auctionInfo[auctionId].clockOpen == 2) {
			CPAClockPhase.setClockOpen(auctionId, 1, auctionInfo);
			
			// Process round results (calculate excess demand and update prices)
			CPAClockPhase.processClockRound(this, auctionId, auctionInfo, poolInfo);
			
			// Emit event for round closure
			emit IErrorsAndEvents.ClockRoundClosed(auctionId, auctionInfo[auctionId].currentRound, auctionInfo[auctionId].roundBids.length);
		}
		
		// Transition to proxy phase
		_changePhase(auctionId, AuctionTypes.AuctionPhase.Proxy);
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
			commitProxy
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
	 * @notice Dropout from auction with penalty
	 * probably need to rewrite this to accept WHO is dropping out
	 */
	function dropout(AuctionId auctionId) external whenAuctionActive(auctionId) {
		// the bidders can only dropout if the auction is BEFORE the proxy phase. In other words,
		// only in setup or clock phase.
		// TODO: Uncomment when CPAClockPhase is implemented
		if (auctionInfo[auctionId].currentPhase == AuctionTypes.AuctionPhase.Proxy) revert IErrorsAndEvents.InvalidPhase(AuctionTypes.AuctionPhase.Proxy, auctionInfo[auctionId].currentPhase);
		if (auctionInfo[auctionId].currentPhase != AuctionTypes.AuctionPhase.Setup && auctionInfo[auctionId].currentPhase != AuctionTypes.AuctionPhase.Clock) revert IErrorsAndEvents.InvalidPhase(AuctionTypes.AuctionPhase.Setup, auctionInfo[auctionId].currentPhase);
		
		uint256 stake = bidderStake[auctionId][msg.sender];
		if (stake == 0) revert IErrorsAndEvents.InvalidStakeAmount();
		
		uint256 penalty = (stake * auctionInfo[auctionId].config.dropoutSlashRatio) / 10000;
		uint256 refund = stake - penalty;
		
		// Clear bidder data
		bidderStake[auctionId][msg.sender] = refund;
		bidderBidPoints[auctionId][msg.sender] = 0;
		
		// Set dropped bidder status
		droppedBidders[auctionId][msg.sender] = true;
		
		// Transfer refund to bidder (simplified)
		// In practice, this would use SafeERC20
		
		emit IErrorsAndEvents.PenaltyApplied(auctionId, msg.sender, penalty);
		emit IErrorsAndEvents.StakeRefunded(auctionId, msg.sender, refund);

		// revert("Not yet implemented");
	}

	// ========================================
	// PROXY PHASE
	// ========================================

	// function startProxyPhase(AuctionId auctionId) external onlyAuctionOwner(auctionId) onlyPhase(auctionId, AuctionTypes.AuctionPhase.Clock) {
	// 	CPAProxyPhase.startProxyPhase(this, proxyPhaseStartTime, auctionId);
	// }

	function endProxyPhase(AuctionId auctionId) external onlyAuctionOwner(auctionId) onlyPhase(auctionId, AuctionTypes.AuctionPhase.Proxy) {
		CPAProxyPhase.endProxyPhase(this, auctionId);

		_changePhase(auctionId, AuctionTypes.AuctionPhase.Allocation);
	}

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
		bundleId = CPAProxyPhase.submitBundle(this, commitHash, bundles, commitProxy, bundleData);
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
		if (msg.sender != allocationData.allocator) revert IErrorsAndEvents.Unauthorized();
		// TODO: Uncomment when CPAAllocationPhase is implemented
		CPAAllocationPhase.submitAllocation(this, allocationData, topAllocation, auctionInfo, poolInfo, bundles);
		// revert("Not yet implemented");
	}

	/**
	 * @notice End allocation phase and select winner
	 */
	function endAllocationPhase(AuctionId auctionId) external onlyAuctionOwner(auctionId) onlyPhase(auctionId, AuctionTypes.AuctionPhase.Allocation) {
		// TODO: Uncomment when CPAProxyPhase and CPAClockPhase are implemented
		/*
		if (allocations[auctionId].length == 0) revert InvalidPhase(AuctionTypes.AuctionPhase.Allocation, auctionPhase[auctionId]);
		
		// Get bundles and bidders for allocation scoring
		AuctionTypes.Bundle[] memory allBundles = CPAProxyPhase.getAllBundles(this);
		// uint256 totalBidders = CPAClockPhase.getTotalBidders(this);
		
		// Select winning allocation
		uint256 winningIndex = AllocationScoring.selectWinningAllocation(
			allocations[auctionId],
			allBundles,
			totalBidders
		);
		
		finalAllocation[auctionId] = allocations[auctionId][winningIndex];
		winningAllocator[auctionId] = finalAllocation[auctionId].allocator;
		
		_changePhase(auctionId, AuctionTypes.AuctionPhase.Reveal);
		*/
		CPAAllocationPhase.endAllocationPhase(this, auctionId, topAllocation, auctionInfo, poolInfo, bundles, winningBundleIds);
		_changePhase(auctionId, AuctionTypes.AuctionPhase.Settlement);
	}

	// register as allocator

	// ========================================
	// REVEAL PHASE (not sure if this is necessary or if it can be incorporated into the settlement phase)
	// ========================================

	// /**
	//  * @notice Start reveal phase
	//  */
	// function startRevealPhase(AuctionId auctionId) external onlyAuctionOwner(auctionId) onlyPhase(auctionId, AuctionTypes.AuctionPhase.Allocation) {
	// 	_changePhase(auctionId, AuctionTypes.AuctionPhase.Reveal);
	// }

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

	// /**
	//  * @notice End reveal phase and move to settlement
	//  */
	// function endRevealPhase(AuctionId auctionId) external onlyAuctionOwner(auctionId) onlyPhase(auctionId, AuctionTypes.AuctionPhase.Reveal) {
	// 	_changePhase(auctionId, AuctionTypes.AuctionPhase.Settlement);
	// 	_finalizeSettlement(auctionId);
	// }

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
			// topAllocation[auctionId],
			auctionInfo[auctionId],
			revealedMappings[auctionId],
			bidderStake[auctionId],
			bundles[auctionId],
			winningBundleIds
		);

		// now that they've claimed all their tokens, delete the bundle at the commit hash from the winning bundle ids
		winningBundleIds[commitHash] = BundleId.wrap(0);
	}

	function endSettlementPhase(AuctionId auctionId) external onlyAuctionOwner(auctionId) onlyPhase(auctionId, AuctionTypes.AuctionPhase.Settlement) {
		CPASettlementPhase.endSettlementPhase(this, auctionId);
		_changePhase(auctionId, AuctionTypes.AuctionPhase.Finished);
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
	// UTILITY FUNCTIONS
	// ========================================

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
		_updateCPAHookStates(auctionId);
		emit IErrorsAndEvents.AuctionPhaseChanged(auctionId, newPhase);
	}

	/**
	 * @notice Process financial settlement
	 * @param bidder The bidder address
	 * @param finalPurchaseAmount Final purchase amount
	 */
	function _processFinancialSettlement(address bidder, uint256 finalPurchaseAmount) internal {
		// TODO: Uncomment when CPARevealPhase is implemented
		// CPARevealPhase.processFinancialSettlement(this, bidder, finalPurchaseAmount);
		revert("Not yet implemented");
	}

	/**
	 * @notice Finalize settlement
	 */
	function _finalizeSettlement(AuctionId auctionId) internal {
		// TODO: Uncomment when CPARevealPhase is implemented
		// CPARevealPhase.finalizeSettlement(this);
		revert("Not yet implemented");
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
		address token0 = data.token0;
		address token1 = data.token1;
		int128 amount0 = data.amount0;
		int128 amount1 = data.amount1;
		
		// Transfer numeraire from bidder to pool manager
		Currency.wrap(token1).settle(manager, sender, uint256(int256(amount1)), false);
		
		// Mint ERC6909 claims to this hook (bypassing V3 curve)
		Currency.wrap(token1).take(manager, address(this), uint256(int256(amount1)), true);
		
		// Return the balance deltas
		return abi.encode(
			toBalanceDelta(0, -amount1), // callerDelta
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
		return CPAAllocationPhase.handleMintPosition(this, operationData);
		// revert("Not yet implemented");
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
		if (bidderStake >= totalNumeraireOwed) {
			// since they have enough to cover, we can settle directly
			numeraire.settle(manager, address(this), totalNumeraireOwed, true); // might need to be true since the manager has ERC6909 claims
			numerairePaidByManager = totalNumeraireOwed;

			// since they had enough, refund any leftover numeraire
			manager.burn(address(this), CurrencyLibrary.toId(numeraire), bidderStake - totalNumeraireOwed);
			numeraire.take(manager, callbackData.bidder, bidderStake - totalNumeraireOwed, false);
		} else {
			//since they don't have enough, we need to do two settles
			numeraire.settle(manager, address(this), bidderStake, true); // might need to be true since the manager has ERC6909 claims
			numeraire.settle(manager, callbackData.bidder, totalNumeraireOwed - bidderStake, false); // the bidder pays in ERC20
			numerairePaidByManager = bidderStake;

			// bidder has no leftover stake so all is well here
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
		CPASettlementPhase.handleClaimAllocatorReward(this, data);
		return abi.encode(data.reward);
	}

	/**
	 * @notice Refund all stakes
	 * @param auctionId The auction ID
	 */
	function _refundAllStakes(AuctionId auctionId) internal {
		// TODO: Implement stake refunds
		// This should iterate through all bidders and refund their stakes
		// when auction is cancelled or auctioneer fails to uphold their end
	}
}