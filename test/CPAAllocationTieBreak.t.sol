// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { CPATestBase } from "./base/CPATestBase.sol";
import { AuctionTypes } from "../src/types/AuctionTypes.sol";
import { BundleId, BundleIdLibrary } from "../src/types/BundleId.sol";
import { AuctionId } from "../src/types/AuctionId.sol";
import { CommitReveal } from "../src/utils/CommitReveal.sol";

contract CPAAllocationTieBreakTest is CPATestBase {
    address allocA;
    address allocB;

    function setUp() public override {
        super.setUp();

        allocA = makeAddr("allocA");
        allocB = makeAddr("allocB");

        // Create auction and move to Proxy phase with two submitted bundles
        AuctionTypes.AuctionConfig memory config = createStandardAuctionConfig();
        auctionId = createAuction(config, auctioneer);

        // deposits
        mintTokensToAuctioneer(1_000_000e18);
        approveTokens(address(asset1Token), address(cpaManager), 1000e18);
        approveTokens(address(asset2Token), address(cpaManager), 1000e18);
        moveDeposit(auctionId, asset1PoolKey, 100e18);
        moveDeposit(auctionId, asset2PoolKey, 100e18);

        // start/end clock
        vm.prank(auctioneer);
        cpaManager.startClockPhase(auctionId);
        vm.prank(auctioneer);
        cpaManager.endClockPhase(auctionId);

        // submit two bundles from two different proxies
        uint256[] memory q1 = new uint256[](2);
        q1[0] = 10e18; q1[1] = 10e18;
        uint256[] memory q2 = new uint256[](2);
        q2[0] = 10e18; q2[1] = 10e18;

        bytes32 sA1 = keccak256("sA1"); bytes32 sB1 = keccak256("sB1");
        bytes32 sA2 = keccak256("sA2"); bytes32 sB2 = keccak256("sB2");
        bytes32 ch1 = CommitReveal.generateCommitHash(bidder1, proxy1, sA1, sB1);
        bytes32 ch2 = CommitReveal.generateCommitHash(bidder2, proxy2, sA2, sB2);

        vm.prank(proxy1); cpaManager.commitToBidder(auctionId, ch1);
        vm.prank(proxy2); cpaManager.commitToBidder(auctionId, ch2);

        _submitBundle(auctionId, proxy1, ch1, q1);
        _submitBundle(auctionId, proxy2, ch2, q2);

        // advance to Allocation
        AuctionTypes.AuctionInfo memory auction = cpaManager.getAuctionInfo(auctionId);
        vm.warp(block.timestamp + auction.config.phaseDurations[0]);
        cpaManager.transitionToAllocation(auctionId);
    }

    function _submitBundle(AuctionId _auctionId, address _proxy, bytes32 commitHash, uint256[] memory q) internal {
        AuctionTypes.Bundle memory bundle = AuctionTypes.Bundle({
            auctionId: _auctionId,
            commitHash: commitHash,
            value: 1000e18,
            quantities: q,
            timestamp: block.timestamp
        });
        vm.prank(_proxy);
        cpaManager.submitBundle(_auctionId, commitHash, bundle);
    }

    function test_FirstSubmissionWinsOnTie() public {
        // same totalValue, two allocations; first should win deterministically
        bytes32 sA1 = keccak256("sA1"); bytes32 sB1 = keccak256("sB1");
        bytes32 sA2 = keccak256("sA2"); bytes32 sB2 = keccak256("sB2");
        bytes32 ch1 = CommitReveal.generateCommitHash(bidder1, proxy1, sA1, sB1);
        bytes32 ch2 = CommitReveal.generateCommitHash(bidder2, proxy2, sA2, sB2);

        uint256[] memory q1 = new uint256[](2); q1[0] = 10e18; q1[1] = 10e18;
        uint256[] memory q2 = new uint256[](2); q2[0] = 10e18; q2[1] = 10e18;
        BundleId[] memory selected = new BundleId[](2);
        selected[0] = BundleIdLibrary.createId(ch1, keccak256(abi.encode(q1)));
        selected[1] = BundleIdLibrary.createId(ch2, keccak256(abi.encode(q2)));

        AuctionTypes.Allocation memory A = AuctionTypes.Allocation({
            auctionId: auctionId,
            allocator: allocA,
            bundleIds: selected,
            totalValue: 2000e18,
            timestamp: block.timestamp
        });
        AuctionTypes.Allocation memory B = AuctionTypes.Allocation({
            auctionId: auctionId,
            allocator: allocB,
            bundleIds: selected,
            totalValue: 2000e18,
            timestamp: block.timestamp
        });

        vm.prank(allocA); cpaManager.submitAllocation(auctionId, A);
        vm.prank(allocB); cpaManager.submitAllocation(auctionId, B);

        // move to Settlement (select winner happens in transition)
        AuctionTypes.AuctionInfo memory auction = cpaManager.getAuctionInfo(auctionId);
        vm.warp(block.timestamp + auction.config.phaseDurations[1]);
        cpaManager.transitionToSettlement(auctionId);

        // Verify winner is allocA (first)
        (AuctionTypes.Allocation memory winning,,) = cpaManager.topAllocation(auctionId);
        require(winning.allocator == allocA, "first submitter should win tie");
    }
}


