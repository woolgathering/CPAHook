// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { Test, console } from "forge-std/Test.sol";
import { CPATestBase6Decimals } from "./base/CPATestBase6Decimals.sol";
import { AuctionTypes } from "../src/types/AuctionTypes.sol";
import { AuctionId } from "../src/types/AuctionId.sol";
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { Currency, CurrencyLibrary } from "@uniswap/v4-core/src/types/Currency.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC6909Claims } from "@uniswap/v4-core/src/interfaces/external/IERC6909Claims.sol";

/**
 * @title CPAClock6DecimalsTest
 * @notice Tests clock phase functionality with 6-decimal numeraire and mixed asset decimals
 * @dev Verifies that bid value calculations, stake management, and price updates work correctly
 *      with non-18-decimal tokens, ensuring proper decimal conversion formulas.
 */
contract CPAClock6DecimalsTest is CPATestBase6Decimals {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    function setUp() public override {
        super.setUp();
        // Additional setup for 6-decimal tests if needed
    }

    // ============ Bid Points Tests ============

    function test_BidPoints_6DecimalNumeraire() public {
        // Setup complete auction (this will create auction with 6-decimal numeraire)
        auctionId = setupCompleteAuction();
        
        // Setup bidder with sufficient numeraire
        uint256 bidderAmount = 10000 * 10**6; // 10k USDC (6 decimals)
        createBidder(bidder1, bidderAmount);
        approveNumeraireForBidder(bidder1, type(uint256).max);
        
        // Submit bid to test actual bid points calculation
        uint256[] memory demands = new uint256[](2);
        demands[0] = 100 * 10**18; // 100 Asset1 (18 decimals)
        demands[1] = 50 * 10**6; // 50 Asset2 (6 decimals)
        
        // This will call the actual computeBidPoints function in context
        vm.prank(bidder1);
        cpaManager.submitBid(auctionId, demands, type(uint256).max);
        
        // Calculate expected bid value using the updated test base function
        // This now uses the same decimal conversion formula as the contract
        uint256 expectedBidValue = calculateBidValue(demands);
        
        // Expected bid points: bidValue * 10^18 / 10^6 = bidValue * 10^12
        uint256 expectedBidPoints = expectedBidValue * 10**12; // 200 * 10^18
        
        // Get the actual bid points from the contract
        uint256 actualBidPoints = cpaManager.bidderBidPoints(auctionId, bidder1);
        
        // Precise assertion
        assertEq(actualBidPoints, expectedBidPoints, "Bid points should be calculated correctly for 6-decimal numeraire");
    }

    // ============ Bid Value Calculation Tests ============

    function test_BidValue_MixedAssets() public {
        // Test with both 18-decimal and 6-decimal assets in same bid using real auction
        auctionId = setupCompleteAuction();
        
        // Setup bidder with sufficient numeraire
        uint256 bidderAmount = 10000 * 10**6; // 10k USDC (6 decimals)
        createBidder(bidder1, bidderAmount);
        approveNumeraireForBidder(bidder1, type(uint256).max);
        
        // Submit bid with mixed decimal assets
        uint256[] memory demands = new uint256[](2);
        demands[0] = 500 * 10**18; // 500 tokens of 18-decimal asset
        demands[1] = 1000 * 10**6; // 1000 tokens of 6-decimal asset
        
        // Calculate expected bid value using the test base function
        uint256 expectedBidValue = calculateBidValue(demands);
        
        // Submit the bid to test actual bid value calculation
        vm.prank(bidder1);
        cpaManager.submitBid(auctionId, demands, type(uint256).max);
        
        // Get the actual bid points from the contract
        uint256 actualBidPoints = cpaManager.bidderBidPoints(auctionId, bidder1);
        
        // Calculate expected bid points: bidValue * 10^18 / 10^6 = bidValue * 10^12
        uint256 expectedBidPoints = expectedBidValue * 10**12;
        
        // Precise assertions
        assertEq(actualBidPoints, expectedBidPoints, "Mixed assets bid points should be calculated correctly");
        assertEq(actualBidPoints, expectedBidValue * 10**12, "Bid points should match expected calculation");
        
        console.log("Expected bid value (6 decimals):", expectedBidValue);
        console.log("Expected bid points (18 decimals):", expectedBidPoints);
        console.log("Actual bid points (18 decimals):", actualBidPoints);
    }

    // ============ Stake Management Tests ============

    function test_StakeManagement_MixedDecimals() public {
        // Test stake deposits, tracking, and refunds with 6-decimal numeraire
        auctionId = setupCompleteAuction();
        
        // Setup bidder with initial numeraire
        uint256 initialBidderAmount = 10000 * 10**6; // 10k USDC (6 decimals)
        createBidder(bidder1, initialBidderAmount);
        approveNumeraireForBidder(bidder1, type(uint256).max);
        
        // Record initial balances
        uint256 initialBidderERC20 = numeraireToken.balanceOf(bidder1);
        uint256 initialCPAManagerERC20 = numeraireToken.balanceOf(address(cpaManager));
        uint256 initialPoolManagerERC20 = numeraireToken.balanceOf(address(poolManager));
        
        console.log("=== INITIAL BALANCES ===");
        console.log("Bidder ERC20:", initialBidderERC20);
        console.log("CPAManager ERC20:", initialCPAManagerERC20);
        console.log("PoolManager ERC20:", initialPoolManagerERC20);
        
        // Submit first bid with mixed decimal assets
        uint256[] memory demands1 = new uint256[](2);
        demands1[0] = 100 * 10**18; // 100 Asset1 (18 decimals)
        demands1[1] = 50 * 10**6; // 50 Asset2 (6 decimals)
        
        // Calculate expected bid value
        uint256 expectedBidValue1 = calculateBidValue(demands1);
        
        // Get allocator fee percentage from auction config
        AuctionTypes.AuctionInfo memory auctionInfo = cpaManager.getAuctionInfo(auctionId);
        uint256 allocatorRewardPct = auctionInfo.config.allocatorRewardPct;
        
        // Calculate allocator fee from config
        uint256 allocatorFee1 = (expectedBidValue1 * allocatorRewardPct) / 10000;
        uint256 totalTransfer1 = expectedBidValue1 + allocatorFee1;
        
        vm.prank(bidder1);
        cpaManager.submitBid(auctionId, demands1, type(uint256).max);
        
        console.log("=== AFTER FIRST BID ===");
        console.log("Bidder ERC20:", numeraireToken.balanceOf(bidder1));
        console.log("CPAManager ERC20:", numeraireToken.balanceOf(address(cpaManager)));
        console.log("PoolManager ERC20:", numeraireToken.balanceOf(address(poolManager)));
        
        // Verify stake tracking
        uint256 actualBidderStake = cpaManager.bidderStake(auctionId, bidder1);
        uint256 actualBidPoints = cpaManager.bidderBidPoints(auctionId, bidder1);
        
        console.log("Expected bid value (6 decimals):", expectedBidValue1);
        console.log("Allocator fee (6 decimals):", allocatorFee1);
        console.log("Total transfer (6 decimals):", totalTransfer1);
        console.log("Actual bidder stake (6 decimals):", actualBidderStake);
        console.log("Actual bid points (18 decimals):", actualBidPoints);
        
        // Assertions for first bid
        assertEq(actualBidderStake, expectedBidValue1, "Bidder stake should equal bid value");
        assertEq(actualBidPoints, expectedBidValue1 * 10**12, "Bid points should be bid value * 10^12");
        
        // Verify ERC20 balance changes (bidder loses total transfer, PoolManager gets total transfer, CPAManager gets 0 ERC20)
        assertEq(numeraireToken.balanceOf(bidder1), initialBidderERC20 - totalTransfer1, "Bidder ERC20 should decrease by total transfer");
        assertEq(numeraireToken.balanceOf(address(cpaManager)), 0, "CPAManager ERC20 should remain 0");
        assertEq(numeraireToken.balanceOf(address(poolManager)), initialPoolManagerERC20 + totalTransfer1, "PoolManager ERC20 should increase by total transfer");
        
        // Verify ERC6909 balance changes (CPAManager gets claims for total transfer amount)
        assertEq(IERC6909Claims(address(poolManager)).balanceOf(bidder1, numeraireCurrencyId), 0, "Bidder ERC6909 should not change");
        assertEq(IERC6909Claims(address(poolManager)).balanceOf(address(cpaManager), numeraireCurrencyId), totalTransfer1, "CPAManager ERC6909 should increase by total transfer");
        assertEq(IERC6909Claims(address(poolManager)).balanceOf(address(poolManager), numeraireCurrencyId), 0, "PoolManager ERC6909 should not change");
        
        // Submit second bid with increased demand
        uint256[] memory demands2 = new uint256[](2);
        demands2[0] = 150 * 10**18; // 150 Asset1 (18 decimals)
        demands2[1] = 50 * 10**6; // 50 Asset2 (6 decimals)
        
        // Calculate expected bid value for second bid
        uint256 expectedBidValue2 = calculateBidValue(demands2);
        uint256 additionalStakeRequired = expectedBidValue2 - expectedBidValue1;
        
        // Calculate allocator fee for additional stake using config
        uint256 additionalAllocatorFee = (additionalStakeRequired * allocatorRewardPct) / 10000;
        uint256 totalAdditionalTransfer = additionalStakeRequired + additionalAllocatorFee;
        uint256 totalTransfer2 = expectedBidValue2 + (expectedBidValue2 * allocatorRewardPct) / 10000; // Total for second bid
        
        vm.prank(bidder1);
        cpaManager.submitBid(auctionId, demands2, type(uint256).max);
        
        console.log("=== AFTER SECOND BID ===");
        console.log("Bidder ERC20:", numeraireToken.balanceOf(bidder1));
        console.log("CPAManager ERC20:", numeraireToken.balanceOf(address(cpaManager)));
        console.log("PoolManager ERC20:", numeraireToken.balanceOf(address(poolManager)));
        
        // Verify stake tracking after second bid
        uint256 actualBidderStake2 = cpaManager.bidderStake(auctionId, bidder1);
        uint256 actualBidPoints2 = cpaManager.bidderBidPoints(auctionId, bidder1);
        
        console.log("Expected bid value 2 (6 decimals):", expectedBidValue2);
        console.log("Additional stake required (6 decimals):", additionalStakeRequired);
        console.log("Additional allocator fee (6 decimals):", additionalAllocatorFee);
        console.log("Total additional transfer (6 decimals):", totalAdditionalTransfer);
        console.log("Actual bidder stake 2 (6 decimals):", actualBidderStake2);
        console.log("Actual bid points 2 (18 decimals):", actualBidPoints2);
        
        // Assertions for second bid
        assertEq(actualBidderStake2, expectedBidValue2, "Bidder stake should equal new bid value");
        assertEq(actualBidPoints2, expectedBidValue2 * 10**12, "Bid points should be new bid value * 10^12");
        
        // Verify ERC20 balance changes for second bid
        assertEq(numeraireToken.balanceOf(bidder1), initialBidderERC20 - totalTransfer2, "Bidder ERC20 should decrease by total transfer");
        assertEq(numeraireToken.balanceOf(address(cpaManager)), 0, "CPAManager ERC20 should remain 0");
        assertEq(numeraireToken.balanceOf(address(poolManager)), initialPoolManagerERC20 + totalTransfer2, "PoolManager ERC20 should increase by total transfer");
        
        // Verify ERC6909 balance changes for second bid
        assertEq(IERC6909Claims(address(poolManager)).balanceOf(bidder1, numeraireCurrencyId), 0, "Bidder ERC6909 should not change");
        assertEq(IERC6909Claims(address(poolManager)).balanceOf(address(cpaManager), numeraireCurrencyId), totalTransfer2, "CPAManager ERC6909 should increase by total transfer");
        assertEq(IERC6909Claims(address(poolManager)).balanceOf(address(poolManager), numeraireCurrencyId), 0, "PoolManager ERC6909 should not change");
        
        // Submit third bid with decreased demand (stake should not decrease)
        uint256[] memory demands3 = new uint256[](2);
        demands3[0] = 120 * 10**18; // 120 Asset1 (18 decimals)
        demands3[1] = 50 * 10**6; // 50 Asset2 (6 decimals)
        
        // Calculate expected bid value for third bid
        uint256 expectedBidValue3 = calculateBidValue(demands3);
        
        vm.prank(bidder1);
        cpaManager.submitBid(auctionId, demands3, type(uint256).max);
        
        console.log("=== AFTER THIRD BID (DECREASED DEMAND) ===");
        console.log("Bidder ERC20:", numeraireToken.balanceOf(bidder1));
        console.log("CPAManager ERC20:", numeraireToken.balanceOf(address(cpaManager)));
        console.log("PoolManager ERC20:", numeraireToken.balanceOf(address(poolManager)));
        
        // Verify stake tracking after third bid
        uint256 actualBidderStake3 = cpaManager.bidderStake(auctionId, bidder1);
        uint256 actualBidPoints3 = cpaManager.bidderBidPoints(auctionId, bidder1);
        
        console.log("Expected bid value 3 (6 decimals):", expectedBidValue3);
        console.log("Actual bidder stake 3 (6 decimals):", actualBidderStake3);
        console.log("Actual bid points 3 (18 decimals):", actualBidPoints3);
        
        // Assertions for third bid - stake should not decrease
        assertEq(actualBidderStake3, expectedBidValue2, "Bidder stake should not decrease on reduced bid");
        assertEq(actualBidPoints3, expectedBidValue2 * 10**12, "Bid points should not decrease on reduced bid");
        
        // Verify ERC20 balance changes for third bid (should not change since no additional stake required)
        assertEq(numeraireToken.balanceOf(bidder1), initialBidderERC20 - totalTransfer2, "Bidder ERC20 should not change on reduced bid");
        assertEq(numeraireToken.balanceOf(address(cpaManager)), 0, "CPAManager ERC20 should remain 0");
        assertEq(numeraireToken.balanceOf(address(poolManager)), initialPoolManagerERC20 + totalTransfer2, "PoolManager ERC20 should not change on reduced bid");
        
        // Verify ERC6909 balance changes for third bid (should not change)
        assertEq(IERC6909Claims(address(poolManager)).balanceOf(bidder1, numeraireCurrencyId), 0, "Bidder ERC6909 should not change on reduced bid");
        assertEq(IERC6909Claims(address(poolManager)).balanceOf(address(cpaManager), numeraireCurrencyId), totalTransfer2, "CPAManager ERC6909 should not change on reduced bid");
        assertEq(IERC6909Claims(address(poolManager)).balanceOf(address(poolManager), numeraireCurrencyId), 0, "PoolManager ERC6909 should not change on reduced bid");
    }

    function test_StakeRefund_6DecimalNumeraire() public {
        // Test actual dropout mechanism with 6-decimal numeraire and penalty from config
        auctionId = setupCompleteAuction();
        
        // Setup bidder with sufficient numeraire
        uint256 bidderAmount = 10000 * 10**6; // 10k USDC (6 decimals)
        createBidder(bidder1, bidderAmount);
        approveNumeraireForBidder(bidder1, type(uint256).max);
        
        // Submit bid to create stake
        uint256[] memory demands = new uint256[](2);
        demands[0] = 100 * 10**18; // 100 Asset1 (18 decimals)
        demands[1] = 50 * 10**6; // 50 Asset2 (6 decimals)
        
        vm.prank(bidder1);
        cpaManager.submitBid(auctionId, demands, type(uint256).max);
        
        // Get actual stake amount and auction config
        uint256 actualStake = cpaManager.bidderStake(auctionId, bidder1);
        AuctionTypes.AuctionInfo memory auctionInfo = cpaManager.getAuctionInfo(auctionId);
        uint256 dropoutSlashRatio = auctionInfo.config.dropoutSlashRatio;
        
        // Calculate expected penalty and refund using config
        uint256 expectedPenalty = (actualStake * dropoutSlashRatio) / 10000;
        uint256 expectedRefund = actualStake - expectedPenalty;
        
        console.log("=== BEFORE DROPOUT ===");
        console.log("Actual stake (6 decimals):", actualStake);
        console.log("Dropout slash ratio (basis points):", dropoutSlashRatio);
        console.log("Expected penalty (6 decimals):", expectedPenalty);
        console.log("Expected refund (6 decimals):", expectedRefund);
        
        // Record initial balances
        uint256 initialBidderERC20 = numeraireToken.balanceOf(bidder1);
        uint256 initialProtocolPenalties = cpaManager.protocolPenalties(auctionId);
        uint256 initialCPAManagerERC6909 = IERC6909Claims(address(poolManager)).balanceOf(address(cpaManager), numeraireCurrencyId);
        uint256 initialPoolManagerERC20 = numeraireToken.balanceOf(address(poolManager));
        
        console.log("Initial bidder ERC20:", initialBidderERC20);
        console.log("Initial protocol penalties:", initialProtocolPenalties);
        console.log("Initial CPAManager ERC6909:", initialCPAManagerERC6909);
        console.log("Initial PoolManager ERC20:", initialPoolManagerERC20);
        
        // Perform dropout
        vm.prank(bidder1);
        cpaManager.dropout(auctionId);
        
        // Record final balances
        uint256 finalBidderERC20 = numeraireToken.balanceOf(bidder1);
        uint256 finalProtocolPenalties = cpaManager.protocolPenalties(auctionId);
        uint256 finalCPAManagerERC6909 = IERC6909Claims(address(poolManager)).balanceOf(address(cpaManager), numeraireCurrencyId);
        uint256 finalPoolManagerERC20 = numeraireToken.balanceOf(address(poolManager));
        
        console.log("=== AFTER DROPOUT ===");
        console.log("Final bidder ERC20:", finalBidderERC20);
        console.log("Final protocol penalties:", finalProtocolPenalties);
        console.log("Final CPAManager ERC6909:", finalCPAManagerERC6909);
        console.log("Final PoolManager ERC20:", finalPoolManagerERC20);
        
        // Verify bidder stake is cleared
        uint256 bidderStakeAfter = cpaManager.bidderStake(auctionId, bidder1);
        uint256 bidderBidPointsAfter = cpaManager.bidderBidPoints(auctionId, bidder1);
        
        console.log("Bidder stake after dropout:", bidderStakeAfter);
        console.log("Bidder bid points after dropout:", bidderBidPointsAfter);
        
        // Verify penalty calculation
        uint256 actualPenalty = finalProtocolPenalties - initialProtocolPenalties;
        assertEq(actualPenalty, expectedPenalty, "Penalty should match expected calculation from config");
        
        // Verify refund amount
        uint256 actualRefund = finalBidderERC20 - initialBidderERC20;
        assertEq(actualRefund, expectedRefund, "Refund should match expected calculation");
        
        // Verify bidder stake is cleared
        assertEq(bidderStakeAfter, 0, "Bidder stake should be 0 after dropout");
        assertEq(bidderBidPointsAfter, 0, "Bidder bid points should be 0 after dropout");
        
        // Verify ERC6909 claims are reduced by refund amount only (allocator fee remains)
        uint256 expectedERC6909Reduction = expectedRefund; // Only refund amount is returned, allocator fee stays
        uint256 actualERC6909Reduction = initialCPAManagerERC6909 - finalCPAManagerERC6909;
        assertEq(actualERC6909Reduction, expectedERC6909Reduction, "ERC6909 claims should be reduced by refund amount only");
        
        // Verify PoolManager ERC20 is reduced by refund amount
        uint256 expectedPoolManagerReduction = expectedRefund;
        uint256 actualPoolManagerReduction = initialPoolManagerERC20 - finalPoolManagerERC20;
        assertEq(actualPoolManagerReduction, expectedPoolManagerReduction, "PoolManager ERC20 should be reduced by refund amount");
        
        console.log("Actual penalty (6 decimals):", actualPenalty);
        console.log("Actual refund (6 decimals):", actualRefund);
        console.log("ERC6909 reduction:", actualERC6909Reduction);
        console.log("PoolManager ERC20 reduction:", actualPoolManagerReduction);
    }

    // ============ Price Update Tests ============

    function test_PriceUpdate_MixedDecimals() public {
        // Test that price updates work correctly with mixed decimal assets
        auctionId = setupCompleteAuction();
        
        // Setup bidders with sufficient numeraire
        uint256 bidderAmount = type(uint256).max / 2; // 10k USDC (6 decimals)
        createBidder(bidder1, bidderAmount);
        createBidder(bidder2, bidderAmount);
        approveNumeraireForBidder(bidder1, type(uint256).max);
        approveNumeraireForBidder(bidder2, type(uint256).max);
        
        // Get initial pool states
        PoolId asset1PoolId = asset1PoolKey.toId();
        PoolId asset2PoolId = asset2PoolKey.toId();
        
        (, int24 asset1InitialTick, , ) = poolManager.getSlot0(asset1PoolId);
        (, int24 asset2InitialTick, , ) = poolManager.getSlot0(asset2PoolId);
        
        console.log("=== INITIAL PRICES ===");
        console.log("Asset1 initial tick:", asset1InitialTick);
        console.log("Asset2 initial tick:", asset2InitialTick);
        
        // Get actual deposit amounts from the auction
        (,,,uint256 asset1Deposit, , , , ) = cpaManager.getPoolInfo(asset1PoolId);
        (,,,uint256 asset2Deposit, , , , ) = cpaManager.getPoolInfo(asset2PoolId);
        
        console.log("=== ACTUAL DEPOSIT AMOUNTS ===");
        console.log("Asset1 deposit:", asset1Deposit);
        console.log("Asset2 deposit:", asset2Deposit);
        
        // Submit bids that create excess demand for both assets
        // Use 60% of deposit amount to create excess demand
        uint256[] memory demands1 = new uint256[](2);
        demands1[0] = (asset1Deposit * 60) / 100; // 60% of Asset1 deposit
        demands1[1] = (asset2Deposit * 60) / 100; // 60% of Asset2 deposit
        
        uint256[] memory demands2 = new uint256[](2);
        demands2[0] = (asset1Deposit * 60) / 100; // 60% of Asset1 deposit - total 120%
        demands2[1] = (asset2Deposit * 60) / 100; // 60% of Asset2 deposit - total 120%

        approveNumeraireForBidder(bidder1, type(uint256).max);
        approveNumeraireForBidder(bidder2, type(uint256).max);
        
        vm.prank(bidder1);
        cpaManager.submitBid(auctionId, demands1, type(uint256).max);
        
        vm.prank(bidder2);
        cpaManager.submitBid(auctionId, demands2, type(uint256).max);
        
        console.log("=== AFTER BIDS SUBMITTED ===");
        console.log("Total Asset1 demand:", (asset1Deposit * 120) / 100);
        console.log("Total Asset2 demand:", (asset2Deposit * 120) / 100);
        console.log("Asset1 deposit:", asset1Deposit);
        console.log("Asset2 deposit:", asset2Deposit);
        
        // End round 1 - should create excess demand and increase prices
        endClockRound(auctionId);
        
        // Get pool info after price update
        (,,,uint256 asset1Deposit1, int256 asset1ExcessDemand1, int24 asset1LastOversoldTick1, AuctionId asset1AuctionId1, uint256 asset1PositionId1) = cpaManager.getPoolInfo(asset1PoolId);
        (,,,uint256 asset2Deposit1, int256 asset2ExcessDemand1, int24 asset2LastOversoldTick1, AuctionId asset2AuctionId1, uint256 asset2PositionId1) = cpaManager.getPoolInfo(asset2PoolId);
        
        // Get new tick values
        (, int24 asset1Tick1, , ) = poolManager.getSlot0(asset1PoolId);
        (, int24 asset2Tick1, , ) = poolManager.getSlot0(asset2PoolId);
        
        console.log("=== AFTER PRICE UPDATE ===");
        console.log("Asset1 excess demand:", asset1ExcessDemand1);
        console.log("Asset2 excess demand:", asset2ExcessDemand1);
        console.log("Asset1 new tick:", asset1Tick1);
        console.log("Asset2 new tick:", asset2Tick1);
        console.log("Asset1 tick change:", int256(asset1Tick1) - int256(asset1InitialTick));
        console.log("Asset2 tick change:", int256(asset2Tick1) - int256(asset2InitialTick));
        
        // Calculate actual total demand from the bids we submitted
        uint256 totalAsset1Demand = demands1[0] + demands2[0];
        uint256 totalAsset2Demand = demands1[1] + demands2[1];
        
        // Calculate expected excess demand (total demand - deposit)
        int256 expectedAsset1Excess = int256(totalAsset1Demand) - int256(asset1Deposit);
        int256 expectedAsset2Excess = int256(totalAsset2Demand) - int256(asset2Deposit);
        
        console.log("=== EXPECTED VS ACTUAL EXCESS DEMAND ===");
        console.log("Total Asset1 demand:", totalAsset1Demand);
        console.log("Asset1 deposit:", asset1Deposit);
        console.log("Expected Asset1 excess:", expectedAsset1Excess);
        console.log("Actual Asset1 excess:", asset1ExcessDemand1);
        console.log("Total Asset2 demand:", totalAsset2Demand);
        console.log("Asset2 deposit:", asset2Deposit);
        console.log("Expected Asset2 excess:", expectedAsset2Excess);
        console.log("Actual Asset2 excess:", asset2ExcessDemand1);
        
        // Verify excess demand calculations with mixed decimals
        assertEq(asset1ExcessDemand1, expectedAsset1Excess, "Asset1 excess demand should match calculated demand minus deposit");
        assertEq(asset2ExcessDemand1, expectedAsset2Excess, "Asset2 excess demand should match calculated demand minus deposit");
        
        // Verify price changes based on excess demand
        if (totalAsset1Demand > asset1Deposit) {
            assertGt(asset1Tick1, asset1InitialTick, "Asset1 price should have increased due to excess demand");
        } else {
            assertEq(asset1Tick1, asset1InitialTick, "Asset1 price should remain unchanged when demand <= supply");
        }
        
        if (totalAsset2Demand > asset2Deposit) {
            assertGt(asset2Tick1, asset2InitialTick, "Asset2 price should have increased due to excess demand");
        } else {
            assertEq(asset2Tick1, asset2InitialTick, "Asset2 price should remain unchanged when demand <= supply");
        }
        
        // Test price update with different decimal precisions
        console.log("=== TESTING DECIMAL PRECISION HANDLING ===");
        
        // Calculate expected price changes using the price increment from config
        AuctionTypes.AuctionInfo memory auctionInfo = cpaManager.getAuctionInfo(auctionId);
        int24 asset1PriceIncrement = auctionInfo.config.priceIncrements[0];
        int24 asset2PriceIncrement = auctionInfo.config.priceIncrements[1];
        
        console.log("Asset1 price increment:", asset1PriceIncrement);
        console.log("Asset2 price increment:", asset2PriceIncrement);
        
        // Verify tick changes match expected increments
        int256 expectedAsset1TickChange = int256(asset1PriceIncrement);
        int256 expectedAsset2TickChange = int256(asset2PriceIncrement);
        
        assertEq(int256(asset1Tick1) - int256(asset1InitialTick), expectedAsset1TickChange, "Asset1 tick change should match price increment");
        assertEq(int256(asset2Tick1) - int256(asset2InitialTick), expectedAsset2TickChange, "Asset2 tick change should match price increment");
        
        // Test that price updates work correctly regardless of decimal precision
        console.log("=== DECIMAL PRECISION VERIFICATION ===");
        console.log("Asset1 (18 decimals) price update successful");
        console.log("Asset2 (6 decimals) price update successful");
        console.log("Both assets handled mixed decimal precisions correctly");
        
        // Verify that the price update mechanism works with mixed decimals
        // by checking that the excess demand calculation is correct
        // We already computed totalAsset1Demand and totalAsset2Demand above
        assertEq(uint256(asset1ExcessDemand1), totalAsset1Demand - asset1Deposit, "Asset1 excess demand calculation should be correct with 18 decimals");
        assertEq(uint256(asset2ExcessDemand1), totalAsset2Demand - asset2Deposit, "Asset2 excess demand calculation should be correct with 6 decimals");
        
        console.log("Price update test with mixed decimals completed successfully");
        console.log("Both 18-decimal and 6-decimal assets handled correctly");
    }

    // ============ Edge Case Tests ============

    function test_EdgeCase_ZeroDemand() public {
        // Test behavior when bidders submit zero demand for assets
        auctionId = setupCompleteAuction();
    
        // Setup bidder
        createBidder(bidder1, type(uint256).max);
        approveNumeraireForBidder(bidder1, type(uint256).max);
        
        // Submit bid with zero demand for both assets
        uint256[] memory demands = new uint256[](2);
        demands[0] = 0; // Zero demand for Asset1
        demands[1] = 0; // Zero demand for Asset2
        
        vm.prank(bidder1);
        cpaManager.submitBid(auctionId, demands, type(uint256).max);
        
        // Calculate expected bid value (should be 0)
        uint256 expectedBidValue = calculateBidValue(demands);
        uint256 expectedBidPoints = expectedBidValue * 10**12;
        
        // Get actual bid points
        uint256 actualBidPoints = cpaManager.bidderBidPoints(auctionId, bidder1);
        
        // Verify bid points are correct
        assertEq(actualBidPoints, expectedBidPoints, "Bid points should be 0 for zero demand");
        assertEq(actualBidPoints, 0, "Bid points should be 0 for zero demand");
        
        console.log("Zero demand test completed successfully");
    }

    function test_EdgeCase_MaximalDemand() public {
        // Test behavior with very large demand amounts
        auctionId = setupCompleteAuction();
        
        // Setup bidder with massive numeraire balance
        createBidder(bidder1, type(uint256).max);
        approveNumeraireForBidder(bidder1, type(uint256).max);
        
        // Submit bid with very large demand amounts
        uint256[] memory demands = new uint256[](2);
        demands[0] = 1e30; // Very large 18-decimal amount
        demands[1] = 1e18; // Very large 6-decimal amount
        
        vm.prank(bidder1);
        cpaManager.submitBid(auctionId, demands, type(uint256).max);
        
        // Calculate expected bid value
        uint256 expectedBidValue = calculateBidValue(demands);
        uint256 expectedBidPoints = expectedBidValue * 10**12;
        
        // Get actual bid points
        uint256 actualBidPoints = cpaManager.bidderBidPoints(auctionId, bidder1);
        
        // Verify bid points are correct
        assertEq(actualBidPoints, expectedBidPoints, "Bid points should be calculated correctly for large demands");
        
        console.log("Maximal demand test completed successfully");
    }

    function testFuzz_EdgeCase_PreciseDemand(uint256 asset1Demand, uint256 asset2Demand) public {
        // Fuzz test with random demand amounts
        // Bound the inputs to reasonable ranges to avoid overflow
        asset1Demand = bound(asset1Demand, 0, 1e24); // 0 to 1M tokens (18 decimals)
        asset2Demand = bound(asset2Demand, 0, 1e12); // 0 to 1M tokens (6 decimals)
        
        auctionId = setupCompleteAuction();
        
        // Setup bidder
        createBidder(bidder1, type(uint256).max);
        approveNumeraireForBidder(bidder1, type(uint256).max);
        
        // Submit bid with fuzzed demand amounts
        uint256[] memory demands = new uint256[](2);
        demands[0] = asset1Demand; // Fuzzed Asset1 demand (18 decimals)
        demands[1] = asset2Demand; // Fuzzed Asset2 demand (6 decimals)
        
        vm.prank(bidder1);
        cpaManager.submitBid(auctionId, demands, type(uint256).max);
        
        // Calculate expected bid value
        uint256 expectedBidValue = calculateBidValue(demands);
        uint256 expectedBidPoints = expectedBidValue * 10**12;
        
        // Get actual bid points
        uint256 actualBidPoints = cpaManager.bidderBidPoints(auctionId, bidder1);
        
        // Verify bid points are correct
        assertEq(actualBidPoints, expectedBidPoints, "Bid points should be calculated correctly for fuzzed demands");
        
        console.log("Fuzz test completed with Asset1 demand:", asset1Demand);
        console.log("Fuzz test completed with Asset2 demand:", asset2Demand);
    }

    function test_EdgeCase_SingleAssetDemand() public {
        // Test behavior when demand is only for one asset (mixed decimal scenario)
        auctionId = setupCompleteAuction();
        
        // Setup bidder
        createBidder(bidder1, type(uint256).max);
        approveNumeraireForBidder(bidder1, type(uint256).max);
        
        // Submit bid with demand only for Asset1 (18 decimals)
        uint256[] memory demands = new uint256[](2);
        demands[0] = 1000 * 10**18; // 1000 Asset1 (18 decimals)
        demands[1] = 0; // No demand for Asset2
        
        vm.prank(bidder1);
        cpaManager.submitBid(auctionId, demands, type(uint256).max);
        
        // Calculate expected bid value
        uint256 expectedBidValue = calculateBidValue(demands);
        uint256 expectedBidPoints = expectedBidValue * 10**12;
        
        // Get actual bid points
        uint256 actualBidPoints = cpaManager.bidderBidPoints(auctionId, bidder1);
        
        // Verify bid points are correct
        assertEq(actualBidPoints, expectedBidPoints, "Bid points should be calculated correctly for single asset demand");
        
        console.log("Single asset demand test completed successfully");
    }

    function test_EdgeCase_VerySmallAmounts() public {
        // Test with very small amounts to ensure precision is maintained
        auctionId = setupCompleteAuction();
        
        // Setup bidder
        createBidder(bidder1, type(uint256).max);
        approveNumeraireForBidder(bidder1, type(uint256).max);
        
        // Submit bid with very small amounts
        uint256[] memory demands = new uint256[](2);
        demands[0] = 1; // 1 wei for 18-decimal asset
        demands[1] = 1; // 1 unit for 6-decimal asset
        
        vm.prank(bidder1);
        cpaManager.submitBid(auctionId, demands, type(uint256).max);
        
        // Calculate expected bid value
        uint256 expectedBidValue = calculateBidValue(demands);
        uint256 expectedBidPoints = expectedBidValue * 10**12;
        
        // Get actual bid points
        uint256 actualBidPoints = cpaManager.bidderBidPoints(auctionId, bidder1);
        
        // Verify bid points are correct
        assertEq(actualBidPoints, expectedBidPoints, "Bid points should be calculated correctly for very small amounts");
        
        console.log("Very small amounts test completed successfully");
    }
}
