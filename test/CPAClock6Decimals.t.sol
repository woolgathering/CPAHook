// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { Test, console } from "forge-std/Test.sol";
import { CPATestBase6Decimals } from "./base/CPATestBase6Decimals.sol";
import { AuctionTypes } from "../src/types/AuctionTypes.sol";
import { AuctionId } from "../src/types/AuctionId.sol";
import { AssetId, AssetIdLibrary } from "../src/types/AssetConfig.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title CPAClock6DecimalsTest
 * @notice Tests clock phase functionality with 6-decimal numeraire and mixed asset decimals
 */
contract CPAClock6DecimalsTest is CPATestBase6Decimals {

    function setUp() public override {
        super.setUp();
    }

    // ============ Bid Points Tests ============

    function test_BidPoints_6DecimalNumeraire() public {
        auctionId = setupCompleteAuction();

        uint256 bidderAmount = 10000 * 10**6;
        createBidder(bidder1, bidderAmount);
        approveNumeraireForBidder(bidder1, type(uint256).max);

        uint256[] memory demands = new uint256[](2);
        demands[0] = 100 * 10**18;
        demands[1] = 50 * 10**6;

        vm.prank(bidder1);
        cpaManager.submitBid(auctionId, demands, type(uint256).max);

        uint256 expectedBidValue = calculateBidValue(demands);
        uint256 expectedBidPoints = expectedBidValue * 10**12;
        uint256 actualBidPoints = cpaManager.bidderBidPoints(auctionId, bidder1);

        assertEq(actualBidPoints, expectedBidPoints, "Bid points should be calculated correctly for 6-decimal numeraire");
    }

    // ============ Bid Value Calculation Tests ============

    function test_BidValue_MixedAssets() public {
        auctionId = setupCompleteAuction();

        createBidder(bidder1, 10000 * 10**6);
        approveNumeraireForBidder(bidder1, type(uint256).max);

        uint256[] memory demands = new uint256[](2);
        demands[0] = 500 * 10**18;
        demands[1] = 1000 * 10**6;

        uint256 expectedBidValue = calculateBidValue(demands);

        vm.prank(bidder1);
        cpaManager.submitBid(auctionId, demands, type(uint256).max);

        uint256 actualBidPoints = cpaManager.bidderBidPoints(auctionId, bidder1);
        uint256 expectedBidPoints = expectedBidValue * 10**12;

        assertEq(actualBidPoints, expectedBidPoints, "Mixed assets bid points should be calculated correctly");

        console.log("Expected bid value (6 decimals):", expectedBidValue);
        console.log("Expected bid points (18 decimals):", expectedBidPoints);
        console.log("Actual bid points (18 decimals):", actualBidPoints);
    }

    // ============ Stake Management Tests ============

    function test_StakeManagement_FirstBid() public returns (uint256 expectedBidValue2) {
        auctionId = setupCompleteAuction();

        createBidder(bidder1, 10000 * 10**6);
        approveNumeraireForBidder(bidder1, type(uint256).max);

        uint256 initialBidderERC20 = numeraireToken.balanceOf(bidder1);

        uint256[] memory demands1 = new uint256[](2);
        demands1[0] = 100 * 10**18;
        demands1[1] = 50 * 10**6;

        uint256 expectedBidValue1 = calculateBidValue(demands1);
        uint256 allocatorRewardPct = cpaManager.getAuctionInfo(auctionId).config.allocatorRewardPct;
        uint256 allocatorFee1 = (expectedBidValue1 * allocatorRewardPct) / 10000;
        uint256 totalTransfer1 = expectedBidValue1 + allocatorFee1;

        vm.prank(bidder1);
        cpaManager.submitBid(auctionId, demands1, type(uint256).max);

        assertEq(cpaManager.bidderStake(auctionId, bidder1), expectedBidValue1, "Bidder stake should equal bid value");
        assertEq(cpaManager.bidderBidPoints(auctionId, bidder1), expectedBidValue1 * 10**12, "Bid points should be bid value * 10^12");
        assertEq(numeraireToken.balanceOf(bidder1), initialBidderERC20 - totalTransfer1, "Bidder ERC20 should decrease by total transfer");

        uint256[] memory demands2 = new uint256[](2);
        demands2[0] = 150 * 10**18;
        demands2[1] = 50 * 10**6;
        expectedBidValue2 = calculateBidValue(demands2);

        {
            uint256 additionalStake = expectedBidValue2 - expectedBidValue1;
            uint256 additionalFee = (additionalStake * allocatorRewardPct) / 10000;
            uint256 totalTransfer2 = expectedBidValue2 + (expectedBidValue2 * allocatorRewardPct) / 10000;

            vm.prank(bidder1);
            cpaManager.submitBid(auctionId, demands2, type(uint256).max);

            assertEq(cpaManager.bidderStake(auctionId, bidder1), expectedBidValue2, "Bidder stake should equal new bid value");
            assertEq(numeraireToken.balanceOf(bidder1), initialBidderERC20 - totalTransfer2, "Bidder ERC20 should decrease by total transfer 2");
            console.log("Additional stake:", additionalStake, "Fee:", additionalFee);
        }
    }

    function test_StakeManagement_ThirdBid() public {
        uint256 expectedBidValue2 = test_StakeManagement_FirstBid();

        uint256[] memory demands3 = new uint256[](2);
        demands3[0] = 120 * 10**18;
        demands3[1] = 50 * 10**6;

        vm.prank(bidder1);
        cpaManager.submitBid(auctionId, demands3, type(uint256).max);

        assertEq(cpaManager.bidderStake(auctionId, bidder1), expectedBidValue2, "Bidder stake should not decrease on reduced bid");
        assertEq(cpaManager.bidderBidPoints(auctionId, bidder1), expectedBidValue2 * 10**12, "Bid points should not decrease on reduced bid");
    }

    function test_StakeRefund_6DecimalNumeraire() public {
        auctionId = setupCompleteAuction();

        createBidder(bidder1, 10000 * 10**6);
        approveNumeraireForBidder(bidder1, type(uint256).max);

        uint256[] memory demands = new uint256[](2);
        demands[0] = 100 * 10**18;
        demands[1] = 50 * 10**6;

        vm.prank(bidder1);
        cpaManager.submitBid(auctionId, demands, type(uint256).max);

        uint256 actualStake = cpaManager.bidderStake(auctionId, bidder1);
        uint256 dropoutSlashRatio = cpaManager.getAuctionInfo(auctionId).config.dropoutSlashRatio;
        uint256 expectedPenalty = (actualStake * dropoutSlashRatio) / 10000;
        uint256 expectedRefund = actualStake - expectedPenalty;

        uint256 initialBidderERC20 = numeraireToken.balanceOf(bidder1);
        uint256 initialProtocolAccrued = cpaManager.protocolAccrued(auctionId);

        vm.prank(bidder1);
        cpaManager.dropout(auctionId);

        uint256 actualPenalty = cpaManager.protocolAccrued(auctionId) - initialProtocolAccrued;
        uint256 actualRefund = numeraireToken.balanceOf(bidder1) - initialBidderERC20;

        assertEq(actualPenalty, expectedPenalty, "Penalty should match expected calculation from config");
        assertEq(actualRefund, expectedRefund, "Refund should match expected calculation");
        assertEq(cpaManager.bidderStake(auctionId, bidder1), 0, "Bidder stake should be 0 after dropout");
        assertEq(cpaManager.bidderBidPoints(auctionId, bidder1), 0, "Bidder bid points should be 0 after dropout");
    }

    // ============ Price Update Tests ============

    function test_PriceUpdate_MixedDecimals() public {
        auctionId = setupCompleteAuction();

        createBidder(bidder1, type(uint256).max / 2);
        createBidder(bidder2, type(uint256).max / 2);
        approveNumeraireForBidder(bidder1, type(uint256).max);
        approveNumeraireForBidder(bidder2, type(uint256).max);

        AssetId assetId1 = AssetIdLibrary.createId(auctionId, address(asset1Token));
        AssetId assetId2 = AssetIdLibrary.createId(auctionId, address(asset2Token));

        uint256 initialPrice1 = cpaManager.getAssetInfo(assetId1).currentPrice;
        uint256 initialPrice2 = cpaManager.getAssetInfo(assetId2).currentPrice;

        _submitOverdemandBids();

        endClockRound(auctionId);

        _assertPriceUpdates(assetId1, assetId2, initialPrice1, initialPrice2);
    }

    function _submitOverdemandBids() internal {
        uint256 asset1Deposit = depositAmount1;
        uint256 asset2Deposit = depositAmount2;

        uint256[] memory demands1 = new uint256[](2);
        demands1[0] = (asset1Deposit * 60) / 100;
        demands1[1] = (asset2Deposit * 60) / 100;

        uint256[] memory demands2 = new uint256[](2);
        demands2[0] = (asset1Deposit * 60) / 100;
        demands2[1] = (asset2Deposit * 60) / 100;

        vm.prank(bidder1);
        cpaManager.submitBid(auctionId, demands1, type(uint256).max);

        vm.prank(bidder2);
        cpaManager.submitBid(auctionId, demands2, type(uint256).max);
    }

    function _assertPriceUpdates(AssetId assetId1, AssetId assetId2, uint256 initialPrice1, uint256 initialPrice2) internal view {
        AuctionTypes.AssetInfo memory asset1After = cpaManager.getAssetInfo(assetId1);
        AuctionTypes.AssetInfo memory asset2After = cpaManager.getAssetInfo(assetId2);

        uint256 totalAsset1Demand = (depositAmount1 * 120) / 100;
        uint256 totalAsset2Demand = (depositAmount2 * 120) / 100;

        int256 expectedAsset1Excess = int256(totalAsset1Demand) - int256(depositAmount1);
        int256 expectedAsset2Excess = int256(totalAsset2Demand) - int256(depositAmount2);

        assertEq(asset1After.excessDemand, expectedAsset1Excess, "Asset1 excess demand should match");
        assertEq(asset2After.excessDemand, expectedAsset2Excess, "Asset2 excess demand should match");

        if (expectedAsset1Excess > 0) {
            assertEq(asset1After.currentPrice, initialPrice1 + asset1PriceIncrement, "Asset1 price should increase by one increment");
        }
        if (expectedAsset2Excess > 0) {
            assertEq(asset2After.currentPrice, initialPrice2 + asset2PriceIncrement, "Asset2 price should increase by one increment");
        }
    }

    // ============ Edge Case Tests ============

    function test_EdgeCase_ZeroDemand() public {
        auctionId = setupCompleteAuction();

        createBidder(bidder1, type(uint256).max);
        approveNumeraireForBidder(bidder1, type(uint256).max);

        uint256[] memory demands = new uint256[](2);
        demands[0] = 0;
        demands[1] = 0;

        vm.prank(bidder1);
        cpaManager.submitBid(auctionId, demands, type(uint256).max);

        assertEq(cpaManager.bidderBidPoints(auctionId, bidder1), 0, "Bid points should be 0 for zero demand");
    }

    function test_EdgeCase_MaximalDemand() public {
        auctionId = setupCompleteAuction();

        createBidder(bidder1, type(uint256).max);
        approveNumeraireForBidder(bidder1, type(uint256).max);

        uint256[] memory demands = new uint256[](2);
        demands[0] = 1e30;
        demands[1] = 1e18;

        vm.prank(bidder1);
        cpaManager.submitBid(auctionId, demands, type(uint256).max);

        uint256 expectedBidPoints = calculateBidValue(demands) * 10**12;
        assertEq(cpaManager.bidderBidPoints(auctionId, bidder1), expectedBidPoints, "Bid points should be calculated correctly for large demands");
    }

    function testFuzz_EdgeCase_PreciseDemand(uint256 asset1Demand, uint256 asset2Demand) public {
        asset1Demand = bound(asset1Demand, 0, 1e24);
        asset2Demand = bound(asset2Demand, 0, 1e12);

        auctionId = setupCompleteAuction();

        createBidder(bidder1, type(uint256).max);
        approveNumeraireForBidder(bidder1, type(uint256).max);

        uint256[] memory demands = new uint256[](2);
        demands[0] = asset1Demand;
        demands[1] = asset2Demand;

        vm.prank(bidder1);
        cpaManager.submitBid(auctionId, demands, type(uint256).max);

        uint256 expectedBidPoints = calculateBidValue(demands) * 10**12;
        assertEq(cpaManager.bidderBidPoints(auctionId, bidder1), expectedBidPoints, "Bid points should be calculated correctly for fuzzed demands");
    }

    function test_EdgeCase_SingleAssetDemand() public {
        auctionId = setupCompleteAuction();

        createBidder(bidder1, type(uint256).max);
        approveNumeraireForBidder(bidder1, type(uint256).max);

        uint256[] memory demands = new uint256[](2);
        demands[0] = 1000 * 10**18;
        demands[1] = 0;

        vm.prank(bidder1);
        cpaManager.submitBid(auctionId, demands, type(uint256).max);

        uint256 expectedBidPoints = calculateBidValue(demands) * 10**12;
        assertEq(cpaManager.bidderBidPoints(auctionId, bidder1), expectedBidPoints, "Bid points should be calculated correctly for single asset demand");
    }

    function test_EdgeCase_VerySmallAmounts() public {
        auctionId = setupCompleteAuction();

        createBidder(bidder1, type(uint256).max);
        approveNumeraireForBidder(bidder1, type(uint256).max);

        uint256[] memory demands = new uint256[](2);
        demands[0] = 1;
        demands[1] = 1;

        vm.prank(bidder1);
        cpaManager.submitBid(auctionId, demands, type(uint256).max);

        uint256 expectedBidPoints = calculateBidValue(demands) * 10**12;
        assertEq(cpaManager.bidderBidPoints(auctionId, bidder1), expectedBidPoints, "Bid points should be calculated correctly for very small amounts");
    }
}
