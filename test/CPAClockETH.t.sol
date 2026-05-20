// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { Test, console } from "forge-std/Test.sol";
import { CPATestBaseETH } from "./base/CPATestBaseETH.sol";
import { AuctionTypes } from "../src/types/AuctionTypes.sol";
import { AuctionId } from "../src/types/AuctionId.sol";
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { Currency, CurrencyLibrary } from "@uniswap/v4-core/src/types/Currency.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC6909Claims } from "@uniswap/v4-core/src/interfaces/external/IERC6909Claims.sol";
import { IErrorsAndEvents } from "../src/utils/IErrorsAndEvents.sol";

/**
 * @title CPAClockETHTest
 * @notice Tests clock phase functionality with ETH as numeraire and ERC20 assets
 * @dev Verifies that ETH handling, stake management, and price updates work correctly
 *      with native ETH as numeraire and standard ERC20 assets.
 */
contract CPAClockETHTest is CPATestBaseETH {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    uint256 public constant BIDDER_AMOUNT = 10000 ether;

    function setUp() public override {
        super.setUp();
        // Additional setup for ETH tests if needed
    }

    // ============ ETH Balance Tests ============

    function test_ETHBalanceChecks() public {
        // Test ETH balance tracking instead of ERC20 balanceOf()
        auctionId = setupCompleteAuction();
        
        // Setup bidder with ETH (using vm.deal instead of token.mint)
        uint256 bidderAmount = BIDDER_AMOUNT; // 100 ETH
        vm.deal(bidder1, bidderAmount);
        
        // Record initial ETH balances
        uint256 initialBidderETH = bidder1.balance;
        uint256 initialCPAManagerETH = address(cpaManager).balance;
        uint256 initialPoolManagerETH = address(poolManager).balance;
        
        console.log("=== INITIAL ETH BALANCES ===");
        console.log("Bidder ETH:", initialBidderETH);
        console.log("CPAManager ETH:", initialCPAManagerETH);
        console.log("PoolManager ETH:", initialPoolManagerETH);
        
        // Submit bid with ETH (msg.value)
        uint256[] memory demands = new uint256[](2);
        demands[0] = 100 * 10**18; // 100 Asset1 (18 decimals)
        demands[1] = 50 * 10**6; // 50 Asset2 (6 decimals)
        
        // Calculate expected bid value
        uint256 expectedBidValue = calculateBidValue(demands);
        
        // Get allocator fee from config
        AuctionTypes.AuctionInfo memory auctionInfo = cpaManager.getAuctionInfo(auctionId);
        uint256 allocatorRewardPct = auctionInfo.config.allocatorRewardPct;
        uint256 allocatorFee = (expectedBidValue * allocatorRewardPct) / 10000;
        uint256 totalETHRequired = expectedBidValue + allocatorFee;
        
        vm.prank(bidder1);
        cpaManager.submitBid{value: totalETHRequired}(auctionId, demands, type(uint256).max);
        
        // Record final ETH balances
        uint256 finalBidderETH = bidder1.balance;
        uint256 finalCPAManagerETH = address(cpaManager).balance;
        uint256 finalPoolManagerETH = address(poolManager).balance;
        
        console.log("=== AFTER BID ===");
        console.log("Bidder ETH:", finalBidderETH);
        console.log("CPAManager ETH:", finalCPAManagerETH);
        console.log("PoolManager ETH:", finalPoolManagerETH);
        
        // Verify ETH balance changes
        assertEq(finalBidderETH, initialBidderETH - totalETHRequired, "Bidder ETH should decrease by total required");
        assertEq(finalCPAManagerETH, 0, "CPAManager ETH should remain 0");
        assertEq(finalPoolManagerETH, initialPoolManagerETH + totalETHRequired, "PoolManager ETH should increase by total required");
        
        // Verify stake tracking
        uint256 actualBidderStake = cpaManager.bidderStake(auctionId, bidder1);
        uint256 actualBidPoints = cpaManager.bidderBidPoints(auctionId, bidder1);
        
        assertEq(actualBidderStake, expectedBidValue, "Bidder stake should equal bid value");
        assertEq(actualBidPoints, expectedBidValue, "Bid points should be bid value * 10^18 for ETH");
    }

    // ============ ETH Funding Tests ============

    function test_ETHFunding() public {
        // Test ETH funding using vm.deal instead of token.mint
        auctionId = setupCompleteAuction();
        
        // Fund bidder with ETH using vm.deal
        uint256 bidderAmount = BIDDER_AMOUNT; // 1000 ETH
        vm.deal(bidder1, bidderAmount);
        
        // Verify ETH balance
        assertEq(bidder1.balance, bidderAmount, "Bidder should have correct ETH balance");
        
        // Submit bid with ETH
        uint256[] memory demands = new uint256[](2);
        demands[0] = 100 * 10**18; // 100 Asset1 (18 decimals)
        demands[1] = 50 * 10**6; // 50 Asset2 (6 decimals)
        
        uint256 expectedBidValue = calculateBidValue(demands);
        AuctionTypes.AuctionInfo memory auctionInfo = cpaManager.getAuctionInfo(auctionId);
        uint256 allocatorRewardPct = auctionInfo.config.allocatorRewardPct;
        uint256 allocatorFee = (expectedBidValue * allocatorRewardPct) / 10000;
        uint256 totalETHRequired = expectedBidValue + allocatorFee;
        
        vm.prank(bidder1);
        cpaManager.submitBid{value: totalETHRequired}(auctionId, demands, type(uint256).max);
        
        // Verify stake was created correctly
        uint256 actualBidderStake = cpaManager.bidderStake(auctionId, bidder1);
        assertEq(actualBidderStake, expectedBidValue, "Bidder stake should equal bid value");
        
        console.log("ETH funding test completed successfully");
    }

    // ============ ETH Transfer Validation Tests ============

    function test_ETHTransferValidation() public {
        // Test ETH transfer validation in submitBid
        auctionId = setupCompleteAuction();
        
        // Fund bidder with ETH
        vm.deal(bidder1, BIDDER_AMOUNT);
        
        uint256[] memory demands = new uint256[](2);
        demands[0] = 100 * 10**18;
        demands[1] = 50 * 10**6;
        
        uint256 expectedBidValue = calculateBidValue(demands);
        AuctionTypes.AuctionInfo memory auctionInfo = cpaManager.getAuctionInfo(auctionId);
        uint256 allocatorRewardPct = auctionInfo.config.allocatorRewardPct;
        uint256 allocatorFee = (expectedBidValue * allocatorRewardPct) / 10000;
        uint256 totalETHRequired = expectedBidValue + allocatorFee;
        
        // Test insufficient ETH
        vm.prank(bidder1);
        vm.expectRevert();
        cpaManager.submitBid{value: totalETHRequired - 1}(auctionId, demands, type(uint256).max);
        
        // Test correct ETH amount
        vm.prank(bidder1);
        cpaManager.submitBid{value: totalETHRequired}(auctionId, demands, type(uint256).max);
        
        // Verify stake was created
        uint256 actualBidderStake = cpaManager.bidderStake(auctionId, bidder1);
        assertEq(actualBidderStake, expectedBidValue, "Bidder stake should equal bid value");
        
        console.log("ETH transfer validation test completed successfully");
    }

    // ============ ETH Refund Tests ============

    function test_ETHRefunds() public {
        // Test ETH refund mechanics for dropout
        auctionId = setupCompleteAuction();
        
        // Fund bidder with ETH
        vm.deal(bidder1, BIDDER_AMOUNT);
        
        // Submit bid to create stake
        uint256[] memory demands = new uint256[](2);
        demands[0] = 100 * 10**18;
        demands[1] = 50 * 10**6;
        
        uint256 expectedBidValue = calculateBidValue(demands);
        AuctionTypes.AuctionInfo memory auctionInfo = cpaManager.getAuctionInfo(auctionId);
        uint256 allocatorRewardPct = auctionInfo.config.allocatorRewardPct;
        uint256 allocatorFee = (expectedBidValue * allocatorRewardPct) / 10000;
        uint256 totalETHRequired = expectedBidValue + allocatorFee;
        
        vm.prank(bidder1);
        cpaManager.submitBid{value: totalETHRequired}(auctionId, demands, type(uint256).max);
        
        // Record initial balances
        uint256 initialBidderETH = bidder1.balance;
        uint256 initialPoolManagerETH = address(poolManager).balance;
        
        // Get penalty info from config
        uint256 dropoutSlashRatio = auctionInfo.config.dropoutSlashRatio;
        uint256 expectedPenalty = (expectedBidValue * dropoutSlashRatio) / 10000;
        uint256 expectedRefund = expectedBidValue - expectedPenalty;
        
        // Perform dropout
        vm.prank(bidder1);
        cpaManager.dropout(auctionId);
        
        // Record final balances
        uint256 finalBidderETH = bidder1.balance;
        uint256 finalPoolManagerETH = address(poolManager).balance;
        
        // Verify ETH refund
        uint256 actualRefund = finalBidderETH - initialBidderETH;
        assertEq(actualRefund, expectedRefund, "ETH refund should match expected calculation");
        
        // Verify PoolManager ETH reduction
        uint256 poolManagerReduction = initialPoolManagerETH - finalPoolManagerETH;
        assertEq(poolManagerReduction, expectedRefund, "PoolManager ETH should be reduced by refund amount");
        
        console.log("ETH refund test completed successfully");
    }

    // ============ ETH + ERC20 Mixed Tests ============

    function test_ETHNumeraireWithERC20Assets() public {
        // Test ETH numeraire with ERC20 assets (the main scenario)
        auctionId = setupCompleteAuction();
        
        // Fund bidder with ETH
        vm.deal(bidder1, BIDDER_AMOUNT);
        
        // Submit bid with mixed decimal ERC20 assets
        uint256[] memory demands = new uint256[](2);
        demands[0] = 100 * 10**18; // 100 Asset1 (18 decimals)
        demands[1] = 50 * 10**6; // 50 Asset2 (6 decimals)
        
        uint256 expectedBidValue = calculateBidValue(demands);
        AuctionTypes.AuctionInfo memory auctionInfo = cpaManager.getAuctionInfo(auctionId);
        uint256 allocatorRewardPct = auctionInfo.config.allocatorRewardPct;
        uint256 allocatorFee = (expectedBidValue * allocatorRewardPct) / 10000;
        uint256 totalETHRequired = expectedBidValue + allocatorFee;
        
        vm.prank(bidder1);
        cpaManager.submitBid{value: totalETHRequired}(auctionId, demands, type(uint256).max);
        
        // Verify stake tracking
        uint256 actualBidderStake = cpaManager.bidderStake(auctionId, bidder1);
        uint256 actualBidPoints = cpaManager.bidderBidPoints(auctionId, bidder1);
        
        assertEq(actualBidderStake, expectedBidValue, "Bidder stake should equal bid value");
        assertEq(actualBidPoints, expectedBidValue, "Bid points should be bid value * 10^18 for ETH");
        
        console.log("ETH numeraire with ERC20 assets test completed successfully");
    }

    // ============ ETH Edge Cases ============

    // // THIS TEST WILL FAIL AND THAT"S EXACTLY WHAT WE WANT.
    // function test_ETHInsufficientBalance() public {
    //     // Test behavior when bidder has insufficient ETH
    //     auctionId = setupCompleteAuction();
        
    //     // Fund bidder with insufficient ETH
    //     vm.deal(bidder1, 1 ether); // Only 1 ETH
        
    //     uint256[] memory demands = new uint256[](2);
    //     demands[0] = 100 * 10**18;
    //     demands[1] = 50 * 10**6;
        
    //     uint256 expectedBidValue = calculateBidValue(demands);
    //     AuctionTypes.AuctionInfo memory auctionInfo = cpaManager.getAuctionInfo(auctionId);
    //     uint256 allocatorRewardPct = auctionInfo.config.allocatorRewardPct;
    //     uint256 allocatorFee = (expectedBidValue * allocatorRewardPct) / 10000;
    //     uint256 totalETHRequired = expectedBidValue + allocatorFee;
        
    //     // Should fail with insufficient ETH
    //     vm.prank(bidder1);
    //     vm.expectRevert();
    //     cpaManager.submitBid{value: totalETHRequired}(auctionId, demands, type(uint256).max);
        
    //     console.log("ETH insufficient balance test completed successfully");
    // }

    function test_ETHZeroValue() public {
        // Test behavior when bidder sends zero ETH
        auctionId = setupCompleteAuction();
        
        // Fund bidder with ETH
        vm.deal(bidder1, 100 ether);
        
        uint256[] memory demands = new uint256[](2);
        demands[0] = 100 * 10**18;
        demands[1] = 50 * 10**6;
        
        // Should fail with zero ETH
        vm.prank(bidder1);
        vm.expectRevert(IErrorsAndEvents.EthRequired.selector);
        cpaManager.submitBid{value: 0}(auctionId, demands, type(uint256).max);
        
        console.log("ETH zero value test completed successfully");
    }

    // ============ ETH Price Update Tests ============

    function test_ETHPriceUpdates() public {
        // Test price updates with ETH numeraire
        auctionId = setupCompleteAuction();
        
        // Fund bidders with ETH
        vm.deal(bidder1, type(uint256).max);
        vm.deal(bidder2, type(uint256).max);
        
        // Get initial pool states
        PoolId asset1PoolId = asset1PoolKey.toId();
        PoolId asset2PoolId = asset2PoolKey.toId();
        
        (, int24 asset1InitialTick, , ) = poolManager.getSlot0(asset1PoolId);
        (, int24 asset2InitialTick, , ) = poolManager.getSlot0(asset2PoolId);
        
        // Get deposit amounts
        (,,,uint256 asset1Deposit, , , , ) = cpaManager.getPoolInfo(asset1PoolId);
        (,,,uint256 asset2Deposit, , , , ) = cpaManager.getPoolInfo(asset2PoolId);
        
        // Get price increments from config
        AuctionTypes.AuctionInfo memory auctionInfo = cpaManager.getAuctionInfo(auctionId);
        int24 asset1PriceIncrement = auctionInfo.config.priceIncrements[0];
        int24 asset2PriceIncrement = auctionInfo.config.priceIncrements[1];
        
        console.log("=== PRICE INCREMENTS ===");
        console.log("Asset1 price increment:", asset1PriceIncrement);
        console.log("Asset2 price increment:", asset2PriceIncrement);
        
        // Submit bids that create excess demand
        uint256[] memory demands1 = new uint256[](2);
        demands1[0] = (asset1Deposit * 60) / 100; // 60% of Asset1 deposit
        demands1[1] = (asset2Deposit * 60) / 100; // 60% of Asset2 deposit
        
        uint256[] memory demands2 = new uint256[](2);
        demands2[0] = (asset1Deposit * 60) / 100; // 60% of Asset1 deposit - total 120%
        demands2[1] = (asset2Deposit * 60) / 100; // 60% of Asset2 deposit - total 120%
        
        // Calculate required ETH for each bid
        uint256 expectedBidValue1 = calculateBidValue(demands1);
        uint256 expectedBidValue2 = calculateBidValue(demands2);
        uint256 allocatorRewardPct = auctionInfo.config.allocatorRewardPct;
        uint256 allocatorFee1 = (expectedBidValue1 * allocatorRewardPct) / 10000;
        uint256 allocatorFee2 = (expectedBidValue2 * allocatorRewardPct) / 10000;
        uint256 totalETH1 = expectedBidValue1 + allocatorFee1;
        uint256 totalETH2 = expectedBidValue2 + allocatorFee2;
        
        vm.prank(bidder1);
        cpaManager.submitBid{value: totalETH1}(auctionId, demands1, type(uint256).max);
        
        vm.prank(bidder2);
        cpaManager.submitBid{value: totalETH2}(auctionId, demands2, type(uint256).max);
        
        // End round to trigger price updates
        endClockRound(auctionId);
        
        // Get new tick values
        (, int24 asset1Tick1, , ) = poolManager.getSlot0(asset1PoolId);
        (, int24 asset2Tick1, , ) = poolManager.getSlot0(asset2PoolId);
        
        // Calculate actual tick changes from pool states
        int256 actualAsset1TickChange = int256(asset1Tick1) - int256(asset1InitialTick);
        int256 actualAsset2TickChange = int256(asset2Tick1) - int256(asset2InitialTick);
        
        // Calculate expected tick changes from config
        // We can hardcode negation here because ETH will always be token0.
        // This means that when prices increase for the asset, the ticks go DOWN.
        int256 expectedAsset1TickChange = -int256(asset1PriceIncrement);
        int256 expectedAsset2TickChange = -int256(asset2PriceIncrement);
        
        console.log("=== TICK CHANGES ===");
        console.log("Asset1 initial tick:", asset1InitialTick);
        console.log("Asset1 new tick:", asset1Tick1);
        console.log("Asset1 expected change:", expectedAsset1TickChange);
        console.log("Asset1 actual change:", actualAsset1TickChange);
        console.log("Asset2 initial tick:", asset2InitialTick);
        console.log("Asset2 new tick:", asset2Tick1);
        console.log("Asset2 expected change:", expectedAsset2TickChange);
        console.log("Asset2 actual change:", actualAsset2TickChange);
        
        // Verify exact tick changes match expected increments
        assertEq(actualAsset1TickChange, expectedAsset1TickChange, "Asset1 tick change should match price increment");
        assertEq(actualAsset2TickChange, expectedAsset2TickChange, "Asset2 tick change should match price increment");
        
        console.log("ETH price update test completed successfully");
    }
}
