// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { Test, console } from "forge-std/Test.sol";
import { CPATestBase } from "./base/CPATestBase.sol";
import { AuctionTypes } from "../src/types/AuctionTypes.sol";
import { AuctionId } from "../src/types/AuctionId.sol";
import { AssetId, AssetIdLibrary } from "../src/types/AssetConfig.sol";
import { BundleId, BundleIdLibrary } from "../src/types/BundleId.sol";
import { CommitReveal } from "../src/utils/CommitReveal.sol";
import { IErrorsAndEvents } from "../src/utils/IErrorsAndEvents.sol";

/**
 * @title CPACompleteFlowTest
 * @notice Comprehensive integration test covering the complete Clock-Proxy Auction flow
 * @author Clock-Proxy Auction Team
 */
contract CPACompleteFlowTest is CPATestBase {
    // Clock phase test data
    address testBidder1;
    address testBidder2;
    address testBidder3;

    // Bundle storage for allocation phase
    AuctionTypes.Bundle[] public submittedBundles;
    BundleId[] public bundleIds;
    bytes32 saltA1;
    bytes32 saltB1;
    bytes32 saltA2;
    bytes32 saltB2;
    bytes32 saltA3;
    bytes32 saltB3;
    bytes32 commitHash1;
    bytes32 commitHash2;
    bytes32 commitHash3;
    bytes32 partialCommit1;
    bytes32 partialCommit2;
    bytes32 partialCommit3;

    // Proxy phase test data
    address testProxy1;
    address testProxy2;
    bytes32 proxySaltA1;
    bytes32 proxySaltB1;
    bytes32 proxySaltA2;
    bytes32 proxySaltB2;
    bytes32 proxyCommitHash1;
    bytes32 proxyCommitHash2;

    function setUp() public override {
        super.setUp();

        // Create auction with standard configuration
        AuctionTypes.AuctionConfig memory config = createStandardAuctionConfig();
        auctionId = createAuction(config, auctioneer);

        mintTokensToAuctioneer(1000000 * 10**18);
        approveTokens(address(asset1Token), address(cpaManager), 1000 * 10**18);
        approveTokens(address(asset2Token), address(cpaManager), 1000 * 10**18);

        // Move deposits
        moveDeposit(auctionId, address(asset1Token), 100 * 10**18);
        moveDeposit(auctionId, address(asset2Token), 150 * 10**18);

        setupAdditionalAccountsAndCommitHashes();
    }

    function setupAdditionalAccountsAndCommitHashes() internal {
        testBidder1 = bidder1;
        testBidder2 = bidder2;
        testBidder3 = makeAddr("testBidder3");

        testProxy1 = proxy1;
        testProxy2 = proxy2;

        createBidder(testBidder1, 1000000 * 10**18);
        createBidder(testBidder2, 1000000 * 10**18);
        createBidder(testBidder3, 1000000 * 10**18);

        approveNumeraireForBidder(testBidder1, type(uint256).max);
        approveNumeraireForBidder(testBidder2, type(uint256).max);
        approveNumeraireForBidder(testBidder3, type(uint256).max);

        saltA1 = keccak256("saltA1");
        saltB1 = keccak256("saltB1");
        saltA2 = keccak256("saltA2");
        saltB2 = keccak256("saltB2");
        saltA3 = keccak256("saltA3");
        saltB3 = keccak256("saltB3");

        commitHash1 = CommitReveal.generateCommitHash(testBidder1, testProxy1, saltA1, saltB1);
        commitHash2 = CommitReveal.generateCommitHash(testBidder2, testProxy2, saltA2, saltB2);
        commitHash3 = CommitReveal.generateCommitHash(testBidder3, testProxy1, saltA3, saltB3);

        proxySaltA1 = keccak256("proxySaltA1");
        proxySaltB1 = keccak256("proxySaltB1");
        proxySaltA2 = keccak256("proxySaltA2");
        proxySaltB2 = keccak256("proxySaltB2");

        proxyCommitHash1 = CommitReveal.generateCommitHash(testBidder1, testProxy1, proxySaltA1, proxySaltB1);
        proxyCommitHash2 = CommitReveal.generateCommitHash(testBidder2, testProxy2, proxySaltA2, proxySaltB2);
    }

    function test_CompleteAuctionFlow() public {
        // ========================================
        // SETUP PHASE (deposits already moved in setUp)
        // ========================================

        vm.prank(testProxy1);
        cpaManager.commitToBidder(auctionId, commitHash1);
        vm.prank(testProxy2);
        cpaManager.commitToBidder(auctionId, commitHash2);
        vm.prank(testProxy1);
        cpaManager.commitToBidder(auctionId, commitHash3);

        // ========================================
        // CLOCK PHASE - ROUND 1
        // ========================================

        vm.prank(auctioneer);
        cpaManager.startClockPhase(auctionId);

        uint256[] memory demands1 = new uint256[](2);
        demands1[0] = 50 * 10**18;
        demands1[1] = 60 * 10**18;

        uint256[] memory demands2 = new uint256[](2);
        demands2[0] = 40 * 10**18;
        demands2[1] = 50 * 10**18;

        uint256[] memory demands3 = new uint256[](2);
        demands3[0] = 30 * 10**18;
        demands3[1] = 41 * 10**18;

        vm.prank(testBidder1);
        cpaManager.submitBid(auctionId, demands1, 1000 * 10**18);

        vm.prank(testBidder2);
        cpaManager.submitBid(auctionId, demands2, 1000 * 10**18);

        vm.prank(testBidder3);
        cpaManager.submitBid(auctionId, demands3, 1000 * 10**18);

        endClockRound(auctionId);

        // Verify round 1 results via getAssetInfo
        AssetId assetId1 = AssetIdLibrary.createId(auctionId, address(asset1Token));
        AssetId assetId2 = AssetIdLibrary.createId(auctionId, address(asset2Token));
        AuctionTypes.AssetInfo memory asset1Info1 = cpaManager.getAssetInfo(assetId1);
        AuctionTypes.AssetInfo memory asset2Info1 = cpaManager.getAssetInfo(assetId2);

        assertGt(asset1Info1.excessDemand, 0, "Asset1 should have excess demand after round 1");
        assertGt(asset2Info1.excessDemand, 0, "Asset2 should have excess demand after round 1");
        assertGt(asset1Info1.currentPrice, asset1StartingPrice, "Asset1 price should have increased after round 1");
        assertGt(asset2Info1.currentPrice, asset2StartingPrice, "Asset2 price should have increased after round 1");

        // ========================================
        // CLOCK PHASE - ROUND 2
        // ========================================

        uint256[] memory demands1_2 = new uint256[](2);
        demands1_2[0] = 45 * 10**18;
        demands1_2[1] = 45 * 10**18;

        uint256[] memory demands2_2 = new uint256[](2);
        demands2_2[0] = 35 * 10**18;
        demands2_2[1] = 35 * 10**18;

        uint256[] memory demands3_2 = new uint256[](2);
        demands3_2[0] = 25 * 10**18;
        demands3_2[1] = 25 * 10**18;

        vm.prank(testBidder1);
        cpaManager.submitBid(auctionId, demands1_2, 1000 * 10**18);

        vm.prank(testBidder2);
        cpaManager.submitBid(auctionId, demands2_2, 1000 * 10**18);

        vm.prank(testBidder3);
        cpaManager.submitBid(auctionId, demands3_2, 1000 * 10**18);

        endClockRound(auctionId);

        AuctionTypes.AssetInfo memory asset1Info2 = cpaManager.getAssetInfo(assetId1);
        AuctionTypes.AssetInfo memory asset2Info2 = cpaManager.getAssetInfo(assetId2);

        // Round 2: Only asset1 has excess demand (105 > 100), asset2 has undersell (105 < 150)
        assertGt(asset1Info2.excessDemand, 0, "Asset1 should still have excess demand after round 2");
        assertLt(asset2Info2.excessDemand, 0, "Asset2 should have undersell after round 2");
        assertLt(asset1Info2.excessDemand, asset1Info1.excessDemand, "Asset1 excess demand should be reduced in round 2");
        assertGt(asset1Info2.currentPrice, asset1Info1.currentPrice, "Asset1 price should continue increasing in round 2");
        assertEq(asset2Info2.currentPrice, asset2Info1.currentPrice, "Asset2 price should remain the same in round 2");

        // ========================================
        // CLOCK PHASE - ROUND 3 (FINAL)
        // ========================================

        uint256[] memory demands1_3 = new uint256[](2);
        demands1_3[0] = 35 * 10**18;
        demands1_3[1] = 40 * 10**18;

        uint256[] memory demands2_3 = new uint256[](2);
        demands2_3[0] = 30 * 10**18;
        demands2_3[1] = 35 * 10**18;

        uint256[] memory demands3_3 = new uint256[](2);
        demands3_3[0] = 25 * 10**18;
        demands3_3[1] = 30 * 10**18;

        vm.prank(testBidder1);
        cpaManager.submitBid(auctionId, demands1_3, 1000 * 10**18);

        vm.prank(testBidder2);
        cpaManager.submitBid(auctionId, demands2_3, 1000 * 10**18);

        vm.prank(testBidder3);
        cpaManager.submitBid(auctionId, demands3_3, 1000 * 10**18);

        endClockRound(auctionId);

        AuctionTypes.AssetInfo memory asset1Info3 = cpaManager.getAssetInfo(assetId1);
        AuctionTypes.AssetInfo memory asset2Info3 = cpaManager.getAssetInfo(assetId2);

        // Round 3: Both assets have undersell (90 < 100, 105 < 150)
        assertLt(asset1Info3.excessDemand, 0, "Asset1 should have undersell after round 3");
        assertLt(asset2Info3.excessDemand, 0, "Asset2 should have undersell after round 3");

        // ========================================
        // END CLOCK PHASE
        // ========================================

        AuctionTypes.AuctionInfo memory endClockInfo = cpaManager.getAuctionInfo(auctionId);
        assertEq(endClockInfo.clockOpen, 1, "Clock should be closed");
        assertEq(endClockInfo.currentRound, 3, "Round should be 3");
        assertEq(uint8(endClockInfo.currentPhase), uint8(AuctionTypes.AuctionPhase.Proxy), "Auction should be in proxy phase");

        // ========================================
        // VERIFY CLOCK PHASE RESULTS
        // ========================================

        AuctionTypes.AuctionInfo memory auctionInfo = cpaManager.getAuctionInfo(auctionId);
        assertEq(uint8(auctionInfo.currentPhase), uint8(AuctionTypes.AuctionPhase.Proxy), "Auction should be in proxy phase");

        AuctionTypes.AssetInfo memory asset1Final = cpaManager.getAssetInfo(assetId1);
        AuctionTypes.AssetInfo memory asset2Final = cpaManager.getAssetInfo(assetId2);

        assertGt(asset1Final.currentPrice, asset1StartingPrice, "Asset1 price should have increased from starting price");
        assertEq(asset2Final.currentPrice, asset2StartingPrice, "Asset2 price should have remained the same since start");

        assertLt(asset1Final.excessDemand, int256(100 * 10**18), "Asset1 excess demand should be reduced");
        assertLt(asset2Final.excessDemand, int256(150 * 10**18), "Asset2 excess demand should be reduced");

        console.log("Clock phase completed successfully");
        console.log("Asset1 final price:", asset1Final.currentPrice);
        console.log("Asset2 final price:", asset2Final.currentPrice);
        console.log("Asset1 final excess demand:", asset1Final.excessDemand);
        console.log("Asset2 final excess demand:", asset2Final.excessDemand);

        // ========================================
        // PROXY PHASE
        // ========================================

        for (uint256 i = 0; i < 4; i++) {
            uint256[] memory quantities1 = new uint256[](2);
            quantities1[0] = (30 + i * 5) * 10**18;
            quantities1[1] = (20 + i * 3) * 10**18;

            AuctionTypes.Bundle memory bundle1 = AuctionTypes.Bundle({
                auctionId: auctionId,
                commitHash: commitHash1,
                value: calculateBidValue(quantities1),
                quantities: quantities1,
                timestamp: block.timestamp
            });

            BundleId bundleId1 = BundleIdLibrary.createId(commitHash1, keccak256(abi.encode(quantities1)));
            bundleIds.push(bundleId1);
            submittedBundles.push(bundle1);

            vm.prank(testProxy1);
            cpaManager.submitBundle(auctionId, commitHash1, bundle1);
        }

        for (uint256 i = 0; i < 3; i++) {
            uint256[] memory quantities3 = new uint256[](2);
            quantities3[0] = (25 + i * 4) * 10**18;
            quantities3[1] = (15 + i * 2) * 10**18;

            AuctionTypes.Bundle memory bundle3 = AuctionTypes.Bundle({
                auctionId: auctionId,
                commitHash: commitHash3,
                value: calculateBidValue(quantities3),
                quantities: quantities3,
                timestamp: block.timestamp
            });

            BundleId bundleId3 = BundleIdLibrary.createId(commitHash3, keccak256(abi.encode(quantities3)));
            bundleIds.push(bundleId3);
            submittedBundles.push(bundle3);

            vm.prank(testProxy1);
            cpaManager.submitBundle(auctionId, commitHash3, bundle3);
        }

        for (uint256 i = 0; i < 4; i++) {
            uint256[] memory quantities2 = new uint256[](2);
            quantities2[0] = (35 + i * 3) * 10**18;
            quantities2[1] = (25 + i * 4) * 10**18;

            AuctionTypes.Bundle memory bundle2 = AuctionTypes.Bundle({
                auctionId: auctionId,
                commitHash: commitHash2,
                value: calculateBidValue(quantities2),
                quantities: quantities2,
                timestamp: block.timestamp
            });

            BundleId bundleId2 = BundleIdLibrary.createId(commitHash2, keccak256(abi.encode(quantities2)));
            bundleIds.push(bundleId2);
            submittedBundles.push(bundle2);

            vm.prank(testProxy2);
            cpaManager.submitBundle(auctionId, commitHash2, bundle2);
        }

        AuctionTypes.AuctionInfo memory auction = cpaManager.getAuctionInfo(auctionId);
        vm.warp(block.timestamp + auction.config.phaseDurations[0] + 1);
        cpaManager.transitionToAllocation(auctionId);

        // ========================================
        // VERIFY PROXY PHASE RESULTS
        // ========================================

        AuctionTypes.AuctionInfo memory auctionInfoAfterProxy = cpaManager.getAuctionInfo(auctionId);
        assertEq(uint8(auctionInfoAfterProxy.currentPhase), uint8(AuctionTypes.AuctionPhase.Allocation), "Auction should be in allocation phase");

        assertEq(submittedBundles.length, 11, "Should have submitted 11 bundles total (4+3+4)");
        assertEq(bundleIds.length, 11, "Should have 11 bundle IDs corresponding to submitted bundles");

        AuctionTypes.Bundle memory firstBundle = submittedBundles[0];
        assertEq(uint256(AuctionId.unwrap(firstBundle.auctionId)), uint256(AuctionId.unwrap(auctionId)), "First bundle should have correct auction ID");
        assertEq(firstBundle.commitHash, commitHash1, "First bundle should have correct commit hash");
        assertEq(firstBundle.quantities[0], 30 * 10**18, "First bundle should have correct asset1 quantity");
        assertEq(firstBundle.quantities[1], 20 * 10**18, "First bundle should have correct asset2 quantity");
        assertGt(firstBundle.value, 0, "First bundle should have positive value");

        AuctionTypes.Bundle memory bidder2Bundle = submittedBundles[7];
        assertEq(bidder2Bundle.commitHash, commitHash2, "Bidder2 bundle should have correct commit hash");
        assertEq(bidder2Bundle.quantities[0], 35 * 10**18, "Bidder2 bundle should have correct asset1 quantity");
        assertEq(bidder2Bundle.quantities[1], 25 * 10**18, "Bidder2 bundle should have correct asset2 quantity");

        AuctionTypes.Bundle memory bidder3Bundle = submittedBundles[4];
        assertEq(bidder3Bundle.commitHash, commitHash3, "Bidder3 bundle should have correct commit hash");
        assertEq(bidder3Bundle.quantities[0], 25 * 10**18, "Bidder3 bundle should have correct asset1 quantity");
        assertEq(bidder3Bundle.quantities[1], 15 * 10**18, "Bidder3 bundle should have correct asset2 quantity");

        for (uint256 i = 0; i < submittedBundles.length; i++) {
            assertGt(submittedBundles[i].value, 0, "All bundles should have positive value");
            assertEq(submittedBundles[i].quantities.length, 2, "All bundles should have 2 asset quantities");
            assertGt(submittedBundles[i].quantities[0], 0, "All bundles should have positive asset1 quantity");
            assertGt(submittedBundles[i].quantities[1], 0, "All bundles should have positive asset2 quantity");
        }

        console.log("Proxy phase verification completed successfully");
        console.log("Total bundles submitted:", submittedBundles.length);

        // ========================================
        // ALLOCATION PHASE
        // ========================================

        AuctionTypes.AuctionInfo memory auctionInfoAllocation = cpaManager.getAuctionInfo(auctionId);
        assertEq(uint8(auctionInfoAllocation.currentPhase), uint8(AuctionTypes.AuctionPhase.Allocation), "Auction should be in allocation phase");

        // Check ERC20 balances before allocation phase ends
        console.log("=== ERC20 BALANCES BEFORE ALLOCATION PHASE ENDS ===");
        {
            uint256 auctioneerNumeraireBefore = numeraireToken.balanceOf(auctioneer);
            uint256 managerNumeraireBefore = numeraireToken.balanceOf(address(cpaManager));
            console.log("Numeraire Token Balances:");
            console.log("  Auctioneer:", auctioneerNumeraireBefore);
            console.log("  CPAManager:", managerNumeraireBefore);
        }
        {
            uint256 managerAsset1Before = asset1Token.balanceOf(address(cpaManager));
            uint256 managerAsset2Before = asset2Token.balanceOf(address(cpaManager));
            console.log("Asset Balances (CPAManager):");
            console.log("  Asset1:", managerAsset1Before);
            console.log("  Asset2:", managerAsset2Before);
        }

        // Allocator 1: small allocation (1 bundle)
        address allocator1 = makeAddr("allocator1");
        BundleId[] memory allocator1Bundles = new BundleId[](1);
        allocator1Bundles[0] = bundleIds[0];

        AuctionTypes.Allocation memory allocation1 = AuctionTypes.Allocation({
            auctionId: auctionId,
            allocator: allocator1,
            bundleIds: allocator1Bundles,
            totalValue: 0,
            timestamp: block.timestamp
        });

        vm.prank(allocator1);
        cpaManager.submitAllocation(auctionId, allocation1);

        AuctionTypes.TopAllocation memory _top1 = cpaManager.getTopAllocation(auctionId);
        AuctionTypes.Allocation memory topAllocation1 = _top1.allocation; uint256 topScore1 = _top1.score;
        assertEq(topAllocation1.allocator, allocator1, "Allocator1 should be the top allocation");
        assertEq(topAllocation1.bundleIds.length, 1, "Allocator1 should have 1 bundle");
        assertGt(topScore1, 0, "Allocator1 should have a positive score");

        // Allocator 2: excessive allocation (should fail)
        address allocator2 = makeAddr("allocator2");
        BundleId[] memory allocator2Bundles = new BundleId[](3);
        allocator2Bundles[0] = bundleIds[0];
        allocator2Bundles[1] = bundleIds[1];
        allocator2Bundles[2] = bundleIds[2];

        AuctionTypes.Allocation memory allocation2 = AuctionTypes.Allocation({
            auctionId: auctionId,
            allocator: allocator2,
            bundleIds: allocator2Bundles,
            totalValue: 0,
            timestamp: block.timestamp
        });

        vm.prank(allocator2);
        vm.expectRevert();
        cpaManager.submitAllocation(auctionId, allocation2);

        AuctionTypes.TopAllocation memory _top2 = cpaManager.getTopAllocation(auctionId);
        AuctionTypes.Allocation memory topAllocationAfterFailure = _top2.allocation; uint256 topScoreAfterFailure = _top2.score;
        assertEq(topAllocationAfterFailure.allocator, allocator1, "Allocator1 should still be the top allocation");
        assertEq(topScoreAfterFailure, topScore1, "Top score should remain unchanged after failed allocation");

        // Allocator 3: better allocation (should win)
        address allocator3 = makeAddr("allocator3");
        BundleId[] memory allocator3Bundles = new BundleId[](3);
        allocator3Bundles[0] = bundleIds[0];
        allocator3Bundles[1] = bundleIds[4];
        allocator3Bundles[2] = bundleIds[7];

        AuctionTypes.Allocation memory allocation3 = AuctionTypes.Allocation({
            auctionId: auctionId,
            allocator: allocator3,
            bundleIds: allocator3Bundles,
            totalValue: 0,
            timestamp: block.timestamp
        });

        vm.prank(allocator3);
        cpaManager.submitAllocation(auctionId, allocation3);

        AuctionTypes.TopAllocation memory _top3 = cpaManager.getTopAllocation(auctionId);
        AuctionTypes.Allocation memory topAllocation3 = _top3.allocation; uint256 topScore3 = _top3.score;
        assertEq(topAllocation3.allocator, allocator3, "Allocator3 should now be the top allocation");
        assertEq(topAllocation3.bundleIds.length, 3, "Allocator3 should have 3 bundles");
        assertGt(topScore3, topScore1, "Allocator3 should have a higher score than allocator1");
        console.log("Allocator3 allocation recorded - Score:", topScore3);

        // End allocation phase
        auction = cpaManager.getAuctionInfo(auctionId);
        vm.warp(block.timestamp + auction.config.phaseDurations[1] + 1);
        transitionToSettlement(auctionId);

        // ========================================
        // VERIFY SETTLEMENT PHASE
        // ========================================

        AuctionTypes.AuctionInfo memory auctionInfoSettlement = cpaManager.getAuctionInfo(auctionId);
        assertEq(uint8(auctionInfoSettlement.currentPhase), uint8(AuctionTypes.AuctionPhase.Settlement), "Auction should be in settlement phase");

        AuctionTypes.TopAllocation memory _topWinner = cpaManager.getTopAllocation(auctionId);
        AuctionTypes.Allocation memory winnerAllocation = _topWinner.allocation; uint256 winnerScore = _topWinner.score;
        assertEq(winnerAllocation.allocator, allocator3, "Allocator3 should be the winner");
        assertGt(winnerScore, 0, "Winner should have a positive score");

        console.log("Allocation phase completed successfully");
        console.log("Winner allocator:", winnerAllocation.allocator);
        console.log("Winner score:", winnerScore);

        // ========================================
        // REVEAL PHASE
        // ========================================

        vm.prank(testBidder1);
        cpaManager.reveal(auctionId, testProxy1, saltA1, saltB1);

        vm.prank(testBidder2);
        cpaManager.reveal(auctionId, testProxy2, saltA2, saltB2);

        vm.prank(testBidder3);
        cpaManager.reveal(auctionId, testProxy1, saltA3, saltB3);

        address revealedBidder1 = cpaManager.revealedMappings(auctionId, commitHash1);
        address revealedBidder2 = cpaManager.revealedMappings(auctionId, commitHash2);
        address revealedBidder3 = cpaManager.revealedMappings(auctionId, commitHash3);

        assertEq(revealedBidder1, testBidder1, "Bidder1 should be revealed correctly");
        assertEq(revealedBidder2, testBidder2, "Bidder2 should be revealed correctly");
        assertEq(revealedBidder3, testBidder3, "Bidder3 should be revealed correctly");

        // ========================================
        // CLAIM PHASE
        // ========================================

        uint256 bidder1Asset1BalanceBefore = asset1Token.balanceOf(testBidder1);
        uint256 bidder1Asset2BalanceBefore = asset2Token.balanceOf(testBidder1);

        vm.prank(testBidder1);
        cpaManager.claimAllTokens(auctionId, commitHash1);

        uint256 bidder1Asset1BalanceAfter = asset1Token.balanceOf(testBidder1);
        uint256 bidder1Asset2BalanceAfter = asset2Token.balanceOf(testBidder1);

        assertGt(bidder1Asset1BalanceAfter, bidder1Asset1BalanceBefore, "Bidder1 should have received asset1 tokens");
        assertGt(bidder1Asset2BalanceAfter, bidder1Asset2BalanceBefore, "Bidder1 should have received asset2 tokens");

        // ========================================
        // ALLOCATOR REWARD CLAIM
        // ========================================

        AuctionTypes.Allocation memory currentWinnerAllocation = cpaManager.getTopAllocation(auctionId).allocation;
        address winningAllocator = currentWinnerAllocation.allocator;

        uint256 allocatorBalanceBefore = numeraireToken.balanceOf(winningAllocator);

        vm.prank(winningAllocator);
        cpaManager.claimAllocatorReward(auctionId);

        uint256 allocatorBalanceAfter = numeraireToken.balanceOf(winningAllocator);

        assertGt(allocatorBalanceAfter, allocatorBalanceBefore, "Winning allocator should have received reward");
        console.log("Allocator reward claim completed successfully");
        console.log("Reward claimed:", allocatorBalanceAfter - allocatorBalanceBefore);
    }

    function test_ReturnProceeds_AfterSettlement() public {
        // Set up full auction flow to settlement with a bidder claim
        AuctionTypes.AuctionConfig memory config = createStandardAuctionConfig();
        AuctionId id = createAuction(config, auctioneer);

        mintTokensToAuctioneer(depositAmount1 + depositAmount2);
        vm.prank(auctioneer); asset1Token.approve(address(cpaManager), depositAmount1);
        vm.prank(auctioneer); asset2Token.approve(address(cpaManager), depositAmount2);

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = depositAmount1;
        amounts[1] = depositAmount2;
        depositAllAndStartClock(id, amounts);

        // Clock phase
        bytes32 sA = keccak256("sA");
        bytes32 sB = keccak256("sB");
        bytes32 ch = CommitReveal.generateCommitHash(bidder1, proxy1, sA, sB);

        createBidder(bidder1, 1_000_000e18);
        approveNumeraireForBidder(bidder1, type(uint256).max);

        vm.prank(proxy1);
        cpaManager.commitToBidder(id, ch);

        uint256[] memory demands = new uint256[](2);
        demands[0] = 50e18;
        demands[1] = 50e18;

        vm.prank(bidder1);
        cpaManager.submitBid(id, demands, type(uint256).max);

        vm.prank(auctioneer);
        cpaManager.endClockPhase(id);

        // Proxy phase
        uint256[] memory qtys = new uint256[](2);
        qtys[0] = 50e18;
        qtys[1] = 50e18;

        AuctionTypes.Bundle memory b = AuctionTypes.Bundle({
            auctionId: id,
            commitHash: ch,
            value: 1000e18,
            quantities: qtys,
            timestamp: block.timestamp
        });

        vm.prank(proxy1);
        BundleId bid1 = cpaManager.submitBundle(id, ch, b);

        AuctionTypes.AuctionInfo memory ai = cpaManager.getAuctionInfo(id);
        vm.warp(block.timestamp + ai.config.phaseDurations[0] + 1);
        cpaManager.transitionToAllocation(id);

        // Allocation phase
        BundleId[] memory bids = new BundleId[](1);
        bids[0] = bid1;
        AuctionTypes.Allocation memory alloc = AuctionTypes.Allocation({
            auctionId: id,
            allocator: makeAddr("alloc"),
            bundleIds: bids,
            totalValue: 1000e18,
            timestamp: block.timestamp
        });

        vm.prank(makeAddr("alloc"));
        cpaManager.submitAllocation(id, alloc);

        ai = cpaManager.getAuctionInfo(id);
        vm.warp(block.timestamp + ai.config.phaseDurations[1] + 1);
        transitionToSettlement(id);

        // Reveal and claim
        vm.prank(bidder1);
        cpaManager.reveal(id, proxy1, sA, sB);

        vm.prank(bidder1);
        cpaManager.claimAllTokens(id, ch);

        // Test returnProceeds
        uint256 auctioneerBefore = numeraireToken.balanceOf(auctioneer);

        vm.prank(auctioneer);
        cpaManager.returnProceeds(id);

        uint256 auctioneerAfter = numeraireToken.balanceOf(auctioneer);
        assertGt(auctioneerAfter, auctioneerBefore, "Auctioneer should receive numeraire proceeds");

        // Verify proceedsClaimed is set (double-call should revert)
        vm.prank(auctioneer);
        vm.expectRevert();
        cpaManager.returnProceeds(id);

        console.log("test_ReturnProceeds_AfterSettlement passed");
        console.log("Proceeds received by auctioneer:", auctioneerAfter - auctioneerBefore);
    }

    function test_WithdrawProtocolFees() public {
        // Set up full auction with a claim so protocolAccrued > 0
        AuctionTypes.AuctionConfig memory config = createStandardAuctionConfig();
        AuctionId id = createAuction(config, auctioneer);

        mintTokensToAuctioneer(depositAmount1 + depositAmount2);
        vm.prank(auctioneer); asset1Token.approve(address(cpaManager), depositAmount1);
        vm.prank(auctioneer); asset2Token.approve(address(cpaManager), depositAmount2);

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = depositAmount1;
        amounts[1] = depositAmount2;
        depositAllAndStartClock(id, amounts);

        bytes32 sA = keccak256("wSA");
        bytes32 sB = keccak256("wSB");
        bytes32 ch = CommitReveal.generateCommitHash(bidder1, proxy1, sA, sB);

        createBidder(bidder1, 1_000_000e18);
        approveNumeraireForBidder(bidder1, type(uint256).max);

        vm.prank(proxy1);
        cpaManager.commitToBidder(id, ch);

        uint256[] memory demands = new uint256[](2);
        demands[0] = 50e18;
        demands[1] = 50e18;

        vm.prank(bidder1);
        cpaManager.submitBid(id, demands, type(uint256).max);

        vm.prank(auctioneer);
        cpaManager.endClockPhase(id);

        uint256[] memory qtys = new uint256[](2);
        qtys[0] = 50e18;
        qtys[1] = 50e18;

        AuctionTypes.Bundle memory b = AuctionTypes.Bundle({
            auctionId: id,
            commitHash: ch,
            value: 1000e18,
            quantities: qtys,
            timestamp: block.timestamp
        });

        vm.prank(proxy1);
        BundleId bid1 = cpaManager.submitBundle(id, ch, b);

        AuctionTypes.AuctionInfo memory ai = cpaManager.getAuctionInfo(id);
        vm.warp(block.timestamp + ai.config.phaseDurations[0] + 1);
        cpaManager.transitionToAllocation(id);

        BundleId[] memory bids = new BundleId[](1);
        bids[0] = bid1;
        address alloc = makeAddr("alloc2");
        AuctionTypes.Allocation memory allocObj = AuctionTypes.Allocation({
            auctionId: id,
            allocator: alloc,
            bundleIds: bids,
            totalValue: 1000e18,
            timestamp: block.timestamp
        });

        vm.prank(alloc);
        cpaManager.submitAllocation(id, allocObj);

        ai = cpaManager.getAuctionInfo(id);
        vm.warp(block.timestamp + ai.config.phaseDurations[1] + 1);
        transitionToSettlement(id);

        vm.prank(bidder1);
        cpaManager.reveal(id, proxy1, sA, sB);

        vm.prank(bidder1);
        cpaManager.claimAllTokens(id, ch);

        // protocolAccrued should be > 0 after a claim
        uint256 protocolAccruedAmount = cpaManager.protocolAccrued(id);
        assertGt(protocolAccruedAmount, 0, "protocolAccrued should be > 0 after claim");

        // address(this) is the protocolWallet
        uint256 protocolWalletBefore = numeraireToken.balanceOf(address(this));

        cpaManager.withdrawProtocolFees(id);

        uint256 protocolWalletAfter = numeraireToken.balanceOf(address(this));
        assertEq(protocolWalletAfter - protocolWalletBefore, protocolAccruedAmount, "protocolWallet should receive protocolAccrued amount");
        assertEq(cpaManager.protocolAccrued(id), 0, "protocolAccrued should be 0 after withdrawal");

        console.log("test_WithdrawProtocolFees passed");
        console.log("Protocol fees withdrawn:", protocolAccruedAmount);
    }
}
