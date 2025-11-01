// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { CPATestBase } from "./base/CPATestBase.sol";
import { AuctionTypes } from "../src/types/AuctionTypes.sol";
import { IErrorsAndEvents } from "../src/utils/IErrorsAndEvents.sol";

contract CPAClockTerminationTest is CPATestBase {
    function setUp() public override {
        super.setUp();
    }

    /// @notice Helper to create auction config with custom maxRounds
    function createAuctionConfigWithMaxRounds(uint256 _maxRounds) internal returns (AuctionTypes.AuctionConfig memory) {
        AuctionTypes.AuctionConfig memory config = createStandardAuctionConfig();
        config.maxRounds = _maxRounds;
        return config;
    }

    // ========================================
    // MAX ROUNDS EXCEEDED TERMINATION
    // ========================================

    function test_MaxRoundsExceeded_TerminatesClock() public {
        // Setup: Create auction with maxRounds = 3 for faster testing
        AuctionTypes.AuctionConfig memory config = createAuctionConfigWithMaxRounds(3);
        auctionId = createAuction(config, auctioneer);

        // Setup deposits and start clock
        mintTokensToAuctioneer(1000000 * 10**18);
        approveTokens(address(asset1Token), address(cpaManager), 1000 * 10**18);
        approveTokens(address(asset2Token), address(cpaManager), 1000 * 10**18);
        moveDeposit(auctionId, asset1PoolKey, 100 * 10**18);
        moveDeposit(auctionId, asset2PoolKey, 150 * 10**18);

        // Create bidders
        createBidder(bidder1, 100000 * 10**18);
        createBidder(bidder2, 100000 * 10**18);
        approveNumeraireForBidder(bidder1, type(uint256).max);
        approveNumeraireForBidder(bidder2, type(uint256).max);

        // Start clock phase - this opens round 1
        vm.prank(auctioneer);
        cpaManager.startClockPhase(auctionId);

        AuctionTypes.AuctionInfo memory auction = cpaManager.getAuctionInfo(auctionId);
        assertEq(auction.currentRound, 1, "Should start at round 1");

        // Round 1: Submit bids with excess demand to continue
        uint256[] memory demands1 = new uint256[](2);
        demands1[0] = 60 * 10**18; // Excess demand on asset1
        demands1[1] = 40 * 10**18;
        uint256[] memory demands2 = new uint256[](2);
        demands2[0] = 50 * 10**18; // More excess demand
        demands2[1] = 30 * 10**18;

        vm.prank(bidder1);
        cpaManager.submitBid(auctionId, demands1, type(uint256).max);
        vm.prank(bidder2);
        cpaManager.submitBid(auctionId, demands2, type(uint256).max);

        // End round 1 - should continue (round 1 < maxRounds=3)
        vm.prank(auctioneer);
        cpaManager.endClockRound(auctionId);

        auction = cpaManager.getAuctionInfo(auctionId);
        assertEq(auction.currentRound, 2, "Should advance to round 2");
        assertEq(uint8(auction.currentPhase), uint8(AuctionTypes.AuctionPhase.Clock), "Should still be in Clock");

        // Round 2: Continue with excess demand
        vm.prank(bidder1);
        cpaManager.submitBid(auctionId, demands1, type(uint256).max);
        vm.prank(bidder2);
        cpaManager.submitBid(auctionId, demands2, type(uint256).max);

        // End round 2 - should continue (round 2 < maxRounds=3)
        vm.prank(auctioneer);
        cpaManager.endClockRound(auctionId);

        auction = cpaManager.getAuctionInfo(auctionId);
        assertEq(auction.currentRound, 3, "Should advance to round 3");
        assertEq(uint8(auction.currentPhase), uint8(AuctionTypes.AuctionPhase.Clock), "Should still be in Clock");

        // Round 3: This is the max round - should trigger termination
        vm.prank(bidder1);
        cpaManager.submitBid(auctionId, demands1, type(uint256).max);
        vm.prank(bidder2);
        cpaManager.submitBid(auctionId, demands2, type(uint256).max);

        // End round 3 - should terminate because currentRound (3) >= maxRounds (3)
        vm.prank(auctioneer);
        cpaManager.endClockRound(auctionId);

        // Verify clock phase ended and transitioned to Proxy phase
        auction = cpaManager.getAuctionInfo(auctionId);
        assertEq(auction.currentRound, 3, "Round should be 3 (max rounds reached)");
        assertEq(uint8(auction.currentPhase), uint8(AuctionTypes.AuctionPhase.Proxy), "Phase should transition to Proxy");
    }

    // ========================================
    // REVENUE IMPROVEMENT THRESHOLD TERMINATION
    // ========================================

    function test_RevenueImprovementBelowThreshold_TerminatesClock() public {
        // Setup auction with high maxRounds so it doesn't terminate early
        AuctionTypes.AuctionConfig memory config = createAuctionConfigWithMaxRounds(100);
        auctionId = createAuction(config, auctioneer);

        // Setup deposits and start clock
        mintTokensToAuctioneer(1000000 * 10**18);
        approveTokens(address(asset1Token), address(cpaManager), 1000 * 10**18);
        approveTokens(address(asset2Token), address(cpaManager), 1000 * 10**18);
        moveDeposit(auctionId, asset1PoolKey, 100 * 10**18);
        moveDeposit(auctionId, asset2PoolKey, 150 * 10**18);

        // Create bidders
        createBidder(bidder1, 100000 * 10**18);
        createBidder(bidder2, 100000 * 10**18);
        approveNumeraireForBidder(bidder1, type(uint256).max);
        approveNumeraireForBidder(bidder2, type(uint256).max);

        // Start clock phase
        vm.prank(auctioneer);
        cpaManager.startClockPhase(auctionId);

        // Round 1: Submit initial bids with excess demand
        // We need to create revenue that will allow us to test the EMA threshold
        uint256[] memory demands1_r1 = new uint256[](2);
        demands1_r1[0] = 60 * 10**18;
        demands1_r1[1] = 80 * 10**18;
        uint256[] memory demands2_r1 = new uint256[](2);
        demands2_r1[0] = 50 * 10**18;
        demands2_r1[1] = 70 * 10**18;

        vm.prank(bidder1);
        cpaManager.submitBid(auctionId, demands1_r1, type(uint256).max);
        vm.prank(bidder2);
        cpaManager.submitBid(auctionId, demands2_r1, type(uint256).max);

        vm.prank(auctioneer);
        cpaManager.endClockRound(auctionId); // Round 1 ends, round 2 starts

        // Round 2: Submit similar bids (very small revenue improvement)
        // The revenue improvement should be < 0.5% to trigger termination
        // EMA calculation: R_t = 0.5 * r_t internally + 0.5 * R_{t-1}
        // If revenue stays nearly the same, EMA will indicate minimal improvement
        // We'll submit bids with slightly lower total value to create < 0.5% improvement
        
        uint256[] memory demands1_r2 = new uint256[](2);
        demands1_r2[0] = 59 * 10**18; // Slightly lower to reduce revenue
        demands1_r2[1] = 79 * 10**18;
        uint256[] memory demands2_r2 = new uint256[](2);
        demands2_r2[0] = 49 * 10**18;
        demands2_r2[1] = 69 * 10**18;

        vm.prank(bidder1);
        cpaManager.submitBid(auctionId, demands1_r2, type(uint256).max);
        vm.prank(bidder2);
        cpaManager.submitBid(auctionId, demands2_r2, type(uint256).max);

        // End round 2 - this should check revenue improvement
        // If revenue improvement < 0.5%, clock phase should end
        vm.prank(auctioneer);
        cpaManager.endClockRound(auctionId);

        // Verify clock phase ended due to revenue threshold
        AuctionTypes.AuctionInfo memory auction = cpaManager.getAuctionInfo(auctionId);
        // The phase might transition to Proxy if revenue threshold was met
        // This test verifies that the termination logic runs and can end the phase
        // Note: The exact threshold may vary based on price changes, so we check phase transition
        assertTrue(
            uint8(auction.currentPhase) >= uint8(AuctionTypes.AuctionPhase.Proxy),
            "Clock phase should have ended (transitioned to Proxy or later)"
        );
    }

    // ========================================
    // MULTIPLE TERMINATION CONDITIONS
    // ========================================

    function test_MultipleTerminationConditions_SameRound() public {
        // Setup: Create auction with maxRounds = 2, and we'll also have no excess demand
        AuctionTypes.AuctionConfig memory config = createAuctionConfigWithMaxRounds(2);
        auctionId = createAuction(config, auctioneer);

        // Setup deposits and start clock
        mintTokensToAuctioneer(1000000 * 10**18);
        approveTokens(address(asset1Token), address(cpaManager), 1000 * 10**18);
        approveTokens(address(asset2Token), address(cpaManager), 1000 * 10**18);
        moveDeposit(auctionId, asset1PoolKey, 100 * 10**18);
        moveDeposit(auctionId, asset2PoolKey, 150 * 10**18);

        // Create bidders
        createBidder(bidder1, 100000 * 10**18);
        createBidder(bidder2, 100000 * 10**18);
        approveNumeraireForBidder(bidder1, type(uint256).max);
        approveNumeraireForBidder(bidder2, type(uint256).max);

        // Start clock phase - round 1
        vm.prank(auctioneer);
        cpaManager.startClockPhase(auctionId);

        // Round 1: Submit bids with excess demand
        uint256[] memory demands1 = new uint256[](2);
        demands1[0] = 60 * 10**18;
        demands1[1] = 80 * 10**18;
        uint256[] memory demands2 = new uint256[](2);
        demands2[0] = 50 * 10**18;
        demands2[1] = 70 * 10**18;

        vm.prank(bidder1);
        cpaManager.submitBid(auctionId, demands1, type(uint256).max);
        vm.prank(bidder2);
        cpaManager.submitBid(auctionId, demands2, type(uint256).max);

        // End round 1
        vm.prank(auctioneer);
        cpaManager.endClockRound(auctionId);

        AuctionTypes.AuctionInfo memory auction = cpaManager.getAuctionInfo(auctionId);
        assertEq(auction.currentRound, 2, "Should be at round 2");

        // Round 2: Submit bids with NO excess demand (condition 1)
        // And this is also round 2 which equals maxRounds=2 (condition 2)
        // Both conditions should be checked, and either should trigger termination
        uint256[] memory demands1_r2 = new uint256[](2);
        demands1_r2[0] = 30 * 10**18; // No excess (30 + 40 = 70 < 100)
        demands1_r2[1] = 40 * 10**18; // No excess (40 + 50 = 90 < 150)
        uint256[] memory demands2_r2 = new uint256[](2);
        demands2_r2[0] = 40 * 10**18;
        demands2_r2[1] = 50 * 10**18;

        vm.prank(bidder1);
        cpaManager.submitBid(auctionId, demands1_r2, type(uint256).max);
        vm.prank(bidder2);
        cpaManager.submitBid(auctionId, demands2_r2, type(uint256).max);

        // End round 2 - should terminate due to both no excess demand AND max rounds
        vm.prank(auctioneer);
        cpaManager.endClockRound(auctionId);

        // Verify termination occurred
        auction = cpaManager.getAuctionInfo(auctionId);
        assertEq(uint8(auction.currentPhase), uint8(AuctionTypes.AuctionPhase.Proxy), "Should transition to Proxy");
        assertEq(auction.currentRound, 2, "Round should be 2 (max rounds reached)");
    }
}

