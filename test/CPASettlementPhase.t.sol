// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC6909Claims } from "@uniswap/v4-core/src/interfaces/external/IERC6909Claims.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { PoolId } from "@uniswap/v4-core/src/types/PoolId.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { Hooks } from "@uniswap/v4-core/src/libraries/Hooks.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";

import { CPAManager } from "../src/CPAManager.sol";
import { AuctionTypes } from "../src/AuctionTypes.sol";
import { AuctionId } from "../src/AuctionId.sol";
import { BundleId } from "../src/BundleId.sol";
import { IErrorsAndEvents } from "../src/utils/IErrorsAndEvents.sol";
import { CommitReveal } from "../src/CommitReveal.sol";
import { CPATestBase } from "./base/CPATestBase.sol";

contract CPASettlementPhaseTest is CPATestBase {
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

        // Set up complete auction flow to settlement phase
        setupCompleteAuctionFlow();
    }

    function setupCompleteAuctionFlow() internal {

        // 2. Clock phase - bidders submit bids
        setupClockPhase();

        // 3. Proxy phase - proxies submit bundles
        setupProxyPhase();

        // 4. Allocation phase - allocators submit allocations
        setupAllocationPhase();

        // 5. Move to settlement phase (happens automatically in endAllocationPhase)
    }

    function setupClockPhase() internal {
        // Create bidders with sufficient funds
        createBidder(bidder1, 1000000 * 10**18);
        createBidder(bidder2, 1000000 * 10**18);

        // Proxy commits
        vm.prank(proxy1);
        cpaManager.commitToBidder(auctionId, commitHash1);
        vm.prank(proxy2);
        cpaManager.commitToBidder(auctionId, commitHash2);

        // Start clock round
        vm.prank(auctioneer);
        cpaManager.startClockRound(auctionId);

        // Submit bids
        uint256[] memory demands1 = new uint256[](2);
        demands1[0] = 100 * 10**18; // 100 asset1
        demands1[1] = 50 * 10**18;  // 50 asset2

        uint256[] memory demands2 = new uint256[](2);
        demands2[0] = 75 * 10**18;  // 75 asset1
        demands2[1] = 25 * 10**18;  // 25 asset2

        uint256 maxStake1 = 1000 * 10**18;
        uint256 maxStake2 = 1000 * 10**18;

        approveNumeraireForBidder(bidder1, maxStake1);
        approveNumeraireForBidder(bidder2, maxStake2);

        vm.prank(bidder1);
        cpaManager.submitBid(auctionId, demands1, maxStake1);
        vm.prank(bidder2);
        cpaManager.submitBid(auctionId, demands2, maxStake2);

        // End clock phase
        vm.prank(auctioneer);
        cpaManager.endClockPhase(auctionId);
    }

    function setupProxyPhase() internal {
        // Create bundles for both bidders
        uint256[] memory quantities1 = new uint256[](2);
        quantities1[0] = 50 * 10**18; // asset1 (reduced from 100)
        quantities1[1] = 50 * 10**18;  // asset2

        uint256[] memory quantities2 = new uint256[](2);
        quantities2[0] = 50 * 10**18;  // asset1 (reduced from 75)
        quantities2[1] = 25 * 10**18;  // asset2

        // Create bundle structs
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
            value: 800 * 10**18,
            quantities: quantities2,
            timestamp: block.timestamp
        });

        // Submit bundles
        vm.prank(proxy1);
        bundleId1 = cpaManager.submitBundle(auctionId, commitHash1, bundle1);
        vm.prank(proxy2);
        bundleId2 = cpaManager.submitBundle(auctionId, commitHash2, bundle2);

        // End proxy phase
        vm.prank(auctioneer);
        cpaManager.endProxyPhase(auctionId);
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
            totalValue: 1800 * 10**18, // Sum of bundle values
            timestamp: block.timestamp
        });

        // Submit allocation
        vm.prank(allocator1);
        cpaManager.submitAllocation(auctionId, allocation);

        // End allocation phase
        vm.prank(auctioneer);
        cpaManager.endAllocationPhase(auctionId);
    }

    function test_Reveal_Success() public {
        // Test successful reveal
        vm.expectEmit(true, true, true, true);
        emit IErrorsAndEvents.RevealProcessed(auctionId, bidder1, proxy1, commitHash1);

        vm.prank(bidder1);
        cpaManager.reveal(auctionId, proxy1, saltA1, saltB1);

        // Verify reveal was recorded
        assertEq(cpaManager.revealedMappings(auctionId, commitHash1), bidder1, "Reveal should be recorded");
    }

    function test_Reveal_MultipleBidders() public {
        // Reveal both bidders
        vm.prank(bidder1);
        cpaManager.reveal(auctionId, proxy1, saltA1, saltB1);

        vm.prank(bidder2);
        cpaManager.reveal(auctionId, proxy2, saltA2, saltB2);

        // Verify both reveals were recorded
        assertEq(cpaManager.revealedMappings(auctionId, commitHash1), bidder1, "Bidder1 reveal should be recorded");
        assertEq(cpaManager.revealedMappings(auctionId, commitHash2), bidder2, "Bidder2 reveal should be recorded");
    }

    function test_ClaimToken_Success() public {
        // First reveal the bidder
        vm.prank(bidder1);
        cpaManager.reveal(auctionId, proxy1, saltA1, saltB1);

        // Get initial balances
        uint256 initialAsset1Balance = asset1Token.balanceOf(bidder1);
        uint256 initialNumeraireBalance = numeraireToken.balanceOf(bidder1);
        uint256 initialBidderStake = cpaManager.bidderStake(auctionId, bidder1);

        // Claim asset1
        vm.prank(bidder1);
        cpaManager.claimToken(auctionId, commitHash1, asset1PoolKey.toId());

        // Verify state changes
        uint256 finalAsset1Balance = asset1Token.balanceOf(bidder1);
        uint256 finalNumeraireBalance = numeraireToken.balanceOf(bidder1);
        uint256 finalBidderStake = cpaManager.bidderStake(auctionId, bidder1);

        // Should have received asset1 tokens
        assertGt(finalAsset1Balance, initialAsset1Balance, "Bidder should have received asset1 tokens");
        
        // Stake should have been reduced (used for payment)
        assertLt(finalBidderStake, initialBidderStake, "Bidder stake should have been reduced");
    }

    function test_ClaimToken_MultipleAssets() public {
        // Reveal both bidders
        vm.prank(bidder1);
        cpaManager.reveal(auctionId, proxy1, saltA1, saltB1);
        vm.prank(bidder2);
        cpaManager.reveal(auctionId, proxy2, saltA2, saltB2);

        // Get initial balances
        uint256 initialAsset1Balance1 = asset1Token.balanceOf(bidder1);
        uint256 initialAsset2Balance1 = asset2Token.balanceOf(bidder1);
        uint256 initialAsset1Balance2 = asset1Token.balanceOf(bidder2);
        uint256 initialAsset2Balance2 = asset2Token.balanceOf(bidder2);

        // Bidder1 claims both assets
        vm.prank(bidder1);
        cpaManager.claimToken(auctionId, commitHash1, asset1PoolKey.toId());
        vm.prank(bidder1);
        cpaManager.claimToken(auctionId, commitHash1, asset2PoolKey.toId());

        // Bidder2 claims both assets
        vm.prank(bidder2);
        cpaManager.claimToken(auctionId, commitHash2, asset1PoolKey.toId());
        vm.prank(bidder2);
        cpaManager.claimToken(auctionId, commitHash2, asset2PoolKey.toId());

        // Verify both bidders received their allocated tokens
        assertGt(asset1Token.balanceOf(bidder1), initialAsset1Balance1, "Bidder1 should have received asset1");
        assertGt(asset2Token.balanceOf(bidder1), initialAsset2Balance1, "Bidder1 should have received asset2");
        assertGt(asset1Token.balanceOf(bidder2), initialAsset1Balance2, "Bidder2 should have received asset1");
        assertGt(asset2Token.balanceOf(bidder2), initialAsset2Balance2, "Bidder2 should have received asset2");
    }

    function test_ClaimToken_StateChanges() public {
        // Reveal bidder
        vm.prank(bidder1);
        cpaManager.reveal(auctionId, proxy1, saltA1, saltB1);

        // Get initial state
        uint256 initialBidderStake = cpaManager.bidderStake(auctionId, bidder1);
        uint256 initialPoolManagerNumeraire = numeraireToken.balanceOf(address(poolManager));
        uint256 initialCPAManagerClaims = IERC6909Claims(poolManager).balanceOf(address(cpaManager), uint256(uint160(address(numeraireToken))));

        // Claim token
        vm.prank(bidder1);
        cpaManager.claimToken(auctionId, commitHash1, asset1PoolKey.toId());

        // Verify state changes
        uint256 finalBidderStake = cpaManager.bidderStake(auctionId, bidder1);
        uint256 finalPoolManagerNumeraire = numeraireToken.balanceOf(address(poolManager));
        uint256 finalCPAManagerClaims = IERC6909Claims(poolManager).balanceOf(address(cpaManager), uint256(uint160(address(numeraireToken))));

        // Bidder stake should be reduced
        assertLt(finalBidderStake, initialBidderStake, "Bidder stake should be reduced after claim");

        // Pool manager numeraire balance should change (used for swap)
        assertTrue(finalPoolManagerNumeraire != initialPoolManagerNumeraire, "Pool manager numeraire balance should change");

        // CPAManager claims should be reduced
        assertLt(finalCPAManagerClaims, initialCPAManagerClaims, "CPAManager claims should be reduced");
    }

    function test_CompleteSettlementFlow() public {
        // This test verifies the complete settlement flow from reveal to claim
        
        // 1. Reveal both bidders
        vm.prank(bidder1);
        cpaManager.reveal(auctionId, proxy1, saltA1, saltB1);
        vm.prank(bidder2);
        cpaManager.reveal(auctionId, proxy2, saltA2, saltB2);

        // 2. Verify reveals were recorded
        assertEq(cpaManager.revealedMappings(auctionId, commitHash1), bidder1, "Bidder1 reveal recorded");
        assertEq(cpaManager.revealedMappings(auctionId, commitHash2), bidder2, "Bidder2 reveal recorded");

        // 3. Get initial balances
        uint256 initialAsset1Balance1 = asset1Token.balanceOf(bidder1);
        uint256 initialAsset2Balance1 = asset2Token.balanceOf(bidder1);
        uint256 initialAsset1Balance2 = asset1Token.balanceOf(bidder2);
        uint256 initialAsset2Balance2 = asset2Token.balanceOf(bidder2);

        // 4. Claim all allocated tokens
        vm.prank(bidder1);
        cpaManager.claimToken(auctionId, commitHash1, asset1PoolKey.toId());
        vm.prank(bidder1);
        cpaManager.claimToken(auctionId, commitHash1, asset2PoolKey.toId());
        vm.prank(bidder2);
        cpaManager.claimToken(auctionId, commitHash2, asset1PoolKey.toId());
        vm.prank(bidder2);
        cpaManager.claimToken(auctionId, commitHash2, asset2PoolKey.toId());

        // 5. Verify final balances
        assertGt(asset1Token.balanceOf(bidder1), initialAsset1Balance1, "Bidder1 received asset1");
        assertGt(asset2Token.balanceOf(bidder1), initialAsset2Balance1, "Bidder1 received asset2");
        assertGt(asset1Token.balanceOf(bidder2), initialAsset1Balance2, "Bidder2 received asset1");
        assertGt(asset2Token.balanceOf(bidder2), initialAsset2Balance2, "Bidder2 received asset2");

        // 6. Verify stake balances were reduced
        assertLt(cpaManager.bidderStake(auctionId, bidder1), 1000 * 10**18, "Bidder1 stake reduced");
        assertLt(cpaManager.bidderStake(auctionId, bidder2), 1000 * 10**18, "Bidder2 stake reduced");
    }
}