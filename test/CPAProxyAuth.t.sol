// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { CPATestBase } from "./base/CPATestBase.sol";
import { AuctionTypes } from "../src/types/AuctionTypes.sol";
import { AuctionId } from "../src/types/AuctionId.sol";
import { BundleId, BundleIdLibrary } from "../src/types/BundleId.sol";
import { IErrorsAndEvents } from "../src/utils/IErrorsAndEvents.sol";
import { CommitReveal } from "../src/utils/CommitReveal.sol";

contract CPAProxyAuthTest is CPATestBase {
    function setUp() public override {
        super.setUp();

        // Create auction and deposit into pools, start Clock, end Clock to reach Proxy phase
        AuctionTypes.AuctionConfig memory config = createStandardAuctionConfig();
        auctionId = createAuction(config, auctioneer);

        // Mint and approve deposits
        mintTokensToAuctioneer(1_000_000e18);
        approveTokens(address(asset1Token), address(cpaManager), 1000e18);
        approveTokens(address(asset2Token), address(cpaManager), 1000e18);

        moveDeposit(auctionId, asset1PoolKey, 100e18);
        moveDeposit(auctionId, asset2PoolKey, 100e18);

        // Start and immediately end a clock round to move to Proxy
        vm.prank(auctioneer);
        cpaManager.startClockPhase(auctionId);
        vm.prank(auctioneer);
        cpaManager.endClockPhase(auctionId);
    }

    function _submitBundle(
        AuctionId _auctionId,
        address _proxy,
        address _bidder,
        bytes32 commitHash,
        uint256 quantity0,
        uint256 quantity1
    ) internal {
        uint256[] memory quantities = new uint256[](2);
        quantities[0] = quantity0;
        quantities[1] = quantity1;

        AuctionTypes.Bundle memory bundle = AuctionTypes.Bundle({
            auctionId: _auctionId,
            commitHash: commitHash,
            value: 1000e18,
            quantities: quantities,
            timestamp: block.timestamp
        });

        vm.prank(_proxy);
        cpaManager.submitBundle(_auctionId, commitHash, bundle);
    }

    function test_SelfProxyHappyPath() public {
        // bidder acts as own proxy (same address)
        address self = makeAddr("selfBidder");

        // fund and approve numeraire so bidder can participate later if needed
        createBidder(self, 1_000_000e18);

        bytes32 saltA = keccak256("a");
        bytes32 saltB = keccak256("b");
        bytes32 commitHash = CommitReveal.generateCommitHash(self, self, saltA, saltB);

        vm.prank(self);
        cpaManager.commitToBidder(auctionId, commitHash);

        _submitBundle(auctionId, self, self, commitHash, 1e18, 2e18);
        // success if no revert
    }

    function test_UnauthorizedProxyReverts() public {
        // register proxy1 for a given commit
        bytes32 saltA = keccak256("a1");
        bytes32 saltB = keccak256("b1");
        bytes32 commitHash = CommitReveal.generateCommitHash(bidder1, proxy1, saltA, saltB);

        vm.prank(proxy1);
        cpaManager.commitToBidder(auctionId, commitHash);

        // proxy2 attempts to submit bundle -> revert SenderIsNotProxy
        uint256[] memory quantities = new uint256[](2);
        quantities[0] = 1e18;
        quantities[1] = 1e18;
        AuctionTypes.Bundle memory bundle = AuctionTypes.Bundle({
            auctionId: auctionId,
            commitHash: commitHash,
            value: 1000e18,
            quantities: quantities,
            timestamp: block.timestamp
        });

        vm.prank(proxy2);
        vm.expectRevert(abi.encodeWithSelector(IErrorsAndEvents.SenderIsNotProxy.selector, auctionId, commitHash));
        cpaManager.submitBundle(auctionId, commitHash, bundle);
    }

    function test_DuplicateCommitRegistrationReverts() public {
        bytes32 saltA = keccak256("x");
        bytes32 saltB = keccak256("y");
        bytes32 commitHash = CommitReveal.generateCommitHash(bidder1, proxy1, saltA, saltB);

        // Use registerCommit which guards duplicates
        vm.prank(proxy1);
        cpaManager.registerCommit(auctionId, commitHash);

        vm.prank(proxy1);
        vm.expectRevert(abi.encodeWithSelector(IErrorsAndEvents.InvalidCommitHash.selector));
        cpaManager.registerCommit(auctionId, commitHash);
    }

    function test_CrossAuctionReplayReverts() public {
        // Create a second auction B
        AuctionTypes.AuctionConfig memory configB = createNewAuctionConfig();
        AuctionId auctionIdB = createAuction(configB, auctioneer);
        // move some deposits to enable proxy phase later (but we’ll only test registration mapping)
        moveDeposit(auctionIdB, asset1PoolKey, 10e18);
        moveDeposit(auctionIdB, asset2PoolKey, 10e18);

        // Register commit in auction A
        bytes32 saltA = keccak256("ca");
        bytes32 saltB = keccak256("cb");
        bytes32 commitHash = CommitReveal.generateCommitHash(bidder1, proxy1, saltA, saltB);
        vm.prank(proxy1);
        cpaManager.commitToBidder(auctionId, commitHash);

        // Attempt to submit in auction B should fail (no proxy registered there)
        uint256[] memory quantities = new uint256[](2);
        quantities[0] = 1e18;
        quantities[1] = 1e18;
        AuctionTypes.Bundle memory bundle = AuctionTypes.Bundle({
            auctionId: auctionIdB,
            commitHash: commitHash,
            value: 1000e18,
            quantities: quantities,
            timestamp: block.timestamp
        });

        // Move auction B to Proxy quickly
        vm.prank(auctioneer);
        cpaManager.startClockPhase(auctionIdB);
        vm.prank(auctioneer);
        cpaManager.endClockPhase(auctionIdB);

        vm.prank(proxy1);
        vm.expectRevert(abi.encodeWithSelector(IErrorsAndEvents.SenderIsNotProxy.selector, auctionIdB, commitHash));
        cpaManager.submitBundle(auctionIdB, commitHash, bundle);
    }

    function test_RevealMismatchReverts_wrongSalts() public {
        // Register commit and submit bundle correctly
        bytes32 saltA = keccak256("ra");
        bytes32 saltB = keccak256("rb");
        bytes32 commitHash = CommitReveal.generateCommitHash(bidder1, proxy1, saltA, saltB);

        vm.prank(proxy1);
        cpaManager.commitToBidder(auctionId, commitHash);
        uint256[] memory q = new uint256[](2);
        q[0] = 1e18;
        q[1] = 1e18;
        _submitBundle(auctionId, proxy1, bidder1, commitHash, q[0], q[1]);

        // End Proxy → Allocation (needs at least one submission already), then Allocation → Settlement
        AuctionTypes.AuctionInfo memory auction = cpaManager.getAuctionInfo(auctionId);
        vm.warp(block.timestamp + auction.config.phaseDurations[0]);
        cpaManager.transitionToAllocation(auctionId);

        // Submit trivial allocation by first allocator
        BundleId[] memory selected = new BundleId[](1);
        selected[0] = BundleIdLibrary.createId(commitHash, keccak256(abi.encode(q)));

        AuctionTypes.Allocation memory allocation = AuctionTypes.Allocation({
            auctionId: auctionId,
            allocator: makeAddr("allocA"),
            bundleIds: selected,
            totalValue: 1000e18,
            timestamp: block.timestamp
        });
        vm.prank(allocation.allocator);
        cpaManager.submitAllocation(auctionId, allocation);

        vm.warp(block.timestamp + auction.config.phaseDurations[1]);
        cpaManager.transitionToSettlement(auctionId);

        // Wrong salts should revert
        vm.prank(bidder1);
        vm.expectRevert();
        cpaManager.reveal(auctionId, proxy1, keccak256("wrongA"), keccak256("wrongB"));

        // Correct salts should succeed
        vm.prank(bidder1);
        cpaManager.reveal(auctionId, proxy1, saltA, saltB);
    }

    // no helpers below
}


