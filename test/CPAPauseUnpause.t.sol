// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { CPATestBase } from "./base/CPATestBase.sol";
import { AuctionTypes } from "../src/types/AuctionTypes.sol";
import { IErrorsAndEvents } from "../src/utils/IErrorsAndEvents.sol";
import { CommitReveal } from "../src/utils/CommitReveal.sol";
import { BundleId, BundleIdLibrary } from "../src/types/BundleId.sol";

contract CPAPauseUnpauseTest is CPATestBase {
    address allocator1;

    function setUp() public override {
        super.setUp();
        allocator1 = makeAddr("allocator1");
    }

    // ========================================
    // PAUSE/UNPAUSE LIFECYCLE TESTS
    // ========================================

    function test_PauseUnpauseMultipleCycles() public {
        // Setup: Create auction, move to Clock phase
        AuctionTypes.AuctionConfig memory config = createStandardAuctionConfig();
        auctionId = createAuction(config, auctioneer);

        mintTokensToAuctioneer(1000000 * 10**18);
        approveTokens(address(asset1Token), address(cpaManager), 1000 * 10**18);
        approveTokens(address(asset2Token), address(cpaManager), 1000 * 10**18);
        moveDeposit(auctionId, asset1PoolKey, 100 * 10**18);
        moveDeposit(auctionId, asset2PoolKey, 150 * 10**18);

        vm.prank(auctioneer);
        cpaManager.startClockPhase(auctionId);

        // Verify initial totalPauseDuration = 0
        AuctionTypes.AuctionInfo memory auction = cpaManager.getAuctionInfo(auctionId);
        assertEq(auction.totalPauseDuration, 0, "Initial totalPauseDuration should be 0");

        // Cycle 1: Pause for 100 seconds
        vm.prank(auctioneer);
        cpaManager.pause(auctionId);
        vm.warp(block.timestamp + 100);

        vm.prank(auctioneer);
        cpaManager.unpause(auctionId);
        auction = cpaManager.getAuctionInfo(auctionId);
        assertEq(auction.totalPauseDuration, 100, "totalPauseDuration should be 100 after first cycle");
        assertEq(uint8(auction.currentStatus), uint8(AuctionTypes.AuctionStatus.Active), "Status should be Active");

        // Cycle 2: Pause for 150 more seconds
        vm.prank(auctioneer);
        cpaManager.pause(auctionId);
        vm.warp(block.timestamp + 150);

        vm.prank(auctioneer);
        cpaManager.unpause(auctionId);
        auction = cpaManager.getAuctionInfo(auctionId);
        assertEq(auction.totalPauseDuration, 250, "totalPauseDuration should be 250 after second cycle");

        // Cycle 3: Pause for 50 more seconds
        vm.prank(auctioneer);
        cpaManager.pause(auctionId);
        vm.warp(block.timestamp + 50);

        vm.prank(auctioneer);
        cpaManager.unpause(auctionId);
        auction = cpaManager.getAuctionInfo(auctionId);
        assertEq(auction.totalPauseDuration, 300, "totalPauseDuration should be 300 after third cycle");

        // Verify phase persisted
        assertEq(uint8(auction.currentPhase), uint8(AuctionTypes.AuctionPhase.Clock), "Phase should remain Clock");
        assertEq(uint8(auction.currentStatus), uint8(AuctionTypes.AuctionStatus.Active), "Status should be Active");
    }

    function test_PauseInAllowedPhases() public {
        AuctionTypes.AuctionConfig memory config = createStandardAuctionConfig();
        auctionId = createAuction(config, auctioneer);
        mintTokensToAuctioneer(1000000 * 10**18);
        approveTokens(address(asset1Token), address(cpaManager), 1000 * 10**18);
        approveTokens(address(asset2Token), address(cpaManager), 1000 * 10**18);

        // Test Setup phase
        vm.expectEmit(true, true, true, true);
        emit IErrorsAndEvents.AuctionPaused(auctionId, auctioneer);
        vm.prank(auctioneer);
        cpaManager.pause(auctionId);
        AuctionTypes.AuctionInfo memory auction = cpaManager.getAuctionInfo(auctionId);
        assertEq(uint8(auction.currentStatus), uint8(AuctionTypes.AuctionStatus.Paused), "Should be paused");
        
        vm.prank(auctioneer);
        cpaManager.unpause(auctionId);
        auction = cpaManager.getAuctionInfo(auctionId);
        assertEq(uint8(auction.currentStatus), uint8(AuctionTypes.AuctionStatus.Active), "Should be active");

        // Test Clock phase
        moveDeposit(auctionId, asset1PoolKey, 100 * 10**18);
        moveDeposit(auctionId, asset2PoolKey, 150 * 10**18);
        vm.prank(auctioneer);
        cpaManager.startClockPhase(auctionId);

        vm.prank(auctioneer);
        cpaManager.pause(auctionId);
        auction = cpaManager.getAuctionInfo(auctionId);
        assertEq(uint8(auction.currentStatus), uint8(AuctionTypes.AuctionStatus.Paused), "Should be paused");

        // Verify bids blocked
        createBidder(bidder1, 100000 * 10**18);
        approveNumeraireForBidder(bidder1, type(uint256).max);
        uint256[] memory demands = new uint256[](2);
        demands[0] = 10 * 10**18;
        demands[1] = 20 * 10**18;
        vm.prank(bidder1);
        vm.expectRevert(abi.encodeWithSelector(IErrorsAndEvents.AuctionNotActive.selector, auctionId, AuctionTypes.AuctionStatus.Paused));
        cpaManager.submitBid(auctionId, demands, type(uint256).max);

        vm.prank(auctioneer);
        cpaManager.unpause(auctionId);

        // Test Proxy phase
        vm.prank(auctioneer);
        cpaManager.endClockPhase(auctionId);

        vm.prank(auctioneer);
        cpaManager.pause(auctionId);
        auction = cpaManager.getAuctionInfo(auctionId);
        assertEq(uint8(auction.currentStatus), uint8(AuctionTypes.AuctionStatus.Paused), "Should be paused");

        // Verify bundles blocked
        bytes32 saltA = keccak256("saltA");
        bytes32 saltB = keccak256("saltB");
        bytes32 commitHash = CommitReveal.generateCommitHash(bidder1, proxy1, saltA, saltB);
        vm.prank(proxy1);
        cpaManager.commitToBidder(auctionId, commitHash);
        uint256[] memory quantities = new uint256[](2);
        quantities[0] = 5 * 10**18;
        quantities[1] = 10 * 10**18;
        AuctionTypes.Bundle memory bundle = AuctionTypes.Bundle({
            auctionId: auctionId,
            commitHash: commitHash,
            value: 1000 * 10**18,
            quantities: quantities,
            timestamp: block.timestamp
        });
        vm.prank(proxy1);
        vm.expectRevert(abi.encodeWithSelector(IErrorsAndEvents.AuctionNotActive.selector, auctionId, AuctionTypes.AuctionStatus.Paused));
        cpaManager.submitBundle(auctionId, commitHash, bundle);

        vm.prank(auctioneer);
        cpaManager.unpause(auctionId);

        // Test Allocation phase
        vm.prank(proxy1);
        cpaManager.submitBundle(auctionId, commitHash, bundle);
        AuctionTypes.AuctionInfo memory auctionInfo = cpaManager.getAuctionInfo(auctionId);
        vm.warp(block.timestamp + auctionInfo.config.phaseDurations[0]);
        cpaManager.transitionToAllocation(auctionId);

        vm.prank(auctioneer);
        cpaManager.pause(auctionId);
        auction = cpaManager.getAuctionInfo(auctionId);
        assertEq(uint8(auction.currentStatus), uint8(AuctionTypes.AuctionStatus.Paused), "Should be paused");

        // Verify allocations blocked
        BundleId bundleId = BundleIdLibrary.createId(commitHash, keccak256(abi.encode(quantities)));
        BundleId[] memory bundleIds = new BundleId[](1);
        bundleIds[0] = bundleId;
        AuctionTypes.Allocation memory allocation = AuctionTypes.Allocation({
            auctionId: auctionId,
            allocator: allocator1,
            bundleIds: bundleIds,
            totalValue: 1000 * 10**18,
            timestamp: block.timestamp
        });
        vm.prank(allocator1);
        vm.expectRevert(abi.encodeWithSelector(IErrorsAndEvents.AuctionNotActive.selector, auctionId, AuctionTypes.AuctionStatus.Paused));
        cpaManager.submitAllocation(auctionId, allocation);
    }

    function test_PauseRevertsInSettlementFinished() public {
        // Setup complete auction flow to Settlement
        AuctionTypes.AuctionConfig memory config = createStandardAuctionConfig();
        auctionId = createAuction(config, auctioneer);
        mintTokensToAuctioneer(1000000 * 10**18);
        approveTokens(address(asset1Token), address(cpaManager), 1000 * 10**18);
        approveTokens(address(asset2Token), address(cpaManager), 1000 * 10**18);
        moveDeposit(auctionId, asset1PoolKey, 100 * 10**18);
        moveDeposit(auctionId, asset2PoolKey, 150 * 10**18);

        // Move through phases to Settlement
        vm.prank(auctioneer);
        cpaManager.startClockPhase(auctionId);
        vm.prank(auctioneer);
        cpaManager.endClockPhase(auctionId);

        bytes32 saltA = keccak256("saltA");
        bytes32 saltB = keccak256("saltB");
        bytes32 commitHash = CommitReveal.generateCommitHash(bidder1, proxy1, saltA, saltB);
        vm.prank(proxy1);
        cpaManager.commitToBidder(auctionId, commitHash);
        uint256[] memory quantities = new uint256[](2);
        quantities[0] = 5 * 10**18;
        quantities[1] = 10 * 10**18;
        AuctionTypes.Bundle memory bundle = AuctionTypes.Bundle({
            auctionId: auctionId,
            commitHash: commitHash,
            value: 1000 * 10**18,
            quantities: quantities,
            timestamp: block.timestamp
        });
        vm.prank(proxy1);
        cpaManager.submitBundle(auctionId, commitHash, bundle);

        AuctionTypes.AuctionInfo memory auctionInfo = cpaManager.getAuctionInfo(auctionId);
        vm.warp(block.timestamp + auctionInfo.config.phaseDurations[0]);
        cpaManager.transitionToAllocation(auctionId);

        BundleId bundleId = BundleIdLibrary.createId(commitHash, keccak256(abi.encode(quantities)));
        BundleId[] memory bundleIds = new BundleId[](1);
        bundleIds[0] = bundleId;
        AuctionTypes.Allocation memory allocation = AuctionTypes.Allocation({
            auctionId: auctionId,
            allocator: allocator1,
            bundleIds: bundleIds,
            totalValue: 1000 * 10**18,
            timestamp: block.timestamp
        });
        vm.prank(allocator1);
        cpaManager.submitAllocation(auctionId, allocation);

        vm.warp(block.timestamp + auctionInfo.config.phaseDurations[1]);
        cpaManager.transitionToSettlement(auctionId);

        // Test pause in Settlement phase
        auctionInfo = cpaManager.getAuctionInfo(auctionId);
        assertEq(uint8(auctionInfo.currentPhase), uint8(AuctionTypes.AuctionPhase.Settlement), "Should be in Settlement");
        vm.prank(auctioneer);
        vm.expectRevert(abi.encodeWithSelector(IErrorsAndEvents.InvalidPhase.selector, AuctionTypes.AuctionPhase.Setup, AuctionTypes.AuctionPhase.Settlement));
        cpaManager.pause(auctionId);
        
        // Verify auction remains Active
        auctionInfo = cpaManager.getAuctionInfo(auctionId);
        assertEq(uint8(auctionInfo.currentStatus), uint8(AuctionTypes.AuctionStatus.Active), "Status should remain Active");

        // Transition to Finished
        vm.warp(block.timestamp + auctionInfo.config.phaseDurations[2]);
        cpaManager.transitionToFinished(auctionId);

        // Test pause in Finished phase
        auctionInfo = cpaManager.getAuctionInfo(auctionId);
        assertEq(uint8(auctionInfo.currentPhase), uint8(AuctionTypes.AuctionPhase.Finished), "Should be in Finished");
        vm.prank(auctioneer);
        vm.expectRevert(abi.encodeWithSelector(IErrorsAndEvents.InvalidPhase.selector, AuctionTypes.AuctionPhase.Setup, AuctionTypes.AuctionPhase.Finished));
        cpaManager.pause(auctionId);

        // Verify no events emitted and status unchanged
        auctionInfo = cpaManager.getAuctionInfo(auctionId);
        assertEq(uint8(auctionInfo.currentStatus), uint8(AuctionTypes.AuctionStatus.Active), "Status should remain Active");
    }

    function test_OperationsBlockedDuringPause() public {
        AuctionTypes.AuctionConfig memory config = createStandardAuctionConfig();
        auctionId = createAuction(config, auctioneer);
        mintTokensToAuctioneer(1000000 * 10**18);
        approveTokens(address(asset1Token), address(cpaManager), 1000 * 10**18);
        approveTokens(address(asset2Token), address(cpaManager), 1000 * 10**18);
        moveDeposit(auctionId, asset1PoolKey, 100 * 10**18);
        moveDeposit(auctionId, asset2PoolKey, 150 * 10**18);
        vm.prank(auctioneer);
        cpaManager.startClockPhase(auctionId);

        // Pause auction
        vm.prank(auctioneer);
        cpaManager.pause(auctionId);

        // Test submitBid blocked
        createBidder(bidder1, 100000 * 10**18);
        approveNumeraireForBidder(bidder1, type(uint256).max);
        uint256[] memory demands = new uint256[](2);
        demands[0] = 10 * 10**18;
        demands[1] = 20 * 10**18;
        vm.prank(bidder1);
        vm.expectRevert(abi.encodeWithSelector(IErrorsAndEvents.AuctionNotActive.selector, auctionId, AuctionTypes.AuctionStatus.Paused));
        cpaManager.submitBid(auctionId, demands, type(uint256).max);

        // Test dropout blocked
        vm.prank(bidder1);
        vm.expectRevert(abi.encodeWithSelector(IErrorsAndEvents.AuctionNotActive.selector, auctionId, AuctionTypes.AuctionStatus.Paused));
        cpaManager.dropout(auctionId);

        // Move to Proxy phase and test bundle submission blocked
        vm.prank(auctioneer);
        cpaManager.unpause(auctionId);
        vm.prank(auctioneer);
        cpaManager.endClockPhase(auctionId);
        vm.prank(auctioneer);
        cpaManager.pause(auctionId);

        bytes32 saltA = keccak256("saltA");
        bytes32 saltB = keccak256("saltB");
        bytes32 commitHash = CommitReveal.generateCommitHash(bidder1, proxy1, saltA, saltB);
        vm.prank(proxy1);
        cpaManager.commitToBidder(auctionId, commitHash);
        uint256[] memory quantities = new uint256[](2);
        quantities[0] = 5 * 10**18;
        quantities[1] = 10 * 10**18;
        AuctionTypes.Bundle memory bundle = AuctionTypes.Bundle({
            auctionId: auctionId,
            commitHash: commitHash,
            value: 1000 * 10**18,
            quantities: quantities,
            timestamp: block.timestamp
        });
        vm.prank(proxy1);
        vm.expectRevert(abi.encodeWithSelector(IErrorsAndEvents.AuctionNotActive.selector, auctionId, AuctionTypes.AuctionStatus.Paused));
        cpaManager.submitBundle(auctionId, commitHash, bundle);

        // Move to Allocation phase and test allocation blocked
        vm.prank(auctioneer);
        cpaManager.unpause(auctionId);
        vm.prank(proxy1);
        cpaManager.submitBundle(auctionId, commitHash, bundle);
        AuctionTypes.AuctionInfo memory auctionInfo = cpaManager.getAuctionInfo(auctionId);
        vm.warp(block.timestamp + auctionInfo.config.phaseDurations[0]);
        cpaManager.transitionToAllocation(auctionId);
        vm.prank(auctioneer);
        cpaManager.pause(auctionId);

        BundleId bundleId = BundleIdLibrary.createId(commitHash, keccak256(abi.encode(quantities)));
        BundleId[] memory bundleIds = new BundleId[](1);
        bundleIds[0] = bundleId;
        AuctionTypes.Allocation memory allocation = AuctionTypes.Allocation({
            auctionId: auctionId,
            allocator: allocator1,
            bundleIds: bundleIds,
            totalValue: 1000 * 10**18,
            timestamp: block.timestamp
        });
        vm.prank(allocator1);
        vm.expectRevert(abi.encodeWithSelector(IErrorsAndEvents.AuctionNotActive.selector, auctionId, AuctionTypes.AuctionStatus.Paused));
        cpaManager.submitAllocation(auctionId, allocation);

        // Test reveal blocked
        vm.prank(auctioneer);
        cpaManager.unpause(auctionId);
        vm.prank(allocator1);
        cpaManager.submitAllocation(auctionId, allocation);
        vm.warp(block.timestamp + auctionInfo.config.phaseDurations[1]);
        cpaManager.transitionToSettlement(auctionId);
        vm.prank(auctioneer);
        cpaManager.pause(auctionId);

        vm.prank(bidder1);
        vm.expectRevert(abi.encodeWithSelector(IErrorsAndEvents.AuctionNotActive.selector, auctionId, AuctionTypes.AuctionStatus.Paused));
        cpaManager.reveal(auctionId, proxy1, saltA, saltB);
    }

    function test_PhaseTransitionsBlockedDuringPause() public {
        AuctionTypes.AuctionConfig memory config = createStandardAuctionConfig();
        auctionId = createAuction(config, auctioneer);
        mintTokensToAuctioneer(1000000 * 10**18);
        approveTokens(address(asset1Token), address(cpaManager), 1000 * 10**18);
        approveTokens(address(asset2Token), address(cpaManager), 1000 * 10**18);
        moveDeposit(auctionId, asset1PoolKey, 100 * 10**18);
        moveDeposit(auctionId, asset2PoolKey, 150 * 10**18);
        vm.prank(auctioneer);
        cpaManager.startClockPhase(auctionId);
        vm.prank(auctioneer);
        cpaManager.endClockPhase(auctionId);

        // Setup Proxy phase with bundle
        bytes32 saltA = keccak256("saltA");
        bytes32 saltB = keccak256("saltB");
        bytes32 commitHash = CommitReveal.generateCommitHash(bidder1, proxy1, saltA, saltB);
        vm.prank(proxy1);
        cpaManager.commitToBidder(auctionId, commitHash);
        uint256[] memory quantities = new uint256[](2);
        quantities[0] = 5 * 10**18;
        quantities[1] = 10 * 10**18;
        AuctionTypes.Bundle memory bundle = AuctionTypes.Bundle({
            auctionId: auctionId,
            commitHash: commitHash,
            value: 1000 * 10**18,
            quantities: quantities,
            timestamp: block.timestamp
        });
        vm.prank(proxy1);
        cpaManager.submitBundle(auctionId, commitHash, bundle);

        // Pause and test transition blocked
        vm.prank(auctioneer);
        cpaManager.pause(auctionId);

        AuctionTypes.AuctionInfo memory auctionInfo = cpaManager.getAuctionInfo(auctionId);
        vm.warp(block.timestamp + auctionInfo.config.phaseDurations[0]);
        vm.expectRevert(abi.encodeWithSelector(IErrorsAndEvents.AuctionNotActive.selector, auctionId, AuctionTypes.AuctionStatus.Paused));
        cpaManager.transitionToAllocation(auctionId);

        // Verify phase unchanged
        auctionInfo = cpaManager.getAuctionInfo(auctionId);
        assertEq(uint8(auctionInfo.currentPhase), uint8(AuctionTypes.AuctionPhase.Proxy), "Phase should remain Proxy");

        // Test Allocation -> Settlement transition blocked
        vm.prank(auctioneer);
        cpaManager.unpause(auctionId);
        cpaManager.transitionToAllocation(auctionId);

        BundleId bundleId = BundleIdLibrary.createId(commitHash, keccak256(abi.encode(quantities)));
        BundleId[] memory bundleIds = new BundleId[](1);
        bundleIds[0] = bundleId;
        AuctionTypes.Allocation memory allocation = AuctionTypes.Allocation({
            auctionId: auctionId,
            allocator: allocator1,
            bundleIds: bundleIds,
            totalValue: 1000 * 10**18,
            timestamp: block.timestamp
        });
        vm.prank(allocator1);
        cpaManager.submitAllocation(auctionId, allocation);

        vm.prank(auctioneer);
        cpaManager.pause(auctionId);

        auctionInfo = cpaManager.getAuctionInfo(auctionId);
        vm.warp(block.timestamp + auctionInfo.config.phaseDurations[1]);
        vm.expectRevert(abi.encodeWithSelector(IErrorsAndEvents.AuctionNotActive.selector, auctionId, AuctionTypes.AuctionStatus.Paused));
        cpaManager.transitionToSettlement(auctionId);

        // Test Settlement -> Finished transition blocked
        vm.prank(auctioneer);
        cpaManager.unpause(auctionId);
        cpaManager.transitionToSettlement(auctionId);
        vm.prank(auctioneer);
        cpaManager.pause(auctionId);

        auctionInfo = cpaManager.getAuctionInfo(auctionId);
        vm.warp(block.timestamp + auctionInfo.config.phaseDurations[2]);
        vm.expectRevert(abi.encodeWithSelector(IErrorsAndEvents.AuctionNotActive.selector, auctionId, AuctionTypes.AuctionStatus.Paused));
        cpaManager.transitionToFinished(auctionId);

        // Verify phase unchanged
        auctionInfo = cpaManager.getAuctionInfo(auctionId);
        assertEq(uint8(auctionInfo.currentPhase), uint8(AuctionTypes.AuctionPhase.Settlement), "Phase should remain Settlement");
    }

    function test_MaxPauseDurationAccumulation() public {
        AuctionTypes.AuctionConfig memory config = createStandardAuctionConfig();
        auctionId = createAuction(config, auctioneer);
        mintTokensToAuctioneer(1000000 * 10**18);
        approveTokens(address(asset1Token), address(cpaManager), 1000 * 10**18);
        approveTokens(address(asset2Token), address(cpaManager), 1000 * 10**18);
        moveDeposit(auctionId, asset1PoolKey, 100 * 10**18);
        moveDeposit(auctionId, asset2PoolKey, 150 * 10**18);
        vm.prank(auctioneer);
        cpaManager.startClockPhase(auctionId);

        // Accumulate pause time to just under 72h
        uint256 maxPauseDuration = 72 * 60 * 60; // 259200 seconds
        uint256 targetDuration = maxPauseDuration - 1; // 259199 seconds

        // Accumulate pause time through multiple cycles
        uint256 accumulated = 0;
        while (accumulated < targetDuration) {
            uint256 pauseTime = (targetDuration - accumulated) > 1000 ? 1000 : (targetDuration - accumulated);
            vm.prank(auctioneer);
            cpaManager.pause(auctionId);
            vm.warp(block.timestamp + pauseTime);
            vm.prank(auctioneer);
            cpaManager.unpause(auctionId);
            accumulated += pauseTime;
        }

        AuctionTypes.AuctionInfo memory auction = cpaManager.getAuctionInfo(auctionId);
        assertEq(auction.totalPauseDuration, targetDuration, "Should have accumulated exactly 259199 seconds");

        // Pause again - should succeed
        vm.prank(auctioneer);
        cpaManager.pause(auctionId);

        // Try to unpause after >1 second - should revert
        vm.warp(block.timestamp + 2);
        vm.prank(auctioneer);
        vm.expectRevert(abi.encodeWithSelector(IErrorsAndEvents.MaxPauseDurationExceeded.selector, maxPauseDuration, maxPauseDuration));
        cpaManager.unpause(auctionId);

        // Verify exact boundary: pause at 259199, warp +1s, verify revert
        vm.prank(auctioneer);
        cpaManager.unpause(auctionId); // Unpause manually (time already warped)
        auction = cpaManager.getAuctionInfo(auctionId);
        assertEq(auction.totalPauseDuration, targetDuration, "Should still be at 259199");

        // Final pause, warp +1, attempt unpause
        vm.prank(auctioneer);
        cpaManager.pause(auctionId);
        vm.warp(block.timestamp + 1);
        vm.prank(auctioneer);
        vm.expectRevert(abi.encodeWithSelector(IErrorsAndEvents.MaxPauseDurationExceeded.selector, maxPauseDuration + 1, maxPauseDuration));
        cpaManager.unpause(auctionId);
    }

    function test_ForceCancelAfterMaxPauseDuration() public {
        AuctionTypes.AuctionConfig memory config = createStandardAuctionConfig();
        auctionId = createAuction(config, auctioneer);
        mintTokensToAuctioneer(1000000 * 10**18);
        approveTokens(address(asset1Token), address(cpaManager), 1000 * 10**18);
        approveTokens(address(asset2Token), address(cpaManager), 1000 * 10**18);
        moveDeposit(auctionId, asset1PoolKey, 100 * 10**18);
        moveDeposit(auctionId, asset2PoolKey, 150 * 10**18);
        vm.prank(auctioneer);
        cpaManager.startClockPhase(auctionId);

        // Accumulate 72h pause time
        uint256 maxPauseDuration = 72 * 60 * 60;
        uint256 accumulated = 0;
        while (accumulated < maxPauseDuration) {
            uint256 pauseTime = (maxPauseDuration - accumulated) > 10000 ? 10000 : (maxPauseDuration - accumulated);
            vm.prank(auctioneer);
            cpaManager.pause(auctionId);
            vm.warp(block.timestamp + pauseTime);
            vm.prank(auctioneer);
            cpaManager.unpause(auctionId);
            accumulated += pauseTime;
        }

        // Final pause
        vm.prank(auctioneer);
        cpaManager.pause(auctionId);
        vm.warp(block.timestamp + 1); // Push total over 72h

        // Call forceCancelTion as non-owner
        address randomUser = makeAddr("randomUser");
        vm.prank(randomUser);
        cpaManager.forceCancelAuction(auctionId);

        AuctionTypes.AuctionInfo memory auction = cpaManager.getAuctionInfo(auctionId);
        assertEq(uint8(auction.currentStatus), uint8(AuctionTypes.AuctionStatus.Cancelled), "Status should be Cancelled");
    }

    function test_ForceCancelAfterMaxPause_ProperCancellationState() public {
        AuctionTypes.AuctionConfig memory config = createStandardAuctionConfig();
        auctionId = createAuction(config, auctioneer);
        mintTokensToAuctioneer(1000000 * 10**18);
        approveTokens(address(asset1Token), address(cpaManager), 1000 * 10**18);
        approveTokens(address(asset2Token), address(cpaManager), 1000 * 10**18);
        moveDeposit(auctionId, asset1PoolKey, 100 * 10**18);
        moveDeposit(auctionId, asset2PoolKey, 150 * 10**18);
        vm.prank(auctioneer);
        cpaManager.startClockPhase(auctionId);

        // Create bidders with stakes
        createBidder(bidder1, 100000 * 10**18);
        createBidder(bidder2, 100000 * 10**18);
        createBidder(bidder3, 100000 * 10**18);
        approveNumeraireForBidder(bidder1, type(uint256).max);
        approveNumeraireForBidder(bidder2, type(uint256).max);
        approveNumeraireForBidder(bidder3, type(uint256).max);

        // Submit bids
        uint256[] memory demands1 = new uint256[](2);
        demands1[0] = 10 * 10**18;
        demands1[1] = 20 * 10**18;
        uint256[] memory demands2 = new uint256[](2);
        demands2[0] = 15 * 10**18;
        demands2[1] = 25 * 10**18;
        uint256[] memory demands3 = new uint256[](2);
        demands3[0] = 12 * 10**18;
        demands3[1] = 18 * 10**18;

        vm.prank(bidder1);
        cpaManager.submitBid(auctionId, demands1, type(uint256).max);
        vm.prank(bidder2);
        cpaManager.submitBid(auctionId, demands2, type(uint256).max);
        vm.prank(bidder3);
        cpaManager.submitBid(auctionId, demands3, type(uint256).max);

        uint256 stake1 = cpaManager.bidderStake(auctionId, bidder1);
        uint256 stake2 = cpaManager.bidderStake(auctionId, bidder2);
        uint256 stake3 = cpaManager.bidderStake(auctionId, bidder3);
        assertTrue(stake1 > 0, "Bidder1 should have stake");
        assertTrue(stake2 > 0, "Bidder2 should have stake");
        assertTrue(stake3 > 0, "Bidder3 should have stake");

        // Accumulate pause time to exactly 72h
        uint256 maxPauseDuration = 72 * 60 * 60;
        uint256 accumulated = 0;
        while (accumulated < maxPauseDuration) {
            uint256 pauseTime = (maxPauseDuration - accumulated) > 10000 ? 10000 : (maxPauseDuration - accumulated);
            vm.prank(auctioneer);
            cpaManager.pause(auctionId);
            vm.warp(block.timestamp + pauseTime);
            vm.prank(auctioneer);
            cpaManager.unpause(auctionId);
            accumulated += pauseTime;
        }

        AuctionTypes.AuctionInfo memory auction = cpaManager.getAuctionInfo(auctionId);
        assertEq(auction.totalPauseDuration, maxPauseDuration, "Should have exactly 72h accumulated");

        // Final pause
        uint256 pauseStartTimestamp = block.timestamp;
        vm.prank(auctioneer);
        cpaManager.pause(auctionId);
        vm.warp(block.timestamp + 1); // Push total over 72h

        // Verify total pause time >= 72h (we track pauseStartTimestamp ourselves since it's not exposed)
        auction = cpaManager.getAuctionInfo(auctionId);
        uint256 currentPauseDuration = block.timestamp - pauseStartTimestamp;
        assertTrue(auction.totalPauseDuration + currentPauseDuration >= maxPauseDuration, "Total pause time should be >= 72h");

        // Force cancel as non-owner
        address randomUser = makeAddr("randomUser");
        vm.expectEmit(true, true, true, true);
        emit IErrorsAndEvents.AuctionCancelled(auctionId, randomUser);
        vm.prank(randomUser);
        cpaManager.forceCancelAuction(auctionId);

        // Verify cancellation state
        auction = cpaManager.getAuctionInfo(auctionId);
        assertEq(uint8(auction.currentStatus), uint8(AuctionTypes.AuctionStatus.Cancelled), "Status should be Cancelled");
        assertEq(uint8(auction.currentPhase), uint8(AuctionTypes.AuctionPhase.Clock), "Phase should remain Clock");

        // Verify bidders can reclaim with full refunds
        uint256 balance1Before = numeraireToken.balanceOf(bidder1);
        uint256 balance2Before = numeraireToken.balanceOf(bidder2);
        uint256 balance3Before = numeraireToken.balanceOf(bidder3);
        uint256 initialPenalties = cpaManager.protocolPenalties(auctionId);

        vm.prank(bidder1);
        cpaManager.reclaimStake(auctionId);
        assertEq(cpaManager.bidderStake(auctionId, bidder1), 0, "Bidder1 stake should be zero");
        assertEq(cpaManager.bidderBidPoints(auctionId, bidder1), 0, "Bidder1 bidPoints should be zero");
        assertEq(numeraireToken.balanceOf(bidder1), balance1Before + stake1, "Bidder1 should receive full refund");

        vm.prank(bidder2);
        cpaManager.reclaimStake(auctionId);
        assertEq(cpaManager.bidderStake(auctionId, bidder2), 0, "Bidder2 stake should be zero");
        assertEq(numeraireToken.balanceOf(bidder2), balance2Before + stake2, "Bidder2 should receive full refund");

        vm.prank(bidder3);
        cpaManager.reclaimStake(auctionId);
        assertEq(cpaManager.bidderStake(auctionId, bidder3), 0, "Bidder3 stake should be zero");
        assertEq(numeraireToken.balanceOf(bidder3), balance3Before + stake3, "Bidder3 should receive full refund");

        assertEq(cpaManager.protocolPenalties(auctionId), initialPenalties, "Protocol penalties should be unchanged");

        // Verify operations blocked after cancellation
        uint256[] memory demands = new uint256[](2);
        demands[0] = 5 * 10**18;
        demands[1] = 10 * 10**18;
        vm.prank(bidder1);
        vm.expectRevert(abi.encodeWithSelector(IErrorsAndEvents.AuctionNotActive.selector, auctionId, AuctionTypes.AuctionStatus.Cancelled));
        cpaManager.submitBid(auctionId, demands, type(uint256).max);

        vm.prank(auctioneer);
        vm.expectRevert(); // Should revert on cancel of already cancelled auction
        cpaManager.cancelAuction(auctionId);
    }

    function test_ForceCancelBeforeMaxPauseDurationReverts() public {
        AuctionTypes.AuctionConfig memory config = createStandardAuctionConfig();
        auctionId = createAuction(config, auctioneer);
        mintTokensToAuctioneer(1000000 * 10**18);
        approveTokens(address(asset1Token), address(cpaManager), 1000 * 10**18);
        approveTokens(address(asset2Token), address(cpaManager), 1000 * 10**18);
        moveDeposit(auctionId, asset1PoolKey, 100 * 10**18);
        moveDeposit(auctionId, asset2PoolKey, 150 * 10**18);
        vm.prank(auctioneer);
        cpaManager.startClockPhase(auctionId);

        // Accumulate 1 hour pause time
        vm.prank(auctioneer);
        cpaManager.pause(auctionId);
        vm.warp(block.timestamp + 3600); // 1 hour
        vm.prank(auctioneer);
        cpaManager.unpause(auctionId);

        AuctionTypes.AuctionInfo memory auction = cpaManager.getAuctionInfo(auctionId);
        assertEq(auction.totalPauseDuration, 3600, "Should have 1 hour accumulated");

        // Attempt force cancel - should revert
        uint256 maxPauseDuration = 72 * 60 * 60;
        vm.expectRevert(abi.encodeWithSelector(IErrorsAndEvents.PauseDurationNotExceeded.selector, 3600, maxPauseDuration));
        cpaManager.forceCancelAuction(auctionId);

        // Verify auction remains Active
        auction = cpaManager.getAuctionInfo(auctionId);
        assertEq(uint8(auction.currentStatus), uint8(AuctionTypes.AuctionStatus.Active), "Status should remain Active");
    }

    function test_UnpauseWhenNotPausedReverts() public {
        AuctionTypes.AuctionConfig memory config = createStandardAuctionConfig();
        auctionId = createAuction(config, auctioneer);
        mintTokensToAuctioneer(1000000 * 10**18);
        approveTokens(address(asset1Token), address(cpaManager), 1000 * 10**18);
        approveTokens(address(asset2Token), address(cpaManager), 1000 * 10**18);
        moveDeposit(auctionId, asset1PoolKey, 100 * 10**18);
        moveDeposit(auctionId, asset2PoolKey, 150 * 10**18);
        vm.prank(auctioneer);
        cpaManager.startClockPhase(auctionId);

        // Attempt unpause on active auction - should revert
        vm.prank(auctioneer);
        vm.expectRevert(abi.encodeWithSelector(IErrorsAndEvents.AuctionNotActive.selector, auctionId, AuctionTypes.AuctionStatus.Active));
        cpaManager.unpause(auctionId);

        // Verify auction remains Active
        AuctionTypes.AuctionInfo memory auction = cpaManager.getAuctionInfo(auctionId);
        assertEq(uint8(auction.currentStatus), uint8(AuctionTypes.AuctionStatus.Active), "Status should remain Active");

        // Cancel auction, attempt unpause - should revert
        vm.prank(auctioneer);
        cpaManager.cancelAuction(auctionId);
        vm.prank(auctioneer);
        vm.expectRevert(abi.encodeWithSelector(IErrorsAndEvents.AuctionNotActive.selector, auctionId, AuctionTypes.AuctionStatus.Cancelled));
        cpaManager.unpause(auctionId);
    }

    function test_PauseResumesCorrectPhase() public {
        AuctionTypes.AuctionConfig memory config = createStandardAuctionConfig();
        auctionId = createAuction(config, auctioneer);
        mintTokensToAuctioneer(1000000 * 10**18);
        approveTokens(address(asset1Token), address(cpaManager), 1000 * 10**18);
        approveTokens(address(asset2Token), address(cpaManager), 1000 * 10**18);

        // Test Clock phase
        moveDeposit(auctionId, asset1PoolKey, 100 * 10**18);
        moveDeposit(auctionId, asset2PoolKey, 150 * 10**18);
        vm.prank(auctioneer);
        cpaManager.startClockPhase(auctionId);

        AuctionTypes.AuctionInfo memory auction = cpaManager.getAuctionInfo(auctionId);
        uint256 roundBefore = auction.currentRound;
        vm.prank(auctioneer);
        cpaManager.pause(auctionId);
        auction = cpaManager.getAuctionInfo(auctionId);
        assertEq(uint8(auction.currentPhase), uint8(AuctionTypes.AuctionPhase.Clock), "Should be in Clock");
        vm.prank(auctioneer);
        cpaManager.unpause(auctionId);
        auction = cpaManager.getAuctionInfo(auctionId);
        assertEq(uint8(auction.currentPhase), uint8(AuctionTypes.AuctionPhase.Clock), "Should still be in Clock");
        assertEq(auction.currentRound, roundBefore, "Round should be unchanged");

        // Test Proxy phase
        vm.prank(auctioneer);
        cpaManager.endClockPhase(auctionId);
        vm.prank(auctioneer);
        cpaManager.pause(auctionId);
        auction = cpaManager.getAuctionInfo(auctionId);
        assertEq(uint8(auction.currentPhase), uint8(AuctionTypes.AuctionPhase.Proxy), "Should be in Proxy");
        vm.prank(auctioneer);
        cpaManager.unpause(auctionId);
        auction = cpaManager.getAuctionInfo(auctionId);
        assertEq(uint8(auction.currentPhase), uint8(AuctionTypes.AuctionPhase.Proxy), "Should still be in Proxy");

        // Test Allocation phase
        bytes32 saltA = keccak256("saltA");
        bytes32 saltB = keccak256("saltB");
        bytes32 commitHash = CommitReveal.generateCommitHash(bidder1, proxy1, saltA, saltB);
        vm.prank(proxy1);
        cpaManager.commitToBidder(auctionId, commitHash);
        uint256[] memory quantities = new uint256[](2);
        quantities[0] = 5 * 10**18;
        quantities[1] = 10 * 10**18;
        AuctionTypes.Bundle memory bundle = AuctionTypes.Bundle({
            auctionId: auctionId,
            commitHash: commitHash,
            value: 1000 * 10**18,
            quantities: quantities,
            timestamp: block.timestamp
        });
        vm.prank(proxy1);
        cpaManager.submitBundle(auctionId, commitHash, bundle);
        auction = cpaManager.getAuctionInfo(auctionId);
        vm.warp(block.timestamp + auction.config.phaseDurations[0]);
        cpaManager.transitionToAllocation(auctionId);

        vm.prank(auctioneer);
        cpaManager.pause(auctionId);
        auction = cpaManager.getAuctionInfo(auctionId);
        assertEq(uint8(auction.currentPhase), uint8(AuctionTypes.AuctionPhase.Allocation), "Should be in Allocation");
        vm.prank(auctioneer);
        cpaManager.unpause(auctionId);
        auction = cpaManager.getAuctionInfo(auctionId);
        assertEq(uint8(auction.currentPhase), uint8(AuctionTypes.AuctionPhase.Allocation), "Should still be in Allocation");
    }
}

