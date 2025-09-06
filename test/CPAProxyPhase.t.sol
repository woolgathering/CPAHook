// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { Test, console } from "forge-std/Test.sol";
import { Deployers } from "./utils/Deployers.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { Currency, CurrencyLibrary } from "@uniswap/v4-core/src/types/Currency.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { Hooks } from "@uniswap/v4-core/src/libraries/Hooks.sol";
import { HookMiner } from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC6909Claims } from "@uniswap/v4-core/src/interfaces/external/IERC6909Claims.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { Constants } from "../lib/uniswap-hooks/lib/v4-core/test/utils/Constants.sol";

import { CPAManagerHook } from "../src/CPAManager.sol";
import { PoolHook } from "../src/PoolHook.sol";
import { AuctionTypes } from "../src/AuctionTypes.sol";
import { AuctionId } from "../src/AuctionId.sol";
import { MockERC20 } from "solmate/src/test/utils/mocks/MockERC20.sol";
import { IErrorsAndEvents } from "../src/utils/IErrorsAndEvents.sol";
import { CommitReveal } from "../src/CommitReveal.sol";

contract CPAProxyPhaseTest is Deployers {
	using PoolIdLibrary for PoolKey;
	using CurrencyLibrary for Currency;

	CPAManagerHook public cpaHook;
	PoolHook public poolHook;
	MockERC20 public numeraireToken;
	MockERC20 public asset1Token;
	MockERC20 public asset2Token;
	uint256 public asset1InitialPrice;
	uint256 public asset2InitialPrice;

	address public protocolOwner;
	address public auctioneer;
	address public bidder1;
	address public bidder2;
	address public proxy1;
	address public proxy2;

	PoolKey public auctioneerPoolKey;
	PoolKey public asset1PoolKey;
	PoolKey public asset2PoolKey;

	function setUp() public {
		deployArtifacts();

		// Deploy test tokens
		numeraireToken = new MockERC20("Numeraire Token", "NUM", 18);
		asset1Token = new MockERC20("Asset 1 Token", "AST1", 18);
		asset2Token = new MockERC20("Asset 2 Token", "AST2", 18);

		asset1InitialPrice = 1 * 10**18;
		asset2InitialPrice = 2 * 10**18;

		// Set up test accounts
		protocolOwner = makeAddr("protocolOwner");
		auctioneer = makeAddr("auctioneer");

		// Deploy hooks
		vm.startPrank(protocolOwner);
		poolHook = deployPoolHook(poolManager);
		cpaHook = deployCPAHook(poolManager, protocolOwner, address(poolHook));
		poolHook.setAuctionManager(address(cpaHook));
		vm.stopPrank();

		// Set up pool keys
		auctioneerPoolKey = PoolKey({
			currency0: Currency.wrap(address(0)), // ETH
			currency1: Currency.wrap(address(numeraireToken)),
			fee: 3000,
			tickSpacing: 60,
			hooks: IHooks(address(cpaHook))
		});

		asset1PoolKey = PoolKey({
			currency0: Currency.wrap(address(asset1Token)),
			currency1: Currency.wrap(address(numeraireToken)),
			fee: 3000,
			tickSpacing: 60,
			hooks: IHooks(address(poolHook))
		});

		asset2PoolKey = PoolKey({
			currency0: Currency.wrap(address(asset2Token)),
			currency1: Currency.wrap(address(numeraireToken)),
			fee: 3000,
			tickSpacing: 60,
			hooks: IHooks(address(poolHook))
		});

		// Sort currencies by address
		(asset1PoolKey.currency0, asset1PoolKey.currency1) = asset1PoolKey.currency0 < asset1PoolKey.currency1
			? (asset1PoolKey.currency0, asset1PoolKey.currency1)
			: (asset1PoolKey.currency1, asset1PoolKey.currency0);

		(asset2PoolKey.currency0, asset2PoolKey.currency1) = asset2PoolKey.currency0 < asset2PoolKey.currency1
			? (asset2PoolKey.currency0, asset2PoolKey.currency1)
			: (asset2PoolKey.currency1, asset2PoolKey.currency0);

		// Create pools
		poolManager.initialize(auctioneerPoolKey, Constants.SQRT_PRICE_1_1);
		poolManager.initialize(asset1PoolKey, Constants.SQRT_PRICE_1_1);
		poolManager.initialize(asset2PoolKey, Constants.SQRT_PRICE_1_1);
	}

	/// @notice Deploy PoolHook with proper address mining and flag setting
	function deployPoolHook(IPoolManager _poolManager) internal returns (PoolHook) {
		uint160 flags = uint160(
			Hooks.BEFORE_INITIALIZE_FLAG |
			Hooks.BEFORE_SWAP_FLAG |
			Hooks.BEFORE_ADD_LIQUIDITY_FLAG |
			Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG |
			Hooks.BEFORE_DONATE_FLAG
		);
		
		bytes memory constructorArgs = abi.encode(_poolManager);
		
		(address hookAddress, bytes32 salt) = HookMiner.find(
			protocolOwner,
			flags,
			type(PoolHook).creationCode,
			constructorArgs
		);
		
		PoolHook deployedHook = new PoolHook{salt: salt}(_poolManager);
		require(address(deployedHook) == hookAddress, "Hook address mismatch");
		return deployedHook;
	}

	/// @notice Deploy CPAManagerHook with proper address mining and flag setting
	function deployCPAHook(IPoolManager _poolManager, address _owner, address _poolHook) internal returns (CPAManagerHook) {
		uint160 flags = uint160(
			Hooks.BEFORE_INITIALIZE_FLAG |
			Hooks.BEFORE_SWAP_FLAG
		);
		
		bytes memory constructorArgs = abi.encode(_poolManager, _owner, _poolHook);
		
		(address hookAddress, bytes32 salt) = HookMiner.find(
			protocolOwner,
			flags,
			type(CPAManagerHook).creationCode,
			constructorArgs
		);
		
		CPAManagerHook deployedHook = new CPAManagerHook{salt: salt}(_poolManager, _owner, _poolHook);
		require(address(deployedHook) == hookAddress, "Hook address mismatch");
		return deployedHook;
	}

	// ============================================================================
	// HELPER FUNCTIONS
	// ============================================================================

	/**
	 * @notice Create a basic auction with deposits and return the auction ID
	 * @return auctionId The created auction ID
	 */
	function _createBasicAuction() internal returns (AuctionId auctionId) {
		// Set up auction configuration
		AuctionTypes.AuctionConfig memory config = AuctionTypes.AuctionConfig({
			commonNumeraire: address(numeraireToken),
			minSpendRatio: 1000,
			dropoutSlashRatio: 1000, // 10%
			spendingViolationSlashRatio: 2000, // 20%
			maxRounds: 100,
			clockPriceIncrement: 1000,
			allocatorStakeRequirement: 10000 * 10**18,
			proxyStakeRequirement: 1000 * 10**18,
			maxStakeCap: 1000000 * 10**18,
			revealWindow: 3600,
			allocationWindow: 1800
		});

		// Create auction with asset pools only
		PoolKey[] memory assetPoolKeys = new PoolKey[](2);
		assetPoolKeys[0] = asset1PoolKey;
		assetPoolKeys[1] = asset2PoolKey;

		vm.prank(auctioneer);
		auctionId = cpaHook.createAuction(assetPoolKeys, config, auctioneer);

		// Mint tokens to auctioneer for deposits
		uint256 tokenAmount = 1000000 * 10**18;
		asset1Token.mint(auctioneer, tokenAmount);
		asset2Token.mint(auctioneer, tokenAmount);

		// Auctioneer deposits tokens to asset pools (required for setup completion)
		uint256 depositAmount1 = 100 * 10**18;  // 100 tokens
		uint256 depositAmount2 = 150 * 10**18;  // 150 tokens

		// Approve CPAManagerHook to spend auctioneer's tokens
		vm.prank(auctioneer);
		asset1Token.approve(address(cpaHook), depositAmount1);
		vm.prank(auctioneer);
		asset2Token.approve(address(cpaHook), depositAmount2);

		// Move deposits to pools with initial prices and price increments
		vm.prank(auctioneer);
		cpaHook.moveDeposit(auctionId, asset1PoolKey, depositAmount1, asset1InitialPrice, 1 * 10**18);
		vm.prank(auctioneer);
		cpaHook.moveDeposit(auctionId, asset2PoolKey, depositAmount2, asset2InitialPrice, 1 * 10**18);
	}

	/**
	 * @notice Set up auction to clock phase (ready for bidding, no bids submitted yet)
	 * @return auctionId The auction ID ready for clock phase bidding
	 */
	function _setupAuctionToClockPhase() internal returns (AuctionId auctionId) {
		// Create basic auction
		auctionId = _createBasicAuction();

		// Start clock phase
		vm.prank(auctioneer);
		cpaHook.startClockRound(auctionId);
	}

	/**
	 * @notice Create bidders and proxies with commit hashes
	 * @return _bidder1 First bidder address
	 * @return _bidder2 Second bidder address  
	 * @return _proxy1 First proxy address
	 * @return _proxy2 Second proxy address
	 * @return commitHash1 First commit hash
	 * @return commitHash2 Second commit hash
	 * @return partialCommit1 First partial commit
	 * @return partialCommit2 Second partial commit
	 */
	function _createBiddersAndProxies() internal returns (
		address _bidder1,
		address _bidder2,
		address _proxy1,
		address _proxy2,
		bytes32 commitHash1,
		bytes32 commitHash2,
		bytes32 partialCommit1,
		bytes32 partialCommit2
	) {
		// Create bidders and proxies
		_bidder1 = makeAddr("bidder1");
		_bidder2 = makeAddr("bidder2");
		_proxy1 = makeAddr("proxy1");
		_proxy2 = makeAddr("proxy2");

		// Mint numeraire tokens to bidders for staking
		vm.prank(protocolOwner);
		numeraireToken.mint(_bidder1, 250000 * 10**18);
		vm.prank(protocolOwner);
		numeraireToken.mint(_bidder2, 300000 * 10**18);

		// Generate commit hashes for both bidder-proxy pairs
		bytes32 saltA1 = keccak256("saltA1");
		bytes32 saltB1 = keccak256("saltB1");
		commitHash1 = CommitReveal.generateCommitHash(_bidder1, _proxy1, saltA1, saltB1);
		partialCommit1 = CommitReveal.getBidderHash(_bidder1, saltA1);

		bytes32 saltA2 = keccak256("saltA2");
		bytes32 saltB2 = keccak256("saltB2");
		commitHash2 = CommitReveal.generateCommitHash(_bidder2, _proxy2, saltA2, saltB2);
		partialCommit2 = CommitReveal.getBidderHash(_bidder2, saltA2);
	}

	/**
	 * @notice Submit proxy commits for bidder-proxy pairs
	 * @param auctionId The auction ID
	 * @param _proxy1 First proxy address
	 * @param _proxy2 Second proxy address
	 * @param commitHash1 First commit hash
	 * @param commitHash2 Second commit hash
	 */
	function _submitProxyCommits(
		AuctionId auctionId,
		address _proxy1,
		address _proxy2,
		bytes32 commitHash1,
		bytes32 commitHash2
	) internal {
		// Proxies commit to bidders
		vm.prank(_proxy1);
		cpaHook.commitToBidder(auctionId, commitHash1);
		vm.prank(_proxy2);
		cpaHook.commitToBidder(auctionId, commitHash2);
	}

	/**
	 * @notice Submit a single bid (stake amount calculated automatically)
	 * @param auctionId The auction ID
	 * @param bidder The bidder address
	 * @param demands The bidder's demands
	 * @param partialCommit The bidder's partial commit
	 */
	function _submitBid(
		AuctionId auctionId,
		address bidder,
		uint256[] memory demands,
		bytes32 partialCommit
	) internal {
		// Get current bid points for this bidder
		uint256 currentBidPoints = cpaHook.bidderBidPoints(auctionId, bidder);
		
		// Calculate total bid value
		uint256 totalBidValue = ((demands[0] * asset1InitialPrice) / 10**18) + ((demands[1] * asset2InitialPrice) / 10**18);
		
		// Calculate additional stake needed
		uint256 additionalStake = totalBidValue > currentBidPoints ? totalBidValue - currentBidPoints : 0;

		// Bidder approves additional tokens if needed
		if (additionalStake > 0) {
			vm.prank(bidder);
			numeraireToken.approve(address(cpaHook), additionalStake);
		}

		// Submit bid
		vm.prank(bidder);
		cpaHook.submitBid(auctionId, demands, partialCommit, additionalStake);
	}

	/**
	 * @notice Set up auction with bids (clock phase + bids submitted)
	 * @return auctionId The auction ID
	 * @return _bidder1 First bidder address
	 * @return _bidder2 Second bidder address  
	 * @return _proxy1 First proxy address
	 * @return _proxy2 Second proxy address
	 */
	function _setupAuctionWithBids() internal returns (
		AuctionId auctionId,
		address _bidder1,
		address _bidder2,
		address _proxy1,
		address _proxy2
	) {
		// Set up auction to clock phase
		auctionId = _setupAuctionToClockPhase();

		// Create bidders and proxies
		bytes32 commitHash1;
		bytes32 commitHash2;
		bytes32 partialCommit1;
		bytes32 partialCommit2;
		(_bidder1, _bidder2, _proxy1, _proxy2, commitHash1, commitHash2, partialCommit1, partialCommit2) = _createBiddersAndProxies();

		// Submit proxy commits
		_submitProxyCommits(auctionId, _proxy1, _proxy2, commitHash1, commitHash2);

		// Define default demands
		uint256[] memory demands1 = new uint256[](2);
		demands1[0] = 100 * 10**asset1Token.decimals();
		demands1[1] = 50 * 10**asset2Token.decimals();

		uint256[] memory demands2 = new uint256[](2);
		demands2[0] = 75 * 10**asset1Token.decimals();
		demands2[1] = 25 * 10**asset2Token.decimals();

		// Submit individual bids
		_submitBid(auctionId, _bidder1, demands1, partialCommit1);
		_submitBid(auctionId, _bidder2, demands2, partialCommit2);
	}

	/**
	 * @notice Set up auction to proxy phase (after clock phase completion)
	 * @return auctionId The auction ID ready for proxy phase
	 * @return _bidder1 First bidder address
	 * @return _bidder2 Second bidder address
	 * @return _proxy1 First proxy address  
	 * @return _proxy2 Second proxy address
	 */
	function _setupAuctionToProxyPhase() internal returns (
		AuctionId auctionId,
		address _bidder1,
		address _bidder2,
		address _proxy1,
		address _proxy2
	) {
		// Set up auction with first round bids
		(auctionId, _bidder1, _bidder2, _proxy1, _proxy2) = _setupAuctionWithBids();

		// End first clock round
		vm.prank(auctioneer);
		cpaHook.endClockRound(auctionId);

		// Start second clock round
		vm.prank(auctioneer);
		cpaHook.startClockRound(auctionId);

		// Submit smaller bids in second round
		uint256[] memory demands1_round2 = new uint256[](2);
		demands1_round2[0] = 30 * 10**asset1Token.decimals();
		demands1_round2[1] = 20 * 10**asset2Token.decimals();

		uint256[] memory demands2_round2 = new uint256[](2);
		demands2_round2[0] = 25 * 10**asset1Token.decimals();
		demands2_round2[1] = 15 * 10**asset2Token.decimals();

		// Generate partial commits for second round
		bytes32 saltA1 = keccak256("saltA1");
		bytes32 saltA2 = keccak256("saltA2");
		bytes32 partialCommit1 = CommitReveal.getBidderHash(_bidder1, saltA1);
		bytes32 partialCommit2 = CommitReveal.getBidderHash(_bidder2, saltA2);

		// Submit second round bids (stake calculation handled automatically)
		_submitBid(auctionId, _bidder1, demands1_round2, partialCommit1);
		_submitBid(auctionId, _bidder2, demands2_round2, partialCommit2);

		// End clock phase (transition to proxy phase)
		vm.prank(auctioneer);
		cpaHook.endClockPhase(auctionId);
	}

	/**
	 * @notice Set up auction with specific bidder and proxy for focused testing
	 * @param bidderDemands The demands for the bidder
	 * @return auctionId The auction ID
	 * @return bidder The bidder address
	 * @return proxy The proxy address
	 * @return commitHash The commit hash for the bidder-proxy pair
	 */
	function _setupAuctionWithSingleBidder(
		uint256[] memory bidderDemands
	) internal returns (
		AuctionId auctionId,
		address bidder,
		address proxy,
		bytes32 commitHash
	) {
		// Set up auction to clock phase
		auctionId = _setupAuctionToClockPhase();

		// Create bidder and proxy
		bidder = makeAddr("singleBidder");
		proxy = makeAddr("singleProxy");

		// Calculate expected stake amount and mint tokens to bidder
		uint256 expectedStakeAmount = ((bidderDemands[0] * asset1InitialPrice) / 10**18) + ((bidderDemands[1] * asset2InitialPrice) / 10**18);
		vm.prank(protocolOwner);
		numeraireToken.mint(bidder, expectedStakeAmount * 2); // Extra for safety

		// Generate commit hash
		bytes32 saltA = keccak256("singleSaltA");
		bytes32 saltB = keccak256("singleSaltB");
		commitHash = CommitReveal.generateCommitHash(bidder, proxy, saltA, saltB);
		bytes32 partialCommit = CommitReveal.getBidderHash(bidder, saltA);

		// Proxy commits to bidder
		vm.prank(proxy);
		cpaHook.commitToBidder(auctionId, commitHash);

		// Submit bid
		_submitBid(auctionId, bidder, bidderDemands, partialCommit);

		// End clock phase
		vm.prank(auctioneer);
		cpaHook.endClockRound(auctionId);
		vm.prank(auctioneer);
		cpaHook.endClockPhase(auctionId);
	}
}
