// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { CPAManager } from "../src/CPAManager.sol";
import { AuctionTypes } from "../src/types/AuctionTypes.sol";
import { AuctionId } from "../src/types/AuctionId.sol";
import { BundleId, BundleIdLibrary } from "../src/types/BundleId.sol";
import { CommitReveal } from "../src/utils/CommitReveal.sol";
import { MockERC20 } from "solmate/src/test/utils/mocks/MockERC20.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { Hooks } from "@uniswap/v4-core/src/libraries/Hooks.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { IErrorsAndEvents } from "../src/utils/IErrorsAndEvents.sol";
import { CPATestBase } from "./base/CPATestBase.sol";

contract CPAProxyPhaseTest is CPATestBase {
    // Test data
    bytes32 saltA;
    bytes32 saltB;
    bytes32 commitHash;
    bytes32 partialCommit;
    
    function setUp() public override {
        // Call parent setUp to initialize all accounts and contracts
        super.setUp();

        // Create the auction
        AuctionTypes.AuctionConfig memory config = createStandardAuctionConfig();
        auctionId = createAuction(config, auctioneer);
        
        // Mint tokens to auctioneer for deposits
        mintTokensToAuctioneer(1000000 * 10**18);
        
        // Approve CPAManager to spend auctioneer's tokens
        approveTokens(address(asset1Token), address(cpaManager), 1000 * 10**18);
        approveTokens(address(asset2Token), address(cpaManager), 1000 * 10**18);
        
        // Generate commit-reveal data using existing accounts
        saltA = keccak256("saltA");
        saltB = keccak256("saltB");
        commitHash = CommitReveal.generateCommitHash(bidder1, proxy1, saltA, saltB);
        partialCommit = CommitReveal.getBidderHash(bidder1, saltA);
        
        // Setup auction state: move to proxy phase
        setupAuctionForProxyPhase();
    }
    
    function setupAuctionForProxyPhase() internal {
        // Move deposits to pools
        vm.prank(auctioneer);
        cpaManager.moveDeposit(auctionId, asset1PoolKey, 1000 * 10**18);
        vm.prank(auctioneer);
        cpaManager.moveDeposit(auctionId, asset2PoolKey, 1000 * 10**18);
        
        // Set up proxy commitment for testing
        vm.prank(proxy1);
        cpaManager.commitToBidder(auctionId, commitHash);

        // Start clock phase
        vm.prank(auctioneer);
        cpaManager.startClockPhase(auctionId);
        
        // End clock phase to move to proxy phase
        vm.prank(auctioneer);
        cpaManager.endClockPhase(auctionId);
    }
    
    function test_SubmitBundle_ValidBundle() public {
        // Create valid bundle data
        uint256[] memory quantities = new uint256[](2);
        quantities[0] = 100 * 10**18;
        quantities[1] = 50 * 10**18;
        
        AuctionTypes.Bundle memory bundleData = AuctionTypes.Bundle({
            auctionId: auctionId,
            commitHash: commitHash,
            value: 1000 * 10**18,
            quantities: quantities,
            timestamp: block.timestamp
        });
        
        // Generate bundleId for testing
        BundleId expectedBundleId = BundleIdLibrary.createId(commitHash, keccak256(abi.encode(quantities)));
        
        // Expect the BundleSubmitted event to be emitted
        vm.expectEmit(true, true, true, true);
        emit IErrorsAndEvents.BundleSubmitted(
            auctionId,
            commitHash,
            expectedBundleId,
            quantities,
            bundleData.value
        );
        
        // Submit bundle (proxy commitment already set up in setUp)
        vm.prank(proxy1);
        cpaManager.submitBundle(auctionId, commitHash, bundleData);
        
        // Verify bundle was stored
        (
            AuctionId returnedAuctionId, 
            bytes32 returnedCommitHash, 
            BundleId returnedBundleId, 
            uint256[] memory returnedQuantities, 
            uint256 returnedValue, 
            uint256 returnedTimestamp
        ) = cpaManager.getBundle(auctionId, expectedBundleId);
        assertEq(AuctionId.unwrap(returnedAuctionId), AuctionId.unwrap(auctionId), "Bundle auction ID should match");
        assertEq(returnedCommitHash, commitHash, "Bundle commit hash should match");
        assertEq(BundleId.unwrap(returnedBundleId), BundleId.unwrap(expectedBundleId), "Bundle ID should match");
        assertEq(returnedValue, bundleData.value, "Bundle value should match");
        assertEq(returnedQuantities.length, 2, "Bundle should have 2 quantities");
        assertEq(returnedQuantities[0], quantities[0], "First quantity should match");
        assertEq(returnedQuantities[1], quantities[1], "Second quantity should match");
    }
    
    function test_SubmitBundle_BundleExists() public {
        // Create bundle data
        uint256[] memory quantities = new uint256[](2);
        quantities[0] = 100 * 10**18;
        quantities[1] = 50 * 10**18;
        
        AuctionTypes.Bundle memory bundleData = AuctionTypes.Bundle({
            auctionId: auctionId,
            commitHash: commitHash,
            value: 1000 * 10**18,
            quantities: quantities,
            timestamp: block.timestamp
        });
        
        // Submit bundle first time (proxy commitment already set up in setUp)
        vm.prank(proxy1);
        cpaManager.submitBundle(auctionId, commitHash, bundleData);
        
        // Try to submit same bundle again - should fail
        vm.prank(proxy1);
        vm.expectRevert();
        cpaManager.submitBundle(auctionId, commitHash, bundleData);
    }
    
    function test_SubmitBundle_InvalidProxy() public {
        // Create bundle data
        uint256[] memory quantities = new uint256[](2);
        quantities[0] = 100 * 10**18;
        quantities[1] = 50 * 10**18;
        
        AuctionTypes.Bundle memory bundleData = AuctionTypes.Bundle({
            auctionId: auctionId,
            commitHash: commitHash,
            value: 1000 * 10**18,
            quantities: quantities,
            timestamp: block.timestamp
        });
        
        // Try to submit bundle with a different proxy that hasn't committed - should fail
        vm.prank(proxy2);
        vm.expectRevert();
        cpaManager.submitBundle(auctionId, commitHash, bundleData);
    }
    
    function test_SubmitBundle_WrongQuantitiesLength() public {
        // Create bundle with wrong number of quantities
        uint256[] memory quantities = new uint256[](3); // Should be 2
        quantities[0] = 100 * 10**18;
        quantities[1] = 50 * 10**18;
        quantities[2] = 25 * 10**18;
        
        AuctionTypes.Bundle memory bundleData = AuctionTypes.Bundle({
            auctionId: auctionId,
            commitHash: commitHash,
            value: 1000 * 10**18,
            quantities: quantities,
            timestamp: block.timestamp
        });
        
        // Try to submit bundle with wrong quantities length - should fail
        vm.prank(proxy1);
        vm.expectRevert();
        cpaManager.submitBundle(auctionId, commitHash, bundleData);
    }
    
    function test_SubmitBundle_InvalidCommitHash() public {
        // Create bundle data with valid quantities
        uint256[] memory quantities = new uint256[](2);
        quantities[0] = 100 * 10**18;
        quantities[1] = 50 * 10**18;
        
        // Use a different commit hash that doesn't match any committed proxy
        bytes32 invalidCommitHash = keccak256("invalidCommitHash");
        
        AuctionTypes.Bundle memory bundleData = AuctionTypes.Bundle({
            auctionId: auctionId,
            commitHash: invalidCommitHash,
            value: 1000 * 10**18,
            quantities: quantities,
            timestamp: block.timestamp
        });
        
        // Try to submit bundle with invalid commit hash - should fail
        vm.prank(proxy1);
        vm.expectRevert();
        cpaManager.submitBundle(auctionId, invalidCommitHash, bundleData);
    }
    
    function test_SubmitBundle_ProxyMisrepresentsCommitHash() public {
        // First, let's have proxy2 commit to a different commit hash
        bytes32 proxy2SaltA = keccak256("proxy2SaltA");
        bytes32 proxy2SaltB = keccak256("proxy2SaltB");
        bytes32 proxy2CommitHash = CommitReveal.generateCommitHash(bidder2, proxy2, proxy2SaltA, proxy2SaltB);
        
        // Have proxy2 commit to their own commit hash
        vm.prank(proxy2);
        cpaManager.commitToBidder(auctionId, proxy2CommitHash);
        
        // Create bundle data with valid quantities
        uint256[] memory quantities = new uint256[](2);
        quantities[0] = 100 * 10**18;
        quantities[1] = 50 * 10**18;
        
        // Now proxy1 tries to submit a bundle using proxy2's commit hash
        AuctionTypes.Bundle memory bundleData = AuctionTypes.Bundle({
            auctionId: auctionId,
            commitHash: proxy2CommitHash, // Using proxy2's commit hash
            value: 1000 * 10**18,
            quantities: quantities,
            timestamp: block.timestamp
        });
        
        // Try to submit bundle with wrong commit hash - should fail
        // proxy1 is committed but not to proxy2CommitHash
        vm.prank(proxy1);
        vm.expectRevert();
        cpaManager.submitBundle(auctionId, proxy2CommitHash, bundleData);
    }
    
    function test_BundleExists_CheckFunction() public {
        // Create bundle data
        uint256[] memory quantities = new uint256[](2);
        quantities[0] = 100 * 10**18;
        quantities[1] = 50 * 10**18;
        
        BundleId bundleId = BundleIdLibrary.createId(commitHash, keccak256(abi.encode(quantities)));
        
        // Initially bundle should not exist
        (
            AuctionId returnedAuctionId1, 
            bytes32 returnedCommitHash1, 
            BundleId returnedBundleId1, 
            uint256[] memory returnedQuantities1, 
            uint256 returnedValue1, 
            uint256 returnedTimestamp1
        ) = cpaManager.getBundle(auctionId, bundleId);
        assertEq(returnedCommitHash1, bytes32(0), "Bundle should not exist initially");
        
        // Create and submit bundle
        AuctionTypes.Bundle memory bundleData = AuctionTypes.Bundle({
            auctionId: auctionId,
            commitHash: commitHash,
            value: 1000 * 10**18,
            quantities: quantities,
            timestamp: block.timestamp
        });
        
        // Submit bundle (proxy commitment already set up in setUp)
        vm.prank(proxy1);
        cpaManager.submitBundle(auctionId, commitHash, bundleData);
        
        // Now bundle should exist
        (
            AuctionId returnedAuctionId2, 
            bytes32 returnedCommitHash2, 
            BundleId returnedBundleId2, 
            uint256[] memory returnedQuantities2, 
            uint256 returnedValue2, 
            uint256 returnedTimestamp2
        ) = cpaManager.getBundle(auctionId, bundleId);
        assertTrue(returnedCommitHash2 != bytes32(0), "Bundle should exist after submission");
        assertEq(returnedCommitHash2, commitHash, "Bundle commit hash should match");
    }
    
    function test_SubmitBundle_EventEmission() public {
        // Create bundle data
        uint256[] memory quantities = new uint256[](2);
        quantities[0] = 100 * 10**18;
        quantities[1] = 50 * 10**18;
        
        AuctionTypes.Bundle memory bundleData = AuctionTypes.Bundle({
            auctionId: auctionId,
            commitHash: commitHash,
            value: 1000 * 10**18,
            quantities: quantities,
            timestamp: block.timestamp
        });
        
        // Generate bundleId for testing
        BundleId expectedBundleId = BundleIdLibrary.createId(commitHash, keccak256(abi.encode(quantities)));
        
        // Expect BundleSubmitted event
        vm.expectEmit(true, true, true, true);
        emit IErrorsAndEvents.BundleSubmitted(auctionId, commitHash, expectedBundleId, quantities, bundleData.value);
        
        // Submit bundle (proxy commitment already set up in setUp)
        vm.prank(proxy1);
        cpaManager.submitBundle(auctionId, commitHash, bundleData);
    }
    
    // ========================================
    // EDGE CASE TESTS
    // ========================================
    
    function test_SubmitBundle_ZeroQuantities() public {
        // Create bundle with zero quantities
        uint256[] memory quantities = new uint256[](2);
        quantities[0] = 0;
        quantities[1] = 0;
        
        AuctionTypes.Bundle memory bundleData = AuctionTypes.Bundle({
            auctionId: auctionId,
            commitHash: commitHash,
            value: 0,
            quantities: quantities,
            timestamp: block.timestamp
        });
        
        // Should fail with zero quantities (no demand)
        vm.prank(proxy1);
        vm.expectRevert();
        cpaManager.submitBundle(auctionId, commitHash, bundleData);
    }
    
    function test_SubmitBundle_MixedZeroQuantities() public {
        // Create bundle with mixed zero and non-zero quantities
        uint256[] memory quantities = new uint256[](2);
        quantities[0] = 0;        // Zero quantity
        quantities[1] = 50 * 10**18;  // Non-zero quantity
        
        AuctionTypes.Bundle memory bundleData = AuctionTypes.Bundle({
            auctionId: auctionId,
            commitHash: commitHash,
            value: 1000 * 10**18,
            quantities: quantities,
            timestamp: block.timestamp
        });
        
        // Should succeed with mixed quantities (has some demand)
        vm.prank(proxy1);
        cpaManager.submitBundle(auctionId, commitHash, bundleData);
        
        // Verify bundle was stored
        BundleId bundleId = BundleIdLibrary.createId(commitHash, keccak256(abi.encode(quantities)));
        (,,, uint256[] memory returnedQuantities,,) = cpaManager.getBundle(auctionId, bundleId);
        assertEq(returnedQuantities[0], 0, "First quantity should be zero");
        assertEq(returnedQuantities[1], 50 * 10**18, "Second quantity should be non-zero");
    }
    
    function test_SubmitBundle_MaxUint256Quantities() public {
        // Create bundle with max uint256 quantities
        uint256[] memory quantities = new uint256[](2);
        quantities[0] = type(uint256).max;
        quantities[1] = type(uint256).max;
        
        AuctionTypes.Bundle memory bundleData = AuctionTypes.Bundle({
            auctionId: auctionId,
            commitHash: commitHash,
            value: type(uint256).max,
            quantities: quantities,
            timestamp: block.timestamp
        });
        
        // Should succeed with max quantities
        vm.prank(proxy1);
        cpaManager.submitBundle(auctionId, commitHash, bundleData);
        
        // Verify bundle was stored
        BundleId bundleId = BundleIdLibrary.createId(commitHash, keccak256(abi.encode(quantities)));
        (,,, uint256[] memory returnedQuantities,,) = cpaManager.getBundle(auctionId, bundleId);
        assertEq(returnedQuantities[0], type(uint256).max, "First quantity should be max");
        assertEq(returnedQuantities[1], type(uint256).max, "Second quantity should be max");
    }
    
    function test_SubmitBundle_EmptyQuantitiesArray() public {
        // Create bundle with empty quantities array
        uint256[] memory quantities = new uint256[](0);
        
        AuctionTypes.Bundle memory bundleData = AuctionTypes.Bundle({
            auctionId: auctionId,
            commitHash: commitHash,
            value: 1000 * 10**18,
            quantities: quantities,
            timestamp: block.timestamp
        });
        
        // Should fail with empty quantities array
        vm.prank(proxy1);
        vm.expectRevert();
        cpaManager.submitBundle(auctionId, commitHash, bundleData);
    }
    
    function test_SubmitBundle_InvalidAuctionId() public {
        // Create bundle with invalid auction ID
        uint256[] memory quantities = new uint256[](2);
        quantities[0] = 100 * 10**18;
        quantities[1] = 50 * 10**18;
        
        AuctionId invalidAuctionId = AuctionId.wrap(keccak256("invalidAuctionId"));
        
        AuctionTypes.Bundle memory bundleData = AuctionTypes.Bundle({
            auctionId: invalidAuctionId,
            commitHash: commitHash,
            value: 1000 * 10**18,
            quantities: quantities,
            timestamp: block.timestamp
        });
        
        // Should fail with invalid auction ID
        vm.prank(proxy1);
        vm.expectRevert();
        cpaManager.submitBundle(invalidAuctionId, commitHash, bundleData);
    }
    
    function test_SubmitBundle_WrongAuctionIdInBundle() public {
        // Create bundle with wrong auction ID in bundle data
        uint256[] memory quantities = new uint256[](2);
        quantities[0] = 100 * 10**18;
        quantities[1] = 50 * 10**18;
        
        AuctionId wrongAuctionId = AuctionId.wrap(keccak256("wrongAuctionId"));
        
        AuctionTypes.Bundle memory bundleData = AuctionTypes.Bundle({
            auctionId: wrongAuctionId, // Wrong auction ID in bundle
            commitHash: commitHash,
            value: 1000 * 10**18,
            quantities: quantities,
            timestamp: block.timestamp
        });
        
        // Should fail because auction ID in bundle doesn't match function parameter
        vm.prank(proxy1);
        vm.expectRevert();
        cpaManager.submitBundle(auctionId, commitHash, bundleData);
    }
    
    function test_SubmitBundle_CommitHashMismatch() public {
        // Create bundle with commit hash that doesn't match the one in bundle data
        uint256[] memory quantities = new uint256[](2);
        quantities[0] = 100 * 10**18;
        quantities[1] = 50 * 10**18;
        
        bytes32 differentCommitHash = keccak256("differentCommitHash");
        
        AuctionTypes.Bundle memory bundleData = AuctionTypes.Bundle({
            auctionId: auctionId,
            commitHash: commitHash, // Different from function parameter
            value: 1000 * 10**18,
            quantities: quantities,
            timestamp: block.timestamp
        });
        
        // Should fail because commit hash doesn't match
        vm.prank(proxy1);
        vm.expectRevert();
        cpaManager.submitBundle(auctionId, differentCommitHash, bundleData);
    }
    
    function test_SubmitBundle_ZeroValue() public {
        // Create bundle with zero value
        uint256[] memory quantities = new uint256[](2);
        quantities[0] = 100 * 10**18;
        quantities[1] = 50 * 10**18;
        
        AuctionTypes.Bundle memory bundleData = AuctionTypes.Bundle({
            auctionId: auctionId,
            commitHash: commitHash,
            value: 0,
            quantities: quantities,
            timestamp: block.timestamp
        });
        
        // Should succeed with zero value
        vm.prank(proxy1);
        cpaManager.submitBundle(auctionId, commitHash, bundleData);
        
        // Verify bundle was stored with zero value
        BundleId bundleId = BundleIdLibrary.createId(commitHash, keccak256(abi.encode(quantities)));
        (,,,, uint256 returnedValue,) = cpaManager.getBundle(auctionId, bundleId);
        assertEq(returnedValue, 0, "Bundle value should be zero");
    }
    
    function test_SubmitBundle_MaxTimestamp() public {
        // Create bundle with max timestamp
        uint256[] memory quantities = new uint256[](2);
        quantities[0] = 100 * 10**18;
        quantities[1] = 50 * 10**18;
        
        AuctionTypes.Bundle memory bundleData = AuctionTypes.Bundle({
            auctionId: auctionId,
            commitHash: commitHash,
            value: 1000 * 10**18,
            quantities: quantities,
            timestamp: type(uint256).max
        });
        
        // Should succeed with max timestamp
        vm.prank(proxy1);
        cpaManager.submitBundle(auctionId, commitHash, bundleData);
        
        // Verify bundle was stored with max timestamp
        BundleId bundleId = BundleIdLibrary.createId(commitHash, keccak256(abi.encode(quantities)));
        (,,,,, uint256 returnedTimestamp) = cpaManager.getBundle(auctionId, bundleId);
        assertEq(returnedTimestamp, type(uint256).max, "Bundle timestamp should be max");
    }
    
    function test_SubmitBundle_MultipleBundlesSameProxy() public {
        // Test submitting multiple bundles from the same proxy
        uint256[] memory quantities1 = new uint256[](2);
        quantities1[0] = 100 * 10**18;
        quantities1[1] = 50 * 10**18;
        
        uint256[] memory quantities2 = new uint256[](2);
        quantities2[0] = 200 * 10**18;
        quantities2[1] = 75 * 10**18;
        
        AuctionTypes.Bundle memory bundleData1 = AuctionTypes.Bundle({
            auctionId: auctionId,
            commitHash: commitHash,
            value: 1000 * 10**18,
            quantities: quantities1,
            timestamp: block.timestamp
        });
        
        AuctionTypes.Bundle memory bundleData2 = AuctionTypes.Bundle({
            auctionId: auctionId,
            commitHash: commitHash,
            value: 2000 * 10**18,
            quantities: quantities2,
            timestamp: block.timestamp + 1
        });
        
        // Submit first bundle
        vm.prank(proxy1);
        cpaManager.submitBundle(auctionId, commitHash, bundleData1);
        
        // Submit second bundle - should succeed
        vm.prank(proxy1);
        cpaManager.submitBundle(auctionId, commitHash, bundleData2);
        
        // Verify both bundles exist
        BundleId bundleId1 = BundleIdLibrary.createId(commitHash, keccak256(abi.encode(quantities1)));
        BundleId bundleId2 = BundleIdLibrary.createId(commitHash, keccak256(abi.encode(quantities2)));
        
        (,,, uint256[] memory returnedQuantities1,,) = cpaManager.getBundle(auctionId, bundleId1);
        (,,, uint256[] memory returnedQuantities2,,) = cpaManager.getBundle(auctionId, bundleId2);
        
        assertEq(returnedQuantities1[0], quantities1[0], "First bundle quantities should match");
        assertEq(returnedQuantities2[0], quantities2[0], "Second bundle quantities should match");
    }
    
    function test_SubmitBundle_DifferentProxiesSameCommitHash() public {
        // Test that different proxies cannot submit bundles for the same commit hash
        uint256[] memory quantities = new uint256[](2);
        quantities[0] = 100 * 10**18;
        quantities[1] = 50 * 10**18;
        
        AuctionTypes.Bundle memory bundleData = AuctionTypes.Bundle({
            auctionId: auctionId,
            commitHash: commitHash,
            value: 1000 * 10**18,
            quantities: quantities,
            timestamp: block.timestamp
        });
        
        // proxy1 submits bundle successfully
        vm.prank(proxy1);
        cpaManager.submitBundle(auctionId, commitHash, bundleData);
        
        // proxy2 tries to submit bundle for same commit hash - should fail
        vm.prank(proxy2);
        vm.expectRevert();
        cpaManager.submitBundle(auctionId, commitHash, bundleData);
    }
    
    function test_SubmitBundle_NonExistentCommitHash() public {
        // Test submitting bundle for a commit hash that was never committed
        uint256[] memory quantities = new uint256[](2);
        quantities[0] = 100 * 10**18;
        quantities[1] = 50 * 10**18;
        
        bytes32 nonExistentCommitHash = keccak256("nonExistentCommitHash");
        
        AuctionTypes.Bundle memory bundleData = AuctionTypes.Bundle({
            auctionId: auctionId,
            commitHash: nonExistentCommitHash,
            value: 1000 * 10**18,
            quantities: quantities,
            timestamp: block.timestamp
        });
        
        // Should fail because commit hash was never committed
        vm.prank(proxy1);
        vm.expectRevert();
        cpaManager.submitBundle(auctionId, nonExistentCommitHash, bundleData);
    }
    
    function test_SubmitAllocation_RejectedInProxyPhase() public {
        // Test that allocation submission is rejected during Proxy phase
        address testAllocator = makeAddr("testAllocator");
        
        // Create a test allocation
        AuctionTypes.Allocation memory testAllocation = AuctionTypes.Allocation({
            auctionId: auctionId,
            allocator: testAllocator,
            bundleIds: new BundleId[](0), // Empty bundle array
            totalValue: 1000 * 10**18,
            timestamp: block.timestamp
        });
        
        // Should fail with InvalidPhase error (Proxy phase, not Allocation phase)
        vm.prank(testAllocator);
        vm.expectRevert(abi.encodeWithSelector(IErrorsAndEvents.InvalidPhase.selector, AuctionTypes.AuctionPhase.Allocation, AuctionTypes.AuctionPhase.Proxy));
        cpaManager.submitAllocation(auctionId, testAllocation);
    }
}
