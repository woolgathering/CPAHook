// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IPositionManager } from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { IAllowanceTransfer } from "permit2/src/interfaces/IAllowanceTransfer.sol";

import { IErrorsAndEvents } from "../utils/IErrorsAndEvents.sol";
import { AuctionTypes } from "../types/AuctionTypes.sol";
import { AuctionId } from "../types/AuctionId.sol";
import { BundleId } from "../types/BundleId.sol";

abstract contract CPAStorage {

	/// @notice Commit hash to proxy mapping
	// AuctionId -> CommitHash -> Proxy Address
	mapping(AuctionId => mapping(bytes32 => address)) public commitProxy;

	/// @notice Pool key to auction owner mapping
	mapping(PoolId => AuctionId) public poolToAuctionId;

	/// @notice Auction info mapping
	mapping(AuctionId => AuctionTypes.AuctionInfo) public auctionInfo;

	/// @notice Pool info mapping
	mapping(PoolId => AuctionTypes.PoolInfo) public poolInfo;

	/// @notice Pause start time mapping (timestamp when current pause started, 0 if not paused)
	mapping(AuctionId => uint256) public pauseStartTime;

	/// @notice Current prices for currencies (in numeraire units)
	/// @dev Currency address => price in numeraire (e.g., 1e18 = 1 numeraire token per currency unit)
	mapping(address => uint256) public currentPrices;

	/// @notice CPA Auction Hook address
	// this is the hook that all auction item pools share
	address public cpaAuctionHookAddr;

	/// @notice MathFacet address for external math library calls
	address public mathFacet;

	/// @notice Pool manager
	IPoolManager public immutable manager;
	
	/// @notice Position manager for NFT position creation
	IPositionManager public immutable positionManager;

	/// @notice Permit2 address for allowance transfers
	/// @dev This can be hardcoded since it is the same deployment address across all chains Uniswap V4 is deployed on
	IAllowanceTransfer public immutable permit2 = IAllowanceTransfer(0x000000000022D473030F116dDEE9F6B43aC78BA3);
	
	/// @notice Protocol wallet address for penalty collection
	address public immutable protocolWallet;

	uint256 public constant FORFEITURE_REWARD_RATE = 500; // 5% reward (basis points)

	//// getters
	function getAuctionInfo(AuctionId auctionId) external view returns (AuctionTypes.AuctionInfo memory) {
    	return auctionInfo[auctionId];
	}

	function getPoolInfo(PoolId poolId) external view returns (PoolKey memory, int24, int24, uint256, int256, int24, AuctionId, uint256) {
		return (
			poolInfo[poolId].key,
			poolInfo[poolId].startingTick,
			poolInfo[poolId].priceIncrement,
			poolInfo[poolId].depositAmount,
			poolInfo[poolId].excessDemand,
			poolInfo[poolId].lastOversoldTick,
			poolInfo[poolId].auctionId,
			poolInfo[poolId].positionId
		);
	}


	///////
	// SETUP PHASE
	///////


	function getNumItems(AuctionId auctionId) external view returns (uint256) {
		return auctionInfo[auctionId].poolKeys.length;
	}



    ////////
    // CLOCK PHASE
    ////////
    /// @notice Dropped bidders (not stored in AuctionInfo)
	mapping(AuctionId => mapping(address => bool)) public droppedBidders;

	/// @notice Pending total demands stored between processClockRoundStep and finalizeClockRound
	mapping(AuctionId => uint256[]) internal pendingRoundDemands;

	/// @notice Flag indicating a clock round has been processed and is awaiting finalization
	mapping(AuctionId => bool) internal roundPendingFinalize;

    /// @notice Bidder stake mapping (not stored in AuctionInfo)
	mapping(AuctionId => mapping(address => uint256)) public bidderStake;

    /// @notice Bidder bid points mapping (not stored in AuctionInfo)
	mapping(AuctionId => mapping(address => uint256)) public bidderBidPoints;

	/// @notice Bidder demand vector mapping
	mapping(AuctionId => mapping(address => uint256[])) public bids;

	/// @notice Active bidders mapping
	mapping(AuctionId => address[]) public activeBidders;

    ////////
    // PROXY PHASE
    ////////
    /// @notice Bundle storage (id -> bundleId -> bundle)
	mapping(AuctionId => mapping(BundleId => AuctionTypes.Bundle)) public bundles;

	/// @notice Proxy phase start time
	mapping(AuctionId => uint256) public proxyPhaseStartTime;

	/// @notice Allocation phase start time
	mapping(AuctionId => uint256) public allocationPhaseStartTime;

	/// @notice Settlement phase start time
	mapping(AuctionId => uint256) public settlementPhaseStartTime;

	/// @notice Track if at least one bundle was submitted
	mapping(AuctionId => bool) public hasBundles;

	/// @notice Track if at least one allocation was submitted
	mapping(AuctionId => bool) public hasAllocations;

	/// @notice Flag set after selectAuctionWinner runs, allowing transferToSettlement to proceed
	mapping(AuctionId => bool) internal winnerSelected;

	/// @notice Flag set after initAuction registers pools, cleared after finalizeAuction completes
	mapping(AuctionId => bool) internal poolsRegistered;

	/// @notice Set after convertAuctionAssets completes ERC6909→ERC20 conversion
	mapping(AuctionId => bool) internal assetsConverted;

	/// @notice Position manager nextTokenId captured before minting (for positionId pre-storage)
	mapping(AuctionId => uint256) internal settleStartTokenId;
	
	/// @notice Accumulated penalties per auction (for protocol collection)
	mapping(AuctionId => uint256) public protocolPenalties;

	function getBundle(AuctionId auctionId, BundleId bundleId) external view returns (AuctionId, bytes32, BundleId, uint256[] memory, uint256, uint256) {
		return (
			auctionId,
			bundles[auctionId][bundleId].commitHash,
			bundleId,
			bundles[auctionId][bundleId].quantities,
			bundles[auctionId][bundleId].value,
			bundles[auctionId][bundleId].timestamp
		);
	}


    ////////
    // ALLOCATION PHASE
    ////////
    
	/// @notice Top allocation storage
	mapping(AuctionId => AuctionTypes.TopAllocation) public topAllocation;

	/// @notice Winning bundle ids storage
	/// commitHash -> bundleId
	mapping(bytes32 => BundleId) public winningBundleIds;

	/**
	 * @notice Get top allocation
	 * @param auctionId The auction ID
	 * @return Top allocation
	 */
	function getTopAllocation(AuctionId auctionId) external view returns (AuctionTypes.TopAllocation memory) {
		return topAllocation[auctionId];
	}

    ////////
    // SETTLEMENT PHASE
    ////////
    /// @notice Revealed mappings. AuctionId -> CommitHash -> Bidder Address
	mapping(AuctionId => mapping(bytes32 => address)) public revealedMappings;


	/**
	 * @notice Constructor
	 * @param _cpaAuctionHookAddr The CPA auction hook address
	 * @param _positionManager The PositionManager address for NFT position creation
	 */
	constructor(address _mathFacet, address _cpaAuctionHookAddr, IPositionManager _positionManager) {
		mathFacet = _mathFacet;
		cpaAuctionHookAddr = _cpaAuctionHookAddr;
		positionManager = _positionManager;
	}
}