// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IPositionManager } from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
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
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { CurrencySettler } from "@openzeppelin/uniswap-hooks/src/utils/CurrencySettler.sol";

import { CPAStorage } from "./base/CPAStorage.sol";
import { CPASetup } from "./libraries/CPASetup.sol";
import { CPAClockPhase } from "./libraries/CPAClockPhase.sol";
import { CPAProxyPhase } from "./libraries/CPAProxyPhase.sol";
import { CPAAllocationPhase } from "./libraries/CPAAllocationPhase.sol";
import { CPASettlementPhase } from "./libraries/CPASettlementPhase.sol";
import { CPAFinishedPhase } from "./libraries/CPAFinishedPhase.sol";
import { CPACallbacks } from "./libraries/CPACallbacks.sol";

import { IErrorsAndEvents } from "./utils/IErrorsAndEvents.sol";
import { CommitReveal } from "./utils/CommitReveal.sol";
import { Callbacks } from "./utils/Callbacks.sol";
import { StorageAccess } from "./utils/StorageAccess.sol";
import { AuctionTypes } from "./types/AuctionTypes.sol";
import { AuctionId } from "./types/AuctionId.sol";
import { BundleId } from "./types/BundleId.sol";
import { ICPAHook } from "./interfaces/ICPAHook.sol";

/**
 * @title CPAManager
 * @notice Main auction manager implementing clock-proxy auction with commit-reveal privacy
 * @author notthatintodefi.eth
 */
contract CPAManager is IErrorsAndEvents, Ownable, CPAStorage, ReentrancyGuard, Callbacks {
	using AuctionTypes for *;
	using PoolIdLibrary for PoolKey;
	using CurrencySettler for Currency;
	using BalanceDeltaLibrary for BalanceDelta;
	using CurrencyLibrary for Currency;
	using SafeCast for *;

	// ========================================
	// EXTERNAL LIBRARY ADDRESSES
	// ========================================

	/// @notice Address of the CPASetup external library
	address public immutable setupLib;
	/// @notice Address of the CPAClockPhase external library
	address public immutable clockPhaseLib;
	/// @notice Address of the CPAProxyPhase external library
	address public immutable proxyPhaseLib;
	/// @notice Address of the CPAAllocationPhase external library
	address public immutable allocationPhaseLib;
	/// @notice Address of the CPASettlementPhase external library
	address public immutable settlementPhaseLib;
	/// @notice Address of the CPAFinishedPhase external library
	address public immutable finishedPhaseLib;
	/// @notice Address of the CPAAuctionControl external library
	address public immutable auctionControlLib;
	/// @notice Address of the CPACallbacks external library
	address public immutable callbackLib;
	/// @notice Address of the CPAManagerHelpers external library
	address public immutable helpersLib;
	/// @notice Address of the CPAValidation external library
	address public immutable validationLib;
	/// @notice Address of the CPATransitions external library
	address public immutable transitionsLib;
	/// @notice Address of the CPAUtilities external library
	address public immutable utilitiesLib;

	// ========================================
	// CONSTRUCTOR
	// ========================================

	/**
	 * @notice Constructor
	 * @param _poolManager The V4 pool manager
	 * @param _owner The auction owner
	 * @param _cpaAuctionHookAddr The CPA auction hook address
	 * @param _positionManager The PositionManager address for NFT position creation
	 * @param _protocolWallet The protocol wallet address for penalty collection
	 * @param _setupLib Address of the CPASetup external library
	 * @param _clockPhaseLib Address of the CPAClockPhase external library
	 * @param _proxyPhaseLib Address of the CPAProxyPhase external library
	 * @param _allocationPhaseLib Address of the CPAAllocationPhase external library
	 * @param _settlementPhaseLib Address of the CPASettlementPhase external library
	 * @param _finishedPhaseLib Address of the CPAFinishedPhase external library
	 * @param _auctionControlLib Address of the CPAAuctionControl external library
	 * @param _callbackLib Address of the CPACallbacks external library
	 * @param _helpersLib Address of the CPAManagerHelpers external library
	 * @param _validationLib Address of the CPAValidation external library
	 * @param _transitionsLib Address of the CPATransitions external library
	 * @param _utilitiesLib Address of the CPAUtilities external library
	 */
	constructor(
		IPoolManager _poolManager,
		address _owner,
		address _cpaAuctionHookAddr,
		IPositionManager _positionManager,
		address _protocolWallet,
		address _setupLib,
		address _clockPhaseLib,
		address _proxyPhaseLib,
		address _allocationPhaseLib,
		address _settlementPhaseLib,
		address _finishedPhaseLib,
		address _auctionControlLib,
		address _callbackLib,
		address _helpersLib,
		address _validationLib,
		address _transitionsLib,
		address _utilitiesLib
	) Ownable(_owner) CPAStorage(_cpaAuctionHookAddr, _positionManager) {
		manager = _poolManager;
		protocolWallet = _protocolWallet;
		setupLib = _setupLib;
		clockPhaseLib = _clockPhaseLib;
		proxyPhaseLib = _proxyPhaseLib;
		allocationPhaseLib = _allocationPhaseLib;
		settlementPhaseLib = _settlementPhaseLib;
		finishedPhaseLib = _finishedPhaseLib;
		auctionControlLib = _auctionControlLib;
		callbackLib = _callbackLib;
		helpersLib = _helpersLib;
		validationLib = _validationLib;
		transitionsLib = _transitionsLib;
		utilitiesLib = _utilitiesLib;
	}

	// ========================================
	// MODIFIERS
	// ========================================

	modifier onlyAuctionOwner(AuctionId auctionId) {
		bytes memory result = _delegatecallLibrary(
			validationLib,
			abi.encodeWithSelector(
				bytes4(keccak256("validateAuctionOwner(address,uint256,address)")),
				address(this),
				auctionId,
				msg.sender
			)
		);
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
		_delegatecallLibrary(
			validationLib,
			abi.encodeWithSelector(
				bytes4(keccak256("validateAuctionActive(address,uint256)")),
				address(this),
				auctionId
			)
		);
		_;
	}

	modifier whenAuctionCancelled(AuctionId auctionId) {
		_delegatecallLibrary(
			validationLib,
			abi.encodeWithSelector(
				bytes4(keccak256("validateAuctionCancelled(address,uint256)")),
				address(this),
				auctionId
			)
		);
		_;
	}

	/**
	 * @notice Modifier to ensure auction is in expected phase
	 */
	modifier onlyPhase(AuctionId auctionId, AuctionTypes.AuctionPhase phase) {
		_delegatecallLibrary(
			validationLib,
			abi.encodeWithSelector(
				bytes4(keccak256("validatePhase(address,uint256,uint8)")),
				address(this),
				auctionId,
				uint8(phase)
			)
		);
		_;
	}

	/**
	 * @notice Modifier to ensure phase has expired based on duration
	 */
	modifier onlyWhenPhaseExpired(AuctionId auctionId, AuctionTypes.AuctionPhase phase) {
		_delegatecallLibrary(
			validationLib,
			abi.encodeWithSelector(
				bytes4(keccak256("validatePhaseExpired(address,uint256,uint8)")),
				address(this),
				auctionId,
				uint8(phase)
			)
		);
		_;
	}

	/**
	 * @notice Modifier to ensure phase has not expired based on duration
	 */
	modifier onlyWhenPhaseNotExpired(AuctionId auctionId, AuctionTypes.AuctionPhase phase) {
		_delegatecallLibrary(
			validationLib,
			abi.encodeWithSelector(
				bytes4(keccak256("validatePhaseNotExpired(address,uint256,uint8)")),
				address(this),
				auctionId,
				uint8(phase)
			)
		);
		_;
	}

	/**
	 * @notice Validates ETH handling for numeraire
	 * @dev For ETH numeraire: requires msg.value > 0
	 *      For ERC20 numeraire: requires msg.value == 0
	 */
	modifier validateEthForNumeraire(AuctionId auctionId) {
		_delegatecallLibrary(
			validationLib,
			abi.encodeWithSelector(
				bytes4(keccak256("validateEthForNumeraireValue(address,uint256,uint256)")),
				address(this),
				auctionId,
				msg.value
			)
		);
		_;
	}

	// ========================================
	// CALLBACKS OVERRIDES
	// ========================================

	/// @notice Override getSetupLib to return the immutable library address
	function getSetupLib() internal view override returns (address) {
		return setupLib;
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
	function pause(AuctionId auctionId) external nonReentrant onlyAuctionOwner(auctionId) {
		_delegatecallLibrary(
			auctionControlLib,
			abi.encodeWithSelector(
				bytes4(keccak256("pause(address,uint256,address,address)")),
				address(this),
				auctionId,
				msg.sender,
				cpaAuctionHookAddr
			)
		);
	}

	/**
	 * @notice Unpause the auction
	 */
	function unpause(AuctionId auctionId) external nonReentrant onlyAuctionOwner(auctionId) {
		_delegatecallLibrary(
			auctionControlLib,
			abi.encodeWithSelector(
				bytes4(keccak256("unpause(address,uint256,address,address)")),
				address(this),
				auctionId,
				msg.sender,
				cpaAuctionHookAddr
			)
		);
	}

	/**
	 * @notice Cancel the auction and refund all stakes
	 * @dev Only allowed in Setup and Clock phases
	 */
	function cancelAuction(AuctionId auctionId) external nonReentrant onlyAuctionOwner(auctionId) {
		_delegatecallLibrary(
			auctionControlLib,
			abi.encodeWithSelector(
				bytes4(keccak256("cancelAuction(address,uint256,address,address)")),
				address(this),
				auctionId,
				msg.sender,
				cpaAuctionHookAddr
			)
		);
	}

	/**
	 * @notice Force cancel auction when max pause duration exceeded
	 * @dev Anyone can call this after 72 hours of total pause time
	 */
	function forceCancelAuction(AuctionId auctionId) external nonReentrant {
		_delegatecallLibrary(
			auctionControlLib,
			abi.encodeWithSelector(
				bytes4(keccak256("forceCancelAuction(address,uint256,address,address)")),
				address(this),
				auctionId,
				msg.sender,
				cpaAuctionHookAddr
			)
		);
	}

	function reclaimStake(AuctionId auctionId) external {
		_delegatecallLibrary(
			auctionControlLib,
			abi.encodeWithSelector(
				bytes4(keccak256("reclaimStake(address,uint256,address)")),
				address(this),
				auctionId,
				msg.sender
			)
		);
	}

	/**
	 * @notice Forfeit bidder who didn't claim in time
	 * @dev Only callable in Finished phase. Caller gets 1% reward incentive.
	 * @param auctionId The auction ID
	 * @param bidder The bidder address to forfeit
	 */
	function forfeit(AuctionId auctionId, address bidder) external onlyPhase(auctionId, AuctionTypes.AuctionPhase.Finished) {
		_delegatecallLibrary(
			auctionControlLib,
			abi.encodeWithSelector(
				bytes4(keccak256("forfeit(address,uint256,address,address)")),
				address(this),
				auctionId,
				bidder,
				msg.sender
			)
		);
	}

	/**
	 * @notice Transfer all NFT positions to the auctioneer
	 * @dev Permissionless function - anyone can call as positions only go to auctioneer
	 * @param auctionId The auction identifier
	 */
	function transferPositionsToAuctioneer(AuctionId auctionId) 
		external 
		nonReentrant 
		whenAuctionActive(auctionId) 
		onlyPhase(auctionId, AuctionTypes.AuctionPhase.Finished) 
	{
	bytes memory result = _delegatecallLibrary(
		finishedPhaseLib,
		abi.encodeWithSelector(
			bytes4(keccak256("transferPositionsToAuctioneer(address,uint256)")),
			address(this),
			auctionId
		)
	);
	// No return value to decode
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
	) external nonReentrant returns (AuctionId) {
		// DELEGATECALL to external library - storage mappings are accessible in library context
		// We pass config and auctionOwner, but storage mappings are accessed directly by library
		bytes memory result = _delegatecallLibrary(
			setupLib,
			abi.encodeWithSelector(
				CPASetup.createAuction.selector,
				address(this),
				config,
				auctionOwner
			)
		);
		AuctionId auctionId = abi.decode(result, (AuctionId));
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
	) external nonReentrant onlyAuctionOwner(auctionId) {
		_delegatecallLibrary(
			setupLib,
			abi.encodeWithSelector(
				CPASetup.moveDeposit.selector,
				address(this),
				poolKey,
				auctionId,
				depositAmount
			)
		);
		_updateCPAHookStates(auctionId);
	}

	// ========================================
	// CLOCK PHASE
	// ========================================


	function startClockPhase(AuctionId auctionId) external nonReentrant onlyAuctionOwner(auctionId) onlyPhase(auctionId, AuctionTypes.AuctionPhase.Setup) {
		_startClockRound(auctionId);
	}

	/**
	 * @notice Deposit to all pools and start clock phase in one transaction
	 * @param auctionId The auction ID
	 * @param poolKeys Array of pool keys to deposit to
	 * @param amounts Array of deposit amounts (must match poolKeys length)
	 */
	function depositAllAndStartClock(
		AuctionId auctionId,
		PoolKey[] memory poolKeys,
		uint256[] memory amounts
	) external nonReentrant onlyAuctionOwner(auctionId) onlyPhase(auctionId, AuctionTypes.AuctionPhase.Setup) {
		_delegatecallLibrary(
			setupLib,
			abi.encodeWithSelector(
				CPASetup.depositAllAndStartClock.selector,
				address(this),
				poolKeys,
				amounts,
				auctionId
			)
		);

		// Update CPAHook states for all pools
		_updateCPAHookStates(auctionId);
	}

	/**
	 * @notice Start the clock phase
	 * @param auctionId The auction ID
	 */
	 function _startClockRound(AuctionId auctionId) internal {
		// Handle first-time transition from Setup to Clock phase
		if (StorageAccess.getAuctionPhase(auctionId) == AuctionTypes.AuctionPhase.Setup) {
			bytes memory result = _delegatecallLibrary(
				setupLib,
				abi.encodeWithSelector(
					CPASetup.confirmSetupComplete.selector,
					address(this),
					auctionId
				)
			);
			if (!abi.decode(result, (bool))) revert IErrorsAndEvents.SetupNotComplete();
			// Transition to Clock phase via helpers
			_delegatecallLibrary(
				helpersLib,
				abi.encodeWithSelector(
					bytes4(keccak256("startClockRound(address,uint256,address,address)")),
					address(this),
					auctionId,
					setupLib,
					clockPhaseLib
				)
			);
		}
		_delegatecallLibrary(
			clockPhaseLib,
			abi.encodeWithSelector(
				bytes4(keccak256("openClockRound(address,uint256)")),
				address(this),
				auctionId
			)
		);
	}

	/**
	 * @notice End current clock round
	 * @param auctionId The auction ID
	 */
	 function endClockRound(AuctionId auctionId) external nonReentrant onlyAuctionOwner(auctionId) onlyPhase(auctionId, AuctionTypes.AuctionPhase.Clock) {
		// Set the clock to closed
		_delegatecallLibrary(
			clockPhaseLib,
			abi.encodeWithSelector(
				bytes4(keccak256("setClockOpen(address,uint256,uint256)")),
				address(this),
				auctionId,
				1
			)
		);
		
		// Process round results (calculate excess demand and update prices)
		bytes memory result = _delegatecallLibrary(
			clockPhaseLib,
			abi.encodeWithSelector(
				bytes4(keccak256("processClockRound(address,uint256)")),
				address(this),
				auctionId
			)
		);
		uint256[] memory totalDemands = abi.decode(result, (uint256[]));
		
		// Emit event for round closure
		emit IErrorsAndEvents.ClockRoundClosed(auctionId, StorageAccess.getAuctionCurrentRound(auctionId), StorageAccess.getActiveBiddersLength(auctionId));

		// Check if clock phase should end
		bytes memory endResult = _delegatecallLibrary(
			clockPhaseLib,
			abi.encodeWithSelector(
				bytes4(keccak256("shouldEndClockPhase(address,uint256,uint256[],address)")),
				address(this),
				auctionId,
				totalDemands,
				address(manager)
			)
		);
		bool shouldEnd = abi.decode(endResult, (bool));
		if (shouldEnd) {
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
		if (StorageAccess.getAuctionClockOpen(auctionId) == 2) {
			_delegatecallLibrary(
				clockPhaseLib,
				abi.encodeWithSelector(
					bytes4(keccak256("setClockOpen(address,uint256,uint256)")),
					address(this),
					auctionId,
					1
				)
			);
			
			// Emit event for round closure
			emit IErrorsAndEvents.ClockRoundClosed(auctionId, StorageAccess.getAuctionCurrentRound(auctionId), StorageAccess.getActiveBiddersLength(auctionId));
		}
		
		// Handle undersell by reverting to last oversold prices
		_delegatecallLibrary(
			clockPhaseLib,
			abi.encodeWithSelector(
				bytes4(keccak256("revertUndersoldPrices(address,uint256,address)")),
				address(this),
				auctionId,
				address(manager)
			)
		);
		
		// Transition to proxy phase via helpers
		_delegatecallLibrary(
			helpersLib,
			abi.encodeWithSelector(
				bytes4(keccak256("endClockPhase(address,uint256,address,address)")),
				address(this),
				auctionId,
				clockPhaseLib,
				address(manager)
			)
		);
	}

	/**
	 * @notice End the clock phase and transition to proxy phase
	 * @param auctionId The auction ID
	 */
	function endClockPhase(AuctionId auctionId) external nonReentrant onlyAuctionOwner(auctionId) onlyPhase(auctionId, AuctionTypes.AuctionPhase.Clock) {
		_endClockPhase(auctionId);
	}

	/**
	 * @notice Submit a bid during clock phase
	 * @param auctionId The auction ID
	 * @param demands Array of item demands
	 * @param maxStakeAmount Maximum stake amount the bidder is willing to provide for this bid. This is inclusive of the allocator reward.
	 */
	function submitBid(
		AuctionId auctionId,
		uint256[] calldata demands,
		uint256 maxStakeAmount
	) external payable whenAuctionActive(auctionId) onlyPhase(auctionId, AuctionTypes.AuctionPhase.Clock) onlyWhenPhaseNotExpired(auctionId, AuctionTypes.AuctionPhase.Clock) validateEthForNumeraire(auctionId) {
		
		_delegatecallLibrary(
			clockPhaseLib,
			abi.encodeWithSelector(
				bytes4(keccak256("processBid(address,uint256,uint256[],uint256)")),
				address(this),
				auctionId,
				demands,
				maxStakeAmount
			)
		);
	}

	/**
	 * @notice Commit to a bidder (proxy function)
	 * @param auctionId The auction ID
	 * @param commitHash The commit hash
	 */
	function commitToBidder(AuctionId auctionId, bytes32 commitHash) external {
		_delegatecallLibrary(
			utilitiesLib,
			abi.encodeWithSelector(
				bytes4(keccak256("commitToBidder(address,uint256,bytes32,address)")),
				address(this),
				auctionId,
				commitHash,
				msg.sender
			)
		);
	}

	/**
	 * @notice Dropout from auction with penalty. Can only be done during the clock phase.
	 * @param auctionId The auction ID
	 */
	function dropout(AuctionId auctionId) external whenAuctionActive(auctionId) onlyPhase(auctionId, AuctionTypes.AuctionPhase.Clock) onlyWhenPhaseNotExpired(auctionId, AuctionTypes.AuctionPhase.Clock) {
		_delegatecallLibrary(
			auctionControlLib,
			abi.encodeWithSelector(
				bytes4(keccak256("dropout(address,uint256,address)")),
				address(this),
				auctionId,
				msg.sender
			)
		);
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
	) external whenAuctionActive(auctionId) onlyPhase(auctionId, AuctionTypes.AuctionPhase.Proxy) onlyWhenPhaseNotExpired(auctionId, AuctionTypes.AuctionPhase.Proxy) returns (BundleId bundleId) {
		
		bytes memory result = _delegatecallLibrary(
			proxyPhaseLib,
			abi.encodeWithSelector(
				bytes4(keccak256("submitBundle(address,bytes32,(uint256,bytes32,uint256[],uint256))")),
				address(this),
				commitHash,
				bundleData
			)
		);
		bundleId = abi.decode(result, (BundleId));
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
	) external whenAuctionActive(auctionId) onlyPhase(auctionId, AuctionTypes.AuctionPhase.Allocation) onlyWhenPhaseNotExpired(auctionId, AuctionTypes.AuctionPhase.Allocation) {
		if (msg.sender != allocationData.allocator) revert IErrorsAndEvents.Unauthorized(); // cannot submit an allocation for someone else
		
		_delegatecallLibrary(
			allocationPhaseLib,
			abi.encodeWithSelector(
				bytes4(keccak256("submitAllocation(address,(uint256,(uint256,bytes32,uint256[],uint256)[]))")),
				address(this),
				allocationData
			)
		);
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
		_delegatecallLibrary(
			settlementPhaseLib,
			abi.encodeWithSelector(
				bytes4(keccak256("reveal(address,uint256,address,address,bytes32,bytes32)")),
				address(this),
				auctionId,
				msg.sender,
				proxy,
				saltA,
				saltB
			)
		);
	}

	// ========================================
	// SETTLEMENT PHASE	
	// ========================================

	/**
	 * @notice Claim tokens from winning allocation
	 * @param auctionId The auction ID
	 * @param commitHash The commit hash for the bidder
	 * @param poolId The pool ID to claim from
	 */
	function claimToken(AuctionId auctionId, bytes32 commitHash, PoolId poolId) external payable whenAuctionActive(auctionId) onlyPhase(auctionId, AuctionTypes.AuctionPhase.Settlement) onlyOwner() {
		// we only allow the owner to claim individual tokens on behalf of the bidder because in this function,
		// we do not ever remove the bundle from the winning bundle ids.
		// the owner here is NOT the auction owner, but the owner of the CPA protocol itself.
		
		// Call the settlement phase
		_delegatecallLibrary(
			settlementPhaseLib,
			abi.encodeWithSelector(
				bytes4(keccak256("claimToken(address,address,uint256,bytes32,uint256)")),
				address(this),
				msg.sender,
				auctionId,
				commitHash,
				PoolId.unwrap(poolId)
			)
		);
	}

	/**
	 * @notice Claim all tokens from winning allocation for a bidder.
	 * @param auctionId The auction ID
	 * @param commitHash The commit hash for the bidder
	 */
	function claimAllTokens(AuctionId auctionId, bytes32 commitHash) external payable whenAuctionActive(auctionId) onlyPhase(auctionId, AuctionTypes.AuctionPhase.Settlement) {
		_delegatecallLibrary(
			settlementPhaseLib,
			abi.encodeWithSelector(
				bytes4(keccak256("claimAllTokens(address,address,uint256,bytes32)")),
				address(this),
				msg.sender,
				auctionId,
				commitHash
			)
		);

		// now that they've claimed all their tokens, delete the bundle at the commit hash from the winning bundle ids
		StorageAccess.setWinningBundleId(commitHash, BundleId.wrap(0));
	}

	/**
	 * @notice Claim the allocator reward for the winning allocation.
	 * @dev Only callable by the winning allocator during or after the settlement phase.
	 *      This function will trigger a callback to transfer the reward to the allocator.
	 * @param auctionId The auction ID
	 */
	function claimAllocatorReward(AuctionId auctionId) external {
		_delegatecallLibrary(
			auctionControlLib,
			abi.encodeWithSelector(
				bytes4(keccak256("claimAllocatorReward(address,uint256,address)")),
				address(this),
				auctionId,
				msg.sender
			)
		);
	}

	// ========================================
	// PERMISSIONLESS PHASE TRANSITIONS
	// ========================================

	/**
	 * @notice Transition from Proxy to Allocation phase (callable by anyone)
	 * @param auctionId The auction ID
	 */
	function transitionToAllocation(AuctionId auctionId) external nonReentrant whenAuctionActive(auctionId) onlyPhase(auctionId, AuctionTypes.AuctionPhase.Proxy) {
		_delegatecallLibrary(
			transitionsLib,
			abi.encodeWithSelector(
				bytes4(keccak256("transitionToAllocation(address,uint256,address)")),
				address(this),
				auctionId,
				msg.sender
			)
		);
	}

	/**
	 * @notice Transition from Allocation to Settlement phase (callable by anyone)
	 * @param auctionId The auction ID
	 */
	function transitionToSettlement(AuctionId auctionId) external nonReentrant whenAuctionActive(auctionId) onlyPhase(auctionId, AuctionTypes.AuctionPhase.Allocation) {
		// select the winner and move the assets to the pools
		_delegatecallLibrary(
			allocationPhaseLib,
			abi.encodeWithSelector(
				bytes4(keccak256("selectWinner(address,uint256)")),
				address(this),
				auctionId
			)
		);
		_delegatecallLibrary(
			allocationPhaseLib,
			abi.encodeWithSelector(
				bytes4(keccak256("transferAssetsToPools(address,uint256)")),
				address(this),
				auctionId
			)
		);
		
		// Transition to settlement phase via transitions library
		_delegatecallLibrary(
			transitionsLib,
			abi.encodeWithSelector(
				bytes4(keccak256("transitionToSettlement(address,uint256,address,address)")),
				address(this),
				auctionId,
				allocationPhaseLib,
				msg.sender
			)
		);
	}

	/**
	 * @notice Transition from Settlement to Finished phase (callable by anyone)
	 * @param auctionId The auction ID
	 */
	function transitionToFinished(AuctionId auctionId) external nonReentrant whenAuctionActive(auctionId) onlyPhase(auctionId, AuctionTypes.AuctionPhase.Settlement) {
		_delegatecallLibrary(
			transitionsLib,
			abi.encodeWithSelector(
				bytes4(keccak256("transitionToFinished(address,uint256)")),
				address(this),
				auctionId
			)
		);
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
		return StorageAccess.getBids(auctionId, bidder);
	}

	/**
	 * @notice Register a commit hash (called by proxies)
	 * @param auctionId The auction ID
	 * @param commitHash The commit hash to register
	 * @dev This is called by proxies to register a commit hash. THis can only be submitted during the setup and clock phases.
	 */
	function registerCommit(AuctionId auctionId, bytes32 commitHash) external {
		_delegatecallLibrary(
			utilitiesLib,
			abi.encodeWithSelector(
				bytes4(keccak256("registerCommit(address,uint256,bytes32,address)")),
				address(this),
				auctionId,
				commitHash,
				msg.sender
			)
		);
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
		_delegatecallLibrary(
			helpersLib,
			abi.encodeWithSelector(
				bytes4(keccak256("changePhase(address,uint256,uint8)")),
				address(this),
				auctionId,
				uint8(newPhase)
			)
		);
	}

	/**
	 * @notice Check if a phase has expired based on duration
	 * @param auctionId The auction ID
	 * @param phase The phase to check
	 * @return true if phase has expired
	 */
	function _hasPhaseExpired(AuctionId auctionId, AuctionTypes.AuctionPhase phase) internal view returns (bool) {
		uint256[] memory durations = StorageAccess.getAuctionPhaseDurations(auctionId);
		
		if (phase == AuctionTypes.AuctionPhase.Proxy) {
			uint256 startTime = StorageAccess.getProxyPhaseStartTime(auctionId);
			if (startTime == 0) return false;
			return block.timestamp >= startTime + durations[0];
		}
		
		if (phase == AuctionTypes.AuctionPhase.Allocation) {
			uint256 startTime = StorageAccess.getAllocationPhaseStartTime(auctionId);
			if (startTime == 0) return false;
			return block.timestamp >= startTime + durations[1];
		}
		
		if (phase == AuctionTypes.AuctionPhase.Settlement) {
			uint256 startTime = StorageAccess.getSettlementPhaseStartTime(auctionId);
			if (startTime == 0) return false;
			return block.timestamp >= startTime + durations[2];
		}
		
		// Clock phase doesn't use time-based expiration
		return false;
	}

	/**
	 * @notice Update pool hook states
	 * @param auctionId The auction ID
	 */
	function _updateCPAHookStates(AuctionId auctionId) internal {
		_delegatecallLibrary(
			helpersLib,
			abi.encodeWithSelector(
				bytes4(keccak256("updateCPAHookStates(address,uint256)")),
				address(this),
				auctionId
			)
		);
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
		
		// DELEGATECALL to external callback library
		if (operationType == 0) {
			// Bid as liquidity add
			return _delegatecallLibrary(
				callbackLib,
				abi.encodeWithSelector(
					CPACallbacks.handleBid.selector,
					CPAStorage(address(this)),
					operationData
				)
			);
		} else if (operationType == 1) {
			// Deposit transfer (setup) - still uses setupLib via _handleDepositTransfer
			return _handleDepositTransfer(operationData);
		} else if (operationType == 2) {
			// Price update swap
			return _delegatecallLibrary(
				callbackLib,
				abi.encodeWithSelector(
					CPACallbacks.handlePriceUpdateSwap.selector,
					CPAStorage(address(this)),
					operationData
				)
			);
		} else if (operationType == 3) {
			// Mint position after allocation
			return _delegatecallLibrary(
				callbackLib,
				abi.encodeWithSelector(
					CPACallbacks.handleMintPosition.selector,
					CPAStorage(address(this)),
					operationData
				)
			);
		} else if (operationType == 4) {
			// Claim token settlement
			return _delegatecallLibrary(
				callbackLib,
				abi.encodeWithSelector(
					CPACallbacks.handleClaimToken.selector,
					CPAStorage(address(this)),
					operationData
				)
			);
		} else if (operationType == 5) {
			// Refund stake
			return _delegatecallLibrary(
				callbackLib,
				abi.encodeWithSelector(
					CPACallbacks.refundStake.selector,
					CPAStorage(address(this)),
					operationData
				)
			);
		} else if (operationType == 6) {
			// Claim allocator reward
			return _delegatecallLibrary(
				callbackLib,
				abi.encodeWithSelector(
					CPACallbacks.handleClaimAllocatorReward.selector,
					CPAStorage(address(this)),
					operationData
				)
			);
		} else if (operationType == 7) {
			// Claim all tokens
			return _delegatecallLibrary(
				callbackLib,
				abi.encodeWithSelector(
					CPACallbacks.handleClaimAllTokens.selector,
					CPAStorage(address(this)),
					operationData
				)
			);
		} else if (operationType == 8) {
			// Batch deposit transfer
			return _delegatecallLibrary(
				callbackLib,
				abi.encodeWithSelector(
					CPACallbacks.handleBatchDepositTransfer.selector,
					CPAStorage(address(this)),
					operationData
				)
			);
		} else if (operationType == 9) {
			// Batch ERC6909 to ERC20 conversion for position minting
			return _delegatecallLibrary(
				callbackLib,
				abi.encodeWithSelector(
					CPACallbacks.handleBatchERC6909ToERC20Conversion.selector,
					CPAStorage(address(this)),
					operationData
				)
			);
		} else {
			revert("Invalid operation type");
		}
	}


}