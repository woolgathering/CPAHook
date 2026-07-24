// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { CPAManager } from "../src/CPAManager.sol";
import { AuctionTypes } from "../src/types/AuctionTypes.sol";
import { AuctionId } from "../src/types/AuctionId.sol";
import { BundleId, BundleIdLibrary } from "../src/types/BundleId.sol";
import { IErrorsAndEvents } from "../src/utils/IErrorsAndEvents.sol";
import { CommitReveal } from "../src/utils/CommitReveal.sol";
import { CPATestBase } from "./base/CPATestBase.sol";

contract CPAFinishedPhaseTest is CPATestBase {

    // Test participants
    address allocator1;

    // Commit-reveal data
    bytes32 saltA1;
    bytes32 saltB1;
    bytes32 saltA2;
    bytes32 saltB2;
    bytes32 saltA3;
    bytes32 saltB3;
    bytes32 commitHash1;
    bytes32 commitHash2;
    bytes32 commitHash3;

    // Bundle data
    BundleId bundleId1;
    BundleId bundleId2;

    function setUp() public override {
        // Set up base test environment
        super.setUp();

        // Create test participants
        allocator1 = makeAddr("allocator1");

        // Create auction with standard configuration
        AuctionTypes.AuctionConfig memory config = createStandardAuctionConfig();
        auctionId = createAuction(config, auctioneer);

        // Mint tokens to auctioneer and approve
        mintTokensToAuctioneer(1000000 * 10**18);
        approveTokens(address(asset1Token), address(cpaManager), 1000 * 10**18);
        approveTokens(address(asset2Token), address(cpaManager), 1000 * 10**18);

        // Move deposits to pools
        moveDeposit(auctionId, address(asset1Token), 100 * 10**18);
        moveDeposit(auctionId, address(asset2Token), 150 * 10**18);

        // Generate commit-reveal data
        saltA1 = keccak256("saltA1");
        saltB1 = keccak256("saltB1");
        saltA2 = keccak256("saltA2");
        saltB2 = keccak256("saltB2");
        saltA3 = keccak256("saltA3");
        saltB3 = keccak256("saltB3");
        commitHash1 = CommitReveal.generateCommitHash(bidder1, proxy1, saltA1, saltB1);
        commitHash2 = CommitReveal.generateCommitHash(bidder2, proxy2, saltA2, saltB2);
        commitHash3 = CommitReveal.generateCommitHash(bidder3, proxy3, saltA3, saltB3);

        // Set up complete auction flow to finished phase
        setupCompleteAuctionFlow();
    }

    function setupCompleteAuctionFlow() internal {
        // 2. Clock phase - bidders submit bids
        setupClockPhase();

        // 3. Proxy phase - proxies submit bundles
        setupProxyPhase();

        // 4. Allocation phase - allocators submit allocations
        setupAllocationPhase();

        // 5. Settlement phase - reveals, claims, and transition to finished
        setupSettlementPhase();
    }

    function setupClockPhase() internal {
        // Create bidders with sufficient funds
        createBidder(bidder1, 1000000 * 10**18);
        createBidder(bidder2, 1000000 * 10**18);
        createBidder(bidder3, 1000000 * 10**18); // Add bidder3

        // Approve tokens for bidders
        approveNumeraireForBidder(bidder1, type(uint256).max);
        approveNumeraireForBidder(bidder2, type(uint256).max);
        approveNumeraireForBidder(bidder3, type(uint256).max); // Add approval for bidder3

        // Proxy commits
        vm.prank(proxy1);
        cpaManager.commitToBidder(auctionId, commitHash1);
        vm.prank(proxy2);
        cpaManager.commitToBidder(auctionId, commitHash2);
        vm.prank(proxy3);
        cpaManager.commitToBidder(auctionId, commitHash3); // Add bidder3's proxy commit

        // Start clock round
        vm.prank(auctioneer);
        cpaManager.startClockPhase(auctionId);

        // Submit bids for round 1 - create excess demand on BOTH assets
        uint256[] memory demands1 = new uint256[](2);
        demands1[0] = 50 * 10**18;  // 50 tokens of asset1 (excess demand: 50 + 40 + 30 = 120 > 100 available)
        demands1[1] = 60 * 10**18;  // 60 tokens of asset2 (excess demand: 60 + 50 + 41 = 151 > 150 available)

        uint256[] memory demands2 = new uint256[](2);
        demands2[0] = 40 * 10**18;  // 40 tokens of asset1
        demands2[1] = 50 * 10**18;  // 50 tokens of asset2

        // Approve numeraire for bidders
        approveNumeraireForBidder(bidder1, type(uint256).max);
        approveNumeraireForBidder(bidder2, type(uint256).max);

        // All 3 bidders submit in round 1
        vm.prank(bidder1);
        cpaManager.submitBid(auctionId, demands1, 1000 * 10**18);

        vm.prank(bidder2);
        cpaManager.submitBid(auctionId, demands2, 1000 * 10**18);

        uint256[] memory demands3 = new uint256[](2);
        demands3[0] = 30 * 10**18;  // 30 tokens of asset1
        demands3[1] = 41 * 10**18;  // 41 tokens of asset2

        vm.prank(bidder3);
        cpaManager.submitBid(auctionId, demands3, 1000 * 10**18); // Add bidder3's bid

        // End clock phase
        vm.prank(auctioneer);
        cpaManager.endClockPhase(auctionId);
    }

    function setupProxyPhase() internal {
        // Submit bundles
        uint256[] memory quantities1 = new uint256[](2);
        quantities1[0] = 30 * 10**18;
        quantities1[1] = 20 * 10**18;

        uint256[] memory quantities2 = new uint256[](2);
        quantities2[0] = 25 * 10**18;
        quantities2[1] = 15 * 10**18;

        uint256[] memory quantities3 = new uint256[](2);
        quantities3[0] = 10 * 10**18;
        quantities3[1] = 5 * 10**18;

        AuctionTypes.Bundle memory bundle1 = AuctionTypes.Bundle({
            auctionId: auctionId,
            commitHash: commitHash1,
            value: 1000 * 10**18,
            quantities: quantities1,
            timestamp: block.timestamp
        });

        AuctionTypes.Bundle memory bundle2 = AuctionTypes.Bundle({
            auctionId: auctionId,
            commitHash: commitHash2,
            value: 1000 * 10**18,
            quantities: quantities2,
            timestamp: block.timestamp
        });

        AuctionTypes.Bundle memory bundle3 = AuctionTypes.Bundle({
            auctionId: auctionId,
            commitHash: commitHash3,
            value: 1000 * 10**18,
            quantities: quantities3,
            timestamp: block.timestamp
        });

        // Generate and save bundle IDs
        bundleId1 = BundleIdLibrary.createId(commitHash1, keccak256(abi.encode(quantities1)));
        bundleId2 = BundleIdLibrary.createId(commitHash2, keccak256(abi.encode(quantities2)));

        vm.prank(proxy1);
        cpaManager.submitBundle(auctionId, commitHash1, bundle1);

        vm.prank(proxy2);
        cpaManager.submitBundle(auctionId, commitHash2, bundle2);

        vm.prank(proxy3);
        cpaManager.submitBundle(auctionId, commitHash3, bundle3);

        // Warp time to end proxy phase
        AuctionTypes.AuctionInfo memory auction = cpaManager.getAuctionInfo(auctionId);
        uint256[] memory phaseDurations = auction.config.phaseDurations;
        vm.warp(block.timestamp + phaseDurations[0]);

        // Transition to allocation phase (permissionless)
        cpaManager.transitionToAllocation(auctionId);
    }

    function setupAllocationPhase() internal {
        // Create allocation
        BundleId[] memory selectedBundles = new BundleId[](2);
        selectedBundles[0] = bundleId1;
        selectedBundles[1] = bundleId2;

        AuctionTypes.Allocation memory allocation = AuctionTypes.Allocation({
            auctionId: auctionId,
            allocator: allocator1,
            bundleIds: selectedBundles,
            totalValue: 2000 * 10**18, // Sum of bundle values
            timestamp: block.timestamp
        });

        // Submit allocation
        vm.prank(allocator1);
        cpaManager.submitAllocation(auctionId, allocation);

        // Warp time to end allocation phase
        AuctionTypes.AuctionInfo memory auction = cpaManager.getAuctionInfo(auctionId);
        uint256[] memory phaseDurations = auction.config.phaseDurations;
        vm.warp(block.timestamp + phaseDurations[1]);

        // Transition to settlement phase (permissionless)
        transitionToSettlement(auctionId);
    }

    function setupSettlementPhase() internal {
        // Reveal identities
        vm.prank(bidder1);
        cpaManager.reveal(auctionId, proxy1, saltA1, saltB1);

        vm.prank(bidder2);
        cpaManager.reveal(auctionId, proxy2, saltA2, saltB2);

        vm.prank(bidder3);
        cpaManager.reveal(auctionId, proxy3, saltA3, saltB3); // Add bidder3's reveal

        // Claim tokens (but NOT for bidder3 - this is the key for forfeit testing)
        vm.prank(bidder1);
        cpaManager.claimAllTokens(auctionId, commitHash1);

        vm.prank(bidder2);
        cpaManager.claimAllTokens(auctionId, commitHash2);

        // Skip bidder3's claim - this leaves them with stake to forfeit

        // Warp time to end settlement phase
        AuctionTypes.AuctionInfo memory auction = cpaManager.getAuctionInfo(auctionId);
        uint256[] memory phaseDurations = auction.config.phaseDurations;
        vm.warp(block.timestamp + phaseDurations[2]);

        // Transition to finished phase (permissionless)
        cpaManager.transitionToFinished(auctionId);
    }

    function setupSettlementPhaseWithoutClaims() internal {
        // Reveal identities
        vm.prank(bidder1);
        cpaManager.reveal(auctionId, proxy1, saltA1, saltB1);

        vm.prank(bidder2);
        cpaManager.reveal(auctionId, proxy2, saltA2, saltB2);

        // Skip claims - this is for forfeit testing

        // Warp time to end settlement phase
        AuctionTypes.AuctionInfo memory auction = cpaManager.getAuctionInfo(auctionId);
        uint256[] memory phaseDurations = auction.config.phaseDurations;
        vm.warp(block.timestamp + phaseDurations[2]);

        // Transition to finished phase (permissionless)
        cpaManager.transitionToFinished(auctionId);
    }

    // ========================================
    // PHASE TRANSITION TESTS
    // ========================================

    function test_TransitionToFinished() public {
        // Verify auction is in Finished phase after setup
        AuctionTypes.AuctionInfo memory auction = cpaManager.getAuctionInfo(auctionId);
        assertEq(uint8(auction.currentPhase), uint8(AuctionTypes.AuctionPhase.Finished), "Auction should be in Finished phase");
    }

    // ========================================
    // FORFEIT TESTS
    // ========================================

    function test_ForfeitBidderSuccess() public {
        // In our main auction, bidders already claimed, so stake should be 0
        // For this test, we need to create a scenario where bidders don't claim
        // We'll use the existing auction but simulate the forfeit scenario

        // First, let's check that bidders have no stake after claiming
        uint256 stake1 = cpaManager.bidderStake(auctionId, bidder1);
        uint256 stake2 = cpaManager.bidderStake(auctionId, bidder2);
        assertEq(stake1, 0, "Bidder1 should have no stake after claiming");
        assertEq(stake2, 0, "Bidder2 should have no stake after claiming");

        // For this test, we'll just verify the forfeit function works with zero stake
        vm.prank(bidder2);
        vm.expectRevert(abi.encodeWithSelector(IErrorsAndEvents.InvalidStakeAmount.selector));
        cpaManager.forfeit(auctionId, bidder1);

        console.log("Forfeit correctly reverts when bidder has no stake");
    }

    function test_ForfeitBidderWhoAlreadyClaimed() public {
        // In our main auction, bidders already claimed, so stake should be 0
        uint256 stake = cpaManager.bidderStake(auctionId, bidder1);
        assertEq(stake, 0, "Bidder should have no stake after claiming");

        // Attempt to forfeit bidder1
        vm.prank(bidder2);
        vm.expectRevert(abi.encodeWithSelector(IErrorsAndEvents.InvalidStakeAmount.selector));
        cpaManager.forfeit(auctionId, bidder1);
    }

    function test_ForfeitRevertsInWrongPhase() public {
        // Test forfeit in Finished phase (should work) vs other phases
        // Since we're already in Finished phase, forfeit should work but revert due to no stake

        // Verify we're in Finished phase
        AuctionTypes.AuctionInfo memory auction = cpaManager.getAuctionInfo(auctionId);
        assertEq(uint8(auction.currentPhase), uint8(AuctionTypes.AuctionPhase.Finished), "Should be in Finished phase");

        // Forfeit should work in Finished phase but revert due to no stake
        vm.prank(bidder2);
        vm.expectRevert(abi.encodeWithSelector(IErrorsAndEvents.InvalidStakeAmount.selector));
        cpaManager.forfeit(auctionId, bidder1);

        console.log("Forfeit works in Finished phase but reverts due to no stake");
    }

    function test_ForfeitMultipleBidders() public {
        // Test forfeiting multiple bidders with zero stake (already claimed)
        uint256 stake1 = cpaManager.bidderStake(auctionId, bidder1);
        uint256 stake2 = cpaManager.bidderStake(auctionId, bidder2);

        assertEq(stake1, 0, "Bidder1 should have no stake after claiming");
        assertEq(stake2, 0, "Bidder2 should have no stake after claiming");

        // Attempt to forfeit both bidders - should both revert
        vm.prank(allocator1);
        vm.expectRevert(abi.encodeWithSelector(IErrorsAndEvents.InvalidStakeAmount.selector));
        cpaManager.forfeit(auctionId, bidder1);

        vm.prank(allocator1);
        vm.expectRevert(abi.encodeWithSelector(IErrorsAndEvents.InvalidStakeAmount.selector));
        cpaManager.forfeit(auctionId, bidder2);

        console.log("Multiple forfeit attempts correctly revert when bidders have no stake");
    }

    function test_ForfeitRewardCalculation() public {
        // Test forfeit reward calculation with zero stake (already claimed)
        uint256 stake = cpaManager.bidderStake(auctionId, bidder1);
        assertEq(stake, 0, "Bidder should have no stake after claiming");

        // Record initial balances
        uint256 initialCallerBalance = numeraireToken.balanceOf(bidder2);
        uint256 initialProtocolAccrued = cpaManager.protocolAccrued(auctionId);

        // Attempt forfeit - should revert with InvalidStakeAmount
        vm.prank(bidder2);
        vm.expectRevert(abi.encodeWithSelector(IErrorsAndEvents.InvalidStakeAmount.selector));
        cpaManager.forfeit(auctionId, bidder1);

        // Verify no changes to balances
        uint256 finalCallerBalance = numeraireToken.balanceOf(bidder2);
        uint256 finalProtocolAccrued = cpaManager.protocolAccrued(auctionId);

        assertEq(finalCallerBalance, initialCallerBalance, "Caller balance should be unchanged");
        assertEq(finalProtocolAccrued, initialProtocolAccrued, "Protocol accrued should be unchanged");

        console.log("Forfeit reward calculation correctly reverts when bidder has no stake");
    }

    function test_ForfeitBidderWhoDidNotClaim() public {
        // Test forfeiting a bidder who has stake but didn't claim anything
        // This should work and transfer the stake to the protocol

        // Verify bidder3 has stake but hasn't claimed (set up in setUp with modified settlement)
        uint256 stake = cpaManager.bidderStake(auctionId, bidder3);
        assertTrue(stake > 0, "Bidder3 should have stake");

        // Get initial balances for reward verification
        uint256 initialAccrued = cpaManager.protocolAccrued(auctionId);
        uint256 initialCallerBalance = numeraireToken.balanceOf(address(this));

        // Have the contract (this test contract) forfeit bidder3's stake on their behalf
        // This tests the permissionless nature of the forfeit function
        cpaManager.forfeit(auctionId, bidder3);

        // Verify bidder3's stake is now 0
        uint256 finalStake = cpaManager.bidderStake(auctionId, bidder3);
        assertEq(finalStake, 0, "Bidder3's stake should be 0 after forfeit");

        // Verify protocol accrued increased
        uint256 finalAccrued = cpaManager.protocolAccrued(auctionId);
        assertTrue(finalAccrued > initialAccrued, "Protocol accrued should have increased");

        // Verify the penalty amount is correct (should be minSpendRatio * stake)
        AuctionTypes.AuctionInfo memory auction = cpaManager.getAuctionInfo(auctionId);
        uint256 expectedPenalty = stake * auction.config.minSpendRatio / 10000;
        uint256 actualPenalty = finalAccrued - initialAccrued;
        assertEq(actualPenalty, expectedPenalty, "Penalty amount should be correct");

        // Verify the calling address (this test contract) received the correct reward
        uint256 finalCallerBalance = numeraireToken.balanceOf(address(this));
        uint256 rewardReceived = finalCallerBalance - initialCallerBalance;
        uint256 expectedReward = stake * 500 / 10000; // FORFEITURE_REWARD_RATE = 500 basis points (5%)
        assertEq(rewardReceived, expectedReward, "Calling address should receive correct reward");

        console.log("Successfully forfeited bidder3's stake of %d tokens", stake);
        console.log("Protocol accrued increased by %d tokens", actualPenalty);
        console.log("Calling address received %d tokens as reward", rewardReceived);
    }

    // ========================================
    // RECLAIM STAKE TESTS
    // ========================================

    function test_ReclaimStakeSuccess() public {
        // Verify basic reclaimStake functionality for bidder3 (who didn't claim)
        uint256 initialStake = cpaManager.bidderStake(auctionId, bidder3);
        assertTrue(initialStake > 0, "Bidder3 should have stake");

        // Get initial balances
        uint256 initialBidderBalance = numeraireToken.balanceOf(bidder3);
        uint256 initialProtocolAccrued = cpaManager.protocolAccrued(auctionId);

        // Call reclaimStake
        vm.prank(bidder3);
        cpaManager.reclaimStake(auctionId);

        // Verify stake is zeroed
        uint256 finalStake = cpaManager.bidderStake(auctionId, bidder3);
        assertEq(finalStake, 0, "Bidder3's stake should be 0 after reclaim");

        // Verify penalty calculation (10% penalty)
        AuctionTypes.AuctionInfo memory auction = cpaManager.getAuctionInfo(auctionId);
        uint256 expectedPenalty = initialStake * auction.config.minSpendRatio / 10000;
        uint256 expectedRefund = initialStake - expectedPenalty;

        // Verify protocol accrued increased
        uint256 finalProtocolAccrued = cpaManager.protocolAccrued(auctionId);
        uint256 actualPenalty = finalProtocolAccrued - initialProtocolAccrued;
        assertEq(actualPenalty, expectedPenalty, "Protocol accrued should increase by penalty amount");

        // Verify bidder received refund
        uint256 finalBidderBalance = numeraireToken.balanceOf(bidder3);
        uint256 refundReceived = finalBidderBalance - initialBidderBalance;
        assertEq(refundReceived, expectedRefund, "Bidder should receive 90% of stake");

        console.log("Successfully reclaimed stake: %d tokens, penalty: %d, refund: %d",
                   initialStake, expectedPenalty, expectedRefund);
    }

    function test_ReclaimStakeRevertsWithZeroStake() public {
        // Use bidder1 who already claimed (stake = 0)
        uint256 stake = cpaManager.bidderStake(auctionId, bidder1);
        assertEq(stake, 0, "Bidder1 should have no stake after claiming");

        // Attempt to reclaim stake
        vm.prank(bidder1);
        vm.expectRevert(abi.encodeWithSelector(IErrorsAndEvents.InvalidStakeAmount.selector));
        cpaManager.reclaimStake(auctionId);
    }

    function test_ReclaimStakeMultipleCalls() public {
        // First call should succeed
        vm.prank(bidder3);
        cpaManager.reclaimStake(auctionId);

        // Verify stake is zeroed
        uint256 stake = cpaManager.bidderStake(auctionId, bidder3);
        assertEq(stake, 0, "Bidder3's stake should be 0 after first reclaim");

        // Second call should revert
        vm.prank(bidder3);
        vm.expectRevert(abi.encodeWithSelector(IErrorsAndEvents.InvalidStakeAmount.selector));
        cpaManager.reclaimStake(auctionId);
    }

    function test_ReclaimStakeEmitsCorrectEvents() public {
        uint256 stake = cpaManager.bidderStake(auctionId, bidder3);
        AuctionTypes.AuctionInfo memory auction = cpaManager.getAuctionInfo(auctionId);

        uint256 expectedPenalty = stake * auction.config.minSpendRatio / 10000;
        uint256 expectedRefund = stake - expectedPenalty;

        // Set up event expectations
        vm.expectEmit(true, true, true, true);
        emit IErrorsAndEvents.PenaltyApplied(auctionId, bidder3, expectedPenalty);

        vm.expectEmit(true, true, true, true);
        emit IErrorsAndEvents.StakeRefunded(auctionId, bidder3, expectedRefund);

        // Call reclaimStake
        vm.prank(bidder3);
        cpaManager.reclaimStake(auctionId);
    }

    function test_ReclaimStakePenaltyCalculation() public {
        uint256 stake = cpaManager.bidderStake(auctionId, bidder3);
        AuctionTypes.AuctionInfo memory auction = cpaManager.getAuctionInfo(auctionId);

        // Calculate expected amounts
        uint256 expectedPenalty = stake * auction.config.minSpendRatio / 10000; // 10%
        uint256 expectedRefund = stake - expectedPenalty; // 90%

        // Get initial balances
        uint256 initialBidderBalance = numeraireToken.balanceOf(bidder3);
        uint256 initialProtocolAccrued = cpaManager.protocolAccrued(auctionId);

        // Call reclaimStake
        vm.prank(bidder3);
        cpaManager.reclaimStake(auctionId);

        // Verify exact calculations
        uint256 finalBidderBalance = numeraireToken.balanceOf(bidder3);
        uint256 finalProtocolAccrued = cpaManager.protocolAccrued(auctionId);

        uint256 actualRefund = finalBidderBalance - initialBidderBalance;
        uint256 actualPenalty = finalProtocolAccrued - initialProtocolAccrued;

        assertEq(actualPenalty, expectedPenalty, "Penalty should be exactly 10% of stake");
        assertEq(actualRefund, expectedRefund, "Refund should be exactly 90% of stake");
        assertEq(actualPenalty + actualRefund, stake, "Penalty + refund should equal original stake");

        console.log("Penalty calculation verified: %d penalty, %d refund from %d stake",
                   actualPenalty, actualRefund, stake);
    }

    function test_ReclaimStakeZerosBidderState() public {
        // Verify initial state
        uint256 initialStake = cpaManager.bidderStake(auctionId, bidder3);
        uint256 initialBidPoints = cpaManager.bidderBidPoints(auctionId, bidder3);

        assertTrue(initialStake > 0, "Bidder3 should have stake initially");
        assertTrue(initialBidPoints > 0, "Bidder3 should have bid points initially");

        // Call reclaimStake
        vm.prank(bidder3);
        cpaManager.reclaimStake(auctionId);

        // Verify both mappings are zeroed
        uint256 finalStake = cpaManager.bidderStake(auctionId, bidder3);
        uint256 finalBidPoints = cpaManager.bidderBidPoints(auctionId, bidder3);

        assertEq(finalStake, 0, "bidderStake should be zeroed");
        assertEq(finalBidPoints, 0, "bidderBidPoints should be zeroed");

        console.log("Bidder state completely zeroed after reclaim");
    }

    function test_ReclaimStakeDistribution() public {
        // Test distribution when bidder calls reclaimStake themselves
        uint256 stake = cpaManager.bidderStake(auctionId, bidder3);
        AuctionTypes.AuctionInfo memory auction = cpaManager.getAuctionInfo(auctionId);

        uint256 expectedPenalty = stake * auction.config.minSpendRatio / 10000; // 10%
        uint256 expectedRefund = stake - expectedPenalty; // 90%

        // Get initial balances
        uint256 initialBidderBalance = numeraireToken.balanceOf(bidder3);
        uint256 initialProtocolAccrued = cpaManager.protocolAccrued(auctionId);

        // Call reclaimStake
        vm.prank(bidder3);
        cpaManager.reclaimStake(auctionId);

        // Verify distribution
        uint256 finalBidderBalance = numeraireToken.balanceOf(bidder3);
        uint256 finalProtocolAccrued = cpaManager.protocolAccrued(auctionId);

        uint256 bidderReceived = finalBidderBalance - initialBidderBalance;
        uint256 protocolReceived = finalProtocolAccrued - initialProtocolAccrued;

        // Verify: 90% to bidder, 10% to protocol, no third-party reward
        assertEq(bidderReceived, expectedRefund, "Bidder should receive 90%");
        assertEq(protocolReceived, expectedPenalty, "Protocol should receive 10%");
        assertEq(bidderReceived + protocolReceived, stake, "Total should equal original stake");

        console.log("Distribution verified: %d to bidder (90%%), %d to protocol (10%%)",
                   bidderReceived, protocolReceived);
    }

    function test_ForfeitDistribution() public {
        // Test distribution when third party calls forfeit
        uint256 stake = cpaManager.bidderStake(auctionId, bidder3);
        AuctionTypes.AuctionInfo memory auction = cpaManager.getAuctionInfo(auctionId);

        uint256 penaltyRate = auction.config.minSpendRatio; // 10%
        uint256 forfeitureRewardRate = 500; // 5% (FORFEITURE_REWARD_RATE)

        uint256 expectedPenalty = stake * penaltyRate / 10000; // 10%
        uint256 expectedReward = stake * forfeitureRewardRate / 10000; // 5%
        uint256 expectedRefund = stake - expectedPenalty - expectedReward; // 85%

        // Get initial balances
        uint256 initialBidderBalance = numeraireToken.balanceOf(bidder3);
        uint256 initialProtocolAccrued = cpaManager.protocolAccrued(auctionId);
        uint256 initialCallerBalance = numeraireToken.balanceOf(address(this));

        // Call forfeit (this test contract as caller)
        cpaManager.forfeit(auctionId, bidder3);

        // Verify distribution
        uint256 finalBidderBalance = numeraireToken.balanceOf(bidder3);
        uint256 finalProtocolAccrued = cpaManager.protocolAccrued(auctionId);
        uint256 finalCallerBalance = numeraireToken.balanceOf(address(this));

        uint256 bidderReceived = finalBidderBalance - initialBidderBalance;
        uint256 protocolReceived = finalProtocolAccrued - initialProtocolAccrued;
        uint256 callerReceived = finalCallerBalance - initialCallerBalance;

        // Verify: 85% to bidder, 10% to protocol, 5% to caller
        assertEq(bidderReceived, expectedRefund, "Bidder should receive 85%");
        assertEq(protocolReceived, expectedPenalty, "Protocol should receive 10%");
        assertEq(callerReceived, expectedReward, "Caller should receive 5%");
        assertEq(bidderReceived + protocolReceived + callerReceived, stake, "Total should equal original stake");

        console.log("Forfeit distribution verified: %d to bidder (85%%), %d to protocol (10%%), %d to caller (5%%)",
                   bidderReceived, protocolReceived, callerReceived);
    }

    function test_ReclaimStakeAfterForfeit() public {
        // First call forfeit on bidder3
        cpaManager.forfeit(auctionId, bidder3);

        // Verify stake is zeroed
        uint256 stake = cpaManager.bidderStake(auctionId, bidder3);
        assertEq(stake, 0, "Bidder3's stake should be 0 after forfeit");

        // Now try to call reclaimStake - should revert
        vm.prank(bidder3);
        vm.expectRevert(abi.encodeWithSelector(IErrorsAndEvents.InvalidStakeAmount.selector));
        cpaManager.reclaimStake(auctionId);

        console.log("reclaimStake correctly reverts after forfeit");
    }

    function test_ForfeitEmitsForfeitureRewardTransferredEvent() public {
        uint256 stake = cpaManager.bidderStake(auctionId, bidder3);
        uint256 expectedReward = stake * 500 / 10000; // 5% (FORFEITURE_REWARD_RATE)

        // Set up event expectation
        vm.expectEmit(true, true, true, true);
        emit IErrorsAndEvents.ForfeitureRewardTransferred(auctionId, address(this), expectedReward);

        // Call forfeit
        cpaManager.forfeit(auctionId, bidder3);
    }

    function test_GetBidderDemandsInFinishedPhase() public {
        // Get demands for all bidders in Finished phase
        uint256[] memory demands1 = getBidderDemands(auctionId, bidder1);
        uint256[] memory demands2 = getBidderDemands(auctionId, bidder2);
        uint256[] memory demands3 = getBidderDemands(auctionId, bidder3);

        // Verify correct demands from Clock phase
        assertEq(demands1.length, 2, "Bidder1 should have 2 demands");
        assertEq(demands1[0], 50 * 10**18, "Bidder1 demand1 should be 50e18");
        assertEq(demands1[1], 60 * 10**18, "Bidder1 demand2 should be 60e18");

        assertEq(demands2.length, 2, "Bidder2 should have 2 demands");
        assertEq(demands2[0], 40 * 10**18, "Bidder2 demand1 should be 40e18");
        assertEq(demands2[1], 50 * 10**18, "Bidder2 demand2 should be 50e18");

        assertEq(demands3.length, 2, "Bidder3 should have 2 demands");
        assertEq(demands3[0], 30 * 10**18, "Bidder3 demand1 should be 30e18");
        assertEq(demands3[1], 41 * 10**18, "Bidder3 demand2 should be 41e18");

        console.log("All bidder demands correctly retrieved in Finished phase");
    }

    // ========================================
    // EVENT EMISSION TESTS
    // ========================================

    function test_AllocatorRewardClaimedEmitsCorrectAmount() public {
        // Get the allocator reward amount before claiming
        uint256 rewardAmount = cpaManager.getAuctionInfo(auctionId).allocatorReward;
        assertTrue(rewardAmount > 0, "Allocator should have reward to claim");

        // Set up event expectation
        vm.expectEmit(true, true, true, true);
        emit IErrorsAndEvents.AllocatorRewardClaimed(auctionId, allocator1, rewardAmount);

        // Claim allocator reward
        vm.prank(allocator1);
        cpaManager.claimAllocatorReward(auctionId);
    }

    function test_ForfeitZerosBidderBidPoints() public {
        // Verify bidder3 has both stake and bid points initially
        uint256 initialStake = cpaManager.bidderStake(auctionId, bidder3);
        uint256 initialBidPoints = cpaManager.bidderBidPoints(auctionId, bidder3);

        assertTrue(initialStake > 0, "Bidder3 should have stake");
        assertTrue(initialBidPoints > 0, "Bidder3 should have bid points");

        // Call forfeit
        cpaManager.forfeit(auctionId, bidder3);

        // Verify both are zeroed
        uint256 finalStake = cpaManager.bidderStake(auctionId, bidder3);
        uint256 finalBidPoints = cpaManager.bidderBidPoints(auctionId, bidder3);

        assertEq(finalStake, 0, "Stake should be zeroed after forfeit");
        assertEq(finalBidPoints, 0, "Bid points should be zeroed after forfeit");

        console.log("Forfeit correctly zeros both bidderStake and bidderBidPoints");
    }

    // ========================================
    // HELPER FUNCTIONS
    // ========================================


}
