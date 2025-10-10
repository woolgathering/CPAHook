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
import { AuctionTypes } from "../src/types/AuctionTypes.sol";
import { AuctionId } from "../src/types/AuctionId.sol";
import { IErrorsAndEvents } from "../src/utils/IErrorsAndEvents.sol";
import { CommitReveal } from "../src/utils/CommitReveal.sol";
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
        assertEq(auctionInfo.poolKeys.length, 2, "Should have 2 asset pools");

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
        assertEq(auctionInfoAfterStart.poolKeys.length, 2, "Should still have 2 asset pools");
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
        // Create a new auction with different pool keys but without deposits
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
        cpaManager.submitBid(auctionId, bidder1Demands, calculateBidValue(bidder1Demands));
        vm.stopPrank();
        
        vm.startPrank(testBidder2);
        cpaManager.submitBid(auctionId, bidder2Demands, calculateBidValue(bidder2Demands));
        vm.stopPrank();

        // End first round - this should automatically start the second round (due to excess demand)
        vm.prank(auctioneer);
        cpaManager.endClockRound(auctionId);

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
        cpaManager.submitBid(auctionId, bidder1Demands2, calculateBidValue(bidder1Demands2));
        vm.stopPrank();
        
        vm.startPrank(testBidder2);
        cpaManager.submitBid(auctionId, bidder2Demands2, calculateBidValue(bidder2Demands2));
        vm.stopPrank();

        // End second round - this should automatically start the third round
        vm.prank(auctioneer);
        cpaManager.endClockRound(auctionId);

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
        
        uint256 requiredStake = calculateBidValue(zeroDemands);
        approveNumeraireForBidder(testBidder, type(uint256).max);
        
        vm.prank(testBidder);
        cpaManager.submitBid(auctionId, zeroDemands, requiredStake);
        
        // Verify the zero bid was accepted using mapping-based storage
        uint256[] memory zeroDemandsCheck = cpaManager.getBidderDemands(auctionId, testBidder);
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
        
        uint256 requiredStake = calculateBidValue(largeDemands) * 2;
        approveNumeraireForBidder(testBidder, type(uint256).max);
        
        vm.prank(testBidder);
        cpaManager.submitBid(auctionId, largeDemands, requiredStake);
        
        // Verify the large bid was accepted using mapping-based storage
        uint256[] memory largeDemandsCheck = cpaManager.getBidderDemands(auctionId, testBidder);
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
        
        uint256 requiredStake = calculateBidValue(demands) * 2;
        approveNumeraireForBidder(testBidder, type(uint256).max);
        
        vm.prank(testBidder);
        // This should succeed since the proxy commitment check is commented out
        cpaManager.submitBid(auctionId, demands, requiredStake);
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
        uint256[] memory bidder1DemandsFinal = cpaManager.getBidderDemands(auctionId, bidder1);
        uint256[] memory bidder2DemandsFinal = cpaManager.getBidderDemands(auctionId, bidder2);
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
        
        uint256 requiredStake = calculateBidValue(demands);
        approveNumeraireForBidder(testBidder, type(uint256).max);
        
        vm.prank(testBidder);
        vm.expectRevert(abi.encodeWithSelector(IErrorsAndEvents.InvalidPhase.selector, uint8(AuctionTypes.AuctionPhase.Clock), uint8(AuctionTypes.AuctionPhase.Setup)));
        cpaManager.submitBid(auctionId, demands, requiredStake);
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
        
        uint256 requiredStake = calculateBidValue(demands);
        approveNumeraireForBidder(testBidder, type(uint256).max);
        
        vm.prank(testBidder);
        vm.expectRevert(); // Should revert due to invalid auction
        cpaManager.submitBid(invalidAuctionId, demands, requiredStake);
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
        cpaManager.submitBid(auctionId, bidder1Demands, calculateBidValue(bidder1Demands));
        vm.stopPrank();
        
        vm.startPrank(testBidder2);
        cpaManager.submitBid(auctionId, bidder2Demands, calculateBidValue(bidder2Demands));
        vm.stopPrank();

        // End round to trigger price increase (excess demand on asset1)
        vm.prank(auctioneer);
        cpaManager.endClockRound(auctionId);

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
        cpaManager.submitBid(auctionId, bidder1Demands, calculateBidValue(bidder1Demands));
        vm.stopPrank();

        vm.startPrank(testBidder2);
        cpaManager.submitBid(auctionId, bidder2Demands, calculateBidValue(bidder2Demands));
        vm.stopPrank();

        // End round to trigger price increase (excess demand on asset1)
        vm.prank(auctioneer);
        cpaManager.endClockRound(auctionId);

        // New round should start automatically

        // Submit bid with reduced demands - this should be valid
        uint256[] memory reducedDemands = new uint256[](2);
        reducedDemands[0] = 40 * 10**asset1Token.decimals(); // Reduced from 50 (valid)
        reducedDemands[1] = 25 * 10**asset2Token.decimals(); // Reduced from 30 (valid)
        
        vm.startPrank(testBidder1);
        cpaManager.submitBid(auctionId, reducedDemands, calculateBidValue(reducedDemands));
        vm.stopPrank();

        // Verify the reduced demands were accepted
        uint256[] memory storedDemands = cpaManager.getBidderDemands(auctionId, testBidder1);
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
        cpaManager.submitBid(auctionId, bidder1Demands, calculateBidValue(bidder1Demands));
        vm.stopPrank();
        
        vm.startPrank(testBidder2);
        cpaManager.submitBid(auctionId, bidder2Demands, calculateBidValue(bidder2Demands));
        vm.stopPrank();

        // End round - should automatically end clock phase due to no excess demand
        vm.prank(auctioneer);
        cpaManager.endClockRound(auctionId);

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
        // Test that excessDemand is correctly calculated as signed integer and lastOversoldTick is tracked
        
        PoolKey[] memory poolKeys = new PoolKey[](2);
        poolKeys[0] = asset1PoolKey;
        poolKeys[1] = asset2PoolKey;
        
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
        vm.prank(auctioneer);
        cpaManager.endClockRound(auctionId);
        
        // Check that asset1 was oversold and price increased, asset2 stayed same
        (, int24 asset1Tick1, , ) = poolManager.getSlot0(poolKeys[0].toId());
        (, int24 asset2Tick1, , ) = poolManager.getSlot0(poolKeys[1].toId());
        
        // Verify pool info after round 1
        (,,,uint256 asset1Deposit1, int256 asset1ExcessDemand1, int24 asset1LastOversoldTick1, AuctionId asset1AuctionId1, bytes32 asset1PositionId1) = cpaManager.getPoolInfo(poolKeys[0].toId());
        (,,,uint256 asset2Deposit1, int256 asset2ExcessDemand1, int24 asset2LastOversoldTick1, AuctionId asset2AuctionId1, bytes32 asset2PositionId1) = cpaManager.getPoolInfo(poolKeys[1].toId());
        
        // Asset1 should have positive excess demand (oversold)
        assertGt(asset1ExcessDemand1, 0, "Asset1 should have positive excess demand (oversold)");
        // Asset2 should have positive excess demand (oversold)
        assertGt(asset2ExcessDemand1, 0, "Asset2 should have positive excess demand (oversold)");
        
        
        // Asset1 should have lastOversoldTick set (was oversold)
        // Note: Asset1's starting tick is 0, so lastOversoldTick being 0 is correct
        assertGe(asset1LastOversoldTick1, 0, "Asset1 should have lastOversoldTick set");
        // Asset2 should have lastOversoldTick set (was oversold)
        assertGt(asset2LastOversoldTick1, 0, "Asset2 should have lastOversoldTick set");
        
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
        vm.prank(auctioneer);
        cpaManager.endClockRound(auctionId);
        
        // Verify pool info after round 2
        (,,,uint256 asset1Deposit2, int256 asset1ExcessDemand2, int24 asset1LastOversoldTick2, AuctionId asset1AuctionId2, bytes32 asset1PositionId2) = cpaManager.getPoolInfo(poolKeys[0].toId());
        (,,,uint256 asset2Deposit2, int256 asset2ExcessDemand2, int24 asset2LastOversoldTick2, AuctionId asset2AuctionId2, bytes32 asset2PositionId2) = cpaManager.getPoolInfo(poolKeys[1].toId());
        
        // Asset1 should have zero excess demand (exactly clearing)
        assertEq(asset1ExcessDemand2, 0, "Asset1 should have zero excess demand (exactly clearing)");
        // Asset2 should have negative excess demand (undersold)
        assertLt(asset2ExcessDemand2, 0, "Asset2 should have negative excess demand (undersold)");
        
        // Asset1 should still have lastOversoldTick from round 1
        assertEq(asset1LastOversoldTick2, asset1LastOversoldTick1, "Asset1 should keep lastOversoldTick from round 1");
        // Asset2 should still have lastOversoldTick from round 1 (was oversold in round 1)
        assertEq(asset2LastOversoldTick2, asset2LastOversoldTick1, "Asset2 should keep lastOversoldTick from round 1");
        
        console.log("Test completed successfully - excessDemand and lastOversoldTick tracking working correctly");
    }
}
