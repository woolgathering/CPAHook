// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { Test, console } from "forge-std/Test.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { Currency, CurrencyLibrary } from "@uniswap/v4-core/src/types/Currency.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC6909Claims } from "@uniswap/v4-core/src/interfaces/external/IERC6909Claims.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import { MockERC20 } from "solmate/src/test/utils/mocks/MockERC20.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { LPFeeLibrary } from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";

import { CPAManager } from "../src/CPAManager.sol";
import { AuctionTypes } from "../src/AuctionTypes.sol";
import { AuctionId } from "../src/AuctionId.sol";
import { IErrorsAndEvents } from "../src/utils/IErrorsAndEvents.sol";
import { CommitReveal } from "../src/CommitReveal.sol";
import { CPATestBase } from "./base/CPATestBase.sol";

contract CPAClockPhaseTest is CPATestBase {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;
    using TickMath for uint160;

    uint256 public depositAmount1 = 100 * 10**18;
    uint256 public depositAmount2 = 150 * 10**18;
    
    function setUp() public override {
        super.setUp();
        
        // Create auction with standard configuration
        AuctionTypes.AuctionConfig memory config = createStandardAuctionConfig();
        auctionId = createAuction(config, auctioneer);
        
        // Mint tokens to auctioneer for deposits
        mintTokensToAuctioneer(1000000 * 10**18);
        
        // Approve CPAManager to spend auctioneer's tokens
        approveTokens(address(asset1Token), address(cpaManager), depositAmount1);
        approveTokens(address(asset2Token), address(cpaManager), depositAmount2);
        
        // Move deposits to pools
        moveDeposit(auctionId, asset1PoolKey, depositAmount1);
        moveDeposit(auctionId, asset2PoolKey, depositAmount2);
    }

    function test_StartClockRound_Success() public {
        // Verify initial state
        AuctionTypes.AuctionInfo memory auctionInfo = cpaManager.getAuctionInfo(auctionId);

        assertEq(auctionInfo.auctionOwner, auctioneer, "Auction owner should be auctioneer");
        assertEq(auctionInfo.commonNumeraire, address(numeraireToken), "Common numeraire should be numeraire token");
        assertEq(uint256(auctionInfo.currentPhase), uint256(AuctionTypes.AuctionPhase.Setup), "Initial phase should be Setup");
        assertEq(uint256(auctionInfo.currentStatus), uint256(AuctionTypes.AuctionStatus.Active), "Status should be Active");
        assertEq(auctionInfo.clockOpen, 1, "Clock should be closed initially");
        assertEq(auctionInfo.roundBids.length, 0, "Should have no round bids initially");
        assertEq(auctionInfo.currentRound, 0, "Initial round should be 0");
        assertEq(auctionInfo.poolKeys.length, 2, "Should have 2 asset pools");

        // Open clock round
        vm.prank(auctioneer);
        cpaManager.startClockRound(auctionId);

        // Verify state after opening clock round
        AuctionTypes.AuctionInfo memory auctionInfoAfterStart = cpaManager.getAuctionInfo(auctionId);

        assertEq(uint256(auctionInfoAfterStart.currentPhase), uint256(AuctionTypes.AuctionPhase.Clock), "Phase should be Clock");
        assertEq(uint256(auctionInfoAfterStart.currentStatus), uint256(AuctionTypes.AuctionStatus.Active), "Status should still be Active");
        assertEq(auctionInfoAfterStart.clockOpen, 2, "Clock should be open after opening clock round");
        assertEq(auctionInfoAfterStart.roundBids.length, 0, "Should have no round bids after opening");
        assertEq(auctionInfoAfterStart.currentRound, 1, "Round should be incremented to 1");
        assertEq(auctionInfoAfterStart.poolKeys.length, 2, "Should still have 2 asset pools");
    }

    function test_StartClockRound_InvalidAuctionId() public {
        // Create invalid auction ID
        AuctionId invalidAuctionId = AuctionId.wrap(keccak256("invalid"));

        // Should revert with AuctionNotFound
        vm.prank(auctioneer);
        vm.expectRevert(IErrorsAndEvents.AuctionNotFound.selector);
        cpaManager.startClockRound(invalidAuctionId);
    }

    function test_StartClockRound_UnauthorizedCaller() public {
        // Non-auctioneer should not be able to open clock round
        vm.prank(bidder1);
        vm.expectRevert(IErrorsAndEvents.Unauthorized.selector);
        cpaManager.startClockRound(auctionId);
    }

    function test_StartClockRound_SetupNotComplete() public {
        // Create a new auction with different pool keys but without deposits
        AuctionTypes.AuctionConfig memory config = createNewAuctionConfig();
        AuctionId newAuctionId = createAuction(config, auctioneer);
        
        // Don't move any deposits - auction setup is not complete
        // Try to start clock phase without deposits - should revert
        vm.prank(auctioneer);
        vm.expectRevert(IErrorsAndEvents.SetupNotComplete.selector);
        cpaManager.startClockRound(newAuctionId);
    }

    function test_StartClockRound_AlreadyInClockPhase() public {
        // Start clock phase first time
        vm.prank(auctioneer);
        cpaManager.startClockRound(auctionId);

        // Try to start again - should revert with ClockAlreadyOpen
        vm.prank(auctioneer);
        vm.expectRevert(IErrorsAndEvents.ClockAlreadyOpen.selector);
        cpaManager.startClockRound(auctionId);
    }

    function test_StartClockRound_EventEmission() public {
        // Expect ClockRoundOpened event
        vm.expectEmit(true, true, true, true);
        emit IErrorsAndEvents.ClockRoundOpened(auctionId, 1);

        // Open clock round
        vm.prank(auctioneer);
        cpaManager.startClockRound(auctionId);
    }

    function test_StartClockRound_RoundIncrement() public {
        // Start clock phase (opens first round)
        vm.prank(auctioneer);
        cpaManager.startClockRound(auctionId);

        // Verify first round
        AuctionTypes.AuctionInfo memory auctionInfo1 = cpaManager.getAuctionInfo(auctionId);
        assertEq(auctionInfo1.currentRound, 1, "First round should be 1");

        // End first round (no bids required)
        vm.prank(auctioneer);
        cpaManager.endClockRound(auctionId);

        // Start second round
        vm.prank(auctioneer);
        cpaManager.startClockRound(auctionId);

        // Verify second round
        AuctionTypes.AuctionInfo memory auctionInfo2 = cpaManager.getAuctionInfo(auctionId);
        assertEq(auctionInfo2.currentRound, 2, "Second round should be 2");

        // End second round
        vm.prank(auctioneer);
        cpaManager.endClockRound(auctionId);

        // Start third round
        vm.prank(auctioneer);
        cpaManager.startClockRound(auctionId);

        // Verify third round
        AuctionTypes.AuctionInfo memory auctionInfo3 = cpaManager.getAuctionInfo(auctionId);
        assertEq(auctionInfo3.currentRound, 3, "Third round should be 3");
    }

    function test_CompleteBidFlow_WithProxyCommit() public {
        // Check pool info right after auction creation (before clock phase)
        (PoolKey memory initialAsset1PoolKeyCheck, int24 initialAsset1StartingTick, int24 initialAsset1PriceIncrement, uint256 initialAsset1DepositAmount, uint256 initialAsset1ExcessDemand, , bytes32 initialAsset1PositionId) = cpaManager.getPoolInfo(asset1PoolKey.toId());
        (PoolKey memory initialAsset2PoolKeyCheck, int24 initialAsset2StartingTick, int24 initialAsset2PriceIncrement, uint256 initialAsset2DepositAmount, uint256 initialAsset2ExcessDemand, , bytes32 initialAsset2PositionId) = cpaManager.getPoolInfo(asset2PoolKey.toId());
        
        // Verify pool keys match
        assertEq(Currency.unwrap(initialAsset1PoolKeyCheck.currency0), Currency.unwrap(asset1PoolKey.currency0), "Asset1 pool key currency0 should match");
        assertEq(Currency.unwrap(initialAsset1PoolKeyCheck.currency1), Currency.unwrap(asset1PoolKey.currency1), "Asset1 pool key currency1 should match");
        assertEq(Currency.unwrap(initialAsset2PoolKeyCheck.currency0), Currency.unwrap(asset2PoolKey.currency0), "Asset2 pool key currency0 should match");
        assertEq(Currency.unwrap(initialAsset2PoolKeyCheck.currency1), Currency.unwrap(asset2PoolKey.currency1), "Asset2 pool key currency1 should match");
        
        // Verify starting ticks are correct
        assertEq(initialAsset1StartingTick, 0, "Asset1 starting tick should be 0 for price = 1");
        assertEq(initialAsset2StartingTick, 6931, "Asset2 starting tick should be 6931 for price = 2");
        
        // Verify price increments are correct
        assertEq(initialAsset1PriceIncrement, asset1PoolKey.tickSpacing * 10, "Asset1 price increment should be 100 ticks");
        assertEq(initialAsset2PriceIncrement, asset2PoolKey.tickSpacing * 5, "Asset2 price increment should be 300 ticks");
        
        // Verify initial deposit amounts and excess demand are 0
        assertEq(initialAsset1DepositAmount, depositAmount1, "Asset1 deposit amount should be 0 initially"); // this will probably fail since we have already moved the deposit
        assertEq(initialAsset1ExcessDemand, 0, "Asset1 excess demand should be 0 initially");
        assertEq(initialAsset2DepositAmount, depositAmount2, "Asset2 deposit amount should be 0 initially"); // this will probably fail since we have already moved the deposit
        assertEq(initialAsset2ExcessDemand, 0, "Asset2 excess demand should be 0 initially");

        ////////////////////////////////////////
        ///// CREATE BIDDERS AND PROXIES
        ////////////////////////////////////////

        ///// CREATE BIDDER1 AND PROXY1
        // Create a proxy and bidder
        proxy1 = makeAddr("proxy1");
        bidder1 = makeAddr("bidder1");

        // Create bidder with numeraire tokens
        createBidder(bidder1, 250000 * 10**18);
        uint256 bidder1OriginalBalance = IERC20(address(numeraireToken)).balanceOf(bidder1);

        // Generate commit hash using CommitReveal library (one-time per bidder-proxy pair)
        bytes32 saltA = keccak256("saltA"); // known only to the bidder
        bytes32 saltB = keccak256("saltB"); // known only to the bidder and the proxy
        bytes32 commitHash = CommitReveal.generateCommitHash(bidder1, proxy1, saltA, saltB); // shared with the proxy


        ///// CREATE BIDDER2 AND PROXY2
        // Create a proxy and bidder
        bidder2 = makeAddr("bidder2");
        proxy2 = makeAddr("proxy2");

        // Create bidder with numeraire tokens
        createBidder(bidder2, 300000 * 10**18);
        uint256 bidder2OriginalBalance = IERC20(address(numeraireToken)).balanceOf(bidder2);

        // Generate commit hash using CommitReveal library (one-time per bidder-proxy pair)
        bytes32 saltA2 = keccak256("saltA2");
        bytes32 saltB2 = keccak256("saltB2");
        bytes32 commitHash2 = CommitReveal.generateCommitHash(bidder2, proxy2, saltA2, saltB2);

        // Start clock phase
        ////////////////////////////////////////
        // ROUND ONE
        ////////////////////////////////////////
        vm.prank(auctioneer);
        cpaManager.startClockRound(auctionId);

        // Capture initial sqrtPriceX96 values for inter-round bidding checks
        (uint160 asset1InitialSqrtPriceX96, , , ) = poolManager.getSlot0(asset1PoolKey.toId());
        (uint160 asset2InitialSqrtPriceX96, , , ) = poolManager.getSlot0(asset2PoolKey.toId());

        // Proxy commits to the bidder1 (one-time registration)
        vm.prank(proxy1);
        cpaManager.commitToBidder(auctionId, commitHash);
        assertEq(cpaManager.commitProxy(auctionId, commitHash), proxy1, "Proxy1 should be recorded for commit hash");

        vm.prank(proxy2);
        cpaManager.commitToBidder(auctionId, commitHash2);
        assertEq(cpaManager.commitProxy(auctionId, commitHash2), proxy2, "Proxy2 should be recorded for commit hash2");

        ////////////////
        // BIDDER1 SUBMITS BID 1
        ////////////////

        // Bidder creates a bid: demands [100, 50] for assets [asset1, asset2]
        uint256[] memory demands = new uint256[](2);
        demands[0] = 100 * 10**asset1Token.decimals(); // 100 units of asset1
        demands[1] = 50 * 10**asset2Token.decimals();  // 50 units of asset2
        
        // Calculate expected bid value using current pool prices
        uint256 expectedBidValue = calculateBidValue(demands);
        uint256 maxStakeAmount = expectedBidValue; // Set max to exactly what's needed
        uint256 expectedAllocatorRewardFromBidder1_round1 = (expectedBidValue * allocatorRewardPct) / 10000;
        console.log("expectedBidValue", expectedBidValue);
        console.log("expectedAllocatorRewardFromBidder1_round1", expectedAllocatorRewardFromBidder1_round1);

        // Approve numeraire tokens for the auction contract
        approveNumeraireForBidder(bidder1, type(uint256).max);

        // Submit bid
        vm.prank(bidder1);
        cpaManager.submitBid(auctionId, demands, maxStakeAmount);

        // Verify bid was recorded
        AuctionTypes.AuctionInfo memory auctionInfoBid1 = cpaManager.getAuctionInfo(auctionId);
        assertEq(auctionInfoBid1.clockOpen, 2, "Clock should be open after first bid");
        assertEq(auctionInfoBid1.currentRound, 1, "Current round should be 1");
        assertEq(auctionInfoBid1.roundBids.length, 1, "Should have exactly 1 bid after first bidder");
        assertEq(auctionInfoBid1.roundBids[0].bidder, bidder1, "First bid should be from bidder1");
        assertEq(auctionInfoBid1.roundBids[0].stakeAmount, expectedBidValue, "First bid should have correct stake amount");
        assertEq(auctionInfoBid1.roundBids[0].quantities.length, 2, "First bid should have 2 quantities");
        assertEq(auctionInfoBid1.roundBids[0].quantities[0], 100 * 10**asset1Token.decimals(), "First bid asset1 quantity should be 100");
        assertEq(auctionInfoBid1.roundBids[0].quantities[1], 50 * 10**asset2Token.decimals(), "First bid asset2 quantity should be 50");
        assertEq(auctionInfoBid1.roundBids[0].round, 1, "First bid should be in round 1");

        // Verify bidder stake and bid points were updated
        assertEq(cpaManager.bidderStake(auctionId, bidder1), expectedBidValue, "Bidder1 stake should match expected bid value");
        assertEq(cpaManager.bidderBidPoints(auctionId, bidder1), expectedBidValue, "Bidder1 bid points should match expected bid value (1:1 ratio)");

        // Verify numeraire tokens were transferred
        uint256 expectedBidderBalance = bidder1OriginalBalance - (expectedBidValue + expectedAllocatorRewardFromBidder1_round1);
        uint256 actualBidderBalance = numeraireToken.balanceOf(bidder1);
        // Allow for small allocator reward difference (tolerance of 5 tokens)
        assertTrue(actualBidderBalance >= expectedBidderBalance - 5 && actualBidderBalance <= expectedBidderBalance + 5, 
            string(abi.encodePacked("Bidder1 balance should be within tolerance: expected ~", vm.toString(expectedBidderBalance), ", got ", vm.toString(actualBidderBalance))));
        assertEq(numeraireToken.balanceOf(address(poolManager)), expectedBidValue + expectedAllocatorRewardFromBidder1_round1, "Pool manager should have received expected bid value");
        assertEq(IERC6909Claims(poolManager).balanceOf(address(cpaManager), numeraireCurrencyId), expectedBidValue + expectedAllocatorRewardFromBidder1_round1, "CPAManager should have ERC6909 claims for expected bid value");

        // Verify that the sqrtPriceX96 of either pool has not moved during inter-round bidding
        (uint160 asset1SqrtPriceX96AfterFirstBid, , , ) = poolManager.getSlot0(asset1PoolKey.toId());
        (uint160 asset2SqrtPriceX96AfterFirstBid, , , ) = poolManager.getSlot0(asset2PoolKey.toId());
        assertEq(asset1SqrtPriceX96AfterFirstBid, asset1InitialSqrtPriceX96, "Asset1 sqrtPriceX96 should not have moved after first bid");
        assertEq(asset2SqrtPriceX96AfterFirstBid, asset2InitialSqrtPriceX96, "Asset2 sqrtPriceX96 should not have moved after first bid");


        ////////////////
        // BIDDER2 SUBMITS BID 1
        ///////////////

        // Bidder2 submits different bid: demands [75, 25] for assets [asset1, asset2]
        uint256[] memory demands2 = new uint256[](2);
        demands2[0] = 75 * 10**asset1Token.decimals(); // 75 units of asset1
        demands2[1] = 25 * 10**asset2Token.decimals(); // 25 units of asset2
        
        uint256 expectedBidValue2 = calculateBidValue(demands2);
        uint256 expectedAllocatorReward2 = (expectedBidValue2 * allocatorRewardPct) / 10000;
        uint256 stakeAmount2 = expectedBidValue2;

        // Approve numeraire tokens
        approveNumeraireForBidder(bidder2, type(uint256).max);

        // Submit second bid using partial commit (preserves anonymity)
        vm.prank(bidder2);
        cpaManager.submitBid(auctionId, demands2, stakeAmount2);

        ///////////////
        // VERIFICATION OF BOTH BIDS IN ROUND 1
        ///////////////

        // Verify both bids were recorded
        AuctionTypes.AuctionInfo memory auctionInfoBids = cpaManager.getAuctionInfo(auctionId);
        assertEq(auctionInfoBids.clockOpen, 2, "Clock should still be open after second bid");
        assertEq(auctionInfoBids.currentRound, 1, "Current round should still be 1");
        assertEq(auctionInfoBids.roundBids.length, 2, "Should have exactly 2 bids after second bidder");
        
        // Verify first bidder's bid again
        assertEq(auctionInfoBids.roundBids[0].bidder, bidder1, "First bid should be from bidder1");
        assertEq(auctionInfoBids.roundBids[0].stakeAmount, expectedBidValue, "First bid should have correct stake amount");
        assertEq(auctionInfoBids.roundBids[0].quantities[0], 100 * 10**asset1Token.decimals(), "First bid asset1 quantity should be 100");
        assertEq(auctionInfoBids.roundBids[0].quantities[1], 50 * 10**asset2Token.decimals(), "First bid asset2 quantity should be 50");
        
        // Verify second bidder's bid
        assertEq(auctionInfoBids.roundBids[1].bidder, bidder2, "Second bid should be from bidder2");
        assertEq(auctionInfoBids.roundBids[1].stakeAmount, expectedBidValue2, "Second bid should have correct stake amount2");
        assertEq(auctionInfoBids.roundBids[1].quantities[0], 75 * 10**asset1Token.decimals(), "Second bid asset1 quantity should be 75");
        assertEq(auctionInfoBids.roundBids[1].quantities[1], 25 * 10**asset2Token.decimals(), "Second bid asset2 quantity should be 25");

        // Verify both bidders' stakes and bid points
        assertEq(cpaManager.bidderStake(auctionId, bidder1), expectedBidValue, "Bidder1 stake should match expected bid value");
        assertEq(cpaManager.bidderBidPoints(auctionId, bidder1), expectedBidValue, "Bidder1 bid points should match expected bid value");
        assertEq(cpaManager.bidderStake(auctionId, bidder2), expectedBidValue2, "Bidder2 stake should match expected bid value2");
        assertEq(cpaManager.bidderBidPoints(auctionId, bidder2), expectedBidValue2, "Bidder2 bid points should match expected bid value2");

        // Verify token balances
        uint256 expectedBidder1Balance = bidder1OriginalBalance - (expectedBidValue + expectedAllocatorRewardFromBidder1_round1);
        uint256 actualBidder1Balance = numeraireToken.balanceOf(bidder1);
        assertTrue(actualBidder1Balance >= expectedBidder1Balance - 5 && actualBidder1Balance <= expectedBidder1Balance + 5, 
            string(abi.encodePacked("Bidder1 balance should be within tolerance: expected ~", vm.toString(expectedBidder1Balance), ", got ", vm.toString(actualBidder1Balance))));
        
        uint256 expectedBidder2Balance = bidder2OriginalBalance - (expectedBidValue2 + expectedAllocatorReward2);
        uint256 actualBidder2Balance = numeraireToken.balanceOf(bidder2);
        assertTrue(actualBidder2Balance >= expectedBidder2Balance - 5 && actualBidder2Balance <= expectedBidder2Balance + 5, 
            string(abi.encodePacked("Bidder2 balance should be within tolerance: expected ~", vm.toString(expectedBidder2Balance), ", got ", vm.toString(actualBidder2Balance))));
        uint256 expectedPoolManagerBalance = (expectedBidValue + expectedAllocatorRewardFromBidder1_round1) + (expectedBidValue2 + expectedAllocatorReward2);
        uint256 actualPoolManagerBalance = numeraireToken.balanceOf(address(poolManager));
        // Allow for small allocator reward differences (tolerance of 10 tokens)
        assertTrue(actualPoolManagerBalance >= expectedPoolManagerBalance - 10 && actualPoolManagerBalance <= expectedPoolManagerBalance + 10, 
            string(abi.encodePacked("Pool manager balance should be within tolerance: expected ~", vm.toString(expectedPoolManagerBalance), ", got ", vm.toString(actualPoolManagerBalance))));
        assertEq(IERC6909Claims(poolManager).balanceOf(address(cpaManager), numeraireCurrencyId), actualPoolManagerBalance, "CPAManager should have ERC6909 claims for actual pool manager balance");

        // Verify that sqrtPriceX96 still has not moved after second bid (inter-round bidding)
        (uint160 asset1SqrtPriceX96AfterSecondBid, , , ) = poolManager.getSlot0(asset1PoolKey.toId());
        (uint160 asset2SqrtPriceX96AfterSecondBid, , , ) = poolManager.getSlot0(asset2PoolKey.toId());
        assertEq(asset1SqrtPriceX96AfterSecondBid, asset1InitialSqrtPriceX96, "Asset1 sqrtPriceX96 should not have moved after second bid");
        assertEq(asset2SqrtPriceX96AfterSecondBid, asset2InitialSqrtPriceX96, "Asset2 sqrtPriceX96 should not have moved after second bid");

        ///////////////
        // END FIRST CLOCK ROUND
        ///////////////

        // End the first clock round
        vm.prank(auctioneer);
        cpaManager.endClockRound(auctionId);

        // Verify clock is closed after first round
        AuctionTypes.AuctionInfo memory auctionInfoAfterEnd1 = cpaManager.getAuctionInfo(auctionId);
        assertEq(auctionInfoAfterEnd1.clockOpen, 1,"Clock should be closed after ending first round");
        assertEq(auctionInfoAfterEnd1.currentRound, 1, "Current round should still be 1 after ending first round");
        assertEq(auctionInfoAfterEnd1.roundBids.length, 0, "Round bids should be cleared after ending round");

        ///////////////
        // VERIFICATION OF PRICE INCREMENT FUNCTIONALITY
        ///////////////

        // Verify price increment functionality
        // Asset1: demand = 100 + 75 = 175, supply = 100, excess = 75
        // Asset2: demand = 50 + 25 = 75, supply = 150, excess = 0
        // Price increment = 100 ticks for asset1, 300 ticks for asset2
        // Asset1 price should increase by 100 ticks due to excess demand
        // Asset2 price should remain the same (no excess demand)
        
        // Get asset pool info (getPoolInfo returns startingTick, not currentTick)
        (,int24 asset1StartingTick,int24 asset1PriceIncrement,,uint256 asset1ExcessDemand,,) = cpaManager.getPoolInfo(asset1PoolKey.toId());
        (,int24 asset2StartingTick,int24 asset2PriceIncrement,,uint256 asset2ExcessDemand,,) = cpaManager.getPoolInfo(asset2PoolKey.toId());
        
        // Get the current (actual) tick and sqrtPriceX96 for both assets
        (uint160 actualAsset1SqrtPriceX96, int24 actualAsset1CurrentTick, , ) = poolManager.getSlot0(asset1PoolKey.toId());
        (uint160 actualAsset2SqrtPriceX96, int24 actualAsset2CurrentTick, , ) = poolManager.getSlot0(asset2PoolKey.toId());

        // Verify excess demand was calculated correctly
        assertEq(asset1ExcessDemand, 75 * 10**asset1Token.decimals(), "Asset1 should have excess demand of 75");
        assertEq(asset2ExcessDemand, 0, "Asset2 should have no excess demand");
        
        // Verify price increments are still stored correctly
        assertEq(asset1PriceIncrement, asset1PoolKey.tickSpacing * 10, "Asset1 price increment should be tickSpacing * 10 ticks");
        assertEq(asset2PriceIncrement, asset2PoolKey.tickSpacing * 5, "Asset2 price increment should be tickSpacing * 5 ticks");

        // Verify that Asset1 price increased due to excess demand in both tick-space and sqrtPriceX96-space
        // Asset1 should have moved from starting tick (0) to starting tick + priceIncrement (100)
        assertEq(actualAsset1CurrentTick, asset1StartingTick + asset1PriceIncrement, "Asset1 current tick should be startingTick + priceIncrement");
        assertEq(actualAsset1SqrtPriceX96, TickMath.getSqrtPriceAtTick(asset1StartingTick + asset1PriceIncrement), "Asset1 sqrtPriceX96 should be startingTick + priceIncrement");
        
        // Verify that Asset2 price did not change due to no excess demand in tick-space and sqrtPriceX96-space
        // Asset2 should remain at starting tick (6931 for price = 2)
        assertEq(actualAsset2CurrentTick, asset2StartingTick, "Asset2 current tick should remain at startingTick (no excess demand)");
        assertEq(actualAsset2SqrtPriceX96, asset2InitialSqrtPriceX96, "Asset2 sqrtPriceX96 should remain at initial value");

        ////////////////////////////////////////
        // ROUND TWO
        ////////////////////////////////////////

        // Start second clock round
        vm.prank(auctioneer);
        cpaManager.startClockRound(auctionId);

        // Verify second round is open
        AuctionTypes.AuctionInfo memory auctionInfoRound2 = cpaManager.getAuctionInfo(auctionId);
        assertEq(auctionInfoRound2.clockOpen, 2, "Clock should be open for second round");
        assertEq(auctionInfoRound2.currentRound, 2, "Current round should be 2");
        assertEq(auctionInfoRound2.roundBids.length, 0, "Round bids should be cleared for new round");

        // Existing bidders submit new bids in round 2 with smaller demands
        // This should result in no excess demand due to higher prices from round 1

        // Bidder1 submits smaller bid: demands [30, 20] for assets [asset1, asset2]
        uint256[] memory demands1_round2 = new uint256[](2);
        demands1_round2[0] = 30 * 10**asset1Token.decimals(); // 30 units of asset1
        demands1_round2[1] = 20 * 10**asset2Token.decimals(); // 20 units of asset2
        
        // Calculate bid value with current pool prices
        uint256 expectedBidValue1_round2 = calculateBidValue(demands1_round2);
        
        // Check current bid points for bidder1
        uint256 currentBidPoints1 = cpaManager.bidderBidPoints(auctionId, bidder1);
        uint256 additionalStake1 = expectedBidValue1_round2 > currentBidPoints1 ? expectedBidValue1_round2 - currentBidPoints1 : 0;
        
        // Only approve additional tokens if needed
        if (additionalStake1 > 0) {
            approveNumeraireForBidder(bidder1, type(uint256).max);
        }

        // Submit bidder1's second round bid using same partial commit
        vm.prank(bidder1);
        cpaManager.submitBid(auctionId, demands1_round2, additionalStake1);

        // Bidder2 submits smaller bid: demands [25, 15] for assets [asset1, asset2]
        uint256[] memory demands2_round2 = new uint256[](2);
        demands2_round2[0] = 25 * 10**asset1Token.decimals(); // 25 units of asset1
        demands2_round2[1] = 15 * 10**asset2Token.decimals(); // 15 units of asset2
        
        uint256 expectedBidValue2_round2 = calculateBidValue(demands2_round2);
        
        // Check current bid points for bidder2
        uint256 currentBidPoints2 = cpaManager.bidderBidPoints(auctionId, bidder2);
        uint256 additionalStake2 = expectedBidValue2_round2 > currentBidPoints2 ? expectedBidValue2_round2 - currentBidPoints2 : 0;
        
        // Only approve additional tokens if needed
        if (additionalStake2 > 0) {
            approveNumeraireForBidder(bidder2, type(uint256).max);
        }

        // Submit bidder2's second round bid using same partial commit
        vm.prank(bidder2);
        cpaManager.submitBid(auctionId, demands2_round2, additionalStake2);

        // Verify both bids were recorded in round 2
        AuctionTypes.AuctionInfo memory auctionInfoRound2Bids = cpaManager.getAuctionInfo(auctionId);
        assertEq(auctionInfoRound2Bids.clockOpen, 2, "Clock should still be open after second round bids");
        assertEq(auctionInfoRound2Bids.currentRound, 2, "Current round should still be 2");
        assertEq(auctionInfoRound2Bids.roundBids.length, 2, "Should have exactly 2 bids in second round");
        
        // Verify bidder1's second round bid
        assertEq(auctionInfoRound2Bids.roundBids[0].bidder, bidder1, "First bid in round 2 should be from bidder1");
        assertEq(auctionInfoRound2Bids.roundBids[0].stakeAmount, additionalStake1, "First bid should have correct additional stake amount");
        assertEq(auctionInfoRound2Bids.roundBids[0].quantities[0], 30 * 10**asset1Token.decimals(), "First bid asset1 quantity should be 30");
        assertEq(auctionInfoRound2Bids.roundBids[0].quantities[1], 20 * 10**asset2Token.decimals(), "First bid asset2 quantity should be 20");
        
        // Verify bidder2's second round bid
        assertEq(auctionInfoRound2Bids.roundBids[1].bidder, bidder2, "Second bid in round 2 should be from bidder2");
        assertEq(auctionInfoRound2Bids.roundBids[1].stakeAmount, additionalStake2, "Second bid should have correct additional stake amount");
        assertEq(auctionInfoRound2Bids.roundBids[1].quantities[0], 25 * 10**asset1Token.decimals(), "Second bid asset1 quantity should be 25");
        assertEq(auctionInfoRound2Bids.roundBids[1].quantities[1], 15 * 10**asset2Token.decimals(), "Second bid asset2 quantity should be 15");

        // Verify bid points have been updated correctly (should be max of previous + additional)
        uint256 expectedBidPoints1_round2 = currentBidPoints1 + additionalStake1;
        uint256 expectedBidPoints2_round2 = currentBidPoints2 + additionalStake2;
        assertEq(cpaManager.bidderBidPoints(auctionId, bidder1), expectedBidPoints1_round2, "Bidder1 bid points should be updated correctly");
        assertEq(cpaManager.bidderBidPoints(auctionId, bidder2), expectedBidPoints2_round2, "Bidder2 bid points should be updated correctly");

        // Manually end the clock phase (transition to proxy phase)
        vm.prank(auctioneer);
        cpaManager.endClockRound(auctionId);

        //// END SECOND CLOCK ROUND

        // Verify clock is closed after second round
        AuctionTypes.AuctionInfo memory auctionInfoAfterEnd2 = cpaManager.getAuctionInfo(auctionId);
        assertEq(auctionInfoAfterEnd2.clockOpen, 1, "Clock should be closed after ending second round");
        assertEq(auctionInfoAfterEnd2.currentRound, 2, "Current round should still be 2 after ending second round");
        assertEq(auctionInfoAfterEnd2.roundBids.length, 0, "Round bids should be cleared after ending second round");

        ///////////////
        // VERIFICATION OF PRICE INCREMENT FUNCTIONALITY
        ///////////////

        // Verify price increment functionality
        // Asset1: demand is less than supply, so no excess demand. price remains the same as round 1
        // Asset2: demand is less than supply, so no excess demand. price remains the same as round 1
        // Price increment = 100 ticks for asset1, 300 ticks for asset2
        // Asset1 price should remain the same as the end of round 1
        // Asset2 price should remain the same as the end of round 1
        
        // Get asset pool info (getPoolInfo returns startingTick, not currentTick)
        // we only need to redefine the excess demand since it was calculated in round 2 and everything else is the same
        (,,,,uint256 asset1ExcessDemandRound2,,) = cpaManager.getPoolInfo(asset1PoolKey.toId());
        (,,,,uint256 asset2ExcessDemandRound2,,) = cpaManager.getPoolInfo(asset2PoolKey.toId());
        
        // Get the current (actual) tick and sqrtPriceX96 for both assets
        (uint160 actualAsset1SqrtPriceX96Round2, int24 actualAsset1CurrentTickRound2, , ) = poolManager.getSlot0(asset1PoolKey.toId());
        (uint160 actualAsset2SqrtPriceX96Round2, int24 actualAsset2CurrentTickRound2, , ) = poolManager.getSlot0(asset2PoolKey.toId());

        // Verify excess demand was calculated correctly
        assertEq(asset1ExcessDemandRound2, 0, "Asset1 should have no excess demand");
        assertEq(asset2ExcessDemandRound2, 0, "Asset2 should have no excess demand");
        
        // Verify price increments are still stored correctly
        // assertEq(asset1PriceIncrementRound2, asset1PoolKey.tickSpacing * 10, "Asset1 price increment should be tickSpacing * 10 ticks");
        // assertEq(asset2PriceIncrementRound2, asset2PoolKey.tickSpacing * 5, "Asset2 price increment should be tickSpacing * 5 ticks");

        // Verify that Asset1 price remained the same as the end of round 1 in both tick-space and sqrtPriceX96-space
        // Asset1 should remain at the same price as the end of round 1
        assertEq(actualAsset1CurrentTickRound2, asset1StartingTick + asset1PriceIncrement, "Asset1 current tick should be startingTick + priceIncrement");
        assertEq(actualAsset1SqrtPriceX96Round2, TickMath.getSqrtPriceAtTick(asset1StartingTick + asset1PriceIncrement), "Asset1 sqrtPriceX96 should be startingTick + priceIncrement");
        
        // Verify that Asset2 price did not change due to no excess demand in tick-space and sqrtPriceX96-space
        // Asset2 should remain at starting tick (6931 for price = 2)
        assertEq(actualAsset2CurrentTickRound2, asset2StartingTick, "Asset2 current tick should remain at startingTick (no excess demand)");
        assertEq(actualAsset2SqrtPriceX96Round2, asset2InitialSqrtPriceX96, "Asset2 sqrtPriceX96 should remain at initial value");

        ///////////////
        // END CLOCK PHASE
        ///////////////

        // No excess demand so stop the auction here
        vm.prank(auctioneer);
        cpaManager.endClockPhase(auctionId);

        // Verify clock is closed and phase changed to Proxy
        AuctionTypes.AuctionInfo memory auctionInfoAfterClock = cpaManager.getAuctionInfo(auctionId);
        assertEq(auctionInfoAfterClock.clockOpen, 1, "Clock should be closed after ending clock phase");
        assertEq(uint256(auctionInfoAfterClock.currentPhase), uint256(AuctionTypes.AuctionPhase.Proxy), "Phase should be Proxy after ending clock phase");

        // Verify no excess demand in second round (prices should not increase)
        (,int24 asset1StartingTick2,int24 asset1PriceIncrement2,,uint256 asset1ExcessDemand2,,) = cpaManager.getPoolInfo(asset1PoolKey.toId());
        (,int24 asset2StartingTick2,int24 asset2PriceIncrement2,,uint256 asset2ExcessDemand2,,) = cpaManager.getPoolInfo(asset2PoolKey.toId());
        
        // Asset1: demand = 30 + 25 = 55, supply = 100, excess = 0 (no excess demand)
        // Asset2: demand = 20 + 15 = 35, supply = 150, excess = 0 (no excess demand)
        assertEq(asset1ExcessDemand2, 0, "Asset1 should have no excess demand in second round");
        assertEq(asset2ExcessDemand2, 0, "Asset2 should have no excess demand in second round");
        
        // Verify that prices did not change in second round (no excess demand)
        // Asset1 should remain at tick 100 (from first round)
        (uint160 asset1SqrtPriceX96Final, int24 asset1CurrentTick2Real, , ) = poolManager.getSlot0(asset1PoolKey.toId());
        assertEq(asset1CurrentTick2Real, asset1StartingTick + asset1PriceIncrement, "Asset1 current tick should remain at startingTick + priceIncrement (no excess demand in round 2)");
        assertEq(asset1SqrtPriceX96Final, TickMath.getSqrtPriceAtTick(asset1StartingTick + asset1PriceIncrement), "Asset1 sqrtPriceX96 should remain at startingTick + priceIncrement");
        
        // Asset2 should remain at tick 6931 (from initial setup)
        (uint160 asset2SqrtPriceX96Final, int24 asset2CurrentTick2Real, , ) = poolManager.getSlot0(asset2PoolKey.toId());
        assertEq(asset2CurrentTick2Real, asset2StartingTick, "Asset2 current tick should remain at startingTick (no excess demand in round 2)");
        assertEq(asset2SqrtPriceX96Final, asset2InitialSqrtPriceX96, "Asset2 sqrtPriceX96 should remain at initial value");
    }

    function test_StartClockRound_RoundBidsCleared() public {
        // Start clock phase (opens first round)
        vm.prank(auctioneer);
        cpaManager.startClockRound(auctionId);

        // Verify round bids are cleared
        AuctionTypes.AuctionInfo memory auctionInfoCleared = cpaManager.getAuctionInfo(auctionId);
        assertEq(auctionInfoCleared.roundBids.length, 0, "Round bids should be cleared when starting clock phase");
    }

    // ============ EDGE CASES AND ERROR CONDITIONS ============

    function test_SubmitBid_ValidBidAmounts_ZeroDemands() public {
        // Start clock phase
        vm.prank(auctioneer);
        cpaManager.startClockRound(auctionId);

        // Create bidder and proxy
        address testBidder = makeAddr("testBidder");
        address testProxy = makeAddr("testProxy");
        createBidder(testBidder, 100000 * 10**18);

        // Generate commit hash
        bytes32 saltA = keccak256("saltA");
        bytes32 saltB = keccak256("saltB");
        bytes32 commitHash = CommitReveal.generateCommitHash(testBidder, testProxy, saltA, saltB);

        // Proxy commits
        vm.prank(testProxy);
        cpaManager.commitToBidder(auctionId, commitHash);

        // Test zero demands - should be valid (bidder doesn't want any assets)
        uint256[] memory zeroDemands = new uint256[](2);
        zeroDemands[0] = 0;
        zeroDemands[1] = 0;
        
        uint256 requiredStake = calculateBidValue(zeroDemands);
        approveNumeraireForBidder(testBidder, type(uint256).max);
        
        vm.prank(testBidder);
        cpaManager.submitBid(auctionId, zeroDemands, requiredStake);
        
        // Verify the zero bid was accepted
        AuctionTypes.AuctionInfo memory auctionInfoZero = cpaManager.getAuctionInfo(auctionId);
        assertEq(auctionInfoZero.roundBids.length, 1, "Should have 1 bid after zero demand submission");
        assertEq(auctionInfoZero.roundBids[0].quantities[0], 0, "First asset quantity should be 0");
        assertEq(auctionInfoZero.roundBids[0].quantities[1], 0, "Second asset quantity should be 0");
    }

    function test_SubmitBid_ValidBidAmounts_LargeDemands() public {
        // Start clock phase
        vm.prank(auctioneer);
        cpaManager.startClockRound(auctionId);

        // Create bidder and proxy
        address testBidder = makeAddr("testBidder");
        address testProxy = makeAddr("testProxy");
        createBidder(testBidder, type(uint256).max / 2); // Give bidder massive amount of numeraire

        // Generate commit hash
        bytes32 saltA = keccak256("saltA");
        bytes32 saltB = keccak256("saltB");
        bytes32 commitHash = CommitReveal.generateCommitHash(testBidder, testProxy, saltA, saltB);

        // Proxy commits
        vm.prank(testProxy);
        cpaManager.commitToBidder(auctionId, commitHash);

        // Test very large demands - should be valid but require large stake
        uint256[] memory largeDemands = new uint256[](2);
        largeDemands[0] = 1000000 * 10**18; // Large but reasonable
        largeDemands[1] = 500000 * 10**18;
        
        uint256 requiredStake = calculateBidValue(largeDemands) * 2;
        approveNumeraireForBidder(testBidder, type(uint256).max);
        
        vm.prank(testBidder);
        cpaManager.submitBid(auctionId, largeDemands, requiredStake);
        
        // Verify the large bid was accepted
        AuctionTypes.AuctionInfo memory auctionInfoLarge = cpaManager.getAuctionInfo(auctionId);
        assertEq(auctionInfoLarge.roundBids.length, 1, "Should have 1 bid after large demand submission");
    }


    function test_SubmitBid_BidderWithoutProxyCommitment() public {
        // Start clock phase
        vm.prank(auctioneer);
        cpaManager.startClockRound(auctionId);

        // Create bidder
        address testBidder = makeAddr("testBidder");
        createBidder(testBidder, 100000 * 10**18);

        // Generate commit hash but don't have proxy commit to it
        bytes32 saltA = keccak256("saltA");
        bytes32 saltB = keccak256("saltB");
        bytes32 commitHash = CommitReveal.generateCommitHash(testBidder, makeAddr("testProxy"), saltA, saltB);

        // Test with uncommitted hash
        uint256[] memory demands = new uint256[](2);
        demands[0] = 100 * 10**18;
        demands[1] = 50 * 10**18;
        
        uint256 requiredStake = calculateBidValue(demands) * 2;
        approveNumeraireForBidder(testBidder, type(uint256).max);
        
        vm.prank(testBidder);
        // This should succeed since the proxy commitment check is commented out
        cpaManager.submitBid(auctionId, demands, requiredStake);
    }

    function test_CommitToBidder_ProxyCommitsToMultipleBidders() public {
        // Start clock phase
        vm.prank(auctioneer);
        cpaManager.startClockRound(auctionId);

        // Create multiple bidders
        address bidder1 = makeAddr("bidder1");
        address bidder2 = makeAddr("bidder2");
        address testProxy = makeAddr("testProxy");
        createBidder(bidder1, 100000 * 10**18);
        createBidder(bidder2, 100000 * 10**18);

        // Generate commit hashes for both bidders
        bytes32 saltA1 = keccak256("saltA1");
        bytes32 saltB1 = keccak256("saltB1");
        bytes32 commitHash1 = CommitReveal.generateCommitHash(bidder1, testProxy, saltA1, saltB1);
        
        bytes32 saltA2 = keccak256("saltA2");
        bytes32 saltB2 = keccak256("saltB2");
        bytes32 commitHash2 = CommitReveal.generateCommitHash(bidder2, testProxy, saltA2, saltB2);

        // Proxy commits to both bidders - this should be allowed
        vm.prank(testProxy);
        cpaManager.commitToBidder(auctionId, commitHash1);
        
        vm.prank(testProxy);
        cpaManager.commitToBidder(auctionId, commitHash2);

        // Both bidders should be able to submit bids
        uint256[] memory demands1 = new uint256[](2);
        demands1[0] = 100 * 10**18;
        demands1[1] = 50 * 10**18;
        
        uint256[] memory demands2 = new uint256[](2);
        demands2[0] = 75 * 10**18;
        demands2[1] = 25 * 10**18;
        
        uint256 maxStake1 = calculateBidValue(demands1) * 2; // double the bid value to ensure both bidders have enough stake
        uint256 maxStake2 = calculateBidValue(demands2) * 2; // double the bid value to ensure both bidders have enough stake
        
        approveNumeraireForBidder(bidder1, type(uint256).max);
        approveNumeraireForBidder(bidder2, type(uint256).max);
        
        bytes32 partialCommit1 = CommitReveal.getBidderHash(bidder1, saltA1);
        
        vm.prank(bidder1);
        cpaManager.submitBid(auctionId, demands1, maxStake1);
        
        vm.prank(bidder2);
        cpaManager.submitBid(auctionId, demands2, maxStake2);
        
        // Verify both bids were accepted
        AuctionTypes.AuctionInfo memory auctionInfoBoth = cpaManager.getAuctionInfo(auctionId);
        assertEq(auctionInfoBoth.roundBids.length, 2, "Should have 2 bids after both bidders submit");
    }

    function test_SubmitBid_InsufficientMaxStake() public {
        // Start clock phase
        vm.prank(auctioneer);
        cpaManager.startClockRound(auctionId);

        // Create bidder with sufficient funds but low max stake
        address testBidder = makeAddr("testBidder");
        address testProxy = makeAddr("testProxy");
        createBidder(testBidder, 1000000 * 10**18); // Sufficient funds

        // Generate commit hash
        bytes32 saltA = keccak256("saltA");
        bytes32 saltB = keccak256("saltB");
        bytes32 commitHash = CommitReveal.generateCommitHash(testBidder, testProxy, saltA, saltB);

        // Proxy commits
        vm.prank(testProxy);
        cpaManager.commitToBidder(auctionId, commitHash);

        // Test with demands that require more stake than available
        uint256[] memory largeDemands = new uint256[](2);
        largeDemands[0] = 100000 * 10**18; // Very large demands
        largeDemands[1] = 50000 * 10**18;
        
        uint256 requiredStake = calculateBidValue(largeDemands);
        uint256 insufficientMaxStake = requiredStake - 1; // Max stake is less than required
        
        approveNumeraireForBidder(testBidder, type(uint256).max); // Approve enough tokens
        
        vm.prank(testBidder);
        vm.expectRevert(abi.encodeWithSelector(IErrorsAndEvents.MaxStakeTooLow.selector, auctionId));
        cpaManager.submitBid(auctionId, largeDemands, insufficientMaxStake); // But max stake is too low
    }

    function test_SubmitBid_NotInClockPhase() public {
        // Don't start clock phase - auction is still in Setup phase
        
        // Create bidder and proxy
        address testBidder = makeAddr("testBidder");
        address testProxy = makeAddr("testProxy");
        createBidder(testBidder, 100000 * 10**18);

        // Generate commit hash
        bytes32 saltA = keccak256("saltA");
        bytes32 saltB = keccak256("saltB");
        bytes32 commitHash = CommitReveal.generateCommitHash(testBidder, testProxy, saltA, saltB);

        // Proxy commits
        vm.prank(testProxy);
        cpaManager.commitToBidder(auctionId, commitHash);

        // Test bid submission when clock is not open
        uint256[] memory demands = new uint256[](2);
        demands[0] = 100 * 10**18;
        demands[1] = 50 * 10**18;
        
        uint256 requiredStake = calculateBidValue(demands);
        approveNumeraireForBidder(testBidder, type(uint256).max);
        
        vm.prank(testBidder);
        vm.expectRevert(abi.encodeWithSelector(IErrorsAndEvents.InvalidPhase.selector, uint8(AuctionTypes.AuctionPhase.Clock), uint8(AuctionTypes.AuctionPhase.Setup)));
        cpaManager.submitBid(auctionId, demands, requiredStake);
    }

    function test_SubmitBid_InvalidAuctionId() public {
        // Start clock phase
        vm.prank(auctioneer);
        cpaManager.startClockRound(auctionId);

        // Create bidder and proxy
        address testBidder = makeAddr("testBidder");
        address testProxy = makeAddr("testProxy");
        createBidder(testBidder, 100000 * 10**18);

        // Generate commit hash
        bytes32 saltA = keccak256("saltA");
        bytes32 saltB = keccak256("saltB");
        bytes32 commitHash = CommitReveal.generateCommitHash(testBidder, testProxy, saltA, saltB);

        // Proxy commits
        vm.prank(testProxy);
        cpaManager.commitToBidder(auctionId, commitHash);

        // Test with invalid auction ID
        AuctionId invalidAuctionId = AuctionId.wrap(bytes32(keccak256("invalidAuctionId")));
        
        uint256[] memory demands = new uint256[](2);
        demands[0] = 100 * 10**18;
        demands[1] = 50 * 10**18;
        
        uint256 requiredStake = calculateBidValue(demands);
        approveNumeraireForBidder(testBidder, type(uint256).max);
        
        vm.prank(testBidder);
        vm.expectRevert(); // Should revert due to invalid auction
        cpaManager.submitBid(invalidAuctionId, demands, requiredStake);
    }
}
