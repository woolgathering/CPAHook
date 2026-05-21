// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { Test, console } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { MockERC20 } from "solmate/src/test/utils/mocks/MockERC20.sol";

import { CPAManager } from "../src/CPAManager.sol";
import { AuctionTypes } from "../src/types/AuctionTypes.sol";
import { AuctionId } from "../src/types/AuctionId.sol";
import { AssetId, AssetIdLibrary, AssetConfig } from "../src/types/AssetConfig.sol";
import { BundleId } from "../src/types/BundleId.sol";
import { IErrorsAndEvents } from "../src/utils/IErrorsAndEvents.sol";
import { CommitReveal } from "../src/utils/CommitReveal.sol";
import { CPATestBase } from "./base/CPATestBase.sol";

contract CPAClockPhaseTest is CPATestBase {

    function setUp() public override {
        depositAmount1 = 100 * 10**18;
        depositAmount2 = 150 * 10**18;
        super.setUp();

        // Create auction with standard configuration
        AuctionTypes.AuctionConfig memory config = createStandardAuctionConfig();
        auctionId = createAuction(config, auctioneer);

        // Mint tokens to auctioneer for deposits
        mintTokensToAuctioneer(1000000 * 10**18);

        // Approve CPAManager to spend auctioneer's tokens
        approveTokens(address(asset1Token), address(cpaManager), depositAmount1);
        approveTokens(address(asset2Token), address(cpaManager), depositAmount2);

        // Move deposits to assets
        moveDeposit(auctionId, address(asset1Token), depositAmount1);
        moveDeposit(auctionId, address(asset2Token), depositAmount2);
    }

    function test_StartClockPhase_Success() public {
        // Verify initial state
        AuctionTypes.AuctionInfo memory auctionInfo = cpaManager.getAuctionInfo(auctionId);

        assertEq(auctionInfo.auctionOwner, auctioneer, "Auction owner should be auctioneer");
        assertEq(auctionInfo.commonNumeraire, address(numeraireToken), "Common numeraire should be numeraire token");
        assertEq(uint256(auctionInfo.currentPhase), uint256(AuctionTypes.AuctionPhase.Setup), "Initial phase should be Setup");
        assertEq(uint256(auctionInfo.currentStatus), uint256(AuctionTypes.AuctionStatus.Active), "Status should be Active");
        assertEq(auctionInfo.clockOpen, 1, "Clock should be closed initially");
        // Note: roundBids field removed - using mapping-based storage now
        assertEq(auctionInfo.currentRound, 0, "Initial round should be 0");
        assertEq(auctionInfo.assets.length, 2, "Should have 2 asset pools");

        // Start clock phase (this automatically opens the first round)
        vm.prank(auctioneer);
        cpaManager.startClockPhase(auctionId);

        // Verify state after starting clock phase
        AuctionTypes.AuctionInfo memory auctionInfoAfterStart = cpaManager.getAuctionInfo(auctionId);

        assertEq(uint256(auctionInfoAfterStart.currentPhase), uint256(AuctionTypes.AuctionPhase.Clock), "Phase should be Clock");
        assertEq(uint256(auctionInfoAfterStart.currentStatus), uint256(AuctionTypes.AuctionStatus.Active), "Status should still be Active");
        assertEq(auctionInfoAfterStart.clockOpen, 2, "Clock should be open after starting clock phase");
        // Note: Using mapping-based storage now - no roundBids field
        assertEq(auctionInfoAfterStart.currentRound, 1, "Round should be incremented to 1");
        assertEq(auctionInfoAfterStart.assets.length, 2, "Should still have 2 asset pools");
    }

    function test_StartClockPhase_InvalidAuctionId() public {
        // Create invalid auction ID
        AuctionId invalidAuctionId = AuctionId.wrap(keccak256("invalid"));

        // Should revert with AuctionNotFound
        vm.prank(auctioneer);
        vm.expectRevert(IErrorsAndEvents.AuctionNotFound.selector);
        cpaManager.startClockPhase(invalidAuctionId);
    }

    function test_StartClockPhase_UnauthorizedCaller() public {
        // Non-auctioneer should not be able to start clock phase
        vm.prank(bidder1);
        vm.expectRevert(IErrorsAndEvents.Unauthorized.selector);
        cpaManager.startClockPhase(auctionId);
    }

    function test_StartClockPhase_SetupNotComplete() public {
        // Create a new auction with different assets but without deposits
        AuctionTypes.AuctionConfig memory config = createNewAuctionConfig();
        AuctionId newAuctionId = createAuction(config, auctioneer);

        // Don't move any deposits - auction setup is not complete
        // Try to start clock phase without deposits - should revert
        vm.prank(auctioneer);
        vm.expectRevert(IErrorsAndEvents.SetupNotComplete.selector);
        cpaManager.startClockPhase(newAuctionId);
    }


    function test_StartClockPhase_EventEmission() public {
        // Expect ClockRoundOpened event
        vm.expectEmit(true, true, true, true);
        emit IErrorsAndEvents.ClockRoundOpened(auctionId, 1);

        // Start clock phase
        vm.prank(auctioneer);
        cpaManager.startClockPhase(auctionId);
    }

    function test_AutomaticRoundProgression() public {
        // Start clock phase (opens first round)
        vm.prank(auctioneer);
        cpaManager.startClockPhase(auctionId);

        // Verify first round
        AuctionTypes.AuctionInfo memory auctionInfo1 = cpaManager.getAuctionInfo(auctionId);
        assertEq(auctionInfo1.currentRound, 1, "First round should be 1");
        assertEq(auctionInfo1.clockOpen, 2, "Clock should be open");

        // Create bidders and submit bids with excess demand to keep clock phase going
        address testBidder1 = makeAddr("testBidder1");
        address testBidder2 = makeAddr("testBidder2");
        createBidder(testBidder1, 100000 * 10**18);
        createBidder(testBidder2, 100000 * 10**18);
        approveNumeraireForBidder(testBidder1, type(uint256).max);
        approveNumeraireForBidder(testBidder2, type(uint256).max);

        // Submit bids that create excess demand to keep clock phase going
        // Asset1: supply = 100, demand = 60 + 50 = 110 (excess = 10)
        // Asset2: supply = 150, demand = 80 + 70 = 150 (no excess)
        uint256[] memory bidder1Demands = new uint256[](2);
        bidder1Demands[0] = 60 * 10**asset1Token.decimals();
        bidder1Demands[1] = 80 * 10**asset2Token.decimals();

        uint256[] memory bidder2Demands = new uint256[](2);
        bidder2Demands[0] = 50 * 10**asset1Token.decimals();
        bidder2Demands[1] = 70 * 10**asset2Token.decimals();

        vm.startPrank(testBidder1);
        cpaManager.submitBid(auctionId, bidder1Demands, type(uint256).max);
        vm.stopPrank();

        vm.startPrank(testBidder2);
        cpaManager.submitBid(auctionId, bidder2Demands, type(uint256).max);
        vm.stopPrank();

        // End first round - this should automatically start the second round (due to excess demand)
        endClockRound(auctionId);

        // Verify second round started automatically
        AuctionTypes.AuctionInfo memory auctionInfo2 = cpaManager.getAuctionInfo(auctionId);
        assertEq(auctionInfo2.currentRound, 2, "Second round should be 2");
        assertEq(auctionInfo2.clockOpen, 2, "Clock should be open for second round");

        // Submit new bids for second round with reduced demands (still some excess)
        uint256[] memory bidder1Demands2 = new uint256[](2);
        bidder1Demands2[0] = 55 * 10**asset1Token.decimals(); // Still some excess for asset1
        bidder1Demands2[1] = 70 * 10**asset2Token.decimals(); // Reduced from 80

        uint256[] memory bidder2Demands2 = new uint256[](2);
        bidder2Demands2[0] = 50 * 10**asset1Token.decimals(); // Still some excess for asset1
        bidder2Demands2[1] = 60 * 10**asset2Token.decimals(); // Reduced from 70

        vm.startPrank(testBidder1);
        cpaManager.submitBid(auctionId, bidder1Demands2, type(uint256).max);
        vm.stopPrank();

        vm.startPrank(testBidder2);
        cpaManager.submitBid(auctionId, bidder2Demands2, type(uint256).max);
        vm.stopPrank();

        // End second round - this should automatically start the third round
        endClockRound(auctionId);

        // Verify third round started automatically
        AuctionTypes.AuctionInfo memory auctionInfo3 = cpaManager.getAuctionInfo(auctionId);
        assertEq(auctionInfo3.currentRound, 3, "Third round should be 3");
        assertEq(auctionInfo3.clockOpen, 2, "Clock should be open for third round");
    }

    function test_StartClockPhase_MappingStorage() public {
        // Start clock phase (opens first round)
        vm.prank(auctioneer);
        cpaManager.startClockPhase(auctionId);

        // Verify mapping-based storage is ready
        AuctionTypes.AuctionInfo memory auctionInfoCleared = cpaManager.getAuctionInfo(auctionId);
        assertEq(auctionInfoCleared.clockOpen, 2, "Clock should be open");
        assertEq(auctionInfoCleared.currentRound, 1, "Round should be 1");
        // Note: Using mapping-based storage - no roundBids array to check
    }

    // ============ EDGE CASES AND ERROR CONDITIONS ============

    function test_SubmitBid_ValidBidAmounts_ZeroDemands() public {
        // Start clock phase
        vm.prank(auctioneer);
        cpaManager.startClockPhase(auctionId);

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

        approveNumeraireForBidder(testBidder, type(uint256).max);

        vm.prank(testBidder);
        cpaManager.submitBid(auctionId, zeroDemands, type(uint256).max);

        // Verify the zero bid was accepted using mapping-based storage
        uint256[] memory zeroDemandsCheck = getBidderDemands(auctionId, testBidder);
        assertEq(zeroDemandsCheck.length, 2, "Should have 2 demand quantities");
        assertEq(zeroDemandsCheck[0], 0, "First asset demand should be 0");
        assertEq(zeroDemandsCheck[1], 0, "Second asset demand should be 0");
    }

    function test_SubmitBid_ValidBidAmounts_LargeDemands() public {
        // Start clock phase
        vm.prank(auctioneer);
        cpaManager.startClockPhase(auctionId);

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

        approveNumeraireForBidder(testBidder, type(uint256).max);

        vm.prank(testBidder);
        cpaManager.submitBid(auctionId, largeDemands, type(uint256).max);

        // Verify the large bid was accepted using mapping-based storage
        uint256[] memory largeDemandsCheck = getBidderDemands(auctionId, testBidder);
        assertEq(largeDemandsCheck.length, 2, "Should have 2 demand quantities");
        assertEq(largeDemandsCheck[0], 1000000 * 10**18, "First asset demand should be 1000000");
        assertEq(largeDemandsCheck[1], 500000 * 10**18, "Second asset demand should be 500000");
    }


    function test_SubmitBid_BidderWithoutProxyCommitment() public {
        // Start clock phase
        vm.prank(auctioneer);
        cpaManager.startClockPhase(auctionId);

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

        approveNumeraireForBidder(testBidder, type(uint256).max);

        vm.prank(testBidder);
        // This should succeed since the proxy commitment check is commented out
        cpaManager.submitBid(auctionId, demands, type(uint256).max);
    }

    function test_CommitToBidder_ProxyCommitsToMultipleBidders() public {
        // Start clock phase
        vm.prank(auctioneer);
        cpaManager.startClockPhase(auctionId);

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

        // Verify both bids were accepted using mapping-based storage
        uint256[] memory bidder1DemandsFinal = getBidderDemands(auctionId, bidder1);
        uint256[] memory bidder2DemandsFinal = getBidderDemands(auctionId, bidder2);
        assertEq(bidder1DemandsFinal.length, 2, "Bidder1 should have 2 demand quantities");
        assertEq(bidder2DemandsFinal.length, 2, "Bidder2 should have 2 demand quantities");
        assertEq(bidder1DemandsFinal[0], 100 * 10**18, "Bidder1 first asset demand should be 100");
        assertEq(bidder2DemandsFinal[0], 75 * 10**18, "Bidder2 first asset demand should be 75");
    }

    function test_SubmitBid_InsufficientMaxStake() public {
        // Start clock phase
        vm.prank(auctioneer);
        cpaManager.startClockPhase(auctionId);

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

        approveNumeraireForBidder(testBidder, type(uint256).max);

        vm.prank(testBidder);
        vm.expectRevert(abi.encodeWithSelector(IErrorsAndEvents.InvalidPhase.selector, uint8(AuctionTypes.AuctionPhase.Clock), uint8(AuctionTypes.AuctionPhase.Setup)));
        cpaManager.submitBid(auctionId, demands, type(uint256).max);
    }

    function test_SubmitBid_InvalidAuctionId() public {
        // Start clock phase
        vm.prank(auctioneer);
        cpaManager.startClockPhase(auctionId);

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

        approveNumeraireForBidder(testBidder, type(uint256).max);

        vm.prank(testBidder);
        vm.expectRevert(); // Should revert due to invalid auction
        cpaManager.submitBid(invalidAuctionId, demands, type(uint256).max);
    }

    // ============ ACTIVITY RULE TESTS ============

    function test_ActivityRule_ViolationOnPriceIncrease() public {
        // Start clock phase
        vm.prank(auctioneer);
        cpaManager.startClockPhase(auctionId);

        // Create two bidders to create excess demand
        address testBidder1 = makeAddr("testBidder1");
        address testBidder2 = makeAddr("testBidder2");
        createBidder(testBidder1, 100000 * 10**18);
        createBidder(testBidder2, 100000 * 10**18);
        approveNumeraireForBidder(testBidder1, type(uint256).max);
        approveNumeraireForBidder(testBidder2, type(uint256).max);

        // Submit bids that create excess demand (total demand > supply)
        // Asset1: supply = 100, demand = 50 + 60 = 110 (excess = 10)
        // Asset2: supply = 150, demand = 30 + 40 = 70 (no excess)
        uint256[] memory bidder1Demands = new uint256[](2);
        bidder1Demands[0] = 50 * 10**asset1Token.decimals();
        bidder1Demands[1] = 30 * 10**asset2Token.decimals();

        uint256[] memory bidder2Demands = new uint256[](2);
        bidder2Demands[0] = 60 * 10**asset1Token.decimals();
        bidder2Demands[1] = 40 * 10**asset2Token.decimals();

        vm.startPrank(testBidder1);
        cpaManager.submitBid(auctionId, bidder1Demands, type(uint256).max);
        vm.stopPrank();

        vm.startPrank(testBidder2);
        cpaManager.submitBid(auctionId, bidder2Demands, type(uint256).max);
        vm.stopPrank();

        // End round to trigger price increase (excess demand on asset1)
        endClockRound(auctionId);

        // New round should start automatically

        // Try to submit bid with increased demands when prices have increased
        // This should violate the activity rule for asset1 (price increased)
        uint256[] memory increasedDemands = new uint256[](2);
        increasedDemands[0] = 55 * 10**asset1Token.decimals(); // Increased from 50 (violates activity rule)
        increasedDemands[1] = 25 * 10**asset2Token.decimals(); // Reduced from 30 (valid)

        vm.startPrank(testBidder1);
        vm.expectRevert(IErrorsAndEvents.ActivityRuleViolation.selector);
        cpaManager.submitBid(auctionId, increasedDemands, type(uint256).max);
        vm.stopPrank();
    }

    function test_ActivityRule_ValidDemandReduction() public {
        // Start clock phase
        vm.prank(auctioneer);
        cpaManager.startClockPhase(auctionId);

        // Create two bidders to create excess demand
        address testBidder1 = makeAddr("testBidder1");
        address testBidder2 = makeAddr("testBidder2");
        createBidder(testBidder1, 100000 * 10**18);
        createBidder(testBidder2, 100000 * 10**18);
        approveNumeraireForBidder(testBidder1, type(uint256).max);
        approveNumeraireForBidder(testBidder2, type(uint256).max);

        // Submit bids that create excess demand (total demand > supply)
        // Asset1: supply = 100, demand = 50 + 60 = 110 (excess = 10)
        // Asset2: supply = 150, demand = 30 + 40 = 70 (no excess)
        uint256[] memory bidder1Demands = new uint256[](2);
        bidder1Demands[0] = 50 * 10**asset1Token.decimals();
        bidder1Demands[1] = 30 * 10**asset2Token.decimals();

        uint256[] memory bidder2Demands = new uint256[](2);
        bidder2Demands[0] = 60 * 10**asset1Token.decimals();
        bidder2Demands[1] = 40 * 10**asset2Token.decimals();

        vm.startPrank(testBidder1);
        cpaManager.submitBid(auctionId, bidder1Demands, type(uint256).max);
        vm.stopPrank();

        vm.startPrank(testBidder2);
        cpaManager.submitBid(auctionId, bidder2Demands, type(uint256).max);
        vm.stopPrank();

        // End round to trigger price increase (excess demand on asset1)
        endClockRound(auctionId);

        // New round should start automatically

        // Submit bid with reduced demands - this should be valid
        uint256[] memory reducedDemands = new uint256[](2);
        reducedDemands[0] = 40 * 10**asset1Token.decimals(); // Reduced from 50 (valid)
        reducedDemands[1] = 25 * 10**asset2Token.decimals(); // Reduced from 30 (valid)

        vm.startPrank(testBidder1);
        cpaManager.submitBid(auctionId, reducedDemands, type(uint256).max);
        vm.stopPrank();

        // Verify the reduced demands were accepted
        uint256[] memory storedDemands = getBidderDemands(auctionId, testBidder1);
        assertEq(storedDemands[0], 40 * 10**asset1Token.decimals(), "Demand should be reduced to 40");
        assertEq(storedDemands[1], 25 * 10**asset2Token.decimals(), "Demand should be reduced to 25");
    }

    // ============ AUTOMATIC CLOCK PHASE ENDING TESTS ============

    function test_AutomaticClockPhaseEnding_NoExcessDemand() public {
        // Start clock phase
        vm.prank(auctioneer);
        cpaManager.startClockPhase(auctionId);

        // Create bidders with demands that don't exceed supply
        address testBidder1 = makeAddr("testBidder1");
        address testBidder2 = makeAddr("testBidder2");
        createBidder(testBidder1, 100000 * 10**18);
        createBidder(testBidder2, 100000 * 10**18);
        approveNumeraireForBidder(testBidder1, type(uint256).max);
        approveNumeraireForBidder(testBidder2, type(uint256).max);

        // Submit bids that don't create excess demand
        // Asset1: supply = 100, demand = 30 + 40 = 70 (no excess)
        // Asset2: supply = 150, demand = 20 + 30 = 50 (no excess)
        uint256[] memory bidder1Demands = new uint256[](2);
        bidder1Demands[0] = 30 * 10**asset1Token.decimals();
        bidder1Demands[1] = 20 * 10**asset2Token.decimals();

        uint256[] memory bidder2Demands = new uint256[](2);
        bidder2Demands[0] = 40 * 10**asset1Token.decimals();
        bidder2Demands[1] = 30 * 10**asset2Token.decimals();

        vm.startPrank(testBidder1);
        cpaManager.submitBid(auctionId, bidder1Demands, type(uint256).max);
        vm.stopPrank();

        vm.startPrank(testBidder2);
        cpaManager.submitBid(auctionId, bidder2Demands, type(uint256).max);
        vm.stopPrank();

        // End round - should automatically end clock phase due to no excess demand
        endClockRound(auctionId);

        // Verify clock phase ended and transitioned to proxy phase
        AuctionTypes.AuctionInfo memory auctionInfoAfterEnd = cpaManager.getAuctionInfo(auctionId);
        assertEq(auctionInfoAfterEnd.clockOpen, 1, "Clock should be closed");
        assertEq(uint256(auctionInfoAfterEnd.currentPhase), uint256(AuctionTypes.AuctionPhase.Proxy), "Phase should be Proxy");
    }

    function test_ManualClockPhaseEnding() public {
        // Start clock phase
        vm.prank(auctioneer);
        cpaManager.startClockPhase(auctionId);

        // Verify we're in clock phase
        AuctionTypes.AuctionInfo memory auctionInfoBefore = cpaManager.getAuctionInfo(auctionId);
        assertEq(uint256(auctionInfoBefore.currentPhase), uint256(AuctionTypes.AuctionPhase.Clock), "Should be in Clock phase");
        assertEq(auctionInfoBefore.clockOpen, 2, "Clock should be open");

        // Manually end clock phase
        vm.prank(auctioneer);
        cpaManager.endClockPhase(auctionId);

        // Verify clock phase ended and transitioned to proxy phase
        AuctionTypes.AuctionInfo memory auctionInfoAfter = cpaManager.getAuctionInfo(auctionId);
        assertEq(auctionInfoAfter.clockOpen, 1, "Clock should be closed");
        assertEq(uint256(auctionInfoAfter.currentPhase), uint256(AuctionTypes.AuctionPhase.Proxy), "Phase should be Proxy");
    }

    function test_RevertUndersoldPrices() public {
        // Test that excessDemand is correctly calculated as signed integer and currentPrice is tracked

        // Create bidders and proxies
        address bidder1 = makeAddr("bidder1");
        address bidder2 = makeAddr("bidder2");
        address proxy1 = makeAddr("proxy1");
        address proxy2 = makeAddr("proxy2");

        createBidder(bidder1, 10000000 * 10**18);
        createBidder(bidder2, 10000000 * 10**18);

        // Approve tokens for bidders
        approveNumeraireForBidder(bidder1, type(uint256).max);
        approveNumeraireForBidder(bidder2, type(uint256).max);

        // Generate commit hashes
        bytes32 saltA1 = keccak256("saltA1");
        bytes32 saltB1 = keccak256("saltB1");
        bytes32 saltA2 = keccak256("saltA2");
        bytes32 saltB2 = keccak256("saltB2");

        bytes32 commitHash1 = CommitReveal.generateCommitHash(bidder1, proxy1, saltA1, saltB1);
        bytes32 commitHash2 = CommitReveal.generateCommitHash(bidder2, proxy2, saltA2, saltB2);

        // Proxies commit
        vm.prank(proxy1);
        cpaManager.commitToBidder(auctionId, commitHash1);
        vm.prank(proxy2);
        cpaManager.commitToBidder(auctionId, commitHash2);

        // Start clock phase
        vm.prank(auctioneer);
        cpaManager.startClockPhase(auctionId);

        // Round 1: Asset1 oversold, Asset2 oversold
        uint256[] memory demands1_1 = new uint256[](2);
        demands1_1[0] = 60 * 10**18;  // Asset1: 60 + 50 = 110 > 100 (oversold)
        demands1_1[1] = 80 * 10**18;  // Asset2: 80 + 80 = 160 > 150 (oversold)

        uint256[] memory demands2_1 = new uint256[](2);
        demands2_1[0] = 50 * 10**18;
        demands2_1[1] = 80 * 10**18;

        vm.prank(bidder1);
        cpaManager.submitBid(auctionId, demands1_1, 1000 * 10**18);
        vm.prank(bidder2);
        cpaManager.submitBid(auctionId, demands2_1, 1000 * 10**18);

        // End round 1
        endClockRound(auctionId);

        // Check asset info after round 1
        AssetId assetId1 = AssetIdLibrary.createId(auctionId, address(asset1Token));
        AssetId assetId2 = AssetIdLibrary.createId(auctionId, address(asset2Token));

        AuctionTypes.AssetInfo memory asset1Info1 = cpaManager.getAssetInfo(assetId1);
        AuctionTypes.AssetInfo memory asset2Info1 = cpaManager.getAssetInfo(assetId2);

        // Asset1 should have positive excess demand (oversold)
        assertGt(asset1Info1.excessDemand, 0, "Asset1 should have positive excess demand (oversold)");
        // Asset2 should have positive excess demand (oversold)
        assertGt(asset2Info1.excessDemand, 0, "Asset2 should have positive excess demand (oversold)");

        // Asset1 price should have increased
        assertGt(asset1Info1.currentPrice, asset1StartingPrice, "Asset1 price should have increased after oversold round");
        // Asset2 price should have increased
        assertGt(asset2Info1.currentPrice, asset2StartingPrice, "Asset2 price should have increased after oversold round");

        // Round 2: Asset1 exactly clearing, Asset2 undersold
        uint256[] memory demands1_2 = new uint256[](2);
        demands1_2[0] = 50 * 10**18;  // Asset1: 50 + 50 = 100 = 100 (exactly clearing)
        demands1_2[1] = 30 * 10**18;  // Asset2: 30 + 25 = 55 < 150 (undersold)

        uint256[] memory demands2_2 = new uint256[](2);
        demands2_2[0] = 50 * 10**18;
        demands2_2[1] = 25 * 10**18;

        vm.prank(bidder1);
        cpaManager.submitBid(auctionId, demands1_2, 1000 * 10**18);
        vm.prank(bidder2);
        cpaManager.submitBid(auctionId, demands2_2, 1000 * 10**18);

        // End round 2
        endClockRound(auctionId);

        // Verify asset info after round 2
        AuctionTypes.AssetInfo memory asset1Info2 = cpaManager.getAssetInfo(assetId1);
        AuctionTypes.AssetInfo memory asset2Info2 = cpaManager.getAssetInfo(assetId2);

        // Asset1 should have zero excess demand (exactly clearing)
        assertEq(asset1Info2.excessDemand, 0, "Asset1 should have zero excess demand (exactly clearing)");
        // Asset2 should have negative excess demand (undersold)
        assertLt(asset2Info2.excessDemand, 0, "Asset2 should have negative excess demand (undersold)");

        // Asset1 price should remain from round 1 (no further increase when exactly clearing)
        assertEq(asset1Info2.currentPrice, asset1Info1.currentPrice, "Asset1 price should remain unchanged when exactly clearing");
        // Asset2 price should remain from round 1 (no further increase when undersold)
        assertEq(asset2Info2.currentPrice, asset2Info1.currentPrice, "Asset2 price should remain unchanged when undersold");
    }

    // ============ dropout() Function Tests ============

    function test_Dropout_SuccessInClockPhase() public {
        // Start clock phase
        vm.prank(auctioneer);
        cpaManager.startClockPhase(auctionId);

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

        // Submit bid to establish stake
        uint256[] memory demands = new uint256[](2);
        demands[0] = 50 * 10**asset1Token.decimals();
        demands[1] = 30 * 10**asset2Token.decimals();

        approveNumeraireForBidder(testBidder, type(uint256).max);

        vm.prank(testBidder);
        cpaManager.submitBid(auctionId, demands, type(uint256).max);

        // Verify bidder is in activeBidders and has stake
        address activeBidder = cpaManager.activeBidders(auctionId, 0);
        assertEq(activeBidder, testBidder, "Active bidder should be testBidder");

        uint256 bidderStake = cpaManager.bidderStake(auctionId, testBidder);
        assertGt(bidderStake, 0, "Bidder should have stake");

        // Dropout
        vm.prank(testBidder);
        cpaManager.dropout(auctionId);

        // Verify bidderStake is set to 0
        uint256 bidderStakeAfter = cpaManager.bidderStake(auctionId, testBidder);
        assertEq(bidderStakeAfter, 0, "Bidder stake should be 0 after dropout");

        // Verify bidder removed from activeBidders
        // After dropout, there should be no active bidders (index 0 should be address(0))
        address activeBidderAfter = cpaManager.activeBidders(auctionId, 0);
        assertEq(activeBidderAfter, address(0), "Should have 0 active bidders after dropout");

        // Verify protocol accrued accumulated
        uint256 protocolAccrued = cpaManager.protocolAccrued(auctionId);
        assertGt(protocolAccrued, 0, "Protocol accrued should be accumulated");
    }

    function test_Dropout_CorrectPenaltyCalculation() public {
        // Start clock phase
        vm.prank(auctioneer);
        cpaManager.startClockPhase(auctionId);

        // Create bidder with known stake amount
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

        // Submit bid with known stake amount
        uint256[] memory demands = new uint256[](2);
        demands[0] = 100 * 10**asset1Token.decimals(); // Higher demands for larger stake
        demands[1] = 50 * 10**asset2Token.decimals();

        approveNumeraireForBidder(testBidder, type(uint256).max);

        vm.prank(testBidder);
        cpaManager.submitBid(auctionId, demands, type(uint256).max);

        // Get the actual stake amount
        uint256 stakeAmount = cpaManager.bidderStake(auctionId, testBidder);
        assertGt(stakeAmount, 0, "Bidder should have stake");

        // Get auction config to check dropoutSlashRatio
        AuctionTypes.AuctionInfo memory auctionInfo = cpaManager.getAuctionInfo(auctionId);
        uint256 dropoutSlashRatio = auctionInfo.config.dropoutSlashRatio;

        // Calculate expected penalty and refund
        uint256 expectedPenalty = (stakeAmount * dropoutSlashRatio) / 10000;
        uint256 expectedRefund = stakeAmount - expectedPenalty;

        // Get initial protocol accrued
        uint256 initialProtocolAccrued = cpaManager.protocolAccrued(auctionId);

        // Dropout
        vm.prank(testBidder);
        cpaManager.dropout(auctionId);

        // Verify penalty calculation
        uint256 finalProtocolAccrued = cpaManager.protocolAccrued(auctionId);
        uint256 actualPenalty = finalProtocolAccrued - initialProtocolAccrued;
        assertEq(actualPenalty, expectedPenalty, "Penalty should match expected calculation");

        // Verify bidder stake is 0
        uint256 bidderStakeAfter = cpaManager.bidderStake(auctionId, testBidder);
        assertEq(bidderStakeAfter, 0, "Bidder stake should be 0 after dropout");
    }

    function test_Dropout_RevertNonBidder() public {
        // Start clock phase
        vm.prank(auctioneer);
        cpaManager.startClockPhase(auctionId);

        // Create address that hasn't submitted bid
        address nonBidder = makeAddr("nonBidder");
        createBidder(nonBidder, 100000 * 10**18);

        // Attempt dropout without having submitted bid
        vm.prank(nonBidder);
        vm.expectRevert();
        cpaManager.dropout(auctionId);
    }

    function test_Dropout_RevertWrongPhase() public {
        // Create auction but don't start clock phase (stay in Setup)
        AuctionTypes.AuctionInfo memory auctionInfo = cpaManager.getAuctionInfo(auctionId);
        assertEq(uint8(auctionInfo.currentPhase), uint8(AuctionTypes.AuctionPhase.Setup), "Should be in Setup phase");

        // Create bidder
        address testBidder = makeAddr("testBidder");
        createBidder(testBidder, 100000 * 10**18);

        // Attempt dropout in Setup phase
        vm.prank(testBidder);
        vm.expectRevert(abi.encodeWithSelector(IErrorsAndEvents.InvalidPhase.selector, AuctionTypes.AuctionPhase.Clock, AuctionTypes.AuctionPhase.Setup));
        cpaManager.dropout(auctionId);
    }

    function test_Dropout_MultipleBiddersDropout() public {
        // Start clock phase
        vm.prank(auctioneer);
        cpaManager.startClockPhase(auctionId);

        // Create 3 bidders
        address bidder1 = makeAddr("bidder1");
        address bidder2 = makeAddr("bidder2");
        address bidder3 = makeAddr("bidder3");
        address proxy1 = makeAddr("proxy1");
        address proxy2 = makeAddr("proxy2");
        address proxy3 = makeAddr("proxy3");

        createBidder(bidder1, 10000000 * 10**18);
        createBidder(bidder2, 10000000 * 10**18);
        createBidder(bidder3, 10000000 * 10**18);

        // Generate commit hashes
        bytes32 saltA1 = keccak256("saltA1");
        bytes32 saltB1 = keccak256("saltB1");
        bytes32 commitHash1 = CommitReveal.generateCommitHash(bidder1, proxy1, saltA1, saltB1);

        bytes32 saltA2 = keccak256("saltA2");
        bytes32 saltB2 = keccak256("saltB2");
        bytes32 commitHash2 = CommitReveal.generateCommitHash(bidder2, proxy2, saltA2, saltB2);

        bytes32 saltA3 = keccak256("saltA3");
        bytes32 saltB3 = keccak256("saltB3");
        bytes32 commitHash3 = CommitReveal.generateCommitHash(bidder3, proxy3, saltA3, saltB3);

        // Proxies commit
        vm.prank(proxy1);
        cpaManager.commitToBidder(auctionId, commitHash1);
        vm.prank(proxy2);
        cpaManager.commitToBidder(auctionId, commitHash2);
        vm.prank(proxy3);
        cpaManager.commitToBidder(auctionId, commitHash3);

        // All submit bids in round 1 with high demands to ensure excess demand
        uint256[] memory demands1 = new uint256[](2);
        demands1[0] = 100 * 10**asset1Token.decimals(); // Increased to ensure excess demand
        demands1[1] = 80 * 10**asset2Token.decimals();  // Increased to ensure excess demand

        uint256[] memory demands2 = new uint256[](2);
        demands2[0] = 90 * 10**asset1Token.decimals();   // Increased to ensure excess demand
        demands2[1] = 70 * 10**asset2Token.decimals();   // Increased to ensure excess demand

        uint256[] memory demands3 = new uint256[](2);
        demands3[0] = 85 * 10**asset1Token.decimals();  // Increased to ensure excess demand
        demands3[1] = 65 * 10**asset2Token.decimals();  // Increased to ensure excess demand

        approveNumeraireForBidder(bidder1, type(uint256).max);
        approveNumeraireForBidder(bidder2, type(uint256).max);
        approveNumeraireForBidder(bidder3, type(uint256).max);

        vm.prank(bidder1);
        cpaManager.submitBid(auctionId, demands1, type(uint256).max);
        vm.prank(bidder2);
        cpaManager.submitBid(auctionId, demands2, type(uint256).max);
        vm.prank(bidder3);
        cpaManager.submitBid(auctionId, demands3, type(uint256).max);

        // Verify all 3 bidders are active
        address activeBidder1 = cpaManager.activeBidders(auctionId, 0);
        address activeBidder2 = cpaManager.activeBidders(auctionId, 1);
        address activeBidder3 = cpaManager.activeBidders(auctionId, 2);
        assertTrue(activeBidder1 == bidder1 || activeBidder1 == bidder2 || activeBidder1 == bidder3, "Should have active bidders");

        // Bidder1 drops out
        vm.prank(bidder1);
        cpaManager.dropout(auctionId);

        // Verify bidder2 and bidder3 still active
        // After dropout, bidder1 becomes address(0) but stays in the array
        address activeBidder1After = cpaManager.activeBidders(auctionId, 0);
        address activeBidder2After = cpaManager.activeBidders(auctionId, 1);
        address activeBidder3After = cpaManager.activeBidders(auctionId, 2);

        // bidder1 should be address(0) (dropped out)
        assertEq(activeBidder1After, address(0), "Bidder1 should be dropped (address(0))");
        // bidder2 and bidder3 should still be active
        assertTrue(activeBidder2After == bidder2 || activeBidder2After == bidder3, "Bidder2 or bidder3 should be active at index 1");
        assertTrue(activeBidder3After == bidder2 || activeBidder3After == bidder3, "Bidder2 or bidder3 should be active at index 2");

        // End round 1, start round 2
        endClockRound(auctionId);

        // Bidder2 and bidder3 submit new bids in round 2
        // Must respect activity rule: if price increased, new demand <= previous demand
        uint256[] memory demands2_2 = new uint256[](2);
        demands2_2[0] = 80 * 10**asset1Token.decimals();  // Reduced from 90 to respect activity rule
        demands2_2[1] = 60 * 10**asset2Token.decimals();  // Reduced from 70 to respect activity rule

        uint256[] memory demands3_2 = new uint256[](2);
        demands3_2[0] = 75 * 10**asset1Token.decimals();  // Reduced from 85 to respect activity rule
        demands3_2[1] = 55 * 10**asset2Token.decimals();  // Reduced from 65 to respect activity rule

        vm.prank(bidder2);
        cpaManager.submitBid(auctionId, demands2_2, type(uint256).max);
        vm.prank(bidder3);
        cpaManager.submitBid(auctionId, demands3_2, type(uint256).max);

        // Bidder2 drops out
        vm.prank(bidder2);
        cpaManager.dropout(auctionId);

        // Verify only bidder3 active
        // After round 2 starts, activeBidders array is reset, so only contains current round bidders
        // bidder1 was dropped in round 1, so not in round 2 activeBidders
        // bidder2 was dropped in round 2, so becomes address(0) in round 2 activeBidders
        // bidder3 is still active in round 2
        address activeBidder2Final = cpaManager.activeBidders(auctionId, 0);
        address activeBidder3Final = cpaManager.activeBidders(auctionId, 1);

        // activeBidders[0] should be address(0) (bidder2 dropped out in round 2)
        assertEq(activeBidder2Final, address(0), "Bidder2 should be dropped (address(0))");
        // activeBidders[1] should be bidder3 (only remaining active bidder)
        assertEq(activeBidder3Final, bidder3, "Only bidder3 should be active");

        // Verify protocol accrued accumulated from both dropouts
        uint256 protocolAccrued = cpaManager.protocolAccrued(auctionId);
        assertGt(protocolAccrued, 0, "Protocol accrued should be accumulated from both dropouts");
    }

    function test_Dropout_CannotDropoutTwice() public {
        // Start clock phase
        vm.prank(auctioneer);
        cpaManager.startClockPhase(auctionId);

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

        // Submit bid
        uint256[] memory demands = new uint256[](2);
        demands[0] = 50 * 10**asset1Token.decimals();
        demands[1] = 30 * 10**asset2Token.decimals();

        approveNumeraireForBidder(testBidder, type(uint256).max);

        vm.prank(testBidder);
        cpaManager.submitBid(auctionId, demands, type(uint256).max);

        // First dropout - should succeed
        vm.prank(testBidder);
        cpaManager.dropout(auctionId);

        // Verify bidder stake is 0
        uint256 bidderStake = cpaManager.bidderStake(auctionId, testBidder);
        assertEq(bidderStake, 0, "Bidder stake should be 0 after first dropout");

        // Attempt to dropout again - should revert
        vm.prank(testBidder);
        vm.expectRevert();
        cpaManager.dropout(auctionId);
    }

    // ============ cancelAuction() Function Tests ============

    function test_CancelAuction_SuccessInClockPhase() public {
        // Start clock phase
        vm.prank(auctioneer);
        cpaManager.startClockPhase(auctionId);

        // Verify auction is in Clock phase
        AuctionTypes.AuctionInfo memory auctionInfo = cpaManager.getAuctionInfo(auctionId);
        assertEq(uint8(auctionInfo.currentPhase), uint8(AuctionTypes.AuctionPhase.Clock), "Should be in Clock phase");

        // Cancel auction
        vm.prank(auctioneer);
        cpaManager.cancelAuction(auctionId);

        // Verify auction status is Cancelled
        AuctionTypes.AuctionInfo memory auctionInfoAfter = cpaManager.getAuctionInfo(auctionId);
        assertEq(uint8(auctionInfoAfter.currentStatus), uint8(AuctionTypes.AuctionStatus.Cancelled), "Auction should be cancelled");
    }

    function test_CancelAuction_WithBidsSubmitted() public {
        // Start clock phase
        vm.prank(auctioneer);
        cpaManager.startClockPhase(auctionId);

        // Create bidder and submit bid
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

        // Submit bid
        uint256[] memory demands = new uint256[](2);
        demands[0] = 30 * 10**asset1Token.decimals();
        demands[1] = 35 * 10**asset2Token.decimals();

        approveNumeraireForBidder(testBidder, type(uint256).max);

        vm.prank(testBidder);
        cpaManager.submitBid(auctionId, demands, type(uint256).max);

        // Verify bidder has stake
        uint256 bidderStake = cpaManager.bidderStake(auctionId, testBidder);
        assertGt(bidderStake, 0, "Bidder should have stake");

        // Cancel auction
        vm.prank(auctioneer);
        cpaManager.cancelAuction(auctionId);

        // Verify auction status is Cancelled
        AuctionTypes.AuctionInfo memory auctionInfoAfter = cpaManager.getAuctionInfo(auctionId);
        assertEq(uint8(auctionInfoAfter.currentStatus), uint8(AuctionTypes.AuctionStatus.Cancelled), "Auction should be cancelled");

        // Verify bidder can reclaim full stake (no penalty for cancelled auctions)
        uint256 initialBalance = numeraireToken.balanceOf(testBidder);
        vm.prank(testBidder);
        cpaManager.reclaimStake(auctionId);
        uint256 finalBalance = numeraireToken.balanceOf(testBidder);

        assertGt(finalBalance, initialBalance, "Bidder should receive stake back");
        assertEq(finalBalance - initialBalance, bidderStake, "Bidder should receive full stake back (no penalty)");
    }

    function test_CancelAuction_CannotCancelAfterClock() public {
        // Start clock phase
        vm.prank(auctioneer);
        cpaManager.startClockPhase(auctionId);

        // Create bidder and submit bid
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

        // Submit bid
        uint256[] memory demands = new uint256[](2);
        demands[0] = 30 * 10**asset1Token.decimals();
        demands[1] = 35 * 10**asset2Token.decimals();

        approveNumeraireForBidder(testBidder, type(uint256).max);

        vm.prank(testBidder);
        cpaManager.submitBid(auctionId, demands, type(uint256).max);

        // End clock phase and transition to proxy phase
        vm.prank(auctioneer);
        cpaManager.endClockPhase(auctionId);

        // Verify we're now in Proxy phase
        AuctionTypes.AuctionInfo memory auctionInfo = cpaManager.getAuctionInfo(auctionId);
        assertEq(uint8(auctionInfo.currentPhase), uint8(AuctionTypes.AuctionPhase.Proxy), "Should be in Proxy phase");

        // Try to cancel auction - should revert
        vm.prank(auctioneer);
        vm.expectRevert(abi.encodeWithSelector(IErrorsAndEvents.CannotCancelInThisPhase.selector, auctionId, AuctionTypes.AuctionPhase.Proxy));
        cpaManager.cancelAuction(auctionId);
    }

    // ============ Stake Management Tests ============

    function test_StakeTracking_SingleBidder() public {
        // Start clock phase
        vm.prank(auctioneer);
        cpaManager.startClockPhase(auctionId);

        // Create bidder and proxy
        address testBidder = makeAddr("testBidder");
        address testProxy = makeAddr("testProxy");
        createBidder(testBidder, 10000000 * 10**18);

        // Generate commit hash
        bytes32 saltA = keccak256("saltA");
        bytes32 saltB = keccak256("saltB");
        bytes32 commitHash = CommitReveal.generateCommitHash(testBidder, testProxy, saltA, saltB);

        // Proxy commits
        vm.prank(testProxy);
        cpaManager.commitToBidder(auctionId, commitHash);

        // Submit first bid with high demands to ensure overdemand
        uint256[] memory demands1 = new uint256[](2);
        demands1[0] = 30000 * 10**asset1Token.decimals(); // High demand to cause overdemand (30k vs 50k available)
        demands1[1] = 35000 * 10**asset2Token.decimals(); // High demand to cause overdemand (35k vs 60k available)

        uint256 requiredStake1 = calculateBidValue(demands1);
        uint256 allocatorReward1 = calculateBidValue(demands1) * allocatorRewardPct / 10000;
        approveNumeraireForBidder(testBidder, type(uint256).max);

        vm.prank(testBidder);
        cpaManager.submitBid(auctionId, demands1, requiredStake1 + allocatorReward1);

        // Verify initial stake
        uint256 stake1 = cpaManager.bidderStake(auctionId, testBidder);
        assertEq(stake1, requiredStake1, "Bidder should have stake equal to required stake after first bid");

        // End round 1, start round 2
        endClockRound(auctionId);

        // Submit second bid with same demands (to respect activity rule after price increase)
        uint256[] memory demands2 = new uint256[](2);
        demands2[0] = 30000 * 10**asset1Token.decimals(); // Same demand (activity rule)
        demands2[1] = 35000 * 10**asset2Token.decimals();  // Same demand (activity rule)

        uint256 requiredStake2 = calculateBidValue(demands2);
        uint256 allocatorReward2 = calculateBidValue(demands2) * allocatorRewardPct / 10000;

        vm.prank(testBidder);
        cpaManager.submitBid(auctionId, demands2, requiredStake2 + allocatorReward2);

        // Verify stake increased by the difference (if requiredStake2 > requiredStake1)
        uint256 stake2 = cpaManager.bidderStake(auctionId, testBidder);
        if (requiredStake2 > requiredStake1) {
            assertEq(stake2, requiredStake2, "Stake should be updated to new required stake");
        } else {
            assertEq(stake2, requiredStake1, "Stake should remain unchanged if new required stake is lower");
        }
    }

    function test_StakeTracking_MultipleBidders() public {
        // Start clock phase
        vm.prank(auctioneer);
        cpaManager.startClockPhase(auctionId);

        // Create 3 bidders
        address bidder1 = makeAddr("bidder1");
        address bidder2 = makeAddr("bidder2");
        address bidder3 = makeAddr("bidder3");
        address proxy1 = makeAddr("proxy1");
        address proxy2 = makeAddr("proxy2");
        address proxy3 = makeAddr("proxy3");

        createBidder(bidder1, 10000000 * 10**18);
        createBidder(bidder2, 10000000 * 10**18);
        createBidder(bidder3, 10000000 * 10**18);

        // Generate commit hashes
        bytes32 saltA1 = keccak256("saltA1");
        bytes32 saltB1 = keccak256("saltB1");
        bytes32 commitHash1 = CommitReveal.generateCommitHash(bidder1, proxy1, saltA1, saltB1);

        bytes32 saltA2 = keccak256("saltA2");
        bytes32 saltB2 = keccak256("saltB2");
        bytes32 commitHash2 = CommitReveal.generateCommitHash(bidder2, proxy2, saltA2, saltB2);

        bytes32 saltA3 = keccak256("saltA3");
        bytes32 saltB3 = keccak256("saltB3");
        bytes32 commitHash3 = CommitReveal.generateCommitHash(bidder3, proxy3, saltA3, saltB3);

        // Proxies commit
        vm.prank(proxy1);
        cpaManager.commitToBidder(auctionId, commitHash1);
        vm.prank(proxy2);
        cpaManager.commitToBidder(auctionId, commitHash2);
        vm.prank(proxy3);
        cpaManager.commitToBidder(auctionId, commitHash3);

        // All submit bids with different stake amounts
        uint256[] memory demands1 = new uint256[](2);
        demands1[0] = 100 * 10**asset1Token.decimals();
        demands1[1] = 80 * 10**asset2Token.decimals();

        uint256[] memory demands2 = new uint256[](2);
        demands2[0] = 90 * 10**asset1Token.decimals();
        demands2[1] = 70 * 10**asset2Token.decimals();

        uint256[] memory demands3 = new uint256[](2);
        demands3[0] = 85 * 10**asset1Token.decimals();
        demands3[1] = 65 * 10**asset2Token.decimals();

        approveNumeraireForBidder(bidder1, type(uint256).max);
        approveNumeraireForBidder(bidder2, type(uint256).max);
        approveNumeraireForBidder(bidder3, type(uint256).max);

        // Calculate bid values before prank calls
        uint256 requiredStake1 = calculateBidValue(demands1);
        uint256 allocatorReward1 = calculateBidValue(demands1) * allocatorRewardPct / 10000;
        uint256 requiredStake2 = calculateBidValue(demands2);
        uint256 allocatorReward2 = calculateBidValue(demands2) * allocatorRewardPct / 10000;
        uint256 requiredStake3 = calculateBidValue(demands3);
        uint256 allocatorReward3 = calculateBidValue(demands3) * allocatorRewardPct / 10000;

        // Submit bids
        vm.prank(bidder1);
        cpaManager.submitBid(auctionId, demands1, requiredStake1 + allocatorReward1);
        vm.prank(bidder2);
        cpaManager.submitBid(auctionId, demands2, requiredStake2 + allocatorReward2);
        vm.prank(bidder3);
        cpaManager.submitBid(auctionId, demands3, requiredStake3 + allocatorReward3);

        // Verify all bidders have stakes equal to their calculated required stakes
        uint256 stake1 = cpaManager.bidderStake(auctionId, bidder1);
        uint256 stake2 = cpaManager.bidderStake(auctionId, bidder2);
        uint256 stake3 = cpaManager.bidderStake(auctionId, bidder3);

        assertEq(stake1, requiredStake1, "Bidder1 stake should equal required stake");
        assertEq(stake2, requiredStake2, "Bidder2 stake should equal required stake");
        assertEq(stake3, requiredStake3, "Bidder3 stake should equal required stake");

        // Verify stakes are different based on demands (higher demands = higher stakes)
        assertGt(stake1, stake2, "Bidder1 should have higher stake than bidder2 (higher demands)");
        assertGt(stake2, stake3, "Bidder2 should have higher stake than bidder3 (higher demands)");

        // Verify CPAManager holds all the numeraire tokens
        uint256 totalStake = requiredStake1 + requiredStake2 + requiredStake3 + allocatorReward1 + allocatorReward2 + allocatorReward3;
        uint256 cpaManagerBalance = numeraireToken.balanceOf(address(cpaManager));
        assertEq(cpaManagerBalance, totalStake, "CPAManager should hold all numeraire tokens PLUS allocator rewards");
    }

    function test_StakeUpdate_OnNewBid() public {
        // Start clock phase
        vm.prank(auctioneer);
        cpaManager.startClockPhase(auctionId);

        // Create bidder and proxy
        address testBidder = makeAddr("testBidder");
        address testProxy = makeAddr("testProxy");
        createBidder(testBidder, 10000000 * 10**18);

        // Generate commit hash
        bytes32 saltA = keccak256("saltA");
        bytes32 saltB = keccak256("saltB");
        bytes32 commitHash = CommitReveal.generateCommitHash(testBidder, testProxy, saltA, saltB);

        // Proxy commits
        vm.prank(testProxy);
        cpaManager.commitToBidder(auctionId, commitHash);

        // Submit first bid
        uint256[] memory demands1 = new uint256[](2);
        demands1[0] = 30000 * 10**asset1Token.decimals();
        demands1[1] = 35000 * 10**asset2Token.decimals();

        uint256 requiredStake1 = calculateBidValue(demands1);
        uint256 allocatorReward1 = calculateBidValue(demands1) * allocatorRewardPct / 10000;
        approveNumeraireForBidder(testBidder, type(uint256).max);

        vm.prank(testBidder);
        cpaManager.submitBid(auctionId, demands1, requiredStake1 + allocatorReward1);

        // Get initial stake
        uint256 initialStake = cpaManager.bidderStake(auctionId, testBidder);
        assertGt(initialStake, 0, "Bidder should have initial stake");

        // End round 1, start round 2
        endClockRound(auctionId);

        // Submit second bid with same demands (to respect activity rule after price increase)
        uint256[] memory demands2 = new uint256[](2);
        demands2[0] = 30000 * 10**asset1Token.decimals(); // Same demand (activity rule)
        demands2[1] = 35000 * 10**asset2Token.decimals();  // Same demand (activity rule)

        uint256 requiredStake2 = calculateBidValue(demands2);
        uint256 allocatorReward2 = calculateBidValue(demands2) * allocatorRewardPct / 10000;

        vm.prank(testBidder);
        cpaManager.submitBid(auctionId, demands2, requiredStake2 + allocatorReward2);

        // Verify stake behavior based on required stake difference
        uint256 finalStake = cpaManager.bidderStake(auctionId, testBidder);
        if (requiredStake2 > initialStake) {
            assertEq(finalStake, requiredStake2, "Stake should increase to new required stake");
        } else {
            assertEq(finalStake, initialStake, "Stake should remain unchanged if new required stake is lower");
        }
    }

    function test_StakeUpdate_OnReducedBid() public {
        // Start clock phase
        vm.prank(auctioneer);
        cpaManager.startClockPhase(auctionId);

        // Create bidder and proxy
        address testBidder = makeAddr("testBidder");
        address testProxy = makeAddr("testProxy");
        createBidder(testBidder, 10000000 * 10**18);

        // Generate commit hash
        bytes32 saltA = keccak256("saltA");
        bytes32 saltB = keccak256("saltB");
        bytes32 commitHash = CommitReveal.generateCommitHash(testBidder, testProxy, saltA, saltB);

        // Proxy commits
        vm.prank(testProxy);
        cpaManager.commitToBidder(auctionId, commitHash);

        // Submit first bid with high demands
        uint256[] memory demands1 = new uint256[](2);
        demands1[0] = 30000 * 10**asset1Token.decimals(); // High demand
        demands1[1] = 35000 * 10**asset2Token.decimals(); // High demand

        uint256 requiredStake1 = calculateBidValue(demands1);
        uint256 allocatorReward1 = calculateBidValue(demands1) * allocatorRewardPct / 10000;
        approveNumeraireForBidder(testBidder, type(uint256).max);

        vm.prank(testBidder);
        cpaManager.submitBid(auctionId, demands1, requiredStake1 + allocatorReward1);

        // Get initial stake
        uint256 initialStake = cpaManager.bidderStake(auctionId, testBidder);
        assertGt(initialStake, 0, "Bidder should have initial stake");

        // End round 1, start round 2
        endClockRound(auctionId);

        // Submit second bid with lower demands (stake should NOT decrease)
        uint256[] memory demands2 = new uint256[](2);
        demands2[0] = 28000 * 10**asset1Token.decimals(); // Lower demand (respects activity rule)
        demands2[1] = 33000 * 10**asset2Token.decimals(); // Lower demand (respects activity rule)

        uint256 requiredStake2 = calculateBidValue(demands2);
        uint256 allocatorReward2 = calculateBidValue(demands2) * allocatorRewardPct / 10000;

        vm.prank(testBidder);
        cpaManager.submitBid(auctionId, demands2, requiredStake2 + allocatorReward2);

        // Verify stake behavior: if requiredStake2 < initialStake, stake stays the same
        // If requiredStake2 > initialStake, stake increases to requiredStake2
        uint256 finalStake = cpaManager.bidderStake(auctionId, testBidder);
        if (requiredStake2 > initialStake) {
            assertEq(finalStake, requiredStake2, "Stake should increase if new required stake is higher");
        } else {
            assertEq(finalStake, initialStake, "Stake should remain unchanged if new required stake is lower");
        }
    }


    function test_SubmitAllocation_RejectedInClockPhase() public {
        // Start the clock phase first
        vm.prank(auctioneer);
        cpaManager.startClockPhase(auctionId);

        // Test that allocation submission is rejected during Clock phase
        address testAllocator = makeAddr("testAllocator");

        // Create a test allocation
        AuctionTypes.Allocation memory testAllocation = AuctionTypes.Allocation({
            auctionId: auctionId,
            allocator: testAllocator,
            bundleIds: new BundleId[](0), // Empty bundle array
            totalValue: 1000 * 10**18,
            timestamp: block.timestamp
        });

        // Should fail with InvalidPhase error (Clock phase, not Allocation phase)
        vm.prank(testAllocator);
        vm.expectRevert(abi.encodeWithSelector(IErrorsAndEvents.InvalidPhase.selector, AuctionTypes.AuctionPhase.Allocation, AuctionTypes.AuctionPhase.Clock));
        cpaManager.submitAllocation(auctionId, testAllocation);
    }
}
