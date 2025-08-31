// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { CPABaseCustomAccounting } from "./base/CPABaseCustomAccounting.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { Hooks } from "@uniswap/v4-core/src/libraries/Hooks.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { AuctionTypes } from "./AuctionTypes.sol";
import { AuctionId } from "./AuctionId.sol";
import { CommitReveal } from "./CommitReveal.sol";
import { AllocationScoring } from "./AllocationScoring.sol";
import { PoolHook } from "./PoolHook.sol";
import { IClockProxyAuction } from "./interfaces/IClockProxyAuction.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { BalanceDelta } from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, toBalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

// wanted to use Ownable2Step but we were getting some errors
// review this thread: https://github.com/OpenZeppelin/openzeppelin-contracts/issues/4690
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol"; 
import { CPAStorage } from "./base/CPAStorage.sol";
import { CPASetup } from "./libraries/CPASetup.sol";
// import { CPAClockPhase } from "./libraries/CPAClockPhase.sol";
// import { CPAProxyPhase } from "./libraries/CPAProxyPhase.sol";
// import { CPAAllocationPhase } from "./libraries/CPAAllocationPhase.sol";
// import { CPARevealPhase } from "./libraries/CPARevealPhase.sol";
import { IErrorsAndEvents } from "./utils/IErrorsAndEvents.sol";

/**
 * @title ClockProxyAuctionHook
 * @notice Main auction hook implementing clock-proxy auction with commit-reveal privacy
 * @author Clock-Proxy Auction Team
 */
contract ClockProxyAuctionHook is IErrorsAndEvents, CPABaseCustomAccounting, Ownable, CPAStorage {
	using AuctionTypes for *;
	using PoolIdLibrary for PoolKey;
	// using CPASetup for CPAStorage;

	/**
	 * @notice Constructor
	 * @param _poolManager The V4 pool manager
	 * @param _owner The auction owner
	 */
	constructor(
		IPoolManager _poolManager,
		address _owner
	) CPABaseCustomAccounting(_poolManager) Ownable(_owner) CPAStorage(address(this)) {
		manager = _poolManager;
	}

	modifier onlyAuctionOwner(AuctionId auctionId) {
		if (auctionInfo[auctionId].auctionOwner != msg.sender) revert IErrorsAndEvents.Unauthorized();
		_;
	}

	/**
	 * @notice Modifier to ensure auction is not paused
	 */
	modifier whenNotPaused(AuctionId auctionId) {
		if (paused[auctionId]) revert IErrorsAndEvents.AuctionPausedError();
		_;
	}

	/**
	 * @notice Modifier to ensure auction is not cancelled
	 */
	modifier whenNotCancelled(AuctionId auctionId) {
		if (cancelled[auctionId]) revert IErrorsAndEvents.AuctionCancelledError();
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
	 * @param poolKeys The pool keys for the auction
	 * @param config The auction configuration
	 * @param auctionOwner The auction owner
	 * @return The auction ID
	 */
	function createAuction(
		PoolKey[] memory poolKeys, 
		AuctionTypes.AuctionConfig memory config, 
		address auctionOwner
	) external returns (AuctionId) {
		return CPASetup.createAuction(this, poolKeys, config, auctionOwner, auctionInfo, poolToAuctionId, poolInfo);
	}

	    /**
	 * @notice Start the clock phase
	 */
	 function startClockPhase(AuctionId auctionId) external onlyAuctionOwner(auctionId) onlyPhase(auctionId, AuctionTypes.AuctionPhase.Setup) {
		// if (!confirmSetupComplete(auctionId)) revert SetupNotComplete(); // fix this eventually
		_changePhase(auctionId, AuctionTypes.AuctionPhase.Clock);
		_openClockRound(auctionId);
	}

	/**
	 * @notice Open a new clock round
	 */
	 function _openClockRound(AuctionId auctionId) internal {
		auctionInfo[auctionId].currentRound++;
		auctionInfo[auctionId].clockOpen = true;
		delete auctionInfo[auctionId].roundBids;
		emit IErrorsAndEvents.ClockRoundOpened(auctionInfo[auctionId].currentRound);
	}

	/**
	 * @notice End current clock round
	 */
	 function endClockRound(AuctionId auctionId) external onlyAuctionOwner(auctionId) onlyPhase(auctionId, AuctionTypes.AuctionPhase.Clock) {
		// TODO: Uncomment when CPAClockPhase is implemented
		/*
		clockOpen[auctionId] = false;
		
		// Process round results
		CPAClockPhase.processClockRound(this);
		
		emit IErrorsAndEvents.ClockRoundClosed(currentRound[auctionId], roundBids[auctionId].length);
		
		// Check if clock phase should end
		if (CPAClockPhase.shouldEndClockPhase(this)) {
			_changePhase(auctionId, AuctionTypes.AuctionPhase.Proxy);
		} else {
			_openClockRound(auctionId);
		}
		*/
		revert("Not yet implemented");
	}

	/**
	 * @notice Submit a bid during clock phase
	 * @param auctionId The auction ID
	 * @param demands Array of item demands
	 * @param commitHash The commit hash for privacy
	 * @param stakeAmount Additional stake amount
	 */
	function submitBid(
		AuctionId auctionId,
		uint256[] calldata demands,
		bytes32 commitHash,
		uint256 stakeAmount
	) external whenNotPaused(auctionId) whenNotCancelled(auctionId) onlyPhase(auctionId, AuctionTypes.AuctionPhase.Clock) {
		// TODO: Uncomment when CPAClockPhase is implemented
		// CPAClockPhase.submitBid(this, demands, commitHash, stakeAmount);
		revert("Not yet implemented");
	}
	// we should consider using whenActive(auctionId) as the modifier and just have the actuon be active or inactive. Paused or cancelled can be emitted as an event or something. Having two modifiers feels unnecessary.

	/**
	 * @notice Dropout from auction with penalty
	 * probably need to rewrite this to accept WHO is dropping out
	 */
	function dropout(AuctionId auctionId) external whenNotPaused(auctionId) whenNotCancelled(auctionId) {
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
	) external whenNotPaused(auctionId) whenNotCancelled(auctionId) onlyPhase(auctionId, AuctionTypes.AuctionPhase.Proxy) {
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
	) external whenNotPaused(auctionId) whenNotCancelled(auctionId) onlyPhase(auctionId, AuctionTypes.AuctionPhase.Allocation) {
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
		uint256 totalBidders = CPAClockPhase.getTotalBidders(this);
		
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
	) external whenNotPaused(auctionId) whenNotCancelled(auctionId) onlyPhase(auctionId, AuctionTypes.AuctionPhase.Reveal) {
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
		AuctionTypes.AuctionPhase oldPhase = auctionInfo[auctionId].currentPhase;
		auctionInfo[auctionId].currentPhase = newPhase;
		emit IErrorsAndEvents.AuctionPhaseChanged(oldPhase, newPhase);
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
	 * @dev Unified unlock callback to handle multiple operation types
	 * @param rawData The callback data containing operation type and operation-specific data
	 * @return returnData The encoded balance deltas
	 */
	function unlockCallback(bytes calldata rawData)
		external
		override
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
		} else {
			revert("Invalid operation type");
		}
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

	///////////////////////////////////
	// HOOK SPECIFIC STUFF
	///////////////////////////////////
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
		// this should eventually mint an ERC721 token to this contract
		// that represents the bidder's stake.
	}

	function _getAddLiquidity(uint160 sqrtPriceX96, AddLiquidityAsBidParams memory params)
		internal
		override
		returns (bytes memory modify, uint256 shares) {
			// TODO: Implement get add liquidity
			// this should return the encoded params for the add liquidity
			// and the amount of shares to mint
			// the encoded params should be the same as the encoded params for the remove liquidity
			// and the amount of shares to burn
			// the encoded params should be the same as the encoded params for the remove liquidity
		}
	
	function _getRemoveLiquidity(RemoveLiquidityAsBidParams memory params)
		internal
		override
		returns (bytes memory modify, uint256 shares) {
			// TODO: Implement get remove liquidity
			// This should return the modify and shares
		}

	    /**
     * @dev Initialize the hook's pool key. The stored key should act immutably so that
     * it can safely be used across the hook's functions.
     */
    function _beforeInitialize(address, PoolKey calldata key, uint160) internal override returns (bytes4) {
        // This hook doesn't need to be initialized with a specific pool key
        // It manages auctions that can have multiple pools
		// right now, initialization is NOT the same thing as a createAuction
		// maybe in the future but it is cleaner like this for now.
        return this.beforeInitialize.selector;
    }

    /**
     * @dev Revert when liquidity is attempted to be added via the `PoolManager`.
     */
    function _beforeAddLiquidity(
		address sender, 
		PoolKey calldata poolKey, 
		ModifyLiquidityParams calldata params, 
		bytes calldata hookData
	)
        internal
        virtual
        override
        returns (bytes4)
    {
        if (!allowedPools[poolKey.toId()]) {
			revert AuctionNotFinished();
		}
		return this.beforeAddLiquidity.selector;
    }

    /**
     * @dev Revert when liquidity is attempted to be removed via the `PoolManager`.
     */
    function _beforeRemoveLiquidity(address, PoolKey calldata poolKey, ModifyLiquidityParams calldata, bytes calldata)
        internal
        virtual
        override
        returns (bytes4)
    {
        if (!allowedPools[poolKey.toId()]) {
			revert AuctionNotFinished();
		}
		return this.beforeRemoveLiquidity.selector;
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
