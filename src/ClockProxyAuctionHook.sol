// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { CPABaseCustomAccounting } from "./base/CPABaseCustomAccounting.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { Hooks } from "@uniswap/v4-core/src/libraries/Hooks.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { AuctionTypes } from "./AuctionTypes.sol";
import { CommitReveal } from "./CommitReveal.sol";
import { AllocationScoring } from "./AllocationScoring.sol";
import { PoolHook } from "./PoolHook.sol";
import { IClockProxyAuction } from "./interfaces/IClockProxyAuction.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { BalanceDelta } from "@uniswap/v4-core/src/types/BalanceDelta.sol";

// wanted to use Ownable2Step but we were getting some errors
// review this thread: https://github.com/OpenZeppelin/openzeppelin-contracts/issues/4690
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol"; 
import { CPAStorage } from "./base/CPAStorage.sol";
import { CPASetup } from "./libraries/CPASetup.sol";
import { CPAClockPhase } from "./libraries/CPAClockPhase.sol";
import { CPAProxyPhase } from "./libraries/CPAProxyPhase.sol";
import { CPAAllocationPhase } from "./libraries/CPAAllocationPhase.sol";
import { CPARevealPhase } from "./libraries/CPARevealPhase.sol";
import { IErrorsAndEvents } from "./utils/IErrorsAndEvents.sol";

/**
 * @title ClockProxyAuctionHook
 * @notice Main auction hook implementing clock-proxy auction with commit-reveal privacy
 * @author Clock-Proxy Auction Team
 */
contract ClockProxyAuctionHook is IErrorsAndEvents, CPABaseCustomAccounting, Ownable, CPAStorage {
	using AuctionTypes for *;
	using PoolIdLibrary for PoolKey;

	/**
	 * @notice Constructor
	 * @param _poolManager The V4 pool manager
	 * @param _owner The auction owner
	 * @param _commonNumeraire The common numeraire token
	 * @param _config The auction configuration
	 */
	constructor(
		IPoolManager _poolManager,
		address _owner,
		address _commonNumeraire,
		AuctionTypes.AuctionConfig memory _config
	) CPABaseCustomAccounting(_poolManager) Ownable(_owner) CPAStorage(_commonNumeraire, _config) {
	}

	/**
	 * @notice Modifier to ensure auction is not paused
	 */
	modifier whenNotPaused() {
		if (paused) revert IErrorsAndEvents.AuctionPausedError();
		_;
	}

	/**
	 * @notice Modifier to ensure auction is not cancelled
	 */
	modifier whenNotCancelled() {
		if (cancelled) revert IErrorsAndEvents.AuctionCancelledError();
		_;
	}

	/**
	 * @notice Modifier to ensure auction is in expected phase
	 */
	modifier onlyPhase(AuctionTypes.AuctionPhase phase) {
		if (currentPhase != phase) revert InvalidPhase(phase, currentPhase);
		_;
	}

	// function owner() public view override returns (address) {
	// 	return address(owner);
	// }

	// modifier onlyOwner() {
	// 	if (msg.sender != address(owner)) revert OnlyOwner();
	// 	_;
	// }

	/**
	 * @notice Pause the auction
	 */
	function pause() external onlyOwner {
		paused = true;
		_updatePoolHookStates();
		emit IErrorsAndEvents.AuctionPaused(msg.sender);
	}

	/**
	 * @notice Unpause the auction
	 */
	function unpause() external onlyOwner {
		paused = false;
		_updatePoolHookStates();
		emit IErrorsAndEvents.AuctionUnpaused(msg.sender);
	}

	/**
	 * @notice Cancel the auction and refund all stakes
	 */
	function cancelAuction() external onlyOwner {
		cancelled = true;
		_updatePoolHookStates();
		_refundAllStakes();
		emit IErrorsAndEvents.AuctionCancelled(msg.sender);
	}

	    /**
	 * @notice Start the clock phase
	 */
	 function startClockPhase() external onlyOwner onlyPhase(AuctionTypes.AuctionPhase.Setup) {
		if (!CPASetup.confirmSetupComplete(this)) revert SetupNotComplete();
		_changePhase(AuctionTypes.AuctionPhase.Clock);
		_openClockRound();
	}

	/**
	 * @notice Open a new clock round
	 */
	 function _openClockRound() internal {
		currentRound++;
		clockOpen = true;
		delete roundBids;
		emit IErrorsAndEvents.ClockRoundOpened(currentRound);
	}

	/**
	 * @notice End current clock round
	 */
	 function endClockRound() external onlyOwner onlyPhase(AuctionTypes.AuctionPhase.Clock) {
		clockOpen = false;
		
		// Process round results
		CPAClockPhase.processClockRound(this);
		
		emit IErrorsAndEvents.ClockRoundClosed(currentRound, roundBids.length);
		
		// Check if clock phase should end
		if (CPAClockPhase.shouldEndClockPhase(this)) {
			_changePhase(AuctionTypes.AuctionPhase.Proxy);
		} else {
			_openClockRound();
		}
	}

	/**
	 * @notice Submit a bid during clock phase
	 * @param demands Array of item demands
	 * @param commitHash The commit hash for privacy
	 * @param stakeAmount Additional stake amount
	 */
	function submitBid(
		uint256[] calldata demands,
		bytes32 commitHash,
		uint256 stakeAmount
	) external whenNotPaused whenNotCancelled onlyPhase(AuctionTypes.AuctionPhase.Clock) {
		CPAClockPhase.submitBid(this, demands, commitHash, stakeAmount);
	}

	/**
	 * @notice Dropout from auction with penalty
	 */
	function dropout() external whenNotPaused whenNotCancelled {
		CPAClockPhase.dropout(this);
	}

	/**
	 * @notice Submit bundle during proxy phase
	 * @param commitHash The commit hash
	 * @param bundleData The bundle data
	 */
	function submitBundle(
		bytes32 commitHash,
		AuctionTypes.Bundle calldata bundleData
	) external whenNotPaused whenNotCancelled onlyPhase(AuctionTypes.AuctionPhase.Proxy) {
		CPAProxyPhase.submitBundle(this, commitHash, bundleData);
	}

	/**
	 * @notice Start allocation phase
	 */
	function startAllocationPhase() external onlyOwner onlyPhase(AuctionTypes.AuctionPhase.Proxy) {
		_changePhase(AuctionTypes.AuctionPhase.Allocation);
	}

	/**
	 * @notice Submit allocation during allocation phase
	 * @param allocationData The allocation data
	 */
	function submitAllocation(
		AuctionTypes.Allocation calldata allocationData
	) external whenNotPaused whenNotCancelled onlyPhase(AuctionTypes.AuctionPhase.Allocation) {
		CPAAllocationPhase.submitAllocation(this, allocationData);
	}

	/**
	 * @notice End allocation phase and select winner
	 */
	function endAllocationPhase() external onlyOwner onlyPhase(AuctionTypes.AuctionPhase.Allocation) {
		if (allocations.length == 0) revert InvalidPhase(AuctionTypes.AuctionPhase.Allocation, currentPhase);
		
		// Get bundles and bidders for allocation scoring
		AuctionTypes.Bundle[] memory allBundles = CPAProxyPhase.getAllBundles(this);
		uint256 totalBidders = CPAClockPhase.getTotalBidders(this);
		
		// Select winning allocation
		uint256 winningIndex = AllocationScoring.selectWinningAllocation(
			allocations,
			allBundles,
			totalBidders
		);
		
		finalAllocation = allocations[winningIndex];
		winningAllocator = finalAllocation.allocator;
		
		_changePhase(AuctionTypes.AuctionPhase.Reveal);
	}

	/**
	 * @notice Start reveal phase
	 */
	function startRevealPhase() external onlyOwner onlyPhase(AuctionTypes.AuctionPhase.Allocation) {
		_changePhase(AuctionTypes.AuctionPhase.Reveal);
	}

	/**
	 * @notice Reveal bidder identity
	 * @param bidder The bidder address
	 * @param proxy The proxy address
	 * @param saltA First salt
	 * @param saltB Second salt
	 * @param finalPurchaseAmount Final purchase amount
	 */
	function reveal(
		address bidder,
		address proxy,
		bytes32 saltA,
		bytes32 saltB,
		uint256 finalPurchaseAmount
	) external whenNotPaused whenNotCancelled onlyPhase(AuctionTypes.AuctionPhase.Reveal) {
		CPARevealPhase.reveal(this, bidder, proxy, saltA, saltB, finalPurchaseAmount);
	}

	/**
	 * @notice End reveal phase and move to settlement
	 */
	function endRevealPhase() external onlyOwner onlyPhase(AuctionTypes.AuctionPhase.Reveal) {
		_changePhase(AuctionTypes.AuctionPhase.Settlement);
		_finalizeSettlement();
	}

	/**
	 * @notice Register a commit hash (called by proxies)
	 * @param commitHash The commit hash to register
	 */
	function registerCommit(bytes32 commitHash) external {
		if (commitProxy[commitHash] != address(0)) revert InvalidCommitHash();
		commitProxy[commitHash] = msg.sender;
	}

	/**
	 * @notice Add a pool to the auction
	 * @param poolKey The V4 pool key
	 * @param depositAmount Amount deposited for auction
	 * @param initialPrice Initial price for the pool
	 */
	function addPool(
		PoolKey calldata poolKey,
		uint256 depositAmount,
		uint256 initialPrice
	) external onlyOwner onlyPhase(AuctionTypes.AuctionPhase.Setup) {
		// Use library to validate and prepare pool data
		(PoolId poolId, AuctionTypes.PoolInfo memory poolInfo, bool isCurrency0Numeraire) = 
			CPASetup.validateAndPreparePool(poolKey, depositAmount, poolManager, commonNumeraire);

		// initialize the pool (unlocking not necessary)
		poolManager.initialize(poolKey, 0);

		// transfer the currency that is NOT the common numeraire from the sender to this hook
		if (isCurrency0Numeraire) {
			IERC20(Currency.unwrap(poolKey.currency1)).transferFrom(msg.sender, address(this), depositAmount);
		} else {
			IERC20(Currency.unwrap(poolKey.currency0)).transferFrom(msg.sender, address(this), depositAmount);
		}

		// Store the pool info
		_addPool(poolId, poolInfo);
	}

	/**
	 * @notice Add multiple pools to the auction
	 * @param poolKeys Array of V4 pool keys
	 * @param depositAmounts Array of deposit amounts
	 * @param initialPrices Array of initial prices
	 */
	function addPools(
		PoolKey[] calldata poolKeys,
		uint256[] calldata depositAmounts,
		uint256[] calldata initialPrices
	) external onlyOwner onlyPhase(AuctionTypes.AuctionPhase.Setup) {
		// TODO: Implement batch pool addition
		// This should call CPASetup.addPool for each pool
	}

	// // setup phase
	// // @inheritdoc CPASetup
	// function addPool(
	// 	PoolKey poolKey,
	// 	uint256 depositAmount,
	// 	uint256 initialPrice
	// ) external onlyOwner onlyPhase(AuctionTypes.AuctionPhase.Setup) {
	// 	_addPool(poolKey, depositAmount, initialPrice, poolManager, commonNumeraire);
	// 	// prices.push(initialPrice);
	// }

	// // @inheritdoc CPASetup
	// function addPools(
	// 	PoolKey[] calldata poolKeys,
	// 	uint256[] calldata depositAmounts,
	// 	uint256[] calldata initialPrices
	// ) external onlyOwner onlyPhase(AuctionTypes.AuctionPhase.Setup) {
	// 	_addPools(poolKeys, depositAmounts, initialPrices, poolManager, commonNumeraire);
	// }
	

	// Internal functions

	/**
	 * @notice Change auction phase
	 * @param newPhase The new phase
	 */
	function _changePhase(AuctionTypes.AuctionPhase newPhase) internal {
		AuctionTypes.AuctionPhase oldPhase = currentPhase;
		currentPhase = newPhase;
		emit IErrorsAndEvents.AuctionPhaseChanged(oldPhase, newPhase);
	}

	/**
	 * @notice Process financial settlement
	 * @param bidder The bidder address
	 * @param finalPurchaseAmount Final purchase amount
	 */
	function _processFinancialSettlement(address bidder, uint256 finalPurchaseAmount) internal {
		CPARevealPhase.processFinancialSettlement(this, bidder, finalPurchaseAmount);
	}

	/**
	 * @notice Finalize settlement
	 */
	function _finalizeSettlement() internal {
		CPARevealPhase.finalizeSettlement(this);
	}

	/**
	 * @notice Update pool hook states
	 */
	function _updatePoolHookStates() internal {
		for (uint256 i = 0; i < pools.length; i++) {
			PoolHook(poolHooks[i]).setAuctionState(
				AuctionTypes.AuctionPhase.Clock,
				paused,
				cancelled
			);
		}
	}

	/**
	 * @notice Refund all stakes
	 */
	function _refundAllStakes() internal {
		// TODO: Implement stake refunds
		// This should iterate through all bidders and refund their stakes
		// when auction is cancelled
	}

	//// hook stuff
	function _burn(
		RemoveLiquidityAsBidParams memory params,
		BalanceDelta callerDelta,
		BalanceDelta feesAccrued,
		uint256 shares
	) internal override {
		// TODO: Implement burn
		// This should burn the liquidity shares and refund the stake
		// right now we don't do anything.
	}

	function _mint(
		AddLiquidityAsBidParams memory params,
		BalanceDelta callerDelta,
		BalanceDelta feesAccrued,
		uint256 shares
	) internal override {
		// TODO: Implement mint
		// This should mint the liquidity shares and refund the stake
		// right now we don't do anything.
	}

	function _getAddLiquidity(uint160 sqrtPriceX96, AddLiquidityAsBidParams memory params)
		internal
		override
		returns (bytes memory modify, uint256 shares) {
			// TODO: Implement get add liquidity
			// This should return the modify and shares
		}
	
	function _getRemoveLiquidity(RemoveLiquidityAsBidParams memory params)
		internal
		override
		returns (bytes memory modify, uint256 shares) {
			// TODO: Implement get remove liquidity
			// This should return the modify and shares
		}

	/**
	 * @notice Returns the hook permissions configuration
	 * @return permissions The hook permissions configuration
	 */
	function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
		return Hooks.Permissions({
			beforeInitialize: true,
			afterInitialize: false,
			beforeAddLiquidity: false,
			beforeRemoveLiquidity: false,
			afterAddLiquidity: false,
			afterRemoveLiquidity: false,
			beforeSwap: true,
			afterSwap: false,
			beforeDonate: false,
			afterDonate: false,
			beforeSwapReturnDelta: false,
			afterSwapReturnDelta: false,
			afterAddLiquidityReturnDelta: false,
			afterRemoveLiquidityReturnDelta: false
		});
	}
}
