// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { Test, console2 } from "forge-std/Test.sol";
import { CPAManager } from "../src/CPAManager.sol";
import { AuctionTypes } from "../src/types/AuctionTypes.sol";
import { AuctionId } from "../src/types/AuctionId.sol";
import { AssetId, AssetIdLibrary, AssetConfig } from "../src/types/AssetConfig.sol";
import { MockERC20 } from "solmate/src/test/utils/mocks/MockERC20.sol";
import { IErrorsAndEvents } from "../src/utils/IErrorsAndEvents.sol";
import { CPATestBase } from "./base/CPATestBase.sol";

contract CPASetupPhaseTest is CPATestBase {

	// ============ CreateAuction Tests ============

	function test_CreateAuction_Success() public {
		// Use CPATestBase's standard auction configuration
		AuctionTypes.AuctionConfig memory config = createStandardAuctionConfig();

		// Create auction using CPATestBase's protocolOwner
		AuctionId auctionId = createAuction(config, protocolOwner);

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
		assertEq(auctionInfo.assets.length, 2, "Should have 2 asset pools");

		// Verify the assets in auctionInfo
		assertEq(auctionInfo.assets[0].assetToken, address(asset1Token), "Asset1 token should match");
		assertEq(auctionInfo.assets[1].assetToken, address(asset2Token), "Asset2 token should match");

		// ============ Verify Asset Info Structs ============
		AssetId assetId1 = AssetIdLibrary.createId(auctionId, address(asset1Token));
		AssetId assetId2 = AssetIdLibrary.createId(auctionId, address(asset2Token));

		AuctionTypes.AssetInfo memory asset1Info = cpaManager.getAssetInfo(assetId1);
		AuctionTypes.AssetInfo memory asset2Info = cpaManager.getAssetInfo(assetId2);

		// Verify asset1 info
		assertEq(asset1Info.depositAmount, 0, "Asset1 deposit amount should be 0 initially");
		assertEq(asset1Info.excessDemand, 0, "Asset1 excess demand should be 0 initially");
		assertEq(asset1Info.currentPrice, asset1StartingPrice, "Asset1 starting price should match");
		assertTrue(AuctionId.unwrap(asset1Info.auctionId) == AuctionId.unwrap(auctionId), "Asset1 should reference the correct auction");

		// Verify asset2 info
		assertEq(asset2Info.depositAmount, 0, "Asset2 deposit amount should be 0 initially");
		assertEq(asset2Info.excessDemand, 0, "Asset2 excess demand should be 0 initially");
		assertEq(asset2Info.currentPrice, asset2StartingPrice, "Asset2 starting price should match");
		assertTrue(AuctionId.unwrap(asset2Info.auctionId) == AuctionId.unwrap(auctionId), "Asset2 should reference the correct auction");

		// ============ Verify Auction Config ============
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
		AuctionId auctionId = createAuction(config, auctioneer);

		// Verify auction was created
		assertTrue(AuctionId.unwrap(auctionId) != 0);

		// Verify token balances are still as expected after auction creation
		assertEq(asset1Token.balanceOf(auctioneer), tokenAmount, "Auctioneer should still own asset1 tokens after auction creation");
		assertEq(asset2Token.balanceOf(auctioneer), tokenAmount, "Auctioneer should still own asset2 tokens after auction creation");
		assertEq(asset1Token.balanceOf(protocolOwner), 0, "Protocol owner should still not own asset1 tokens");
		assertEq(asset2Token.balanceOf(protocolOwner), 0, "Protocol owner should still not own asset2 tokens");
		assertEq(numeraireToken.balanceOf(auctioneer), 0, "Auctioneer should still not own numeraire tokens");
		assertEq(numeraireToken.balanceOf(protocolOwner), 0, "Protocol owner should still not own numeraire tokens");
		assertEq(numeraireToken.balanceOf(address(cpaManager)), 0, "CPAManager should still have no tokens");

		// ============ Verify Auction Info Struct ============
		AuctionTypes.AuctionInfo memory auctionInfo2 = cpaManager.getAuctionInfo(auctionId);

		assertEq(auctionInfo2.auctionOwner, auctioneer, "Auction owner should be the auctioneer");
		assertEq(auctionInfo2.commonNumeraire, address(numeraireToken), "Common numeraire should be the numeraire token");
		assertEq(uint8(auctionInfo2.currentPhase), uint8(AuctionTypes.AuctionPhase.Setup), "Auction should start in Setup phase");
		assertEq(uint8(auctionInfo2.currentStatus), uint8(AuctionTypes.AuctionStatus.Active), "Auction should be Active");
		assertEq(auctionInfo2.clockOpen, 1, "Clock should not be open initially");
		assertEq(auctionInfo2.currentRound, 0, "Current round should be 0");
		assertEq(auctionInfo2.assets.length, 2, "Should have 2 assets");

		// Verify the assets in auctionInfo match CPATestBase's tokens
		assertEq(auctionInfo2.assets[0].assetToken, address(asset1Token), "First asset token should match");
		assertEq(auctionInfo2.assets[1].assetToken, address(asset2Token), "Second asset token should match");

		// ============ Verify Asset Info Structs ============
		AssetId assetId1 = AssetIdLibrary.createId(auctionId, address(asset1Token));
		AssetId assetId2 = AssetIdLibrary.createId(auctionId, address(asset2Token));

		AuctionTypes.AssetInfo memory asset1Info = cpaManager.getAssetInfo(assetId1);
		AuctionTypes.AssetInfo memory asset2Info = cpaManager.getAssetInfo(assetId2);

		// Verify asset1 info
		assertEq(asset1Info.depositAmount, 0, "Asset1 deposit amount should be 0 initially");
		assertEq(asset1Info.excessDemand, 0, "Asset1 excess demand should be 0 initially");
		assertEq(asset1Info.currentPrice, asset1StartingPrice, "Asset1 starting price should match");
		assertTrue(AuctionId.unwrap(asset1Info.auctionId) == AuctionId.unwrap(auctionId), "Asset1 should reference the correct auction");

		// Verify asset2 info
		assertEq(asset2Info.depositAmount, 0, "Asset2 deposit amount should be 0 initially");
		assertEq(asset2Info.excessDemand, 0, "Asset2 excess demand should be 0 initially");
		assertEq(asset2Info.currentPrice, asset2StartingPrice, "Asset2 starting price should match");
		assertTrue(AuctionId.unwrap(asset2Info.auctionId) == AuctionId.unwrap(auctionId), "Asset2 should reference the correct auction");

		// ============ Verify Auction Config ============
		assertEq(auctionInfo2.commonNumeraire, address(numeraireToken), "Common numeraire in auctionInfo should match config");

		assertTrue(true, "Auction created with real tokens successfully");
	}

	function test_DepositFunctionality_WithRealTokens() public {
		// Mint asset tokens to the auctioneer
		uint256 tokenAmount = 1000000 * 10**18; // 1M tokens
		asset1Token.mint(auctioneer, tokenAmount);
		asset2Token.mint(auctioneer, tokenAmount);

		// Verify initial state
		assertEq(asset1Token.balanceOf(auctioneer), tokenAmount, "Auctioneer should own asset1 tokens initially");
		assertEq(asset2Token.balanceOf(auctioneer), tokenAmount, "Auctioneer should own asset2 tokens initially");
		assertEq(asset1Token.balanceOf(address(cpaManager)), 0, "CPAManager should start with no asset1 tokens");
		assertEq(asset2Token.balanceOf(address(cpaManager)), 0, "CPAManager should start with no asset2 tokens");

		// Use CPATestBase's standard auction configuration
		AuctionTypes.AuctionConfig memory config = createStandardAuctionConfig();

		// Create auction (auctioneer creates it)
		AuctionId auctionId = createAuction(config, auctioneer);

		// Verify auction was created
		assertTrue(AuctionId.unwrap(auctionId) != 0);

		// ============ Test Deposit Functionality ============
		uint256 dep1 = 100000 * 10**18; // 100K asset1 tokens
		uint256 dep2 = 150000 * 10**18; // 150K asset2 tokens

		// Approve the CPAManager to spend the auctioneer's tokens
		vm.prank(auctioneer);
		asset1Token.approve(address(cpaManager), dep1);
		vm.prank(auctioneer);
		asset2Token.approve(address(cpaManager), dep2);

		// Verify approvals were set
		assertEq(asset1Token.allowance(auctioneer, address(cpaManager)), dep1, "Asset1 approval should be set");
		assertEq(asset2Token.allowance(auctioneer, address(cpaManager)), dep2, "Asset2 approval should be set");

		// Test moving deposits for asset1
		vm.prank(auctioneer);
		cpaManager.moveDeposit(auctionId, address(asset1Token), dep1);

		// Verify token movement
		assertEq(asset1Token.balanceOf(auctioneer), tokenAmount - dep1, "Auctioneer should have reduced asset1 balance");
		assertEq(asset1Token.balanceOf(address(cpaManager)), dep1, "CPAManager should have received asset1 tokens");

		// Verify that asset info is updated
		AssetId assetId1 = AssetIdLibrary.createId(auctionId, address(asset1Token));
		AuctionTypes.AssetInfo memory asset1Info = cpaManager.getAssetInfo(assetId1);
		assertEq(asset1Info.depositAmount, dep1, "Asset1 deposit amount should be updated");
		assertTrue(AuctionId.unwrap(asset1Info.auctionId) == AuctionId.unwrap(auctionId), "Asset1 should reference the correct auction");

		// Test moving deposits for asset2
		vm.prank(auctioneer);
		cpaManager.moveDeposit(auctionId, address(asset2Token), dep2);

		// Verify token movement
		assertEq(asset2Token.balanceOf(auctioneer), tokenAmount - dep2, "Auctioneer should have reduced asset2 balance");
		assertEq(asset2Token.balanceOf(address(cpaManager)), dep2, "CPAManager should have received asset2 tokens");

		// Verify asset2 info is updated
		AssetId assetId2 = AssetIdLibrary.createId(auctionId, address(asset2Token));
		AuctionTypes.AssetInfo memory asset2Info = cpaManager.getAssetInfo(assetId2);
		assertEq(asset2Info.depositAmount, dep2, "Asset2 deposit amount should be updated");
		assertTrue(AuctionId.unwrap(asset2Info.auctionId) == AuctionId.unwrap(auctionId), "Asset2 should reference the correct auction");

		// Verify final state
		assertEq(asset1Token.balanceOf(auctioneer), tokenAmount - dep1, "Final auctioneer asset1 balance should be correct");
		assertEq(asset2Token.balanceOf(auctioneer), tokenAmount - dep2, "Final auctioneer asset2 balance should be correct");
		assertEq(asset1Token.balanceOf(address(cpaManager)), dep1, "Final CPAManager asset1 balance should be correct");
		assertEq(asset2Token.balanceOf(address(cpaManager)), dep2, "Final CPAManager asset2 balance should be correct");

		assertTrue(true, "Deposit functionality working correctly - tokens moved from auctioneer to CPAManager");
	}

	// ============ startClockPhase() Tests ============

	function test_StartClockPhase_Success() public {
		// Create auction and deposit to all pools
		AuctionId auctionId = createAuction(createStandardAuctionConfig(), auctioneer);

		// Mint tokens to auctioneer
		uint256 tokenAmount = 100000 * 10**18;
		asset1Token.mint(auctioneer, tokenAmount);
		asset2Token.mint(auctioneer, tokenAmount);

		// Approve and deposit to both assets
		vm.prank(auctioneer);
		asset1Token.approve(address(cpaManager), tokenAmount);
		vm.prank(auctioneer);
		asset2Token.approve(address(cpaManager), tokenAmount);

		uint256 dep1 = 50000 * 10**18;
		uint256 dep2 = 60000 * 10**18;

		vm.prank(auctioneer);
		cpaManager.moveDeposit(auctionId, address(asset1Token), dep1);
		vm.prank(auctioneer);
		cpaManager.moveDeposit(auctionId, address(asset2Token), dep2);

		// Verify initial state
		AuctionTypes.AuctionInfo memory auctionInfo = cpaManager.getAuctionInfo(auctionId);
		assertEq(uint8(auctionInfo.currentPhase), uint8(AuctionTypes.AuctionPhase.Setup), "Should be in Setup phase");
		assertEq(auctionInfo.clockOpen, 1, "Clock should not be open initially");
		assertEq(auctionInfo.currentRound, 0, "Current round should be 0");

		// Start clock phase
		vm.prank(auctioneer);
		cpaManager.startClockPhase(auctionId);

		// Verify phase transition
		auctionInfo = cpaManager.getAuctionInfo(auctionId);
		assertEq(uint8(auctionInfo.currentPhase), uint8(AuctionTypes.AuctionPhase.Clock), "Should transition to Clock phase");
		assertEq(auctionInfo.clockOpen, 2, "Clock should be open after starting");
		assertEq(auctionInfo.currentRound, 1, "Current round should be initialized to 1");
	}

	function test_StartClockPhase_RevertNonOwner() public {
		// Create auction and deposit to all assets as auctioneer
		AuctionId auctionId = createAuction(createStandardAuctionConfig(), auctioneer);

		// Mint tokens and deposit
		uint256 tokenAmount = 100000 * 10**18;
		asset1Token.mint(auctioneer, tokenAmount);
		asset2Token.mint(auctioneer, tokenAmount);

		vm.prank(auctioneer);
		asset1Token.approve(address(cpaManager), tokenAmount);
		vm.prank(auctioneer);
		asset2Token.approve(address(cpaManager), tokenAmount);

		vm.prank(auctioneer);
		cpaManager.moveDeposit(auctionId, address(asset1Token), 50000 * 10**18);
		vm.prank(auctioneer);
		cpaManager.moveDeposit(auctionId, address(asset2Token), 60000 * 10**18);

		// Attempt to start clock phase as different address (bidder1)
		vm.expectRevert();
		vm.prank(bidder1);
		cpaManager.startClockPhase(auctionId);
	}

	function test_StartClockPhase_RevertWrongPhase() public {
		// Create auction, deposit, and start clock phase
		AuctionId auctionId = createAuction(createStandardAuctionConfig(), auctioneer);

		// Mint tokens and deposit
		uint256 tokenAmount = 100000 * 10**18;
		asset1Token.mint(auctioneer, tokenAmount);
		asset2Token.mint(auctioneer, tokenAmount);

		vm.prank(auctioneer);
		asset1Token.approve(address(cpaManager), tokenAmount);
		vm.prank(auctioneer);
		asset2Token.approve(address(cpaManager), tokenAmount);

		vm.prank(auctioneer);
		cpaManager.moveDeposit(auctionId, address(asset1Token), 50000 * 10**18);
		vm.prank(auctioneer);
		cpaManager.moveDeposit(auctionId, address(asset2Token), 60000 * 10**18);

		// Start clock phase
		vm.prank(auctioneer);
		cpaManager.startClockPhase(auctionId);

		// Verify we're in Clock phase
		AuctionTypes.AuctionInfo memory auctionInfo = cpaManager.getAuctionInfo(auctionId);
		assertEq(uint8(auctionInfo.currentPhase), uint8(AuctionTypes.AuctionPhase.Clock), "Should be in Clock phase");

		// Attempt to start clock phase again (already in Clock phase)
		vm.expectRevert(abi.encodeWithSelector(IErrorsAndEvents.InvalidPhase.selector, AuctionTypes.AuctionPhase.Setup, AuctionTypes.AuctionPhase.Clock));
		vm.prank(auctioneer);
		cpaManager.startClockPhase(auctionId);
	}

	function test_StartClockPhase_RevertSetupNotComplete() public {
		// Create auction
		AuctionId auctionId = createAuction(createStandardAuctionConfig(), auctioneer);

		// Deposit to only first asset, leave second asset at zero
		uint256 tokenAmount = 100000 * 10**18;
		asset1Token.mint(auctioneer, tokenAmount);
		asset2Token.mint(auctioneer, tokenAmount);

		vm.prank(auctioneer);
		asset1Token.approve(address(cpaManager), tokenAmount);
		vm.prank(auctioneer);
		asset2Token.approve(address(cpaManager), tokenAmount);

		// Only deposit to first asset
		vm.prank(auctioneer);
		cpaManager.moveDeposit(auctionId, address(asset1Token), 50000 * 10**18);
		// Intentionally skip second asset deposit

		// Attempt to start clock phase (setup not complete)
		vm.expectRevert();
		vm.prank(auctioneer);
		cpaManager.startClockPhase(auctionId);
	}

	// ============ moveDeposit() Error Tests ============

	function test_MoveDeposit_RevertNonOwner() public {
		// Create auction as auctioneer
		AuctionId auctionId = createAuction(createStandardAuctionConfig(), auctioneer);

		// Mint tokens to bidder1 and approve CPAManager
		uint256 tokenAmount = 100000 * 10**18;
		asset1Token.mint(bidder1, tokenAmount);
		vm.prank(bidder1);
		asset1Token.approve(address(cpaManager), tokenAmount);

		// Attempt moveDeposit() as bidder1 (non-owner)
		vm.expectRevert();
		vm.prank(bidder1);
		cpaManager.moveDeposit(auctionId, address(asset1Token), 50000 * 10**18);
	}

	function test_MoveDeposit_RevertWrongPhase() public {
		// Create auction and deposit to all assets
		AuctionId auctionId = createAuction(createStandardAuctionConfig(), auctioneer);

		// Mint tokens and deposit
		uint256 tokenAmount = 100000 * 10**18;
		asset1Token.mint(auctioneer, tokenAmount);
		asset2Token.mint(auctioneer, tokenAmount);

		vm.prank(auctioneer);
		asset1Token.approve(address(cpaManager), tokenAmount);
		vm.prank(auctioneer);
		asset2Token.approve(address(cpaManager), tokenAmount);

		vm.prank(auctioneer);
		cpaManager.moveDeposit(auctionId, address(asset1Token), 50000 * 10**18);
		vm.prank(auctioneer);
		cpaManager.moveDeposit(auctionId, address(asset2Token), 60000 * 10**18);

		// Start clock phase
		vm.prank(auctioneer);
		cpaManager.startClockPhase(auctionId);

		// Attempt to deposit again (in Clock phase)
		vm.expectRevert(abi.encodeWithSelector(IErrorsAndEvents.InvalidPhase.selector, AuctionTypes.AuctionPhase.Setup, AuctionTypes.AuctionPhase.Clock));
		vm.prank(auctioneer);
		cpaManager.moveDeposit(auctionId, address(asset1Token), 10000 * 10**18);
	}

	function test_MoveDeposit_RevertInsufficientBalance() public {
		// Create auction
		AuctionId auctionId = createAuction(createStandardAuctionConfig(), auctioneer);

		// Mint only 1000 tokens to auctioneer
		uint256 smallAmount = 1000 * 10**18;
		uint256 largeAmount = 100000 * 10**18;
		asset1Token.mint(auctioneer, smallAmount);

		// Approve CPAManager for large amount
		vm.prank(auctioneer);
		asset1Token.approve(address(cpaManager), largeAmount);

		// Attempt to deposit large amount (more than balance)
		vm.expectRevert();
		vm.prank(auctioneer);
		cpaManager.moveDeposit(auctionId, address(asset1Token), largeAmount);
	}

	function test_MoveDeposit_RevertInsufficientApproval() public {
		// Create auction
		AuctionId auctionId = createAuction(createStandardAuctionConfig(), auctioneer);

		// Mint large amount to auctioneer
		uint256 tokenAmount = 100000 * 10**18;
		uint256 smallApproval = 1000 * 10**18;
		uint256 largeDeposit = 10000 * 10**18;
		asset1Token.mint(auctioneer, tokenAmount);

		// Approve CPAManager for only small amount
		vm.prank(auctioneer);
		asset1Token.approve(address(cpaManager), smallApproval);

		// Attempt to deposit large amount (more than approval)
		vm.expectRevert();
		vm.prank(auctioneer);
		cpaManager.moveDeposit(auctionId, address(asset1Token), largeDeposit);
	}

	// ============ depositAllAndStartClock() Tests ============

	function test_DepositAllAndStartClock_Success() public {
		// Create auction
		AuctionId auctionId = createAuction(createStandardAuctionConfig(), auctioneer);

		// Mint tokens to auctioneer
		uint256 tokenAmount = 100000 * 10**18;
		asset1Token.mint(auctioneer, tokenAmount);
		asset2Token.mint(auctioneer, tokenAmount);

		// Approve CPAManager for both tokens
		vm.prank(auctioneer);
		asset1Token.approve(address(cpaManager), tokenAmount);
		vm.prank(auctioneer);
		asset2Token.approve(address(cpaManager), tokenAmount);

		// Prepare batch deposit data (no poolKeys — just amounts)
		uint256[] memory amounts = new uint256[](2);
		amounts[0] = 50000 * 10**18;
		amounts[1] = 60000 * 10**18;

		// Verify initial state
		AuctionTypes.AuctionInfo memory auctionInfo = cpaManager.getAuctionInfo(auctionId);
		assertEq(uint8(auctionInfo.currentPhase), uint8(AuctionTypes.AuctionPhase.Setup), "Should be in Setup phase");
		assertEq(auctionInfo.clockOpen, 1, "Clock should not be open initially");
		assertEq(auctionInfo.currentRound, 0, "Current round should be 0");

		// Call batch deposit and start clock
		vm.prank(auctioneer);
		cpaManager.depositAllAndStartClock(auctionId, amounts);

		// Verify phase transition
		auctionInfo = cpaManager.getAuctionInfo(auctionId);
		assertEq(uint8(auctionInfo.currentPhase), uint8(AuctionTypes.AuctionPhase.Clock), "Should transition to Clock phase");
		assertEq(auctionInfo.clockOpen, 2, "Clock should be open after starting");
		assertEq(auctionInfo.currentRound, 1, "Current round should be initialized to 1");

		// Verify deposits were made
		AssetId assetId1 = AssetIdLibrary.createId(auctionId, address(asset1Token));
		AssetId assetId2 = AssetIdLibrary.createId(auctionId, address(asset2Token));

		AuctionTypes.AssetInfo memory asset1Info = cpaManager.getAssetInfo(assetId1);
		AuctionTypes.AssetInfo memory asset2Info = cpaManager.getAssetInfo(assetId2);

		assertEq(asset1Info.depositAmount, amounts[0], "Asset1 deposit amount should be set");
		assertEq(asset2Info.depositAmount, amounts[1], "Asset2 deposit amount should be set");
	}

	// ============ cancelAuction() in Setup Tests ============

	function test_CancelAuction_SuccessInSetup() public {
		// Create auction (stays in Setup phase)
		AuctionId auctionId = createAuction(createStandardAuctionConfig(), auctioneer);

		// Verify initial state
		AuctionTypes.AuctionInfo memory auctionInfo = cpaManager.getAuctionInfo(auctionId);
		assertEq(uint8(auctionInfo.currentPhase), uint8(AuctionTypes.AuctionPhase.Setup), "Should be in Setup phase");
		assertEq(uint8(auctionInfo.currentStatus), uint8(AuctionTypes.AuctionStatus.Active), "Should be Active");

		// Cancel auction as auction owner
		vm.prank(auctioneer);
		cpaManager.cancelAuction(auctionId);

		// Verify status changes to Cancelled
		auctionInfo = cpaManager.getAuctionInfo(auctionId);
		assertEq(uint8(auctionInfo.currentStatus), uint8(AuctionTypes.AuctionStatus.Cancelled), "Status should be Cancelled");
		assertEq(uint8(auctionInfo.currentPhase), uint8(AuctionTypes.AuctionPhase.Setup), "Phase should remain Setup");

		// Verify auction can no longer progress - attempt to start clock phase should fail
		vm.expectRevert();
		vm.prank(auctioneer);
		cpaManager.startClockPhase(auctionId);
	}

	function test_CancelAuction_SuccessWithDeposits() public {
		// Create auction
		AuctionId auctionId = createAuction(createStandardAuctionConfig(), auctioneer);

		// Mint tokens and deposit to all assets
		uint256 tokenAmount = 100000 * 10**18;
		asset1Token.mint(auctioneer, tokenAmount);
		asset2Token.mint(auctioneer, tokenAmount);

		vm.prank(auctioneer);
		asset1Token.approve(address(cpaManager), tokenAmount);
		vm.prank(auctioneer);
		asset2Token.approve(address(cpaManager), tokenAmount);

		vm.prank(auctioneer);
		cpaManager.moveDeposit(auctionId, address(asset1Token), 50000 * 10**18);
		vm.prank(auctioneer);
		cpaManager.moveDeposit(auctionId, address(asset2Token), 60000 * 10**18);

		// Verify deposits were made
		AssetId assetId1 = AssetIdLibrary.createId(auctionId, address(asset1Token));
		AssetId assetId2 = AssetIdLibrary.createId(auctionId, address(asset2Token));

		AuctionTypes.AssetInfo memory asset1Info = cpaManager.getAssetInfo(assetId1);
		AuctionTypes.AssetInfo memory asset2Info = cpaManager.getAssetInfo(assetId2);

		assertEq(asset1Info.depositAmount, 50000 * 10**18, "Asset1 deposit should be recorded");
		assertEq(asset2Info.depositAmount, 60000 * 10**18, "Asset2 deposit should be recorded");

		// Cancel auction as auction owner
		vm.prank(auctioneer);
		cpaManager.cancelAuction(auctionId);

		// Verify status changes to Cancelled
		AuctionTypes.AuctionInfo memory auctionInfo = cpaManager.getAuctionInfo(auctionId);
		assertEq(uint8(auctionInfo.currentStatus), uint8(AuctionTypes.AuctionStatus.Cancelled), "Status should be Cancelled");

		// Verify deposit amounts are still recorded in assetInfo
		asset1Info = cpaManager.getAssetInfo(assetId1);
		asset2Info = cpaManager.getAssetInfo(assetId2);

		assertEq(asset1Info.depositAmount, 50000 * 10**18, "Asset1 deposit should still be recorded after cancellation");
		assertEq(asset2Info.depositAmount, 60000 * 10**18, "Asset2 deposit should still be recorded after cancellation");
	}

	function test_CancelAuction_RevertNonOwner() public {
		// Create auction as auctioneer
		AuctionId auctionId = createAuction(createStandardAuctionConfig(), auctioneer);

		// Attempt to cancel as bidder1 (non-owner)
		vm.expectRevert();
		vm.prank(bidder1);
		cpaManager.cancelAuction(auctionId);
	}
}
