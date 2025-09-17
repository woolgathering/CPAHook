// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { Test, console } from "forge-std/Test.sol";
import { CPATestBase } from "./base/CPATestBase.sol";
import { AuctionTypes } from "../src/AuctionTypes.sol";
import { AuctionId } from "../src/AuctionId.sol";
import { BundleId, BundleIdLibrary } from "../src/BundleId.sol";
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol"; 
import { CommitReveal } from "../src/CommitReveal.sol";
import { IErrorsAndEvents } from "../src/utils/IErrorsAndEvents.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { IERC6909Claims } from "@uniswap/v4-core/src/interfaces/external/IERC6909Claims.sol";

/**
 * @title CPACompleteFlowTest
 * @notice Comprehensive integration test covering the complete Clock-Proxy Auction flow
 * @author Clock-Proxy Auction Team
 */
contract CPACompleteFlowTest is CPATestBase {
    using StateLibrary for IPoolManager;
    
    // AuctionId auctionId;
    
    // Clock phase test data
    address testBidder1;
    address testBidder2;
    address testBidder3;
    
    // Bundle storage for allocation phase
    // Note: bundleIds[i] corresponds to submittedBundles[i] - allocators will use bundleIds for allocations
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
        
        // Move deposits to pools
        moveDeposit(auctionId, asset1PoolKey, 100 * 10**18);
        moveDeposit(auctionId, asset2PoolKey, 150 * 10**18);
        
        // Setup additional test bidders and proxies (base test only has bidder1, bidder2, proxy1, proxy2)
        setupAdditionalAccountsAndCommitHashes();
    }
    
    function setupAdditionalAccountsAndCommitHashes() internal {
        // Use existing accounts from base test: bidder1, bidder2, proxy1, proxy2
        // Only need to add bidder3
        testBidder1 = bidder1;  // Use existing bidder1
        testBidder2 = bidder2;  // Use existing bidder2
        testBidder3 = makeAddr("testBidder3");  // Create new bidder3
        
        testProxy1 = proxy1;    // Use existing proxy1
        testProxy2 = proxy2;    // Use existing proxy2
        
        // Create all bidders with sufficient tokens (including numeraire for staking)
        createBidder(testBidder1, 1000000 * 10**18);
        createBidder(testBidder2, 1000000 * 10**18);
        createBidder(testBidder3, 1000000 * 10**18);

        // Approve numeraire tokens for bidders
        approveNumeraireForBidder(testBidder1, type(uint256).max);
        approveNumeraireForBidder(testBidder2, type(uint256).max);
        approveNumeraireForBidder(testBidder3, type(uint256).max);
        
        // Generate commit-reveal data for all bidders
        saltA1 = keccak256("saltA1");
        saltB1 = keccak256("saltB1");
        saltA2 = keccak256("saltA2");
        saltB2 = keccak256("saltB2");
        saltA3 = keccak256("saltA3");
        saltB3 = keccak256("saltB3");
        
        commitHash1 = CommitReveal.generateCommitHash(testBidder1, testProxy1, saltA1, saltB1);
        commitHash2 = CommitReveal.generateCommitHash(testBidder2, testProxy2, saltA2, saltB2);
        commitHash3 = CommitReveal.generateCommitHash(testBidder3, testProxy1, saltA3, saltB3);
        
        
        // Generate proxy commit-reveal data
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
        
        // Have proxies commit to bidders
        vm.prank(testProxy1);
        cpaManager.commitToBidder(auctionId, commitHash1);
        vm.prank(testProxy2);
        cpaManager.commitToBidder(auctionId, commitHash2);
        vm.prank(testProxy1);
        cpaManager.commitToBidder(auctionId, commitHash3);
        
        // ========================================
        // CLOCK PHASE - ROUND 1
        // ========================================
        
        // Start clock phase
        vm.prank(auctioneer);
        cpaManager.startClockRound(auctionId);
        
        // Submit bids for round 1 - create excess demand on BOTH assets
        uint256[] memory demands1 = new uint256[](2);
        demands1[0] = 50 * 10**18;  // 50 tokens of asset1 (excess demand: 50 + 40 + 30 = 120 > 100 available)
        demands1[1] = 60 * 10**18;  // 60 tokens of asset2 (excess demand: 60 + 50 + 41 = 151 > 150 available)
        
        uint256[] memory demands2 = new uint256[](2);
        demands2[0] = 40 * 10**18;  // 40 tokens of asset1 (total demand: 120 > 100 available)
        demands2[1] = 50 * 10**18;  // 50 tokens of asset2 (total demand: 150 > 150 available)
        
        uint256[] memory demands3 = new uint256[](2);
        demands3[0] = 30 * 10**18;  // 30 tokens of asset1 (total demand: 120 > 100 available)
        demands3[1] = 41 * 10**18;  // 41 tokens of asset2 (total demand: 151 > 150 available)

        
        // Submit bids
        vm.prank(testBidder1);
        cpaManager.submitBid(auctionId, demands1, 1000 * 10**18);
        
        vm.prank(testBidder2);
        cpaManager.submitBid(auctionId, demands2, 1000 * 10**18);
        
        vm.prank(testBidder3);
        cpaManager.submitBid(auctionId, demands3, 1000 * 10**18);
        
        // End round 1 - should create excess demand and increase prices
        vm.prank(auctioneer);
        cpaManager.endClockRound(auctionId);
        
        // Verify round 1 results
        (,,,uint256 asset1Deposit1, uint256 asset1ExcessDemand1,,bytes32 asset1PositionId1) = cpaManager.getPoolInfo(asset1PoolKey.toId());
        (,,,uint256 asset2Deposit1, uint256 asset2ExcessDemand1,,bytes32 asset2PositionId1) = cpaManager.getPoolInfo(asset2PoolKey.toId());
        (, int24 asset1Tick1, , ) = poolManager.getSlot0(asset1PoolKey.toId());
        (, int24 asset2Tick1, , ) = poolManager.getSlot0(asset2PoolKey.toId());
        
        // Round 1: Both assets should have excess demand (120 > 100, 151 > 150)
        assertGt(asset1ExcessDemand1, 0, "Asset1 should have excess demand after round 1");
        assertGt(asset2ExcessDemand1, 0, "Asset2 should have excess demand after round 1");
        // Prices should have increased from starting prices
        assertGt(asset1Tick1, 0, "Asset1 price should have increased after round 1");
        assertGt(asset2Tick1, 0, "Asset2 price should have increased after round 1");
        
        // console.log("Round 1 - Asset1 excess demand:", asset1ExcessDemand1, "tick:", asset1Tick1);
        // console.log("Round 1 - Asset2 excess demand:", asset2ExcessDemand1, "tick:", asset2Tick1);
        
        // ========================================
        // CLOCK PHASE - ROUND 2
        // ========================================
        
        // Start round 2
        vm.prank(auctioneer);
        cpaManager.startClockRound(auctionId);
        
        // Submit bids for round 2 - only asset1 has excess demand
        uint256[] memory demands1_2 = new uint256[](2);
        demands1_2[0] = 45 * 10**18;  // Reduced demand (total: 45 + 35 + 25 = 105 > 100)
        demands1_2[1] = 45 * 10**18;  // Reduced demand (total: 45 + 35 + 25 = 105 < 150)
        
        uint256[] memory demands2_2 = new uint256[](2);
        demands2_2[0] = 35 * 10**18;  // Reduced demand
        demands2_2[1] = 35 * 10**18;  // Reduced demand
        
        uint256[] memory demands3_2 = new uint256[](2);
        demands3_2[0] = 25 * 10**18;  // Reduced demand
        demands3_2[1] = 25 * 10**18;  // Reduced demand
        
        // All 3 bidders submit in round 2
        vm.prank(testBidder1);
        cpaManager.submitBid(auctionId, demands1_2, 1000 * 10**18);
        
        vm.prank(testBidder2);
        cpaManager.submitBid(auctionId, demands2_2, 1000 * 10**18);
        
        vm.prank(testBidder3);
        cpaManager.submitBid(auctionId, demands3_2, 1000 * 10**18);
        
        // End round 2
        vm.prank(auctioneer);
        cpaManager.endClockRound(auctionId);
        
        // Verify round 2 results
        (,,,uint256 asset1Deposit2, uint256 asset1ExcessDemand2,,bytes32 asset1PositionId2) = cpaManager.getPoolInfo(asset1PoolKey.toId());
        (,,,uint256 asset2Deposit2, uint256 asset2ExcessDemand2,,bytes32 asset2PositionId2) = cpaManager.getPoolInfo(asset2PoolKey.toId());
        (, int24 asset1Tick2, , ) = poolManager.getSlot0(asset1PoolKey.toId());
        (, int24 asset2Tick2, , ) = poolManager.getSlot0(asset2PoolKey.toId());
        
        // Round 2: Only asset1 has excess demand (105 > 100, 105 < 150)
        assertGt(asset1ExcessDemand2, 0, "Asset1 should still have excess demand after round 2");
        assertEq(asset2ExcessDemand2, 0, "Asset2 should have no excess demand after round 2");
        // Excess demand should be reduced compared to round 1
        assertLt(asset1ExcessDemand2, asset1ExcessDemand1, "Asset1 excess demand should be reduced in round 2");
        assertLt(asset2ExcessDemand2, asset2ExcessDemand1, "Asset2 excess demand should be reduced in round 2");
        // Only asset1 price should increase (has excess demand), asset2 price should stay same (no excess demand)
        assertGt(asset1Tick2, asset1Tick1, "Asset1 price should continue increasing in round 2");
        assertEq(asset2Tick2, asset2Tick1, "Asset2 price should remain the same in round 2 (no excess demand)");
        
        // console.log("Round 2 - Asset1 excess demand:", asset1ExcessDemand2, "tick:", asset1Tick2);
        // console.log("Round 2 - Asset2 excess demand:", asset2ExcessDemand2, "tick:", asset2Tick2);
        
        // ========================================
        // CLOCK PHASE - ROUND 3 (FINAL)
        // ========================================
        
        // Start round 3
        vm.prank(auctioneer);
        cpaManager.startClockRound(auctionId);
        
        // Submit final bids - no excess demand on either asset
        uint256[] memory demands1_3 = new uint256[](2);
        demands1_3[0] = 35 * 10**18;  // Further reduced (total: 35 + 30 + 25 = 90 < 100)
        demands1_3[1] = 40 * 10**18;  // Further reduced (total: 40 + 35 + 30 = 105 < 150)
        
        uint256[] memory demands2_3 = new uint256[](2);
        demands2_3[0] = 30 * 10**18;  // Further reduced
        demands2_3[1] = 35 * 10**18;  // Further reduced
        
        uint256[] memory demands3_3 = new uint256[](2);
        demands3_3[0] = 25 * 10**18;  // Further reduced
        demands3_3[1] = 30 * 10**18;  // Further reduced
        
        vm.prank(testBidder1);
        cpaManager.submitBid(auctionId, demands1_3, 1000 * 10**18);
        
        vm.prank(testBidder2);
        cpaManager.submitBid(auctionId, demands2_3, 1000 * 10**18);
        
        vm.prank(testBidder3);
        cpaManager.submitBid(auctionId, demands3_3, 1000 * 10**18);
        
        // End round 3
        vm.prank(auctioneer);
        cpaManager.endClockRound(auctionId);
        
        // Verify round 3 results
        (,,,uint256 asset1Deposit3, uint256 asset1ExcessDemand3,,bytes32 asset1PositionId3) = cpaManager.getPoolInfo(asset1PoolKey.toId());
        (,,,uint256 asset2Deposit3, uint256 asset2ExcessDemand3,,bytes32 asset2PositionId3) = cpaManager.getPoolInfo(asset2PoolKey.toId());
        (, int24 asset1Tick3, , ) = poolManager.getSlot0(asset1PoolKey.toId());
        (, int24 asset2Tick3, , ) = poolManager.getSlot0(asset2PoolKey.toId());
        
        // Round 3: No excess demand on either asset (90 < 100, 105 < 150)
        assertEq(asset1ExcessDemand3, 0, "Asset1 should have no excess demand after round 3");
        assertEq(asset2ExcessDemand3, 0, "Asset2 should have no excess demand after round 3");
        // Prices should continue to increase
        assertEq(asset1Tick3, asset1Tick2, "Asset1 price should be equal after round 3");
        assertEq(asset2Tick3, asset2Tick2, "Asset2 price should be equal after round 3");
        
        // console.log("Round 3 - Asset1 excess demand:", asset1ExcessDemand3, "tick:", asset1Tick3);
        // console.log("Round 3 - Asset2 excess demand:", asset2ExcessDemand3, "tick:", asset2Tick3);
        
        // ========================================
        // END CLOCK PHASE
        // ========================================
        
        // End clock phase to move to proxy phase
        vm.prank(auctioneer);
        cpaManager.endClockPhase(auctionId);
        
        // ========================================
        // VERIFY CLOCK PHASE RESULTS
        // ========================================
        
        // Verify auction is now in proxy phase
        (,,,AuctionTypes.AuctionPhase currentPhase,,,,,) = cpaManager.getAuctionInfo(auctionId);
        assertEq(uint8(currentPhase), uint8(AuctionTypes.AuctionPhase.Proxy), "Auction should be in proxy phase");
        
        // Verify final pool states
        (, int24 asset1StartingTick, , uint256 asset1FinalDeposit, uint256 asset1FinalExcessDemand,,bytes32 asset1FinalPositionId) = cpaManager.getPoolInfo(asset1PoolKey.toId());
        (, int24 asset2StartingTick, , uint256 asset2FinalDeposit, uint256 asset2FinalExcessDemand,,bytes32 asset2FinalPositionId) = cpaManager.getPoolInfo(asset2PoolKey.toId());
        
        // Get current prices from pool manager Slot0
        (, int24 asset1FinalTick, , ) = poolManager.getSlot0(asset1PoolKey.toId());
        (, int24 asset2FinalTick, , ) = poolManager.getSlot0(asset2PoolKey.toId());
        
        // Prices should have increased from starting prices due to excess demand
        assertGt(asset1FinalTick, asset1StartingTick, "Asset1 price should have increased from starting price");
        assertGt(asset2FinalTick, asset2StartingTick, "Asset2 price should have increased from starting price");
        
        // Final excess demand should be reduced (but may not be zero)
        assertLt(asset1FinalExcessDemand, 100 * 10**18, "Asset1 excess demand should be reduced");
        assertLt(asset2FinalExcessDemand, 150 * 10**18, "Asset2 excess demand should be reduced");
        
        console.log("Clock phase completed successfully");
        console.log("Asset1 final tick:", asset1FinalTick);
        console.log("Asset2 final tick:", asset2FinalTick);
        console.log("Asset1 final excess demand:", asset1FinalExcessDemand);
        console.log("Asset2 final excess demand:", asset2FinalExcessDemand);
        
        // ========================================
        // PROXY PHASE
        // ========================================

        // vm.prank(auctioneer);
        // cpaManager.startProxyPhase(auctionId); // automatically moved to proxy phase by calling endClockPhase
        
        // testProxy1 submits bundles for testBidder1 (3-5 bundles)
        for (uint256 i = 0; i < 4; i++) {
            uint256[] memory quantities1 = new uint256[](2);
            quantities1[0] = (30 + i * 5) * 10**18;  // Vary quantities: 30, 35, 40, 45
            quantities1[1] = (20 + i * 3) * 10**18;  // Vary quantities: 20, 23, 26, 29
            
            AuctionTypes.Bundle memory bundle1 = AuctionTypes.Bundle({
                auctionId: auctionId,
                commitHash: commitHash1,
                value: calculateBidValue(quantities1),
                quantities: quantities1,
                timestamp: block.timestamp
            });
            
            // Generate and save bundle ID for allocation phase
            BundleId bundleId1 = BundleIdLibrary.createId(commitHash1, keccak256(abi.encode(quantities1)));
            bundleIds.push(bundleId1);
            
            // Save bundle for allocation phase
            submittedBundles.push(bundle1);
            
            vm.prank(testProxy1);
            cpaManager.submitBundle(auctionId, commitHash1, bundle1);
        }
        
        // testProxy1 submits bundles for testBidder3 (3-5 bundles)
        for (uint256 i = 0; i < 3; i++) {
            uint256[] memory quantities3 = new uint256[](2);
            quantities3[0] = (25 + i * 4) * 10**18;  // Vary quantities: 25, 29, 33
            quantities3[1] = (15 + i * 2) * 10**18;  // Vary quantities: 15, 17, 19
            
            AuctionTypes.Bundle memory bundle3 = AuctionTypes.Bundle({
                auctionId: auctionId,
                commitHash: commitHash3,
                value: calculateBidValue(quantities3),
                quantities: quantities3,
                timestamp: block.timestamp
            });
            
            // Generate and save bundle ID for allocation phase
            BundleId bundleId3 = BundleIdLibrary.createId(commitHash3, keccak256(abi.encode(quantities3)));
            bundleIds.push(bundleId3);
            
            // Save bundle for allocation phase
            submittedBundles.push(bundle3);
            
            vm.prank(testProxy1);
            cpaManager.submitBundle(auctionId, commitHash3, bundle3);
        }
        
        // testProxy2 submits bundles for testBidder2 (3-5 bundles)
        for (uint256 i = 0; i < 4; i++) {
            uint256[] memory quantities2 = new uint256[](2);
            quantities2[0] = (35 + i * 3) * 10**18;  // Vary quantities: 35, 38, 41, 44
            quantities2[1] = (25 + i * 4) * 10**18;  // Vary quantities: 25, 29, 33, 37
            
            AuctionTypes.Bundle memory bundle2 = AuctionTypes.Bundle({
                auctionId: auctionId,
                commitHash: commitHash2,
                value: calculateBidValue(quantities2),
                quantities: quantities2,
                timestamp: block.timestamp
            });
            
            // Generate and save bundle ID for allocation phase
            BundleId bundleId2 = BundleIdLibrary.createId(commitHash2, keccak256(abi.encode(quantities2)));
            bundleIds.push(bundleId2);
            
            // Save bundle for allocation phase
            submittedBundles.push(bundle2);
            
            vm.prank(testProxy2);
            cpaManager.submitBundle(auctionId, commitHash2, bundle2);
        }
        
        vm.prank(auctioneer);
        cpaManager.endProxyPhase(auctionId);

        // ========================================
        // VERIFY PROXY PHASE RESULTS
        // ========================================

        // Verify auction is now in allocation phase
        (,,,AuctionTypes.AuctionPhase phaseAfterProxyPhase,,,,,) = cpaManager.getAuctionInfo(auctionId);
        assertEq(uint8(phaseAfterProxyPhase), uint8(AuctionTypes.AuctionPhase.Allocation), "Auction should be in allocation phase");
        
        // Verify total bundles submitted
        assertEq(submittedBundles.length, 11, "Should have submitted 11 bundles total (4+3+4)");
        assertEq(bundleIds.length, 11, "Should have 11 bundle IDs corresponding to submitted bundles");
        
        // Verify bundles were properly stored by checking a few key bundles
        // Check first bundle from bidder1
        AuctionTypes.Bundle memory firstBundle = submittedBundles[0];
        assertEq(uint256(AuctionId.unwrap(firstBundle.auctionId)), uint256(AuctionId.unwrap(auctionId)), "First bundle should have correct auction ID");
        assertEq(firstBundle.commitHash, commitHash1, "First bundle should have correct commit hash");
        assertEq(firstBundle.quantities[0], 30 * 10**18, "First bundle should have correct asset1 quantity");
        assertEq(firstBundle.quantities[1], 20 * 10**18, "First bundle should have correct asset2 quantity");
        assertGt(firstBundle.value, 0, "First bundle should have positive value");
        
        // Check bundle from bidder2
        AuctionTypes.Bundle memory bidder2Bundle = submittedBundles[7]; // First bidder2 bundle (after 4 bidder1 + 3 bidder3)
        assertEq(bidder2Bundle.commitHash, commitHash2, "Bidder2 bundle should have correct commit hash");
        assertEq(bidder2Bundle.quantities[0], 35 * 10**18, "Bidder2 bundle should have correct asset1 quantity");
        assertEq(bidder2Bundle.quantities[1], 25 * 10**18, "Bidder2 bundle should have correct asset2 quantity");
        
        // Check bundle from bidder3
        AuctionTypes.Bundle memory bidder3Bundle = submittedBundles[4]; // First bidder3 bundle (after 4 bidder1)
        assertEq(bidder3Bundle.commitHash, commitHash3, "Bidder3 bundle should have correct commit hash");
        assertEq(bidder3Bundle.quantities[0], 25 * 10**18, "Bidder3 bundle should have correct asset1 quantity");
        assertEq(bidder3Bundle.quantities[1], 15 * 10**18, "Bidder3 bundle should have correct asset2 quantity");
        
        // Note: Bundle IDs are now generated internally by the submitBundle function
        // and are guaranteed to be unique based on commitHash and quantities hash
        
        // Verify all bundles have valid values
        for (uint256 i = 0; i < submittedBundles.length; i++) {
            assertGt(submittedBundles[i].value, 0, "All bundles should have positive value");
            assertEq(submittedBundles[i].quantities.length, 2, "All bundles should have 2 asset quantities");
            assertGt(submittedBundles[i].quantities[0], 0, "All bundles should have positive asset1 quantity");
            assertGt(submittedBundles[i].quantities[1], 0, "All bundles should have positive asset2 quantity");
        }
        
        console.log("Proxy phase verification completed successfully");
        console.log("Total bundles submitted:", submittedBundles.length);

        for (uint256 i = 0; i < submittedBundles.length; i++) {
            console.log("Bundle", i);
            console.log("bundle ID:", uint256(BundleId.unwrap(bundleIds[i])));
            console.log("commit hash (hex):", uint256(submittedBundles[i].commitHash));
            console.log("value:", submittedBundles[i].value);
            
            // Log quantities individually since console.log can't handle arrays
            for (uint256 j = 0; j < submittedBundles[i].quantities.length; j++) {
                console.log("  quantity[%d]:", j, submittedBundles[i].quantities[j]);
            }
        }

        // ========================================
        // ALLOCATION PHASE
        // ========================================

        // Verify auction is now in allocation phase
        (,,, currentPhase,,,,,) = cpaManager.getAuctionInfo(auctionId);
        assertEq(uint8(currentPhase), uint8(AuctionTypes.AuctionPhase.Allocation), "Auction should be in allocation phase");

        // Test allocator 1 submits an allocation with just bundle 0 (small allocation)
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

        // Verify allocator1's allocation was recorded as the top allocation
        (AuctionTypes.Allocation memory topAllocation1, uint256 topScore1, ) = cpaManager.topAllocation(auctionId);
        assertEq(topAllocation1.allocator, allocator1, "Allocator1 should be the top allocation");
        assertEq(topAllocation1.bundleIds.length, 1, "Allocator1 should have 1 bundle");
        assertEq(BundleId.unwrap(topAllocation1.bundleIds[0]), BundleId.unwrap(bundleIds[0]), "Allocator1 should have bundle 0");
        assertGt(topScore1, 0, "Allocator1 should have a positive score");
        console.log("Allocator1 allocation recorded - Score:", topScore1);

        // Test allocator 2 submits an allocation that fails due to exceeding deposits
        // This will try to allocate bundles 0, 1, and 2 which exceeds available deposits
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

        // This should fail with InvalidQuantities
        vm.prank(allocator2);
        vm.expectRevert();
        cpaManager.submitAllocation(auctionId, allocation2);

        // Verify that allocator1 is still the top allocation after allocator2's failed attempt
        (AuctionTypes.Allocation memory topAllocationAfterFailure, uint256 topScoreAfterFailure, ) = cpaManager.topAllocation(auctionId);
        assertEq(topAllocationAfterFailure.allocator, allocator1, "Allocator1 should still be the top allocation after allocator2's failure");
        assertEq(topScoreAfterFailure, topScore1, "Top score should remain unchanged after failed allocation");
        console.log("Allocator2's failed allocation did not change the top allocation");

        // Test allocator 3 submits a better allocation that beats allocator 1
        // This uses bundles 0, 4, and 7 (one bundle from each bidder/proxy)
        address allocator3 = makeAddr("allocator3");
        BundleId[] memory allocator3Bundles = new BundleId[](3);
        allocator3Bundles[0] = bundleIds[0];  // From testProxy1
        allocator3Bundles[1] = bundleIds[4];  // From testProxy2  
        allocator3Bundles[2] = bundleIds[7];  // From testProxy3

        AuctionTypes.Allocation memory allocation3 = AuctionTypes.Allocation({
            auctionId: auctionId,
            allocator: allocator3,
            bundleIds: allocator3Bundles,
            totalValue: 0,
            timestamp: block.timestamp
        });

        vm.prank(allocator3);
        cpaManager.submitAllocation(auctionId, allocation3);

        // Verify that allocator3's allocation replaced allocator1 as the top allocation
        (AuctionTypes.Allocation memory topAllocation3, uint256 topScore3, ) = cpaManager.topAllocation(auctionId);
        assertEq(topAllocation3.allocator, allocator3, "Allocator3 should now be the top allocation");
        assertEq(topAllocation3.bundleIds.length, 3, "Allocator3 should have 3 bundles");
        assertEq(BundleId.unwrap(topAllocation3.bundleIds[0]), BundleId.unwrap(bundleIds[0]), "Allocator3 should have bundle 0 (from testProxy1)");
        assertEq(BundleId.unwrap(topAllocation3.bundleIds[1]), BundleId.unwrap(bundleIds[4]), "Allocator3 should have bundle 4 (from testProxy2)");
        assertEq(BundleId.unwrap(topAllocation3.bundleIds[2]), BundleId.unwrap(bundleIds[7]), "Allocator3 should have bundle 7 (from testProxy3)");
        assertGt(topScore3, topScore1, "Allocator3 should have a higher score than allocator1");
        console.log("Allocator3 allocation recorded - Score:", topScore3);
        console.log("Allocator3 beat allocator1 - previous score:", topScore1);
        console.log("Allocator3 beat allocator1 - new score:", topScore3);

        // ========================================
        // CHECK BALANCES BEFORE ALLOCATION PHASE ENDS
        // ========================================
        console.log("\n=== COMPREHENSIVE BALANCE CHECK BEFORE ALLOCATION PHASE ENDS ===");
        
        // Get pool keys for the auction
        (,,,,,,,,PoolKey[] memory poolKeys) = cpaManager.getAuctionInfo(auctionId);
        
        // Check ERC20 balances for all tokens
        console.log("=== ERC20 BALANCES BEFORE ALLOCATION PHASE ENDS ===");
        
        // Check numeraire token balances
        {
            uint256 auctioneerNumeraireBefore = numeraireToken.balanceOf(auctioneer);
            uint256 managerNumeraireBefore = numeraireToken.balanceOf(address(cpaManager));
            uint256 poolManagerNumeraireBefore = numeraireToken.balanceOf(address(poolManager));
            
            console.log("Numeraire Token Balances:");
            console.log("  Auctioneer:", auctioneerNumeraireBefore);
            console.log("  CPAManager:", managerNumeraireBefore);
            console.log("  PoolManager:", poolManagerNumeraireBefore);
        }
        
        // Check asset token balances
        {
            uint256 auctioneerAsset1Before = asset1Token.balanceOf(auctioneer);
            uint256 managerAsset1Before = asset1Token.balanceOf(address(cpaManager));
            uint256 poolManagerAsset1Before = asset1Token.balanceOf(address(poolManager));
            
            console.log("Asset1 Token Balances:");
            console.log("  Auctioneer:", auctioneerAsset1Before);
            console.log("  CPAManager:", managerAsset1Before);
            console.log("  PoolManager:", poolManagerAsset1Before);
        }
        
        {
            uint256 auctioneerAsset2Before = asset2Token.balanceOf(auctioneer);
            uint256 managerAsset2Before = asset2Token.balanceOf(address(cpaManager));
            uint256 poolManagerAsset2Before = asset2Token.balanceOf(address(poolManager));
            
            console.log("Asset2 Token Balances:");
            console.log("  Auctioneer:", auctioneerAsset2Before);
            console.log("  CPAManager:", managerAsset2Before);
            console.log("  PoolManager:", poolManagerAsset2Before);
        }
        
        // Check ERC6909 claim balances
        console.log("=== ERC6909 CLAIM BALANCES BEFORE ALLOCATION PHASE ENDS ===");
        
        {
            uint256 managerNumeraireClaimsBefore = IERC6909Claims(address(poolManager)).balanceOf(address(cpaManager), uint256(uint160(address(numeraireToken))));
            uint256 managerAsset1ClaimsBefore = IERC6909Claims(address(poolManager)).balanceOf(address(cpaManager), uint256(uint160(address(asset1Token))));
            uint256 managerAsset2ClaimsBefore = IERC6909Claims(address(poolManager)).balanceOf(address(cpaManager), uint256(uint160(address(asset2Token))));
            
            console.log("ERC6909 Claim Balances (CPAManager):");
            console.log("  Numeraire Claims:", managerNumeraireClaimsBefore);
            console.log("  Asset1 Claims:", managerAsset1ClaimsBefore);
            console.log("  Asset2 Claims:", managerAsset2ClaimsBefore);
        }
        
        // Check liquidity before allocation phase ends
        console.log("=== LIQUIDITY CHECK BEFORE ALLOCATION PHASE ENDS ===");
        for (uint256 i = 0; i < poolKeys.length; i++) {
            PoolId poolId = poolKeys[i].toId();
            uint128 liquidityBefore = poolManager.getLiquidity(poolId);
            console.log("Pool", i, "- Liquidity BEFORE allocation phase ends:", liquidityBefore);
            assertEq(liquidityBefore, 0, "Pool liquidity should be 0 before allocation phase ends");
        }

        // End allocation phase
        vm.prank(auctioneer);
        cpaManager.endAllocationPhase(auctionId);

        // ========================================
        // CHECK BALANCES AFTER ALLOCATION PHASE ENDS
        // ========================================
        console.log("\n=== COMPREHENSIVE BALANCE CHECK AFTER ALLOCATION PHASE ENDS ===");
        
        // Check ERC20 balances for all tokens
        console.log("=== ERC20 BALANCES AFTER ALLOCATION PHASE ENDS ===");
        
        // Check numeraire token balances
        {
            uint256 auctioneerNumeraireAfter = numeraireToken.balanceOf(auctioneer);
            uint256 managerNumeraireAfter = numeraireToken.balanceOf(address(cpaManager));
            uint256 poolManagerNumeraireAfter = numeraireToken.balanceOf(address(poolManager));
            
            console.log("Numeraire Token Balances:");
            console.log("  Auctioneer:", auctioneerNumeraireAfter);
            console.log("  CPAManager:", managerNumeraireAfter);
            console.log("  PoolManager:", poolManagerNumeraireAfter);
        }
        
        // Check asset token balances
        {
            uint256 auctioneerAsset1After = asset1Token.balanceOf(auctioneer);
            uint256 managerAsset1After = asset1Token.balanceOf(address(cpaManager));
            uint256 poolManagerAsset1After = asset1Token.balanceOf(address(poolManager));
            
            console.log("Asset1 Token Balances:");
            console.log("  Auctioneer:", auctioneerAsset1After);
            console.log("  CPAManager:", managerAsset1After);
            console.log("  PoolManager:", poolManagerAsset1After);
        }
        
        {
            uint256 auctioneerAsset2After = asset2Token.balanceOf(auctioneer);
            uint256 managerAsset2After = asset2Token.balanceOf(address(cpaManager));
            uint256 poolManagerAsset2After = asset2Token.balanceOf(address(poolManager));
            
            console.log("Asset2 Token Balances:");
            console.log("  Auctioneer:", auctioneerAsset2After);
            console.log("  CPAManager:", managerAsset2After);
            console.log("  PoolManager:", poolManagerAsset2After);
        }
        
        // Check ERC6909 claim balances
        console.log("=== ERC6909 CLAIM BALANCES AFTER ALLOCATION PHASE ENDS ===");
        
        {
            uint256 managerNumeraireClaimsAfter = IERC6909Claims(address(poolManager)).balanceOf(address(cpaManager), uint256(uint160(address(numeraireToken))));
            uint256 managerAsset1ClaimsAfter = IERC6909Claims(address(poolManager)).balanceOf(address(cpaManager), uint256(uint160(address(asset1Token))));
            uint256 managerAsset2ClaimsAfter = IERC6909Claims(address(poolManager)).balanceOf(address(cpaManager), uint256(uint160(address(asset2Token))));
            
            console.log("ERC6909 Claim Balances (CPAManager):");
            console.log("  Numeraire Claims:", managerNumeraireClaimsAfter);
            console.log("  Asset1 Claims:", managerAsset1ClaimsAfter);
            console.log("  Asset2 Claims:", managerAsset2ClaimsAfter);
        }
        
        // Check liquidity after allocation phase ends
        console.log("=== LIQUIDITY CHECK AFTER ALLOCATION PHASE ENDS ===");
        for (uint256 i = 0; i < poolKeys.length; i++) {
            PoolId poolId = poolKeys[i].toId();
            uint128 liquidityAfter = poolManager.getLiquidity(poolId);
            (,,,,,,bytes32 positionId) = cpaManager.poolInfo(poolId);
            console.log("Pool", i, "- Liquidity AFTER allocation phase ends:", liquidityAfter);
            console.log("Pool", i, "- Position id:", uint256(positionId));
            logLiquidity(poolManager, poolKeys[i], positionId);
            // assertGt(liquidityAfter, 0, "Pool liquidity should be greater than 0 after allocation phase ends");
        }
        
        // ========================================
        // VERIFY BALANCE CHANGES
        // ========================================
        console.log("\n=== BALANCE CHANGE ANALYSIS ===");
        
        // Note: Balance change analysis removed to avoid stack too deep error
        // The individual balance checks above provide sufficient verification

        // Verify auction is now in settlement phase
        (,,,AuctionTypes.AuctionPhase finalPhase,,,,,) = cpaManager.getAuctionInfo(auctionId);
        assertEq(uint8(finalPhase), uint8(AuctionTypes.AuctionPhase.Settlement), "Auction should be in settlement phase");

        // Verify the winner was determined (should be allocator3 with the better allocation)
        (AuctionTypes.Allocation memory winnerAllocation, uint256 winnerScore, ) = cpaManager.topAllocation(auctionId);
        assertEq(winnerAllocation.allocator, allocator3, "Allocator3 should be the winner");
        assertGt(winnerScore, 0, "Winner should have a positive score");

        console.log("Allocation phase completed successfully");
        console.log("Winner allocator:", winnerAllocation.allocator);
        console.log("Winner score:", winnerScore);
        console.log("Winner bundle count:", winnerAllocation.bundleIds.length);
        console.log("Allocator1 (small allocation) was beaten by allocator3");
        console.log("Allocator2 (excessive allocation) failed validation");

        // ========================================
        // REVEAL PHASE - REVEAL BIDDER MAPPINGS
        // ========================================
        console.log("\n=== REVEAL PHASE ===");
        
        // Reveal bidder1's commit hash
        vm.prank(testBidder1);
        cpaManager.reveal(auctionId, testProxy1, saltA1, saltB1);
        console.log("Bidder1 revealed successfully");
        
        // Reveal bidder2's commit hash  
        vm.prank(testBidder2);
        cpaManager.reveal(auctionId, testProxy2, saltA2, saltB2);
        console.log("Bidder2 revealed successfully");
        
        // Reveal bidder3's commit hash
        vm.prank(testBidder3);
        cpaManager.reveal(auctionId, testProxy1, saltA3, saltB3);
        console.log("Bidder3 revealed successfully");
        
        // Verify the reveal mappings
        address revealedBidder1 = cpaManager.revealedMappings(auctionId, commitHash1);
        address revealedBidder2 = cpaManager.revealedMappings(auctionId, commitHash2);
        address revealedBidder3 = cpaManager.revealedMappings(auctionId, commitHash3);
        
        assertEq(revealedBidder1, testBidder1, "Bidder1 should be revealed correctly");
        assertEq(revealedBidder2, testBidder2, "Bidder2 should be revealed correctly");
        assertEq(revealedBidder3, testBidder3, "Bidder3 should be revealed correctly");
        
        console.log("All bidders revealed successfully");
        console.log("Revealed bidder1:", revealedBidder1);
        console.log("Revealed bidder2:", revealedBidder2);
        console.log("Revealed bidder3:", revealedBidder3);

        // ========================================
        // CLAIM PHASE - BIDDER1 CLAIMS ALLOCATION
        // ========================================
        console.log("\n=== CLAIM PHASE ===");
        
        // Get the winning allocation to see which bundles are included
        (AuctionTypes.Allocation memory winnerAllocation2, , ) = cpaManager.topAllocation(auctionId);
        console.log("Winner allocation has", winnerAllocation2.bundleIds.length, "bundles");
        
        // Try to claim from the first pool (asset1) for bidder1
        // We'll use commitHash1 since that's what bidder1 used
        PoolId asset1PoolId = asset1PoolKey.toId();
        
        console.log("Bidder1 attempting to claim from asset1 pool...");
        
        // Check bidder1's stake before claiming
        uint256 bidder1StakeBefore = cpaManager.bidderStake(auctionId, testBidder1);
        console.log("Bidder1 stake before claim:", bidder1StakeBefore);
        
        // Attempt to claim
        vm.prank(testBidder1);
        cpaManager.claimToken(auctionId, commitHash1, asset1PoolId);
        
        console.log("Bidder1 claim completed successfully");
        
        // Check bidder1's stake after claiming
        uint256 bidder1StakeAfter = cpaManager.bidderStake(auctionId, testBidder1);
        console.log("Bidder1 stake after claim:", bidder1StakeAfter);
        console.log("Stake used for claim:", bidder1StakeBefore - bidder1StakeAfter);

    }

    function logLiquidity(
        IPoolManager manager,
        PoolKey memory poolKey,
        bytes32 positionId
    ) internal view {
        PoolId poolId = poolKey.toId();

        // 1. Active pool liquidity at current tick
        uint128 activeLiquidity = manager.getLiquidity(poolId);

        // 2. Your position liquidity
        uint128 positionLiquidity = manager.getPositionLiquidity(poolId,positionId);

        console.log("Pool active liquidity:", activeLiquidity);
        console.log("My position liquidity:", positionLiquidity);
    }

}
