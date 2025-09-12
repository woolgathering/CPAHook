// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { Hooks } from "@uniswap/v4-core/src/libraries/Hooks.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { AuctionTypes } from "./AuctionTypes.sol";
import { AuctionId } from "./AuctionId.sol";
import { CommitReveal } from "./CommitReveal.sol";
// import { AllocationScoring } from "./AllocationScoring.sol";
import { PoolHook } from "./PoolHook.sol";
import { IClockProxyAuction } from "./interfaces/IClockProxyAuction.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { BalanceDelta } from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, toBalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";

// wanted to use Ownable2Step but we were getting some errors
// review this thread: https://github.com/OpenZeppelin/openzeppelin-contracts/issues/4690
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol"; 
import { CPAStorage } from "./base/CPAStorage.sol";
import { CPASetup } from "./libraries/CPASetup.sol";
import { CPAClockPhase } from "./libraries/CPAClockPhase.sol";
// import { CPAProxyPhase } from "./libraries/CPAProxyPhase.sol";
// import { CPAAllocationPhase } from "./libraries/CPAAllocationPhase.sol";
// import { CPARevealPhase } from "./libraries/CPARevealPhase.sol";
import { IErrorsAndEvents } from "./utils/IErrorsAndEvents.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { CurrencySettler } from "@openzeppelin/uniswap-hooks/src/utils/CurrencySettler.sol";

/**
 * @title CPAManager
 * @notice Main auction manager implementing clock-proxy auction with commit-reveal privacy
 * @author Clock-Proxy Auction Team
 */
contract CPAManager is IErrorsAndEvents, Ownable, CPAStorage {
	using AuctionTypes for *;
	using PoolIdLibrary for PoolKey;
	using CurrencySettler for Currency;
	using BalanceDeltaLibrary for BalanceDelta;
	// using CPASetup for CPAStorage;

	uint256 constant twoPow96 = 2**96;

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

	/**
	 * @notice Modifier to ensure auction is in expected phase
	 */
	modifier onlyPhase(AuctionId auctionId, AuctionTypes.AuctionPhase phase) {
		if (auctionInfo[auctionId].currentPhase != phase) revert InvalidPhase(phase, auctionInfo[auctionId].currentPhase);
		_;
	}

	function setCpaAuctionHookAddr(address _cpaAuctionHookAddr) external onlyOwner {
		cpaAuctionHookAddr = _cpaAuctionHookAddr;
	}

	/**
	 * @notice Pause the auction
	 */
	function pause(AuctionId auctionId) external onlyAuctionOwner(auctionId) {
		auctionInfo[auctionId].currentPhase = AuctionTypes.AuctionPhase.Paused;
		_updatePoolHookStates(auctionId);
		emit IErrorsAndEvents.AuctionPaused(auctionId, msg.sender);
	}

	/**
	 * @notice Unpause the auction
	 */
	function unpause(AuctionId auctionId) external onlyAuctionOwner(auctionId) {
		auctionInfo[auctionId].currentPhase = AuctionTypes.AuctionPhase.Clock;
		_updatePoolHookStates(auctionId);
		emit IErrorsAndEvents.AuctionUnpaused(auctionId, msg.sender);
	}

	/**
	 * @notice Cancel the auction and refund all stakes
	 */
	function cancelAuction(AuctionId auctionId) external onlyAuctionOwner(auctionId) {
		auctionInfo[auctionId].currentPhase = AuctionTypes.AuctionPhase.Cancelled;
		_updatePoolHookStates(auctionId);
		_refundAllStakes(auctionId);
		emit IErrorsAndEvents.AuctionCancelled(auctionId, msg.sender);
	}

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
		_updatePoolHookStates(auctionId);
		return auctionId;
	}

	function moveDeposit(
		AuctionId auctionId,
		PoolKey memory poolKey,
		uint256 depositAmount
	) external onlyAuctionOwner(auctionId) {
		CPASetup.moveDeposit(this, auctionInfo, poolInfo, poolKey, auctionId, depositAmount);
		_updatePoolHookStates(auctionId);
	}

	/**
	 * @notice Start the clock phase
	 */
	 function startClockRound(AuctionId auctionId) external onlyAuctionOwner(auctionId) {
		// Handle first-time transition from Setup to Clock phase
		if (auctionInfo[auctionId].currentPhase == AuctionTypes.AuctionPhase.Setup) {
			if (!CPASetup.confirmSetupComplete(this, auctionId, auctionInfo, poolInfo)) revert IErrorsAndEvents.SetupNotComplete();
			// Transition to Clock phase
			auctionInfo[auctionId].currentPhase = AuctionTypes.AuctionPhase.Clock;
			_updatePoolHookStates(auctionId);
		}
		CPAClockPhase.openClockRound(auctionId, auctionInfo);
	}

	/**
	 * @notice End current clock round
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
	 * @param partialCommitHash The commit hash for privacy
	 * @param stakeAmount Additional stake amount
	 */
	function submitBid(
		AuctionId auctionId,
		uint256[] calldata demands,
		bytes32 partialCommitHash,
		uint256 stakeAmount
	) external whenAuctionActive(auctionId) onlyPhase(auctionId, AuctionTypes.AuctionPhase.Clock) {
		CPAClockPhase.processBid(
			this,
			auctionId,
			demands,
			partialCommitHash,
			stakeAmount,
			auctionInfo,
			bidderStake,
			bidderBidPoints,
			poolInfo,
			commitProxy
		);
	}
	// we should consider using whenActive(auctionId) as the modifier and just have the actuon be active or inactive. Paused or cancelled can be emitted as an event or something. Having two modifiers feels unnecessary.


	// Removed setPoolPrice - prices are now managed directly in pools

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
		// TODO: Uncomment when CPAClockPhase is implemented
		// CPAClockPhase.dropout(this);
		revert("Not yet implemented");
	}

	/**
	 * @notice Submit bundle during proxy phase
	 * @param auctionId The auction ID
	 * @param commitHash The commit hash
	 * @param bundleData The bundle data
	 */
	function submitBundle(
		AuctionId auctionId,
		bytes32 commitHash,
		AuctionTypes.Bundle calldata bundleData
	) external whenAuctionActive(auctionId) onlyPhase(auctionId, AuctionTypes.AuctionPhase.Proxy) {
		// TODO: Uncomment when CPAProxyPhase is implemented
		// CPAProxyPhase.submitBundle(this, commitHash, bundleData);
		revert("Not yet implemented");
	}

	/**
	 * @notice Start allocation phase
	 */
	function startAllocationPhase(AuctionId auctionId) external onlyAuctionOwner(auctionId) onlyPhase(auctionId, AuctionTypes.AuctionPhase.Proxy) {
		_changePhase(auctionId, AuctionTypes.AuctionPhase.Allocation);
	}

	/**
	 * @notice Submit allocation during allocation phase
	 * @param auctionId The auction ID
	 * @param allocationData The allocation data
	 */
	function submitAllocation(
		AuctionId auctionId,
		AuctionTypes.Allocation calldata allocationData
	) external whenAuctionActive(auctionId) onlyPhase(auctionId, AuctionTypes.AuctionPhase.Allocation) {
		// TODO: Uncomment when CPAAllocationPhase is implemented
		// CPAAllocationPhase.submitAllocation(this, allocationData);
		revert("Not yet implemented");
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
		revert("Not yet implemented");
	}

	/**
	 * @notice Start reveal phase
	 */
	function startRevealPhase(AuctionId auctionId) external onlyAuctionOwner(auctionId) onlyPhase(auctionId, AuctionTypes.AuctionPhase.Allocation) {
		_changePhase(auctionId, AuctionTypes.AuctionPhase.Reveal);
	}

	/**
	 * @notice Reveal bidder identity
	 * @param auctionId The auction ID
	 * @param bidder The bidder address
	 * @param proxy The proxy address
	 * @param saltA First salt
	 * @param saltB Second salt
	 * @param finalPurchaseAmount Final purchase amount
	 */
	function reveal(
		AuctionId auctionId,
		address bidder,
		address proxy,
		bytes32 saltA,
		bytes32 saltB,
		uint256 finalPurchaseAmount
	) external whenAuctionActive(auctionId) onlyPhase(auctionId, AuctionTypes.AuctionPhase.Reveal) {
		// TODO: Uncomment when CPARevealPhase is implemented
		// CPARevealPhase.reveal(this, bidder, proxy, saltA, saltB, finalPurchaseAmount);
		revert("Not yet implemented");
	}

	/**
	 * @notice End reveal phase and move to settlement
	 */
	function endRevealPhase(AuctionId auctionId) external onlyAuctionOwner(auctionId) onlyPhase(auctionId, AuctionTypes.AuctionPhase.Reveal) {
		_changePhase(auctionId, AuctionTypes.AuctionPhase.Settlement);
		_finalizeSettlement(auctionId);
	}

	/**
	 * @notice Register a commit hash (called by proxies)
	 * @param auctionId The auction ID
	 * @param commitHash The commit hash to register
	 */
	function registerCommit(AuctionId auctionId, bytes32 commitHash) external {
		if (commitProxy[auctionId][commitHash] != address(0)) revert InvalidCommitHash();
		commitProxy[auctionId][commitHash] = msg.sender;
	}


	

	// Internal functions

	/**
	 * @notice Change auction phase
	 * @param auctionId The auction ID
	 * @param newPhase The new phase
	 */
	function _changePhase(AuctionId auctionId, AuctionTypes.AuctionPhase newPhase) internal {
		auctionInfo[auctionId].currentPhase = newPhase;
		_updatePoolHookStates(auctionId);
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
	 * @dev Handle deposit transfer operation (setup)
	 * @param operationData The encoded operation data
	 * @return returnData The encoded balance deltas
	 */
	function _handleDepositTransfer(bytes memory operationData) internal returns (bytes memory returnData) {
		return CPASetup.handleDepositTransfer(this, auctionInfo, poolInfo, operationData);
	}
	
	/**
	 * @dev Handle bid as liquidity add operation
	 * @param operationData The encoded operation data containing (int128 amount0, int128 amount1)
	 * @return returnData The encoded balance deltas
	 */
	function _handleBidAsLiquidity(bytes memory operationData) internal returns (bytes memory returnData) {
		// Decode the callback data
		(AuctionTypes.CallbackDataBid memory data) = abi.decode(operationData, (AuctionTypes.CallbackDataBid));
		address sender = data.sender;
		address token0 = data.token0;
		address token1 = data.token1;
		int128 amount0 = data.amount0;
		int128 amount1 = data.amount1;
		
		// For single-sided numeraire deposits, amount0 should be positive and amount1 should be 0
		// if (amount0 != 0 || amount1 ==0 || token0 != address(0) || token1 == address(0)) {
		// 	revert("Invalid bid params");
		// }
		
		// TODO: Get the pool key for ETH<>numeraire pool
		// For now, we'll use a placeholder - this should be passed in or retrieved from storage
		// PoolKey memory poolKey = PoolKey({
		// 	currency0: Currency.wrap(address(0)), // Placeholder - should be numeraire
		// 	currency1: Currency.wrap(address(0)), // Placeholder - should be ETH
		// 	fee: 0,
		// 	tickSpacing: 0,
		// 	hooks: IHooks(address(this))
		// });
		
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
			return _handleBidAsLiquidity(operationData);
		} else if (operationType == 1) {
			// Deposit transfer (setup)
			return CPASetup.handleDepositTransfer(this, auctionInfo, poolInfo, operationData);
		} else if (operationType == 2) {
			// Price update swap
			return _handlePriceUpdateSwap(operationData);
		} else {
			revert("Invalid operation type");
		}
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
	 * @notice Update pool hook states
	 */
	function _updatePoolHookStates(AuctionId auctionId) internal {
		PoolKey[] memory poolKeys = auctionInfo[auctionId].poolKeys;
		for (uint256 i = 0; i < poolKeys.length; i++) {
			// Get the pool hook address from the pool key
			// address poolHookAddress = address(poolKeys[i].hooks);
			
			// Update the pool hook state
			PoolHook(cpaAuctionHookAddr).setPoolState(
				poolKeys[i],
				auctionInfo[auctionId].currentPhase
			);
		}
	}

	/**
	 * @notice Refund all stakes
	 */
	function _refundAllStakes(AuctionId auctionId) internal {
		// TODO: Implement stake refunds
		// This should iterate through all bidders and refund their stakes
		// when auction is cancelled or auctioneer fails to uphold their end
	}

}
