// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { BaseHook } from "@uniswap/v4-periphery/utils/BaseHook.sol";
import { IPoolManager } from "@uniswap/v4-core/interfaces/IPoolManager.sol";
import { Hooks } from "@uniswap/v4-core/libraries/Hooks.sol";
import { PoolKey } from "@uniswap/v4-core/types/PoolKey.sol";
import { PoolIdLibrary } from "@uniswap/v4-core/types/PoolId.sol";
import { AuctionTypes } from "./AuctionTypes.sol";
import { CommitReveal } from "./CommitReveal.sol";
import { AllocationScoring } from "./AllocationScoring.sol";
import { PoolHook } from "./PoolHook.sol";
import { IClockProxyAuction } from "./IClockProxyAuction.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { ClockProxySetup } from "./base/ClockProxySetup.sol";

/**
 * @title ClockProxyAuctionHook
 * @notice Main auction hook implementing clock-proxy auction with commit-reveal privacy
 * @author Clock-Proxy Auction Team
 */
contract ClockProxyAuctionHook is BaseHook, IClockProxyAuction, Ownable, ClockProxySetup {
	using AuctionTypes for *;
	using PoolIdLibrary for PoolKey;

	/// @notice Auction owner (deployer) - Ownable2Step
	Ownable2Step public immutable owner;
	
	/// @notice Common numeraire token (Y token)
	address public immutable commonNumeraire;
	
	/// @notice Current auction phase
	AuctionTypes.AuctionPhase public currentPhase;
	
	/// @notice Auction configuration
	AuctionTypes.AuctionConfig public config;
	
	/// @notice Current clock round
	uint256 public currentRound;
	
	/// @notice Whether auction is paused
	bool public paused;
	
	/// @notice Whether auction is cancelled
	bool public cancelled;
	
	/// @notice Clock round open for bidding
	bool public clockOpen;
	
	/// @notice Pool information mapping
	mapping(PoolId => AuctionTypes.PoolInfo) public pools;
	
	/// @notice Commit hash to proxy mapping
	mapping(bytes32 => address) public commitProxy;
	
	/// @notice Bidder stake mapping
	mapping(address => uint256) public bidderStake;
	
	/// @notice Bidder bid points mapping
	mapping(address => uint256) public bidderBidPoints;
	
	/// @notice Bundle storage
	mapping(bytes32 => AuctionTypes.Bundle[]) public bundles;
	
	/// @notice Allocation storage
	AuctionTypes.Allocation[] public allocations;
	
	/// @notice Revealed mappings
	mapping(bytes32 => address) public revealedMappings;
	
	/// @notice Final allocation
	AuctionTypes.Allocation public finalAllocation;
	
	/// @notice Winning allocator
	address public winningAllocator;
	
	/// @notice Round bids storage
	AuctionTypes.Bid[] public roundBids;
	
	/// @notice Dropped bidders
	mapping(address => bool) public droppedBidders;

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
	) BaseHook(_poolManager) {
		owner = Ownable2Step(_owner);
		commonNumeraire = _commonNumeraire; // token 1 in the pools
		config = _config;
		currentPhase = AuctionTypes.AuctionPhase.Setup;
	}

	/**
	 * @notice Modifier to ensure only owner can call
	 */
	modifier onlyOwner() {
		if (msg.sender != owner) revert OnlyOwner();
		_;
	}

	/**
	 * @notice Modifier to ensure auction is not paused
	 */
	modifier whenNotPaused() {
		if (paused) revert AuctionPaused();
		_;
	}

	/**
	 * @notice Modifier to ensure auction is not cancelled
	 */
	modifier whenNotCancelled() {
		if (cancelled) revert AuctionCancelled();
		_;
	}

	/**
	 * @notice Modifier to ensure auction is in expected phase
	 */
	modifier onlyPhase(AuctionTypes.AuctionPhase phase) {
		if (currentPhase != phase) revert InvalidPhase(phase, currentPhase);
		_;
	}

	

	/**
	 * @notice Start the clock phase
	 */
	function startClockPhase() external onlyOwner onlyPhase(AuctionTypes.AuctionPhase.Setup) {
		_confirmSetupComplete();
		_changePhase(AuctionTypes.AuctionPhase.Clock);
		_openClockRound();
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
		if (!clockOpen) revert ClockNotOpen();
		if (!CommitReveal.isValidCommitHash(commitHash)) revert InvalidCommitHash();
		
		// Add stake to bidder
		bidderStake[msg.sender] += stakeAmount;
		bidderBidPoints[msg.sender] = computeBidPoints(stakeAmount);

		// Transfer stake from bidder to auction contract
		if (stakeAmount > 0) {
			IERC20(commonNumeraire).transferFrom(msg.sender, address(this), stakeAmount); 
		}
		// would be interesting to eventually have "deposits" for bidders who use the system often
		// so that they don't have to transfer the common numeraire every time they bid.
		// the deposit could be rehypothecated by the protocol when not being used. During auctions,
		// this auction contract would make a "claim" against the deposits that are needed for staking.
		// the complication is that we do not assert a common numeraire across all auction contracts.
		
		// Calculate total bid value
		uint256 totalValue = _calculateBidValue(demands);
		if (totalValue > bidderBidPoints[msg.sender]) revert InsufficientBidPoints();
		
		// Record the bid
		roundBids.push(AuctionTypes.Bid({
			bidder: msg.sender,
			stakeAmount: stakeAmount,
			quantities: demands, // Simplified for now
			round: currentRound
		}));
		
		emit BidSubmitted(msg.sender, commitHash, stakeAmount, currentRound);
	}

	function computeBidPoints(uint256 stakeAmount) internal view returns (uint256 bidPoints) {
		bidPoints = stakeAmount; // 1:1 ratio for now, could theoretically be anything
	}

	/**
	 * @notice End current clock round
	 */
	function endClockRound() external onlyOwner onlyPhase(AuctionTypes.AuctionPhase.Clock) {
		clockOpen = false;
		
		// Process round results
		_processClockRound();
		
		emit ClockRoundClosed(currentRound, roundBids.length);
		
		// Check if clock phase should end
		if (_shouldEndClockPhase()) {
			_changePhase(AuctionTypes.AuctionPhase.Proxy);
		} else {
			_openClockRound();
		}
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
		if (commitProxy[commitHash] != msg.sender) revert Unauthorized();
		if (bundles[commitHash].length > 0) revert DuplicateBundle();
		
		bundles[commitHash].push(bundleData);
		
		emit BundleSubmitted(commitHash, bundleData.bundleId);
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
		allocationData.allocator = msg.sender;
		allocationData.allocationId = allocations.length;
		allocationData.timestamp = block.timestamp;
		
		allocations.push(allocationData);
		
		emit AllocationSubmitted(msg.sender, allocationData.allocationId);
	}

	/**
	 * @notice End allocation phase and select winner
	 */
	function endAllocationPhase() external onlyOwner onlyPhase(AuctionTypes.AuctionPhase.Allocation) {
		if (allocations.length == 0) revert InvalidPhase(AuctionTypes.AuctionPhase.Allocation, currentPhase);
		
		// Select winning allocation
		uint256 winningIndex = AllocationScoring.selectWinningAllocation(
			allocations,
			_getAllBundles(),
			_getTotalBidders()
		);
		
		finalAllocation = allocations[winningIndex];
		winningAllocator = finalAllocation.allocator;
		
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
		bytes32 commitHash = CommitReveal.generateCommitHash(bidder, proxy, saltA, saltB);
		
		if (!CommitReveal.validateReveal(bidder, proxy, saltA, saltB, commitHash)) {
			revert InvalidReveal();
		}
		
		revealedMappings[commitHash] = bidder;
		
		// Process financial settlement
		_processFinancialSettlement(bidder, finalPurchaseAmount);
		
		emit RevealProcessed(bidder, proxy, commitHash);
	}

	/**
	 * @notice End reveal phase and move to settlement
	 */
	function endRevealPhase() external onlyOwner onlyPhase(AuctionTypes.AuctionPhase.Reveal) {
		_changePhase(AuctionTypes.AuctionPhase.Settlement);
		_finalizeSettlement();
	}

	/**
	 * @notice Pause the auction
	 */
	function pause() external onlyOwner {
		paused = true;
		_updatePoolHookStates();
		emit AuctionPaused(msg.sender);
	}

	/**
	 * @notice Unpause the auction
	 */
	function unpause() external onlyOwner {
		paused = false;
		_updatePoolHookStates();
		emit AuctionUnpaused(msg.sender);
	}

	/**
	 * @notice Cancel the auction and refund all stakes
	 */
	function cancelAuction() external onlyOwner {
		cancelled = true;
		_updatePoolHookStates();
		_refundAllStakes();
		emit AuctionCancelled(msg.sender);
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
	 * @notice Dropout from auction with penalty
	 */
	function dropout() external whenNotPaused whenNotCancelled {
		uint256 stake = bidderStake[msg.sender];
		if (stake == 0) revert InvalidStakeAmount();
		
		uint256 penalty = (stake * config.dropoutSlashRatio) / 10000;
		uint256 refund = stake - penalty;
		
		bidderStake[msg.sender] = 0;
		bidderBidPoints[msg.sender] = 0;
		droppedBidders[msg.sender] = true;
		
		// Transfer refund to bidder (simplified)
		// In practice, this would use SafeERC20
		
		emit PenaltyApplied(msg.sender, penalty);
		emit StakeRefunded(msg.sender, refund);
	}

	// Internal functions

	/**
	 * @notice Change auction phase
	 * @param newPhase The new phase
	 */
	function _changePhase(AuctionTypes.AuctionPhase newPhase) internal {
		AuctionTypes.AuctionPhase oldPhase = currentPhase;
		currentPhase = newPhase;
		emit AuctionPhaseChanged(oldPhase, newPhase);
	}

	/**
	 * @notice Open a new clock round
	 */
	function _openClockRound() internal {
		currentRound++;
		clockOpen = true;
		delete roundBids;
		emit ClockRoundOpened(currentRound);
	}

	/**
	 * @notice Process clock round results
	 */
	function _processClockRound() internal {
		// TODO: Implement clock round processing
		// This should calculate excess demand for each item
		// and update pool prices accordingly
		
		// Placeholder: basic excess demand calculation
		for (uint256 i = 0; i < poolCount; i++) {
			uint256 totalDemand = 0;
			for (uint256 j = 0; j < roundBids.length; j++) {
				if (roundBids[j].itemIds.length > i) {
					totalDemand += roundBids[j].quantities[i];
				}
			}
			
			pools[i].excessDemand = totalDemand > pools[i].depositAmount ? 
				totalDemand - pools[i].depositAmount : 0;
		}
	}

	/**
	 * @notice Check if clock phase should end
	 * @return shouldEnd True if clock phase should end
	 */
	function _shouldEndClockPhase() internal view returns (bool shouldEnd) {
		for (uint256 i = 0; i < poolCount; i++) {
			if (pools[i].excessDemand > 0) {
				return false;
			}
		}
		return true;
	}

	/**
	 * @notice Calculate bid value
	 * @param demands Array of demands
	 * @return totalValue Total value of the bid
	 */
	function _calculateBidValue(uint256[] calldata demands) internal view returns (uint256 totalValue) {
		// TODO: Implement bid value calculation
		// This should calculate the total value based on current prices
		// and the bidder's demands
		
		// Placeholder: simple multiplication
		for (uint256 i = 0; i < demands.length && i < poolCount; i++) {
			totalValue += demands[i] * pools[i].currentPrice;
		}
	}

	/**
	 * @notice Get all bundles
	 * @return allBundles Array of all bundles
	 */
	function _getAllBundles() internal view returns (AuctionTypes.Bundle[] memory allBundles) {
		// TODO: Implement bundle collection
		// This should flatten all bundles from all commit hashes
		// into a single array for allocation scoring
		
		// Placeholder: return empty array
		return allBundles;
	}

	/**
	 * @notice Get total bidders
	 * @return totalBidders Total number of bidders
	 */
	function _getTotalBidders() internal view returns (uint256 totalBidders) {
		// TODO: Implement bidder counting
		// This should count unique bidders, not just round bids
		
		// Placeholder: return round bids length
		return roundBids.length;
	}

	/**
	 * @notice Process financial settlement
	 * @param bidder The bidder address
	 * @param finalPurchaseAmount Final purchase amount
	 */
	function _processFinancialSettlement(address bidder, uint256 finalPurchaseAmount) internal {
		// TODO: Implement financial settlement
		// This should handle stake adjustments, refunds, and penalties
		// based on minimum spending requirements
		
		// Placeholder: basic stake adjustment
		uint256 stake = bidderStake[bidder];
		if (finalPurchaseAmount > stake) {
			// Bidder needs to pay more
			bidderStake[bidder] = finalPurchaseAmount;
		} else if (finalPurchaseAmount < stake) {
			// Refund excess stake
			uint256 refund = stake - finalPurchaseAmount;
			bidderStake[bidder] = finalPurchaseAmount;
			emit StakeRefunded(bidder, refund);
		}
	}

	/**
	 * @notice Finalize settlement
	 */
	function _finalizeSettlement() internal {
		// TODO: Implement final settlement
		// This should:
		// - Transfer assets to winning bidders
		// - Mint ERC1155 tokens
		// - Update pool states
		// - Handle any remaining refunds
	}

	/**
	 * @notice Update pool hook states
	 */
	function _updatePoolHookStates() internal {
		for (uint256 i = 0; i < poolCount; i++) {
			PoolHook(poolHooks[i]).setAuctionState(
				currentPhase == AuctionTypes.AuctionPhase.Clock,
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
