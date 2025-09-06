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
import { IERC6909Claims } from "@uniswap/v4-core/src/interfaces/external/IERC6909Claims.sol";


import { CPAManagerHook } from "../src/ClockProxyAuctionHook.sol";
import { PoolHook } from "../src/PoolHook.sol";
import { AuctionTypes } from "../src/AuctionTypes.sol";
import { AuctionId } from "../src/AuctionId.sol";
import { MockERC20 } from "solmate/src/test/utils/mocks/MockERC20.sol";
import { IErrorsAndEvents } from "../src/utils/IErrorsAndEvents.sol";
import { CommitReveal } from "../src/CommitReveal.sol";

contract CPAClockPhaseTest is Deployers {
	using PoolIdLibrary for PoolKey;
	using CurrencyLibrary for Currency;

	CPAManagerHook public cpaHook;
	PoolHook public poolHook;
	MockERC20 public numeraireToken;
	MockERC20 public asset1Token;
    uint256 public asset1InitialPrice;
	MockERC20 public asset2Token;
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

	AuctionId public auctionId;

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
		// bidder1 = makeAddr("bidder1");
		// bidder2 = makeAddr("bidder2");

		// Deploy hooks
		// Deploy both hooks from the same address (owner)
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

		// Note: Bidders will be minted tokens as needed in individual tests

		// Auctioneer deposits tokens to asset pools (required for setup completion)
		// Set deposit amounts smaller than total demand to create excess demand
		uint256 depositAmount1 = 100 * 10**18;  // 100 tokens (less than 175 total demand)
		uint256 depositAmount2 = 150 * 10**18;  // 150 tokens (more than 75 total demand)

		// Approve CPAManagerHook to spend auctioneer's tokens
		vm.prank(auctioneer);
		asset1Token.approve(address(cpaHook), depositAmount1);
		vm.prank(auctioneer);
		asset2Token.approve(address(cpaHook), depositAmount2);

		// Move deposits to pools with initial prices and price increments
		vm.prank(auctioneer);
		cpaHook.moveDeposit(auctionId, asset1PoolKey, depositAmount1, asset1InitialPrice, 1 * 10**18); // 1000 numeraire per asset1, 1000 increment
		vm.prank(auctioneer);
		cpaHook.moveDeposit(auctionId, asset2PoolKey, depositAmount2, asset2InitialPrice, 1 * 10**18); // 2000 numeraire per asset2, 1000 increment
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

	function test_StartClockRound_Success() public {
		// Verify initial state
		(
			address auctionOwner,
			address commonNumeraire,
			AuctionTypes.AuctionConfig memory config,
			AuctionTypes.AuctionPhase currentPhase,
			AuctionTypes.AuctionStatus currentStatus,
			bool clockOpen,
			AuctionTypes.Bid[] memory roundBids,
			uint256 currentRound,
			PoolKey[] memory poolKeys
		) = cpaHook.getAuctionInfo(auctionId);

		assertEq(auctionOwner, auctioneer, "Auction owner should be auctioneer");
		assertEq(commonNumeraire, address(numeraireToken), "Common numeraire should be numeraire token");
		assertEq(uint256(currentPhase), uint256(AuctionTypes.AuctionPhase.Setup), "Initial phase should be Setup");
		assertEq(uint256(currentStatus), uint256(AuctionTypes.AuctionStatus.Active), "Status should be Active");
		assertFalse(clockOpen, "Clock should be closed initially");
		assertEq(roundBids.length, 0, "Should have no round bids initially");
		assertEq(currentRound, 0, "Initial round should be 0");
		assertEq(poolKeys.length, 2, "Should have 2 asset pools");

		// Open clock round
		vm.prank(auctioneer);
		cpaHook.startClockRound(auctionId);

		// Verify state after opening clock round
		(
			,
			,
			,
			currentPhase,
			currentStatus,
			clockOpen,
			roundBids,
			currentRound,
			poolKeys
		) = cpaHook.getAuctionInfo(auctionId);

		assertEq(uint256(currentPhase), uint256(AuctionTypes.AuctionPhase.Clock), "Phase should be Clock");
		assertEq(uint256(currentStatus), uint256(AuctionTypes.AuctionStatus.Active), "Status should still be Active");
		assertTrue(clockOpen, "Clock should be open");
		assertEq(roundBids.length, 0, "Should have no round bids after opening");
		assertEq(currentRound, 1, "Round should be incremented to 1");
		assertEq(poolKeys.length, 2, "Should still have 2 asset pools");
	}

	function test_StartClockRound_InvalidAuctionId() public {
		// Create invalid auction ID
		AuctionId invalidAuctionId = AuctionId.wrap(keccak256("invalid"));

		// Should revert with AuctionNotFound
		vm.prank(auctioneer);
		vm.expectRevert(IErrorsAndEvents.AuctionNotFound.selector);
		cpaHook.startClockRound(invalidAuctionId);
	}

	function test_StartClockRound_UnauthorizedCaller() public {
		// Non-auctioneer should not be able to open clock round
		vm.prank(bidder1);
		vm.expectRevert(IErrorsAndEvents.Unauthorized.selector);
		cpaHook.startClockRound(auctionId);
	}

	function test_StartClockRound_SetupNotComplete() public {
		// Create a new auction without deposits
		AuctionTypes.AuctionConfig memory config = AuctionTypes.AuctionConfig({
			commonNumeraire: address(numeraireToken),
			minSpendRatio: 1000,
			dropoutSlashRatio: 1000,
			spendingViolationSlashRatio: 2000,
			maxRounds: 100,
			clockPriceIncrement: 1000,
			allocatorStakeRequirement: 10000 * 10**18,
			proxyStakeRequirement: 1000 * 10**18,
			maxStakeCap: 1000000 * 10**18,
			revealWindow: 3600,
			allocationWindow: 1800
		});

		PoolKey[] memory assetPoolKeys = new PoolKey[](2);
		assetPoolKeys[0] = asset1PoolKey;
		assetPoolKeys[1] = asset2PoolKey;

		vm.prank(auctioneer);
		AuctionId newAuctionId = cpaHook.createAuction(assetPoolKeys, config, auctioneer);

		// Try to start clock phase without deposits - should revert
		vm.prank(auctioneer);
		vm.expectRevert(IErrorsAndEvents.SetupNotComplete.selector);
		cpaHook.startClockRound(newAuctionId);
	}

	function test_StartClockRound_AlreadyInClockPhase() public {
		// Start clock phase first time
		vm.prank(auctioneer);
		cpaHook.startClockRound(auctionId);

		// Try to start again - should revert with SetupNotComplete
		vm.prank(auctioneer);
		vm.expectRevert(IErrorsAndEvents.SetupNotComplete.selector);
		cpaHook.startClockRound(auctionId);
	}


	function test_StartClockRound_EventEmission() public {
		// Expect ClockRoundOpened event
		vm.expectEmit(true, true, true, true);
		emit IErrorsAndEvents.ClockRoundOpened(auctionId, 1);

		// Open clock round
		vm.prank(auctioneer);
		cpaHook.startClockRound(auctionId);
	}

	function test_StartClockRound_RoundIncrement() public {
		// Start clock phase (opens first round)
		vm.prank(auctioneer);
		cpaHook.startClockRound(auctionId);

		// Verify first round
		(, , , , , , , uint256 currentRound, ) = cpaHook.getAuctionInfo(auctionId);
		assertEq(currentRound, 1, "First round should be 1");

		// Note: Subsequent rounds would be opened by a different function
		// (not startClockRound, which only works from Setup phase)
	}

	function test_CompleteBidFlow_WithProxyCommit() public {
		// Start clock phase
		vm.prank(auctioneer);
		cpaHook.startClockRound(auctionId);

		// Create a proxy and bidder
		proxy1 = makeAddr("proxy1");
		bidder1 = makeAddr("bidder1");

		// Mint numeraire tokens to bidder for staking
		// Need enough for bid value: 100 * 1000 + 50 * 2000 = 200,000 numeraire tokens
		vm.prank(protocolOwner);
		numeraireToken.mint(bidder1, 250000 * 10**18);

		// Generate commit hash using CommitReveal library
		bytes32 saltA = keccak256("saltA");
		bytes32 saltB = keccak256("saltB");
		bytes32 commitHash = CommitReveal.generateCommitHash(bidder1, proxy1, saltA, saltB);

		// Proxy commits to the bidder1
		vm.prank(proxy1);
		cpaHook.commitToBidder(auctionId, commitHash);

		// Verify commit was recorded
		assertEq(cpaHook.commitProxy(auctionId, commitHash), proxy1, "Proxy1 should be recorded for commit hash");

		// Bidder approves numeraire tokens for the auction contract
		vm.prank(bidder1);
		numeraireToken.approve(address(cpaHook), 250000 * 10**18);

		// Bidder submits bid: demands [100, 50] for assets [asset1, asset2]
		uint256[] memory demands = new uint256[](2);
        console.log("asset1Token.decimals()", asset1Token.decimals());
        console.log("asset2Token.decimals()", asset2Token.decimals());
		demands[0] = 100 * 10**asset1Token.decimals(); // 100 units of asset1
		demands[1] = 50 * 10**asset2Token.decimals();  // 50 units of asset2
		
		// uint256 stakeAmount = 200000 * 10**18; // 200,000 numeraire tokens as stake (matches bid value)

		// Calculate expected bid value: 100 * 1000 + 50 * 2000 = 200,000 numeraire
		uint256 expectedBidValue = ((demands[0] * asset1InitialPrice) / 10**18) + ((demands[1] * asset2InitialPrice) / 10**18); // (demand * price) / numeraire.decimals()
        uint256 stakeAmount = expectedBidValue;

        console.log("stakeAmount", stakeAmount);

		// Submit bid
		vm.prank(bidder1);
		cpaHook.submitBid(auctionId, demands, commitHash, stakeAmount);

		// Verify bid was recorded
		(,,,,,bool clockOpen,AuctionTypes.Bid[] memory roundBids,uint256 currentRound,) = cpaHook.getAuctionInfo(auctionId);
		assertTrue(clockOpen, "Clock should be open after first bid");
		assertEq(currentRound, 1, "Current round should be 1");
		assertEq(roundBids.length, 1, "Should have exactly 1 bid after first bidder");
		assertEq(roundBids[0].bidder, bidder1, "First bid should be from bidder1");
		assertEq(roundBids[0].commitHash, commitHash, "First bid should have correct commit hash");
		assertEq(roundBids[0].stakeAmount, stakeAmount, "First bid should have correct stake amount");
		assertEq(roundBids[0].quantities.length, 2, "First bid should have 2 quantities");
		assertEq(roundBids[0].quantities[0], 100 * 10**asset1Token.decimals(), "First bid asset1 quantity should be 100");
		assertEq(roundBids[0].quantities[1], 50 * 10**asset2Token.decimals(), "First bid asset2 quantity should be 50");
		assertEq(roundBids[0].round, 1, "First bid should be in round 1");

		// Verify bidder stake and bid points were updated
		assertEq(cpaHook.bidderStake(auctionId, bidder1), stakeAmount, "Bidder1 stake should match stake amount");
		assertEq(cpaHook.bidderBidPoints(auctionId, bidder1), stakeAmount, "Bidder1 bid points should match stake amount (1:1 ratio)");

		// Verify numeraire tokens were transferred
		uint256 bidder1OriginalBalance = 250000 * 10**18;
		assertEq(numeraireToken.balanceOf(bidder1), bidder1OriginalBalance - stakeAmount, "Bidder1 should have remaining balance after stake");
		assertEq(numeraireToken.balanceOf(address(poolManager)), stakeAmount, "Pool manager should have received stake amount");

		// Add second bidder
		bidder2 = makeAddr("bidder2");
		proxy2 = makeAddr("proxy2");

		// Mint numeraire tokens to second bidder
		vm.prank(protocolOwner);
		numeraireToken.mint(bidder2, 300000 * 10**18);

		// Generate commit hash for second bidder
		bytes32 saltA2 = keccak256("saltA2");
		bytes32 saltB2 = keccak256("saltB2");
		bytes32 commitHash2 = CommitReveal.generateCommitHash(bidder2, proxy2, saltA2, saltB2);

		// Proxy2 commits to bidder2
		vm.prank(proxy2);
		cpaHook.commitToBidder(auctionId, commitHash2);

		// Verify commit was recorded
		assertEq(cpaHook.commitProxy(auctionId, commitHash2), proxy2, "Proxy2 should be recorded for commit hash2");

		// Bidder2 approves numeraire tokens
		vm.prank(bidder2);
		numeraireToken.approve(address(cpaHook), 300000 * 10**18);

		// Bidder2 submits different bid: demands [75, 25] for assets [asset1, asset2]
		uint256[] memory demands2 = new uint256[](2);
		demands2[0] = 75 * 10**asset1Token.decimals(); // 75 units of asset1
		demands2[1] = 25 * 10**asset2Token.decimals(); // 25 units of asset2
		
        uint256 expectedBidValue2 = ((demands2[0] * asset1InitialPrice) / 10**18) + ((demands2[1] * asset2InitialPrice) / 10**18); // (demand * price) / numeraire.decimals()
		uint256 stakeAmount2 = expectedBidValue2;
        

		// Submit second bid
		vm.prank(bidder2);
		cpaHook.submitBid(auctionId, demands2, commitHash2, stakeAmount2);

		// Verify both bids were recorded
		(,,,,,clockOpen,roundBids,currentRound,) = cpaHook.getAuctionInfo(auctionId);
		assertTrue(clockOpen, "Clock should still be open after second bid");
		assertEq(currentRound, 1, "Current round should still be 1");
		assertEq(roundBids.length, 2, "Should have exactly 2 bids after second bidder");
		
		// Verify first bidder's bid
		assertEq(roundBids[0].bidder, bidder1, "First bid should be from bidder1");
		assertEq(roundBids[0].commitHash, commitHash, "First bid should have correct commit hash");
		assertEq(roundBids[0].stakeAmount, stakeAmount, "First bid should have correct stake amount");
		assertEq(roundBids[0].quantities[0], 100 * 10**asset1Token.decimals(), "First bid asset1 quantity should be 100");
		assertEq(roundBids[0].quantities[1], 50 * 10**asset2Token.decimals(), "First bid asset2 quantity should be 50");
		
		// Verify second bidder's bid
		assertEq(roundBids[1].bidder, bidder2, "Second bid should be from bidder2");
		assertEq(roundBids[1].commitHash, commitHash2, "Second bid should have correct commit hash2");
		assertEq(roundBids[1].stakeAmount, stakeAmount2, "Second bid should have correct stake amount2");
		assertEq(roundBids[1].quantities[0], 75 * 10**asset1Token.decimals(), "Second bid asset1 quantity should be 75");
		assertEq(roundBids[1].quantities[1], 25 * 10**asset2Token.decimals(), "Second bid asset2 quantity should be 25");

		// Verify both bidders' stakes and bid points
		assertEq(cpaHook.bidderStake(auctionId, bidder1), stakeAmount, "Bidder1 stake should match stake amount");
		assertEq(cpaHook.bidderBidPoints(auctionId, bidder1), stakeAmount, "Bidder1 bid points should match stake amount");
		assertEq(cpaHook.bidderStake(auctionId, bidder2), stakeAmount2, "Bidder2 stake should match stake amount2");
		assertEq(cpaHook.bidderBidPoints(auctionId, bidder2), stakeAmount2, "Bidder2 bid points should match stake amount2");

		// Verify token balances
		bidder1OriginalBalance = 250000 * 10**18;
		uint256 bidder2OriginalBalance = 300000 * 10**18;
		assertEq(numeraireToken.balanceOf(bidder1), bidder1OriginalBalance - stakeAmount, "Bidder1 should have remaining balance after stake");
		assertEq(numeraireToken.balanceOf(bidder2), bidder2OriginalBalance - stakeAmount2, "Bidder2 should have remaining balance after stake");
		assertEq(numeraireToken.balanceOf(address(poolManager)), stakeAmount + stakeAmount2, "Pool manager should have total stakes");
		
		// Verify ERC6909 claims: CPAAuctionManager should have claims for the total stakes
		uint256 numeraireCurrencyId = uint256(uint160(address(numeraireToken)));
		assertEq(IERC6909Claims(poolManager).balanceOf(address(cpaHook), numeraireCurrencyId), stakeAmount + stakeAmount2, "CPAAuctionManager should have ERC6909 claims for total stakes");

		// End the clock round
		vm.prank(auctioneer);
		cpaHook.endClockRound(auctionId);

		// Verify clock is closed and phase changed to Proxy
		(,,,AuctionTypes.AuctionPhase currentPhase2,AuctionTypes.AuctionStatus currentStatus2,bool clockOpen2,AuctionTypes.Bid[] memory roundBids2,uint256 currentRound2,) = cpaHook.getAuctionInfo(auctionId);
		assertFalse(clockOpen2, "Clock should be closed after ending round");
		assertEq(uint256(currentPhase2), uint256(AuctionTypes.AuctionPhase.Proxy), "Phase should be Proxy after ending clock round");

		// Verify price increment functionality
		// Asset1: demand = 100 + 75 = 175, supply = 100, excess = 75
		// Asset2: demand = 50 + 25 = 75, supply = 150, excess = 0
		// Price increment = 1 token (1 * 10^18)
		// Asset1 price should increase by 1 * priceIncrement = 1 token (regardless of excess demand amount)
		// Asset2 price should remain the same (no excess demand)
		
		// Verify price increment functionality by destructuring getPoolInfo tuples
		// Check asset1 pool price (should be 1000 + 1*1 = 1001)
		uint256 expectedAsset1Price = asset1InitialPrice + 1 * 1 * 10**18; // 1,001
		(,uint256 asset1CurrentPrice,uint256 asset1PriceIncrement,,uint256 asset1ExcessDemand,) = cpaHook.getPoolInfo(asset1PoolKey.toId());
		
		// Debug: Check if price increment is set correctly
		assertEq(asset1PriceIncrement, 1 * 10**18, "Asset1 price increment should be 1 token");
		
		// Debug: Print actual values to understand what's happening
		console.log("Asset1 current price:", asset1CurrentPrice);
		console.log("Asset1 price increment:", asset1PriceIncrement);
		console.log("Asset1 excess demand:", asset1ExcessDemand);
		console.log("Expected asset1 price:", expectedAsset1Price);
		
		assertEq(asset1ExcessDemand, 75 * 10**asset1Token.decimals(), "Asset1 should have excess demand of 75");
		
		assertEq(asset1CurrentPrice, expectedAsset1Price, "Asset1 price should increase by 1 token due to excess demand");
		
		// Check asset2 pool price (should remain 2000, no excess demand)
		uint256 expectedAsset2Price = asset2InitialPrice; // 2,000
		(,uint256 asset2CurrentPrice,,,uint256 asset2ExcessDemand,) = cpaHook.getPoolInfo(asset2PoolKey.toId());
		assertEq(asset2CurrentPrice, expectedAsset2Price, "Asset2 price should remain the same (no excess demand)");
		
		// Verify excess demand was calculated correctly
		assertEq(asset1ExcessDemand, 75 * 10**asset1Token.decimals(), "Asset1 should have excess demand of 75");
		assertEq(asset2ExcessDemand, 0, "Asset2 should have no excess demand");
	}

	function test_StartClockRound_RoundBidsCleared() public {
		// Start clock phase (opens first round)
		vm.prank(auctioneer);
		cpaHook.startClockRound(auctionId);

		// Verify round bids are cleared
		(, , , , , , AuctionTypes.Bid[] memory roundBids, , ) = cpaHook.getAuctionInfo(auctionId);
		assertEq(roundBids.length, 0, "Round bids should be cleared when starting clock phase");
	}
}
