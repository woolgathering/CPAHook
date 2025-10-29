// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { IERC6909Claims } from "@uniswap/v4-core/src/interfaces/external/IERC6909Claims.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { PoolId } from "@uniswap/v4-core/src/types/PoolId.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { Hooks } from "@uniswap/v4-core/src/libraries/Hooks.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { IPositionManager } from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

import { CPAManager } from "../src/CPAManager.sol";
import { AuctionTypes } from "../src/types/AuctionTypes.sol";
import { AuctionId } from "../src/types/AuctionId.sol";
import { BundleId, BundleIdLibrary } from "../src/types/BundleId.sol";
import { IErrorsAndEvents } from "../src/utils/IErrorsAndEvents.sol";
import { CommitReveal } from "../src/utils/CommitReveal.sol";
import { CPATestBase } from "./base/CPATestBase.sol";

contract CPAPhaseTransitionTest is CPATestBase {
    using PoolIdLibrary for PoolKey;

    // Test participants
    address allocator1;

    // Commit-reveal data
    bytes32 saltA1;
    bytes32 saltB1;
    bytes32 saltA2;
    bytes32 saltB2;
    bytes32 commitHash1;
    bytes32 commitHash2;

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
        moveDeposit(auctionId, asset1PoolKey, 100 * 10**18);
        moveDeposit(auctionId, asset2PoolKey, 150 * 10**18);

        // Generate commit-reveal data
        saltA1 = keccak256("saltA1");
        saltB1 = keccak256("saltB1");
        saltA2 = keccak256("saltA2");
        saltB2 = keccak256("saltB2");
        commitHash1 = CommitReveal.generateCommitHash(bidder1, proxy1, saltA1, saltB1);
        commitHash2 = CommitReveal.generateCommitHash(bidder2, proxy2, saltA2, saltB2);
    }

    // ========================================
    // PHASE TRANSITION EVENT TESTS
    // ========================================

    function test_StartClockPhaseEmitsAuctionPhaseChanged() public {
        // Set up event expectation
        vm.expectEmit(true, true, true, true);
        emit IErrorsAndEvents.AuctionPhaseChanged(auctionId, AuctionTypes.AuctionPhase.Clock);

        // Start clock phase
        vm.prank(auctioneer);
        cpaManager.startClockPhase(auctionId);
    }

    function test_DepositAllAndStartClockEmitsAuctionPhaseChanged() public {
        // Set up event expectation
        vm.expectEmit(true, true, true, true);
        emit IErrorsAndEvents.AuctionPhaseChanged(auctionId, AuctionTypes.AuctionPhase.Clock);

        // Deposit all and start clock
        PoolKey[] memory poolKeys = new PoolKey[](2);
        poolKeys[0] = asset1PoolKey;
        poolKeys[1] = asset2PoolKey;
        
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 50 * 10**18;
        amounts[1] = 75 * 10**18;

        vm.prank(auctioneer);
        cpaManager.depositAllAndStartClock(auctionId, poolKeys, amounts);
    }

    function test_EndClockPhaseEmitsAuctionPhaseChanged() public {
        // Set up clock phase but don't end it yet
        setupClockPhaseWithoutEnding();

        // Set up event expectation for Clock -> Proxy transition
        vm.expectEmit(true, true, true, true);
        emit IErrorsAndEvents.AuctionPhaseChanged(auctionId, AuctionTypes.AuctionPhase.Proxy);

        // End clock phase
        vm.prank(auctioneer);
        cpaManager.endClockPhase(auctionId);
    }

    function test_TransitionToAllocationEmitsAuctionPhaseChanged() public {
        // Set up complete flow to Proxy phase but don't transition yet
        setupClockPhase();
        setupProxyPhaseWithoutTransition();

        // Set up event expectation for Proxy -> Allocation transition
        vm.expectEmit(true, true, true, true);
        emit IErrorsAndEvents.AuctionPhaseChanged(auctionId, AuctionTypes.AuctionPhase.Allocation);

        // Transition to allocation phase
        cpaManager.transitionToAllocation(auctionId);
    }

    function test_TransitionToSettlementEmitsAuctionPhaseChanged() public {
        // Set up complete flow to Allocation phase but don't transition yet
        setupClockPhase();
        setupProxyPhase();
        setupAllocationPhaseWithoutTransition();

        // Set up event expectation for Allocation -> Settlement transition
        vm.expectEmit(true, true, true, true);
        emit IErrorsAndEvents.AuctionPhaseChanged(auctionId, AuctionTypes.AuctionPhase.Settlement);

        // Transition to settlement phase
        cpaManager.transitionToSettlement(auctionId);
    }

    function test_TransitionToFinishedEmitsAuctionPhaseChanged() public {
        // Set up complete flow to Settlement phase but don't transition yet
        setupClockPhase();
        setupProxyPhase();
        setupAllocationPhase();
        setupSettlementPhaseWithoutTransition();

        // Set up event expectation for Settlement -> Finished transition
        vm.expectEmit(true, true, true, true);
        emit IErrorsAndEvents.AuctionPhaseChanged(auctionId, AuctionTypes.AuctionPhase.Finished);

        // Transition to finished phase
        cpaManager.transitionToFinished(auctionId);
    }

    // ========================================
    // HELPER FUNCTIONS
    // ========================================

    function setupClockPhase() internal {
        // Create bidders with sufficient funds
        createBidder(bidder1, 1000000 * 10**18);
        createBidder(bidder2, 1000000 * 10**18);

        // Approve tokens for bidders
        approveNumeraireForBidder(bidder1, type(uint256).max);
        approveNumeraireForBidder(bidder2, type(uint256).max);

        // Proxy commits
        vm.prank(proxy1);
        cpaManager.commitToBidder(auctionId, commitHash1);
        vm.prank(proxy2);
        cpaManager.commitToBidder(auctionId, commitHash2);

        // Start clock round
        vm.prank(auctioneer);
        cpaManager.startClockPhase(auctionId);

        // Submit bids for round 1
        uint256[] memory demands1 = new uint256[](2);
        demands1[0] = 50 * 10**18;
        demands1[1] = 60 * 10**18;
        
        uint256[] memory demands2 = new uint256[](2);
        demands2[0] = 40 * 10**18;
        demands2[1] = 50 * 10**18;

        vm.prank(bidder1);
        cpaManager.submitBid(auctionId, demands1, 1000 * 10**18);
        
        vm.prank(bidder2);
        cpaManager.submitBid(auctionId, demands2, 1000 * 10**18);

        // End clock phase
        vm.prank(auctioneer);
        cpaManager.endClockPhase(auctionId);
    }

    function setupClockPhaseWithoutEnding() internal {
        // Create bidders with sufficient funds
        createBidder(bidder1, 1000000 * 10**18);
        createBidder(bidder2, 1000000 * 10**18);

        // Approve tokens for bidders
        approveNumeraireForBidder(bidder1, type(uint256).max);
        approveNumeraireForBidder(bidder2, type(uint256).max);

        // Proxy commits
        vm.prank(proxy1);
        cpaManager.commitToBidder(auctionId, commitHash1);
        vm.prank(proxy2);
        cpaManager.commitToBidder(auctionId, commitHash2);

        // Start clock round
        vm.prank(auctioneer);
        cpaManager.startClockPhase(auctionId);

        // Submit bids for round 1
        uint256[] memory demands1 = new uint256[](2);
        demands1[0] = 50 * 10**18;
        demands1[1] = 60 * 10**18;
        
        uint256[] memory demands2 = new uint256[](2);
        demands2[0] = 40 * 10**18;
        demands2[1] = 50 * 10**18;

        vm.prank(bidder1);
        cpaManager.submitBid(auctionId, demands1, 1000 * 10**18);
        
        vm.prank(bidder2);
        cpaManager.submitBid(auctionId, demands2, 1000 * 10**18);

        // Don't end clock phase - let the test do it
    }

    function setupProxyPhase() internal {
        // Submit bundles
        uint256[] memory quantities1 = new uint256[](2);
        quantities1[0] = 30 * 10**18;
        quantities1[1] = 20 * 10**18;
        
        uint256[] memory quantities2 = new uint256[](2);
        quantities2[0] = 25 * 10**18;
        quantities2[1] = 15 * 10**18;

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

        // Generate and save bundle IDs
        bundleId1 = BundleIdLibrary.createId(commitHash1, keccak256(abi.encode(quantities1)));
        bundleId2 = BundleIdLibrary.createId(commitHash2, keccak256(abi.encode(quantities2)));

        vm.prank(proxy1);
        cpaManager.submitBundle(auctionId, commitHash1, bundle1);
        
        vm.prank(proxy2);
        cpaManager.submitBundle(auctionId, commitHash2, bundle2);

        // Warp time to end proxy phase
        AuctionTypes.AuctionInfo memory auction = cpaManager.getAuctionInfo(auctionId);
        uint256[] memory phaseDurations = auction.config.phaseDurations;
        vm.warp(block.timestamp + phaseDurations[0]);

        // Transition to allocation phase (permissionless)
        cpaManager.transitionToAllocation(auctionId);
    }

    function setupProxyPhaseWithoutTransition() internal {
        // Submit bundles
        uint256[] memory quantities1 = new uint256[](2);
        quantities1[0] = 30 * 10**18;
        quantities1[1] = 20 * 10**18;
        
        uint256[] memory quantities2 = new uint256[](2);
        quantities2[0] = 25 * 10**18;
        quantities2[1] = 15 * 10**18;

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

        // Generate and save bundle IDs
        bundleId1 = BundleIdLibrary.createId(commitHash1, keccak256(abi.encode(quantities1)));
        bundleId2 = BundleIdLibrary.createId(commitHash2, keccak256(abi.encode(quantities2)));

        vm.prank(proxy1);
        cpaManager.submitBundle(auctionId, commitHash1, bundle1);
        
        vm.prank(proxy2);
        cpaManager.submitBundle(auctionId, commitHash2, bundle2);

        // Warp time to end proxy phase
        AuctionTypes.AuctionInfo memory auction = cpaManager.getAuctionInfo(auctionId);
        uint256[] memory phaseDurations = auction.config.phaseDurations;
        vm.warp(block.timestamp + phaseDurations[0]);

        // Don't transition to allocation phase - let the test do it
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
            totalValue: 2000 * 10**18,
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
        cpaManager.transitionToSettlement(auctionId);
    }

    function setupAllocationPhaseWithoutTransition() internal {
        // Create allocation
        BundleId[] memory selectedBundles = new BundleId[](2);
        selectedBundles[0] = bundleId1;
        selectedBundles[1] = bundleId2;

        AuctionTypes.Allocation memory allocation = AuctionTypes.Allocation({
            auctionId: auctionId,
            allocator: allocator1,
            bundleIds: selectedBundles,
            totalValue: 2000 * 10**18,
            timestamp: block.timestamp
        });

        // Submit allocation
        vm.prank(allocator1);
        cpaManager.submitAllocation(auctionId, allocation);

        // Warp time to end allocation phase
        AuctionTypes.AuctionInfo memory auction = cpaManager.getAuctionInfo(auctionId);
        uint256[] memory phaseDurations = auction.config.phaseDurations;
        vm.warp(block.timestamp + phaseDurations[1]);

        // Don't transition to settlement phase - let the test do it
    }

    function setupSettlementPhase() internal {
        // Reveal identities
        vm.prank(bidder1);
        cpaManager.reveal(auctionId, proxy1, saltA1, saltB1);
        
        vm.prank(bidder2);
        cpaManager.reveal(auctionId, proxy2, saltA2, saltB2);

        // Claim tokens
        vm.prank(bidder1);
        cpaManager.claimAllTokens(auctionId, commitHash1);
        
        vm.prank(bidder2);
        cpaManager.claimAllTokens(auctionId, commitHash2);

        // Warp time to end settlement phase
        AuctionTypes.AuctionInfo memory auction = cpaManager.getAuctionInfo(auctionId);
        uint256[] memory phaseDurations = auction.config.phaseDurations;
        vm.warp(block.timestamp + phaseDurations[2]);

        // Transition to finished phase (permissionless)
        cpaManager.transitionToFinished(auctionId);
    }

    function setupSettlementPhaseWithoutTransition() internal {
        // Reveal identities
        vm.prank(bidder1);
        cpaManager.reveal(auctionId, proxy1, saltA1, saltB1);
        
        vm.prank(bidder2);
        cpaManager.reveal(auctionId, proxy2, saltA2, saltB2);

        // Claim tokens
        vm.prank(bidder1);
        cpaManager.claimAllTokens(auctionId, commitHash1);
        
        vm.prank(bidder2);
        cpaManager.claimAllTokens(auctionId, commitHash2);

        // Warp time to end settlement phase
        AuctionTypes.AuctionInfo memory auction = cpaManager.getAuctionInfo(auctionId);
        uint256[] memory phaseDurations = auction.config.phaseDurations;
        vm.warp(block.timestamp + phaseDurations[2]);

        // Don't transition to finished phase - let the test do it
    }
}
