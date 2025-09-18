// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { Test, console2 } from "forge-std/Test.sol";
import { PoolHook } from "../src/PoolHook.sol";
import { CPAManager } from "../src/CPAManager.sol";
import { AuctionTypes } from "../src/types/AuctionTypes.sol";
import { AuctionId } from "../src/types/AuctionId.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { Currency, CurrencyLibrary } from "@uniswap/v4-core/src/types/Currency.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { Hooks } from "@uniswap/v4-core/src/libraries/Hooks.sol";
import { HookMiner } from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { CPATestBase } from "./base/CPATestBase.sol";
import { SwapParams, ModifyLiquidityParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";
import { Constants } from "../lib/uniswap-hooks/lib/v4-core/test/utils/Constants.sol";
import { MockERC20 } from "solmate/src/test/utils/mocks/MockERC20.sol";
import { IERC6909Claims } from "@uniswap/v4-core/src/interfaces/external/IERC6909Claims.sol";

contract CPASetupPhaseTest is CPATestBase {
    using PoolIdLibrary for PoolKey;
	using CurrencyLibrary for Currency;

    // Test pool key and ID for basic tests
    PoolKey public testPoolKey;
    PoolId public testPoolId;

    // CPATestBase handles all setup, so we can override if needed
    function setUp() public override {
        super.setUp();
        
        // Use CPATestBase's pool keys for testing
        testPoolKey = asset1PoolKey;
        testPoolId = testPoolKey.toId();
    }


	// ============ CreateAuction Tests ============

	function test_CreateAuction_Success() public {
		// Use CPATestBase's standard auction configuration
		AuctionTypes.AuctionConfig memory config = createStandardAuctionConfig();

		// Create auction using CPATestBase's protocolOwner
		vm.prank(protocolOwner);
		AuctionId auctionId = cpaManager.createAuction(config, protocolOwner);

		// Verify auction was created
		assertTrue(AuctionId.unwrap(auctionId) != 0);

		// ============ Verify Auction Info Struct ============
		// Check that auctionInfo is properly populated
		AuctionTypes.AuctionInfo memory auctionInfo = cpaManager.getAuctionInfo(auctionId);
		
		assertEq(auctionInfo.auctionOwner, protocolOwner, "Auction owner should be the protocol owner");
		assertEq(auctionInfo.commonNumeraire, address(numeraireToken), "Common numeraire should be the numeraire token");
		assertEq(uint8(auctionInfo.currentPhase), uint8(AuctionTypes.AuctionPhase.Setup), "Auction should start in Setup phase");
		assertEq(uint8(auctionInfo.currentStatus), uint8(AuctionTypes.AuctionStatus.Active), "Auction should be Active");
		assertEq(auctionInfo.clockOpen, 1, "Clock should not be open initially");
		assertEq(auctionInfo.currentRound, 0, "Current round should be 0");
		assertEq(auctionInfo.poolKeys.length, 2, "Should have 2 asset pools");
		
		// Verify the pool keys in auctionInfo match CPATestBase's pool keys
		assertEq(Currency.unwrap(auctionInfo.poolKeys[0].currency0), Currency.unwrap(asset1PoolKey.currency0), "Asset1 pool currency0 should match");
		assertEq(Currency.unwrap(auctionInfo.poolKeys[0].currency1), Currency.unwrap(asset1PoolKey.currency1), "Asset1 pool currency1 should match");
		assertEq(Currency.unwrap(auctionInfo.poolKeys[1].currency0), Currency.unwrap(asset2PoolKey.currency0), "Asset2 pool currency0 should match");
		assertEq(Currency.unwrap(auctionInfo.poolKeys[1].currency1), Currency.unwrap(asset2PoolKey.currency1), "Asset2 pool currency1 should match");
		
		// ============ Verify Pool Info Structs ============
		// Check that poolInfo is properly populated for each pool
		PoolId pool1Id = asset1PoolKey.toId();
		PoolId pool2Id = asset2PoolKey.toId();
		
		(
			PoolKey memory pool1Key,
			int24 pool1StartingTick,
			int24 pool1PriceIncrement,
			uint256 pool1DepositAmount,
			uint256 pool1ExcessDemand,
			AuctionId pool1AuctionId,
			bytes32 pool1PositionId
		) = cpaManager.getPoolInfo(pool1Id);
		
		(
			PoolKey memory pool2Key,
			int24 pool2StartingTick,
			int24 pool2PriceIncrement,
			uint256 pool2DepositAmount,
			uint256 pool2ExcessDemand,
			AuctionId pool2AuctionId,
			bytes32 pool2PositionId
		) = cpaManager.getPoolInfo(pool2Id);
		
		// No main pool verification needed since CPAManager is not a hook
		
		// Verify pool1 info
		assertEq(Currency.unwrap(pool1Key.currency0), Currency.unwrap(asset1PoolKey.currency0), "Pool1 currency0 should match");
		assertEq(Currency.unwrap(pool1Key.currency1), Currency.unwrap(asset1PoolKey.currency1), "Pool1 currency1 should match");
		assertEq(pool1Key.fee, asset1PoolKey.fee, "Pool1 fee should match");
		assertEq(pool1Key.tickSpacing, asset1PoolKey.tickSpacing, "Pool1 tickSpacing should match");
		assertEq(address(pool1Key.hooks), address(asset1PoolKey.hooks), "Pool1 hooks should match");
		assertEq(pool1StartingTick, 0, "Pool1 starting tick should be 0 for price = 1");
		assertEq(pool1PriceIncrement, 600, "Pool1 price increment should be 600 ticks (tickSpacing * 10)");
		assertEq(pool1DepositAmount, 0, "Pool1 deposit amount should be 0 initially");
		assertEq(pool1ExcessDemand, 0, "Pool1 excess demand should be 0 initially");
		assertTrue(AuctionId.unwrap(pool1AuctionId) == AuctionId.unwrap(auctionId), "Pool1 should reference the correct auction");
		assertEq(pool1PositionId, bytes32(0), "Pool1 position id should be 0 initially");
		
		// Verify pool2 info
		assertEq(Currency.unwrap(pool2Key.currency0), Currency.unwrap(asset2PoolKey.currency0), "Pool2 currency0 should match");
		assertEq(Currency.unwrap(pool2Key.currency1), Currency.unwrap(asset2PoolKey.currency1), "Pool2 currency1 should match");
		assertEq(pool2Key.fee, asset2PoolKey.fee, "Pool2 fee should match");
		assertEq(pool2Key.tickSpacing, asset2PoolKey.tickSpacing, "Pool2 tickSpacing should match");
		assertEq(address(pool2Key.hooks), address(asset2PoolKey.hooks), "Pool2 hooks should match");
		assertEq(pool2StartingTick, 6931, "Pool2 starting tick should be 6931 for price = 2");
		assertEq(pool2PriceIncrement, 300, "Pool2 price increment should be 300 ticks (tickSpacing * 5)");
		assertEq(pool2DepositAmount, 0, "Pool2 deposit amount should be 0 initially");
		assertEq(pool2ExcessDemand, 0, "Pool2 excess demand should be 0 initially");
		assertTrue(AuctionId.unwrap(pool2AuctionId) == AuctionId.unwrap(auctionId), "Pool2 should reference the correct auction");
		assertEq(pool2PositionId, bytes32(0), "Pool2 position id should be 0 initially");
		
		// ============ Verify Pool to Auction ID Mapping ============
		// Check that poolToAuctionId mapping is correct
		AuctionId pool1AuctionIdMapping = cpaManager.poolToAuctionId(pool1Id);
		AuctionId pool2AuctionIdMapping = cpaManager.poolToAuctionId(pool2Id);
		
		assertTrue(AuctionId.unwrap(pool1AuctionIdMapping) == AuctionId.unwrap(auctionId), "Pool1 should map to the correct auction ID");
		assertTrue(AuctionId.unwrap(pool2AuctionIdMapping) == AuctionId.unwrap(auctionId), "Pool2 should map to the correct auction ID");
		
		// ============ Verify Auction Config ============
		// We can't directly access the config struct from auctionInfo, but we can verify
		// that the commonNumeraire matches what we expect
		assertEq(auctionInfo.commonNumeraire, address(numeraireToken), "Common numeraire in auctionInfo should match config");
		

	}

	function test_CreateAuction_WithRealTokens() public {
		// Use CPATestBase's tokens and accounts
		// Mint asset tokens to the auctioneer
		uint256 tokenAmount = 1000000 * 10**18; // 1M tokens
		asset1Token.mint(auctioneer, tokenAmount);
		asset2Token.mint(auctioneer, tokenAmount);
		
		// Numeraire token exists but is not minted to anyone (bidders will own it)
		// Protocol owner doesn't own any tokens initially
		
		// Verify initial state before creating pools
		assertEq(asset1Token.balanceOf(auctioneer), tokenAmount, "Auctioneer should own asset1 tokens");
		assertEq(asset2Token.balanceOf(auctioneer), tokenAmount, "Auctioneer should own asset2 tokens");
		assertEq(asset1Token.balanceOf(protocolOwner), 0, "Protocol owner should not own asset1 tokens");
		assertEq(asset2Token.balanceOf(protocolOwner), 0, "Protocol owner should not own asset2 tokens");
		assertEq(numeraireToken.balanceOf(auctioneer), 0, "Auctioneer should not own numeraire tokens");
		assertEq(numeraireToken.balanceOf(protocolOwner), 0, "Protocol owner should not own numeraire tokens");
		assertEq(numeraireToken.balanceOf(address(cpaManager)), 0, "CPAManager should start with no tokens");
		
		// Use CPATestBase's standard auction configuration
		AuctionTypes.AuctionConfig memory config = createStandardAuctionConfig();
	
		// Create auction (auctioneer creates it, not protocol owner)
		vm.prank(auctioneer);
		AuctionId auctionId = cpaManager.createAuction(config, auctioneer);
	
		// Verify auction was created
		assertTrue(AuctionId.unwrap(auctionId) != 0);
		
		// Verify token balances are still as expected after pool creation
		assertEq(asset1Token.balanceOf(auctioneer), tokenAmount, "Auctioneer should still own asset1 tokens after pool creation");
		assertEq(asset2Token.balanceOf(auctioneer), tokenAmount, "Auctioneer should still own asset2 tokens after pool creation");
		assertEq(asset1Token.balanceOf(protocolOwner), 0, "Protocol owner should still not own asset1 tokens");
		assertEq(asset2Token.balanceOf(protocolOwner), 0, "Protocol owner should still not own asset2 tokens");
		assertEq(numeraireToken.balanceOf(auctioneer), 0, "Auctioneer should still not own numeraire tokens");
		assertEq(numeraireToken.balanceOf(protocolOwner), 0, "Protocol owner should still not own numeraire tokens");
		assertEq(numeraireToken.balanceOf(address(cpaManager)), 0, "CPAManagerHook should still have no tokens");
		
		// ============ Verify Auction Info Struct ============
		// Check that auctionInfo is properly populated
		AuctionTypes.AuctionInfo memory auctionInfo2 = cpaManager.getAuctionInfo(auctionId);
		
		assertEq(auctionInfo2.auctionOwner, auctioneer, "Auction owner should be the auctioneer");
		assertEq(auctionInfo2.commonNumeraire, address(numeraireToken), "Common numeraire should be the numeraire token");
		assertEq(uint8(auctionInfo2.currentPhase), uint8(AuctionTypes.AuctionPhase.Setup), "Auction should start in Setup phase");
		assertEq(uint8(auctionInfo2.currentStatus), uint8(AuctionTypes.AuctionStatus.Active), "Auction should be Active");
		assertEq(auctionInfo2.clockOpen, 1, "Clock should not be open initially");
		assertEq(auctionInfo2.currentRound, 0, "Current round should be 0");
		assertEq(auctionInfo2.poolKeys.length, 2, "Should have 2 asset pools");
		
		// Verify the pool keys in auctionInfo match CPATestBase's pool keys
		assertEq(Currency.unwrap(auctionInfo2.poolKeys[0].currency0), Currency.unwrap(asset1PoolKey.currency0), "First pool currency0 should match");
		assertEq(Currency.unwrap(auctionInfo2.poolKeys[0].currency1), Currency.unwrap(asset1PoolKey.currency1), "First pool currency1 should match");
		assertEq(Currency.unwrap(auctionInfo2.poolKeys[1].currency0), Currency.unwrap(asset2PoolKey.currency0), "Second pool currency0 should match");
		assertEq(Currency.unwrap(auctionInfo2.poolKeys[1].currency1), Currency.unwrap(asset2PoolKey.currency1), "Second pool currency1 should match");
		
		// ============ Verify Pool Info Structs ============
		// Check that poolInfo is properly populated for each asset pool
		PoolId pool1Id = asset1PoolKey.toId();
		PoolId pool2Id = asset2PoolKey.toId();
		
		(
			PoolKey memory pool1Key,
			int24 pool1StartingTick,
			int24 pool1PriceIncrement,
			uint256 pool1DepositAmount,
			uint256 pool1ExcessDemand,
			AuctionId pool1AuctionId,
			bytes32 pool1PositionId
		) = cpaManager.getPoolInfo(pool1Id);
		
		(
			PoolKey memory pool2Key,
			int24 pool2StartingTick,
			int24 pool2PriceIncrement,
			uint256 pool2DepositAmount,
			uint256 pool2ExcessDemand,
			AuctionId pool2AuctionId,
			bytes32 pool2PositionId
		) = cpaManager.getPoolInfo(pool2Id);
		
		// Verify pool1 info
		assertEq(Currency.unwrap(pool1Key.currency0), Currency.unwrap(asset1PoolKey.currency0), "Pool1 currency0 should match");
		assertEq(Currency.unwrap(pool1Key.currency1), Currency.unwrap(asset1PoolKey.currency1), "Pool1 currency1 should match");
		assertEq(pool1Key.fee, asset1PoolKey.fee, "Pool1 fee should match");
		assertEq(pool1Key.tickSpacing, asset1PoolKey.tickSpacing, "Pool1 tickSpacing should match");
		assertEq(address(pool1Key.hooks), address(asset1PoolKey.hooks), "Pool1 hooks should match");
		assertEq(pool1StartingTick, 0, "Pool1 starting tick should be 0 for price = 1");
		assertEq(pool1PriceIncrement, 600, "Pool1 price increment should be 600 ticks (tickSpacing * 10)");
		assertEq(pool1DepositAmount, 0, "Pool1 deposit amount should be 0 initially");
		assertEq(pool1ExcessDemand, 0, "Pool1 excess demand should be 0 initially");
		assertTrue(AuctionId.unwrap(pool1AuctionId) == AuctionId.unwrap(auctionId), "Pool1 should reference the correct auction");
		
		// Verify pool2 info
		assertEq(Currency.unwrap(pool2Key.currency0), Currency.unwrap(asset2PoolKey.currency0), "Pool2 currency0 should match");
		assertEq(Currency.unwrap(pool2Key.currency1), Currency.unwrap(asset2PoolKey.currency1), "Pool2 currency1 should match");
		assertEq(pool2Key.fee, asset2PoolKey.fee, "Pool2 fee should match");
		assertEq(pool2Key.tickSpacing, asset2PoolKey.tickSpacing, "Pool2 tickSpacing should match");
		assertEq(address(pool2Key.hooks), address(asset2PoolKey.hooks), "Pool2 hooks should match");
		assertEq(pool2StartingTick, 6931, "Pool2 starting tick should be 6931 for price = 2");
		assertEq(pool2PriceIncrement, 300, "Pool2 price increment should be 300 ticks (tickSpacing * 5)");
		assertEq(pool2DepositAmount, 0, "Pool2 deposit amount should be 0 initially");
		assertEq(pool2ExcessDemand, 0, "Pool2 excess demand should be 0 initially");
		assertTrue(AuctionId.unwrap(pool2AuctionId) == AuctionId.unwrap(auctionId), "Pool2 should reference the correct auction");
		
		// ============ Verify Pool to Auction ID Mapping ============
		// Check that poolToAuctionId mapping is correct
		AuctionId pool1AuctionIdMapping = cpaManager.poolToAuctionId(pool1Id);
		AuctionId pool2AuctionIdMapping = cpaManager.poolToAuctionId(pool2Id);
		
		assertTrue(AuctionId.unwrap(pool1AuctionIdMapping) == AuctionId.unwrap(auctionId), "Pool1 should map to the correct auction ID");
		assertTrue(AuctionId.unwrap(pool2AuctionIdMapping) == AuctionId.unwrap(auctionId), "Pool2 should map to the correct auction ID");
		
		// ============ Verify Auction Config ============
		// We can't directly access the config struct from auctionInfo, but we can verify
		// that the commonNumeraire matches what we expect
		assertEq(auctionInfo2.commonNumeraire, address(numeraireToken), "Common numeraire in auctionInfo should match config");
		
		// Test that the auction manager can actually move tokens
		// This will be important for testing the deposit and settlement functionality
		assertTrue(true, "Auction created with real tokens successfully");
		
		// TODO: Next step will be testing CPAClockPhase.moveDeposit to move tokens from auctioneer to pools with price increments
	}

	function test_DepositFunctionality_WithRealTokens() public {
		// Use CPATestBase's tokens and accounts
		// Mint asset tokens to the auctioneer
		uint256 tokenAmount = 1000000 * 10**18; // 1M tokens
		asset1Token.mint(auctioneer, tokenAmount);
		asset2Token.mint(auctioneer, tokenAmount);
		
		// Verify initial state
		assertEq(asset1Token.balanceOf(auctioneer), tokenAmount, "Auctioneer should own asset1 tokens initially");
		assertEq(asset2Token.balanceOf(auctioneer), tokenAmount, "Auctioneer should own asset2 tokens initially");
		assertEq(asset1Token.balanceOf(address(poolManager)), 0, "PoolManager should start with no asset1 tokens");
		assertEq(asset2Token.balanceOf(address(poolManager)), 0, "PoolManager should start with no asset2 tokens");
		// Note: ERC6909 balance checking requires proper interface casting - skipping for now
		
		// Use CPATestBase's standard auction configuration
		AuctionTypes.AuctionConfig memory config = createStandardAuctionConfig();
	
		// Create auction (auctioneer creates it)
		vm.prank(auctioneer);
		AuctionId auctionId = cpaManager.createAuction(config, auctioneer);
	
		// Verify auction was created
		assertTrue(AuctionId.unwrap(auctionId) != 0);
		
		// ============ Test Deposit Functionality ============
		// Now test that the auctioneer can move tokens to the pools via the auction manager
		
        
		// Get pool IDs for the asset pools
		PoolId pool1Id = asset1PoolKey.toId();
		PoolId pool2Id = asset2PoolKey.toId();
		
		// Define deposit amounts
		uint256 depositAmount1 = 100000 * asset1Token.decimals(); // 100K asset1 tokens
		uint256 depositAmount2 = 150000 * asset2Token.decimals(); // 150K asset2 tokens
		
		// Approve the CPAManagerHook to spend the auctioneer's tokens
		vm.prank(auctioneer);
		asset1Token.approve(address(cpaManager), depositAmount1);
		vm.prank(auctioneer);
		asset2Token.approve(address(cpaManager), depositAmount2);
		
		// Verify approvals were set
		assertEq(asset1Token.allowance(auctioneer, address(cpaManager)), depositAmount1, "Asset1 approval should be set");
		assertEq(asset2Token.allowance(auctioneer, address(cpaManager)), depositAmount2, "Asset2 approval should be set");
		
		// Test moving deposits to pool 1
		vm.prank(auctioneer);
		cpaManager.moveDeposit(auctionId, asset1PoolKey, depositAmount1);
		
		// Verify token movement
		assertEq(asset1Token.balanceOf(auctioneer), tokenAmount - depositAmount1, "Auctioneer should have reduced asset1 balance");
		assertEq(asset1Token.balanceOf(address(poolManager)), depositAmount1, "PoolManager should have received asset1 ERC20 tokens");
		assertEq(IERC6909Claims(address(poolManager)).balanceOf(address(cpaManager), Currency.wrap(address(asset1Token)).toId()), depositAmount1, "CPAHook should have received asset1 ERC6909 tokens");

		// Verify that pool info is updated
		(
			,
			,
			,
			uint256 pool1DepositAmountInPoolInfo,
			,
			AuctionId pool1AuctionIdInPoolInfo,
			
		) = cpaManager.poolInfo(pool1Id);
		
		assertEq(pool1DepositAmountInPoolInfo, depositAmount1, "Pool1 deposit amount should be updated");
		assertTrue(AuctionId.unwrap(pool1AuctionIdInPoolInfo) == AuctionId.unwrap(auctionId), "Pool1 should reference the correct auction");
		
		// Test moving deposits to pool 2
		vm.prank(auctioneer);
		cpaManager.moveDeposit(auctionId, asset2PoolKey, depositAmount2);
		
		// Verify token movement
		assertEq(asset2Token.balanceOf(auctioneer), tokenAmount - depositAmount2, "Auctioneer should have reduced asset2 balance");
		assertEq(asset2Token.balanceOf(address(poolManager)), depositAmount2, "PoolManager should have received asset2 ERC20 tokens");
		assertEq(IERC6909Claims(address(poolManager)).balanceOf(address(cpaManager), Currency.wrap(address(asset2Token)).toId()), depositAmount2, "CPAHook should have received asset2 ERC6909 tokens");
		
		// Verify pool info is updated
		(
			,
			,
			,
			uint256 pool2DepositAmountInPoolInfo,
			,
			AuctionId pool2AuctionIdInPoolInfo,
			
		) = cpaManager.poolInfo(pool2Id);
		
		assertEq(pool2DepositAmountInPoolInfo, depositAmount2, "Pool2 deposit amount should be updated");
		assertTrue(AuctionId.unwrap(pool2AuctionIdInPoolInfo) == AuctionId.unwrap(auctionId), "Pool2 should reference the correct auction");
		
		// Verify final state
		assertEq(asset1Token.balanceOf(auctioneer), tokenAmount - depositAmount1, "Final auctioneer asset1 balance should be correct");
		assertEq(asset2Token.balanceOf(auctioneer), tokenAmount - depositAmount2, "Final auctioneer asset2 balance should be correct");
		assertEq(asset1Token.balanceOf(address(poolManager)), depositAmount1, "Final PoolManager asset1 balance should be correct");
		assertEq(asset2Token.balanceOf(address(poolManager)), depositAmount2, "Final PoolManager asset2 balance should be correct");
		// Note: ERC6909 balance checking requires proper interface casting - skipping for now
		
		// Test that the auction manager can actually move tokens successfully
		assertTrue(true, "Deposit functionality working correctly - tokens moved from auctioneer to pools via auction manager");
	}
}
