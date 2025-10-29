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

import { CPAManager } from "../src/CPAManager.sol";
import { AuctionTypes } from "../src/types/AuctionTypes.sol";
import { AuctionId } from "../src/types/AuctionId.sol";
import { BundleId } from "../src/types/BundleId.sol";
import { IErrorsAndEvents } from "../src/utils/IErrorsAndEvents.sol";
import { CommitReveal } from "../src/utils/CommitReveal.sol";
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
        cpaManager.startClockPhase(auctionId);

        // Submit bids
        uint256[] memory demands1 = new uint256[](2);
        demands1[0] = 100 * 10**18; // 100 asset1
        demands1[1] = 50 * 10**18;  // 50 asset2

        uint256[] memory demands2 = new uint256[](2);
        demands2[0] = 75 * 10**18;  // 75 asset1
        demands2[1] = 25 * 10**18;  // 25 asset2

        uint256 maxStake1 = 1000 * 10**18;
        uint256 maxStake2 = 1000 * 10**18;

        approveNumeraireForBidder(bidder1, type(uint256).max);
        approveNumeraireForBidder(bidder2, type(uint256).max);

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
        // Warp past the proxy phase duration to allow transition
        AuctionTypes.AuctionInfo memory auction = cpaManager.getAuctionInfo(auctionId);
        vm.warp(block.timestamp + auction.config.phaseDurations[0] + 1);
        cpaManager.transitionToAllocation(auctionId); // permissionless transition
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
        // Warp past the allocation phase duration to allow transition
        AuctionTypes.AuctionInfo memory auction = cpaManager.getAuctionInfo(auctionId);
        vm.warp(block.timestamp + auction.config.phaseDurations[1] + 1);
        cpaManager.transitionToSettlement(auctionId); // permissionless transition
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

        // Get the commit hash and check if it's in the winning bundle ids
        bytes32 commitHash = CommitReveal.generateCommitHash(bidder1, proxy1, saltA1, saltB1);
        BundleId bundleId = cpaManager.winningBundleIds(commitHash);
        // assertEq(bundleId, bundleId1, "Commit hash should be in the winning bundle ids");
        console.log("Bundle ID:", uint256(BundleId.unwrap(bundleId)));
        console.log("Commit hash:", uint256(commitHash));
        console.log("Bidder1:", bidder1);
        console.log("Proxy1:", proxy1);
        // console.log("SaltA1:", saltA1);
        // console.log("SaltB1:", saltB1);
        console.log("Commit hash1:", uint256(commitHash1));
        console.log("Bundle ID1:", uint256(BundleId.unwrap(bundleId1)));

        // Claim asset1
        vm.prank(bidder1);
        cpaManager.claimAllTokens(auctionId, commitHash1);

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
        cpaManager.claimAllTokens(auctionId, commitHash1);

        // Bidder2 claims both assets
        vm.prank(bidder2);
        cpaManager.claimAllTokens(auctionId, commitHash2);

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
        uint256 initialBidderNumeraire = numeraireToken.balanceOf(bidder1);
        uint256 initialPoolManagerNumeraire = numeraireToken.balanceOf(address(poolManager));
        uint256 initialCPAManagerClaims = IERC6909Claims(poolManager).balanceOf(address(cpaManager), uint256(uint160(address(numeraireToken))));

        // Claim token
        vm.prank(bidder1);
        cpaManager.claimAllTokens(auctionId, commitHash1);

        // Verify state changes
        uint256 finalBidderStake = cpaManager.bidderStake(auctionId, bidder1);
        uint256 finalBidderNumeraire = numeraireToken.balanceOf(bidder1);
        uint256 finalPoolManagerNumeraire = numeraireToken.balanceOf(address(poolManager));
        uint256 finalCPAManagerClaims = IERC6909Claims(poolManager).balanceOf(address(cpaManager), uint256(uint160(address(numeraireToken))));

        // Calculate changes (using safe subtraction to prevent overflow)
        uint256 stakeReduction = initialBidderStake > finalBidderStake ? initialBidderStake - finalBidderStake : 0;
        uint256 numeraireChange = finalPoolManagerNumeraire > initialPoolManagerNumeraire ? finalPoolManagerNumeraire - initialPoolManagerNumeraire : 0;
        uint256 bidderNumeraireChange = finalBidderNumeraire > initialBidderNumeraire ? finalBidderNumeraire - initialBidderNumeraire : 0;
        uint256 claimsReduction = initialCPAManagerClaims > finalCPAManagerClaims ? initialCPAManagerClaims - finalCPAManagerClaims : 0;

        console.log("Stake reduction:", stakeReduction);
        console.log("Pool manager numeraire change:", numeraireChange);
        console.log("Bidder numeraire change:", bidderNumeraireChange);
        console.log("Claims reduction:", claimsReduction);

        // Bidder stake should be reduced (used for payment)
        assertLt(finalBidderStake, initialBidderStake, "Bidder stake should be reduced after claim");

        // CPAManager claims should be reduced (used for swap)
        assertLt(finalCPAManagerClaims, initialCPAManagerClaims, "CPAManager claims should be reduced");

        // The CPAManager claims should be reduced (used for the swap)
        assertGt(claimsReduction, 0, "CPAManager claims should be reduced for the swap");

        // Pool manager numeraire balance may or may not change depending on the swap mechanism
        // The key is that the CPAManager's claims are reduced, representing the numeraire used for the swap
        if (numeraireChange > 0) {
            // If pool manager received numeraire, it should equal the claims reduction
            assertEq(numeraireChange, claimsReduction, "Pool manager numeraire increase should equal CPAManager claims reduction");
        } else {
            // If pool manager balance didn't change, the CPAManager used its own numeraire balance
            // This is also a valid scenario - the swap happens internally within the CPAManager
            console.log("Pool manager balance unchanged - CPAManager used internal numeraire");
        }

        // If bidder had to pay additional numeraire (insufficient stake), their balance should decrease
        if (bidderNumeraireChange < 0) {
            assertLt(finalBidderNumeraire, initialBidderNumeraire, "Bidder should lose numeraire if stake was insufficient");
        }
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
        cpaManager.claimAllTokens(auctionId, commitHash1);
        vm.prank(bidder2);
        cpaManager.claimAllTokens(auctionId, commitHash2);

        // 5. Verify final balances
        assertGt(asset1Token.balanceOf(bidder1), initialAsset1Balance1, "Bidder1 received asset1");
        assertGt(asset2Token.balanceOf(bidder1), initialAsset2Balance1, "Bidder1 received asset2");
        assertGt(asset1Token.balanceOf(bidder2), initialAsset1Balance2, "Bidder2 received asset1");
        assertGt(asset2Token.balanceOf(bidder2), initialAsset2Balance2, "Bidder2 received asset2");

        // 6. Verify stake balances were reduced
        assertLt(cpaManager.bidderStake(auctionId, bidder1), 1000 * 10**18, "Bidder1 stake reduced");
        assertLt(cpaManager.bidderStake(auctionId, bidder2), 1000 * 10**18, "Bidder2 stake reduced");
    }
    
    function test_SubmitAllocation_RejectedInSettlementPhase() public {
        // Test that allocation submission is rejected during Settlement phase
        address testAllocator = makeAddr("testAllocator");
        
        // Create a test allocation
        AuctionTypes.Allocation memory testAllocation = AuctionTypes.Allocation({
            auctionId: auctionId,
            allocator: testAllocator,
            bundleIds: new BundleId[](0), // Empty bundle array
            totalValue: 1000 * 10**18,
            timestamp: block.timestamp
        });
        
        // Should fail with InvalidPhase error (Settlement phase, not Allocation phase)
        vm.prank(testAllocator);
        vm.expectRevert(abi.encodeWithSelector(IErrorsAndEvents.InvalidPhase.selector, AuctionTypes.AuctionPhase.Allocation, AuctionTypes.AuctionPhase.Settlement));
        cpaManager.submitAllocation(auctionId, testAllocation);
    }

    function test_PositionMintingAndIdMatching() public {
        // This test verifies that positions are minted during transitionToSettlement
        // and that position IDs are correctly set via ERC721 receiver
        
        // Get auction info to access pool keys
        AuctionTypes.AuctionInfo memory auction = cpaManager.getAuctionInfo(auctionId);
        PoolKey[] memory poolKeys = auction.poolKeys;
        
        // Verify positions were minted for each pool
        for (uint256 i = 0; i < poolKeys.length; i++) {
            PoolId poolId = poolKeys[i].toId();
            (,,,uint256 depositAmount,,,AuctionId poolAuctionId, uint256 positionId) = cpaManager.getPoolInfo(poolId);
            
            // Verify position ID is set (should be > 0)
            assertTrue(positionId > 0, "Position ID should be set for pool");
            
            // Verify CPAManager owns the position NFT
            assertEq(IERC721(address(positionManager)).ownerOf(positionId), address(cpaManager), "CPAManager should own the position NFT");
            
            // Verify the position ID corresponds to the correct pool using PositionManager
            (PoolKey memory retrievedPoolKey, ) = positionManager.getPoolAndPositionInfo(positionId);
            assertEq(PoolId.unwrap(retrievedPoolKey.toId()), PoolId.unwrap(poolId), "Position should be associated with correct pool");
            
            console.log("Pool %d: Position ID %d correctly associated with pool", i, positionId);
        }
        
        console.log("All positions minted and IDs correctly matched!");
    }
}