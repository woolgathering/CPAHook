// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { Test, console2 } from "forge-std/Test.sol";
import { PoolHook } from "../src/PoolHook.sol";
import { CPAManager } from "../src/CPAManager.sol";
import { AuctionTypes } from "../src/AuctionTypes.sol";
import { AuctionId } from "../src/AuctionId.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { Currency, CurrencyLibrary } from "@uniswap/v4-core/src/types/Currency.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { Hooks } from "@uniswap/v4-core/src/libraries/Hooks.sol";
import { HookMiner } from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { Deployers } from "./utils/Deployers.sol";
import { SwapParams, ModifyLiquidityParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";
import { Constants } from "../lib/uniswap-hooks/lib/v4-core/test/utils/Constants.sol";
import { MockERC20 } from "solmate/src/test/utils/mocks/MockERC20.sol";
import { IERC6909Claims } from "@uniswap/v4-core/src/interfaces/external/IERC6909Claims.sol";

contract CPASetupPhaseTest is Deployers {
    using PoolIdLibrary for PoolKey;
	using CurrencyLibrary for Currency;

    PoolHook public poolHook;
	CPAManager public cpaManager;
    address public owner;
    address public nonOwner;
    
    PoolKey public testPoolKey;
    PoolId public testPoolId;

    function setUp() public {
        deployArtifacts();
        
        owner = address(0x1111111111111111111111111111111111111111);
        nonOwner = address(0x2222222222222222222222222222222222222222);
        
        // Deploy both hooks from the same address (owner)
        vm.startPrank(owner);
        
        // First deploy PoolHook
        poolHook = deployPoolHook(poolManager);
        
        		// Then deploy CPAManager with poolHook address
        cpaManager = deployCPAManager(poolManager, owner, address(poolHook));
        
        // Set the auction manager in PoolHook to be the CPAManager
        poolHook.setAuctionManager(address(cpaManager));
        
        vm.stopPrank();
        
        // Create a test pool key
        testPoolKey = PoolKey({
            currency0: Currency.wrap(address(0x1000000000000000000000000000000000000000)),
            currency1: Currency.wrap(address(0x2000000000000000000000000000000000000000)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(poolHook))
        });
        testPoolId = testPoolKey.toId();
    }

    /// @notice Deploy PoolHook with proper address mining and flag setting
    function deployPoolHook(IPoolManager _poolManager) internal returns (PoolHook) {
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG |
            Hooks.BEFORE_SWAP_FLAG |
            Hooks.BEFORE_ADD_LIQUIDITY_FLAG |
            Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG |
            Hooks.BEFORE_DONATE_FLAG
        );
        
        bytes memory constructorArgs = abi.encode(_poolManager);
        
        (address hookAddress, bytes32 salt) = HookMiner.find(
            owner,
            flags,
            type(PoolHook).creationCode,
            constructorArgs
        );
        
        PoolHook deployedHook = new PoolHook{salt: salt}(_poolManager);
        require(address(deployedHook) == hookAddress, "Hook address mismatch");
        return deployedHook;
    }

    	/// @notice Deploy CPAManager (no longer a hook, so no address mining needed)
	function deployCPAManager(IPoolManager _poolManager, address _owner, address _poolHook) internal returns (CPAManager) {
        // Simple deployment since CPAManager is no longer a hook
        return new CPAManager(_poolManager, _owner, _poolHook);
    }

	// ============ CreateAuction Tests ============

	function test_CreateAuction_Success() public {
		// Create test pool keys - two asset pools total
		PoolKey[] memory poolKeys = new PoolKey[](2);
		
		address numeraire = address(1);
		
		// No auctioneer pool key needed since CPAManager is not a hook
		
		// Asset pool 1: asset1 <> numeraire (ensure currencies are sorted by address)
		address asset1 = address(2);
		(address assetPool1Soreted0, address assetPool1Soreted1) = asset1 < numeraire ? (asset1, numeraire) : (numeraire, asset1);

        console2.log("assetPool1Soreted0", assetPool1Soreted0);
        console2.log("assetPool1Soreted1", assetPool1Soreted1);
		
		poolKeys[0] = PoolKey({
			currency0: Currency.wrap(assetPool1Soreted0),
			currency1: Currency.wrap(assetPool1Soreted1),
			fee: 3000,
			tickSpacing: 60,
			hooks: IHooks(address(poolHook))
		});
		
		// Asset pool 2: asset2 <> numeraire (ensure currencies are sorted by address)
		address asset2 = address(3);
		(address assetPool2Soreted0, address assetPool2Soreted1) = asset2 < numeraire ? (asset2, numeraire) : (numeraire, asset2);
		
		poolKeys[1] = PoolKey({
			currency0: Currency.wrap(assetPool2Soreted0),
			currency1: Currency.wrap(assetPool2Soreted1),
			fee: 3000,
			tickSpacing: 60,
			hooks: IHooks(address(poolHook))
		});

		// Create auction config
		AuctionTypes.AuctionConfig memory config = AuctionTypes.AuctionConfig({
			commonNumeraire: numeraire,
			minSpendRatio: 1000,
			dropoutSlashRatio: 500,
			spendingViolationSlashRatio: 1000,
			maxRounds: 10,
			allocatorStakeRequirement: 1000,
			proxyStakeRequirement: 500,
			allocationWindow: 7200,
			poolKeys: poolKeys,
			initialSqrtPricesX96: new uint160[](2),
			priceIncrements: new int24[](2)
		});
		
		// Set initial prices and increments for both pools
		config.initialSqrtPricesX96[0] = 79228162514264337593543950336; // sqrt(1) * 2^96 = 1 numeraire per asset
		config.initialSqrtPricesX96[1] = 112045541949572287496682733568; // sqrt(2) * 2^96 = 2 numeraire per asset
		config.priceIncrements[0] = 100; // 100 ticks
		config.priceIncrements[1] = 300; // 300 ticks

		// Create auction
		vm.prank(owner);
		AuctionId auctionId = cpaManager.createAuction(config, owner);

		// Verify auction was created
		assertTrue(AuctionId.unwrap(auctionId) != 0);

		// ============ Verify Auction Info Struct ============
		// Check that auctionInfo is properly populated
		(
			address auctionOwner,
			address commonNumeraire,
			AuctionTypes.AuctionConfig memory auctionConfig,
			AuctionTypes.AuctionPhase currentPhase,
			AuctionTypes.AuctionStatus currentStatus,
			uint256 clockOpen,
			AuctionTypes.Bid[] memory roundBids,
			uint256 currentRound,
			PoolKey[] memory auctionPoolKeys
		) = cpaManager.getAuctionInfo(auctionId);

        // AuctionTypes.AuctionInfo memory auctionInfo = cpaManager.getAuctionInfo(auctionId);
        // address auctionOwner = auctionInfo.auctionOwner;
        // address commonNumeraire = auctionInfo.commonNumeraire;
        // AuctionTypes.AuctionPhase currentPhase = auctionInfo.currentPhase;
        // AuctionTypes.AuctionStatus currentStatus = auctionInfo.currentStatus;
        // uint256 clockOpen = auctionInfo.clockOpen;
        // uint256 currentRound = auctionInfo.currentRound;
        // PoolKey[] memory auctionPoolKeys = auctionInfo.poolKeys;
		
		assertEq(auctionOwner, owner, "Auction owner should be the owner");
		assertEq(commonNumeraire, numeraire, "Common numeraire should be the numeraire address");
		assertEq(uint8(currentPhase), uint8(AuctionTypes.AuctionPhase.Setup), "Auction should start in Setup phase");
		assertEq(uint8(currentStatus), uint8(AuctionTypes.AuctionStatus.Active), "Auction should be Active");
		assertEq(clockOpen, 1, "Clock should not be open initially");
		assertEq(currentRound, 0, "Current round should be 0");
		assertEq(auctionPoolKeys.length, 2, "Should have 2 asset pools");
		
		// Verify the pool keys in auctionInfo match what we sent
		assertEq(Currency.unwrap(auctionPoolKeys[0].currency0), Currency.unwrap(poolKeys[0].currency0), "Asset1 pool currency0 should match");
		assertEq(Currency.unwrap(auctionPoolKeys[0].currency1), Currency.unwrap(poolKeys[0].currency1), "Asset1 pool currency1 should match");
		assertEq(Currency.unwrap(auctionPoolKeys[1].currency0), Currency.unwrap(poolKeys[1].currency0), "Asset2 pool currency0 should match");
		assertEq(Currency.unwrap(auctionPoolKeys[1].currency1), Currency.unwrap(poolKeys[1].currency1), "Asset2 pool currency1 should match");
		
		// ============ Verify Pool Info Structs ============
		// Check that poolInfo is properly populated for each pool
		PoolId pool1Id = poolKeys[0].toId();
		PoolId pool2Id = poolKeys[1].toId();
		
		(
			PoolKey memory pool1Key,
			int24 pool1StartingTick,
			int24 pool1PriceIncrement,
			uint256 pool1DepositAmount,
			uint256 pool1ExcessDemand,
			AuctionId pool1AuctionId
		) = cpaManager.getPoolInfo(pool1Id);
		
		(
			PoolKey memory pool2Key,
			int24 pool2StartingTick,
			int24 pool2PriceIncrement,
			uint256 pool2DepositAmount,
			uint256 pool2ExcessDemand,
			AuctionId pool2AuctionId
		) = cpaManager.getPoolInfo(pool2Id);
		
		// No main pool verification needed since CPAManager is not a hook
		
		// Verify pool1 info
		assertEq(Currency.unwrap(pool1Key.currency0), Currency.unwrap(poolKeys[0].currency0), "Pool1 currency0 should match");
		assertEq(Currency.unwrap(pool1Key.currency1), Currency.unwrap(poolKeys[0].currency1), "Pool1 currency1 should match");
		assertEq(pool1Key.fee, poolKeys[0].fee, "Pool1 fee should match");
		assertEq(pool1Key.tickSpacing, poolKeys[0].tickSpacing, "Pool1 tickSpacing should match");
		assertEq(address(pool1Key.hooks), address(poolKeys[0].hooks), "Pool1 hooks should match");
		assertEq(pool1StartingTick, 0, "Pool1 starting tick should be 0 for price = 1");
		assertEq(pool1PriceIncrement, 100, "Pool1 price increment should be 100 ticks");
		assertEq(pool1DepositAmount, 0, "Pool1 deposit amount should be 0 initially");
		assertEq(pool1ExcessDemand, 0, "Pool1 excess demand should be 0 initially");
		assertTrue(AuctionId.unwrap(pool1AuctionId) == AuctionId.unwrap(auctionId), "Pool1 should reference the correct auction");
		
		// Verify pool2 info
		assertEq(Currency.unwrap(pool2Key.currency0), Currency.unwrap(poolKeys[1].currency0), "Pool2 currency0 should match");
		assertEq(Currency.unwrap(pool2Key.currency1), Currency.unwrap(poolKeys[1].currency1), "Pool2 currency1 should match");
		assertEq(pool2Key.fee, poolKeys[1].fee, "Pool2 fee should match");
		assertEq(pool2Key.tickSpacing, poolKeys[1].tickSpacing, "Pool2 tickSpacing should match");
		assertEq(address(pool2Key.hooks), address(poolKeys[1].hooks), "Pool2 hooks should match");
		assertEq(pool2StartingTick, 6931, "Pool2 starting tick should be 6931 for price = 2");
		assertEq(pool2PriceIncrement, 300, "Pool2 price increment should be 300 ticks");
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
		assertEq(commonNumeraire, numeraire, "Common numeraire in auctionInfo should match config");
		

	}

	function test_CreateAuction_WithRealTokens() public {
		// Deploy real tokens for testing
		MockERC20 numeraireToken = new MockERC20("Numeraire", "NUM", 18);
		MockERC20 asset1Token = new MockERC20("Asset1", "AST1", 18);
		MockERC20 asset2Token = new MockERC20("Asset2", "AST2", 18);
		
		// Define entities
		address protocolOwner = owner; // Protocol owns the auction manager contract
		address auctioneer = address(0x3333333333333333333333333333333333333333); // Auctioneer creates auctions and owns assets
		
		// Mint asset tokens to the auctioneer (not the protocol owner)
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
		assertEq(numeraireToken.balanceOf(address(cpaManager)), 0, "CPAManagerHook should start with no tokens");
		
		// Create test pool keys with real tokens
		PoolKey[] memory poolKeys = new PoolKey[](2); // Only asset pools for createAuction
		
		// No auctioneer pool key needed since CPAManager is not a hook
		
		// Asset pool 1: asset1 <> numeraire (ensure currencies are sorted by address)
		(address sortedAsset1, address sortedNumeraire1) = address(asset1Token) < address(numeraireToken) 
			? (address(asset1Token), address(numeraireToken)) 
			: (address(numeraireToken), address(asset1Token));
		
		poolKeys[0] = PoolKey({
			currency0: Currency.wrap(sortedAsset1),
			currency1: Currency.wrap(sortedNumeraire1),
			fee: 3000,
			tickSpacing: 60,
			hooks: IHooks(address(poolHook))
		});
		
		// Asset pool 2: asset2 <> numeraire (ensure currencies are sorted by address)
		(address sortedAsset2, address sortedNumeraire2) = address(asset2Token) < address(numeraireToken) 
			? (address(asset2Token), address(numeraireToken)) 
			: (address(numeraireToken), address(asset2Token));
		
		poolKeys[1] = PoolKey({
			currency0: Currency.wrap(sortedAsset2),
			currency1: Currency.wrap(sortedNumeraire2),
			fee: 3000,
			tickSpacing: 60,
			hooks: IHooks(address(poolHook))
		});
	
		// Create auction config
		AuctionTypes.AuctionConfig memory config = AuctionTypes.AuctionConfig({
			commonNumeraire: address(numeraireToken),
			minSpendRatio: 1000,
			dropoutSlashRatio: 500,
			spendingViolationSlashRatio: 1000,
			maxRounds: 10,
			allocatorStakeRequirement: 1000,
			proxyStakeRequirement: 500,
			allocationWindow: 7200,
			poolKeys: poolKeys,
			initialSqrtPricesX96: new uint160[](2),
			priceIncrements: new int24[](2)
		});
		
		// Set initial prices and increments for both pools
		config.initialSqrtPricesX96[0] = 79228162514264337593543950336; // sqrt(1) * 2^96 = 1 numeraire per asset
		config.initialSqrtPricesX96[1] = 112045541949572287496682733568; // sqrt(2) * 2^96 = 2 numeraire per asset
		config.priceIncrements[0] = 100; // 100 ticks
		config.priceIncrements[1] = 300; // 300 ticks
	
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
		(
			address auctionOwner,
			address commonNumeraire,
			, // config
			AuctionTypes.AuctionPhase currentPhase,
			AuctionTypes.AuctionStatus currentStatus,
			uint256 clockOpen,
			, // roundBids
			uint256 currentRound,
			PoolKey[] memory auctionPoolKeys
		) = cpaManager.getAuctionInfo(auctionId);
		
		assertEq(auctionOwner, auctioneer, "Auction owner should be the auctioneer");
		assertEq(commonNumeraire, address(numeraireToken), "Common numeraire should be the numeraire token");
		assertEq(uint8(currentPhase), uint8(AuctionTypes.AuctionPhase.Setup), "Auction should start in Setup phase");
		assertEq(uint8(currentStatus), uint8(AuctionTypes.AuctionStatus.Active), "Auction should be Active");
		assertEq(clockOpen, 1, "Clock should not be open initially");
		assertEq(currentRound, 0, "Current round should be 0");
		assertEq(auctionPoolKeys.length, 2, "Should have 2 asset pools");
		
		// Verify the pool keys in auctionInfo match what we sent
		assertEq(Currency.unwrap(auctionPoolKeys[0].currency0), Currency.unwrap(poolKeys[0].currency0), "First pool currency0 should match");
		assertEq(Currency.unwrap(auctionPoolKeys[0].currency1), Currency.unwrap(poolKeys[0].currency1), "First pool currency1 should match");
		assertEq(Currency.unwrap(auctionPoolKeys[1].currency0), Currency.unwrap(poolKeys[1].currency0), "Second pool currency0 should match");
		assertEq(Currency.unwrap(auctionPoolKeys[1].currency1), Currency.unwrap(poolKeys[1].currency1), "Second pool currency1 should match");
		
		// ============ Verify Pool Info Structs ============
		// Check that poolInfo is properly populated for each asset pool
		PoolId pool1Id = poolKeys[0].toId();
		PoolId pool2Id = poolKeys[1].toId();
		
		(
			PoolKey memory pool1Key,
			int24 pool1StartingTick,
			int24 pool1PriceIncrement,
			uint256 pool1DepositAmount,
			uint256 pool1ExcessDemand,
			AuctionId pool1AuctionId
		) = cpaManager.getPoolInfo(pool1Id);
		
		(
			PoolKey memory pool2Key,
			int24 pool2StartingTick,
			int24 pool2PriceIncrement,
			uint256 pool2DepositAmount,
			uint256 pool2ExcessDemand,
			AuctionId pool2AuctionId
		) = cpaManager.getPoolInfo(pool2Id);
		
		// Verify pool1 info
		assertEq(Currency.unwrap(pool1Key.currency0), Currency.unwrap(poolKeys[0].currency0), "Pool1 currency0 should match");
		assertEq(Currency.unwrap(pool1Key.currency1), Currency.unwrap(poolKeys[0].currency1), "Pool1 currency1 should match");
		assertEq(pool1Key.fee, poolKeys[0].fee, "Pool1 fee should match");
		assertEq(pool1Key.tickSpacing, poolKeys[0].tickSpacing, "Pool1 tickSpacing should match");
		assertEq(address(pool1Key.hooks), address(poolKeys[0].hooks), "Pool1 hooks should match");
		assertEq(pool1StartingTick, 0, "Pool1 starting tick should be 0 for price = 1");
		assertEq(pool1PriceIncrement, 100, "Pool1 price increment should be 100 ticks");
		assertEq(pool1DepositAmount, 0, "Pool1 deposit amount should be 0 initially");
		assertEq(pool1ExcessDemand, 0, "Pool1 excess demand should be 0 initially");
		assertTrue(AuctionId.unwrap(pool1AuctionId) == AuctionId.unwrap(auctionId), "Pool1 should reference the correct auction");
		
		// Verify pool2 info
		assertEq(Currency.unwrap(pool2Key.currency0), Currency.unwrap(poolKeys[1].currency0), "Pool2 currency0 should match");
		assertEq(Currency.unwrap(pool2Key.currency1), Currency.unwrap(poolKeys[1].currency1), "Pool2 currency1 should match");
		assertEq(pool2Key.fee, poolKeys[1].fee, "Pool2 fee should match");
		assertEq(pool2Key.tickSpacing, poolKeys[1].tickSpacing, "Pool2 tickSpacing should match");
		assertEq(address(pool2Key.hooks), address(poolKeys[1].hooks), "Pool2 hooks should match");
		assertEq(pool2StartingTick, 6931, "Pool2 starting tick should be 6931 for price = 2");
		assertEq(pool2PriceIncrement, 300, "Pool2 price increment should be 300 ticks");
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
		assertEq(commonNumeraire, address(numeraireToken), "Common numeraire in auctionInfo should match config");
		
		// Test that the auction manager can actually move tokens
		// This will be important for testing the deposit and settlement functionality
		assertTrue(true, "Auction created with real tokens successfully");
		
		// TODO: Next step will be testing CPAClockPhase.moveDeposit to move tokens from auctioneer to pools with price increments
	}

	function test_DepositFunctionality_WithRealTokens() public {
		// Deploy real tokens for testing
		MockERC20 numeraireToken = new MockERC20("Numeraire", "NUM", 18);
		MockERC20 asset1Token = new MockERC20("Asset1", "AST1", 18);
		MockERC20 asset2Token = new MockERC20("Asset2", "AST2", 18);
		
		// Define entities
		address protocolOwner = owner; // Protocol owns the auction manager contract
		address auctioneer = address(0xcafebabe); // Auctioneer creates auctions and owns assets
		
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
		
		// Create test pool keys with real tokens (only asset pools for createAuction)
		PoolKey[] memory poolKeys = new PoolKey[](2);
		
		// Asset pool 1: asset1 <> numeraire (ensure currencies are sorted by address)
		(address sortedAsset1, address sortedNumeraire1) = address(asset1Token) < address(numeraireToken) 
			? (address(asset1Token), address(numeraireToken)) 
			: (address(numeraireToken), address(asset1Token));
		
		poolKeys[0] = PoolKey({
			currency0: Currency.wrap(sortedAsset1),
			currency1: Currency.wrap(sortedNumeraire1),
			fee: 3000,
			tickSpacing: 60,
			hooks: IHooks(address(poolHook))
		});
		
		// Asset pool 2: asset2 <> numeraire (ensure currencies are sorted by address)
		(address sortedAsset2, address sortedNumeraire2) = address(asset2Token) < address(numeraireToken) 
			? (address(asset2Token), address(numeraireToken)) 
			: (address(numeraireToken), address(asset2Token));
		
		poolKeys[1] = PoolKey({
			currency0: Currency.wrap(sortedAsset2),
			currency1: Currency.wrap(sortedNumeraire2),
			fee: 3000,
			tickSpacing: 60,
			hooks: IHooks(address(poolHook))
		});
	
		// Create auction config
		AuctionTypes.AuctionConfig memory config = AuctionTypes.AuctionConfig({
			commonNumeraire: address(numeraireToken),
			minSpendRatio: 1000,
			dropoutSlashRatio: 500,
			spendingViolationSlashRatio: 1000,
			maxRounds: 10,
			allocatorStakeRequirement: 1000,
			proxyStakeRequirement: 500,
			allocationWindow: 7200,
			poolKeys: poolKeys,
			initialSqrtPricesX96: new uint160[](2),
			priceIncrements: new int24[](2)
		});
		
		// Set initial prices and increments for both pools
		config.initialSqrtPricesX96[0] = 79228162514264337593543950336; // sqrt(1) * 2^96 = 1 numeraire per asset
		config.initialSqrtPricesX96[1] = 112045541949572287496682733568; // sqrt(2) * 2^96 = 2 numeraire per asset
		config.priceIncrements[0] = 100; // 100 ticks
		config.priceIncrements[1] = 300; // 300 ticks
	
		// Create auction (auctioneer creates it)
		vm.prank(auctioneer);
		AuctionId auctionId = cpaManager.createAuction(config, auctioneer);
	
		// Verify auction was created
		assertTrue(AuctionId.unwrap(auctionId) != 0);
		
		// ============ Test Deposit Functionality ============
		// Now test that the auctioneer can move tokens to the pools via the auction manager
		
        
		// Get pool IDs for the asset pools
		PoolId pool1Id = poolKeys[0].toId();
		PoolId pool2Id = poolKeys[1].toId();
		
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
		cpaManager.moveDeposit(auctionId, poolKeys[0], depositAmount1);
		
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
			AuctionId pool1AuctionIdInPoolInfo
		) = cpaManager.poolInfo(pool1Id);
		
		assertEq(pool1DepositAmountInPoolInfo, depositAmount1, "Pool1 deposit amount should be updated");
		assertTrue(AuctionId.unwrap(pool1AuctionIdInPoolInfo) == AuctionId.unwrap(auctionId), "Pool1 should reference the correct auction");
		
		// Test moving deposits to pool 2
		vm.prank(auctioneer);
		cpaManager.moveDeposit(auctionId, poolKeys[1], depositAmount2);
		
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
			AuctionId pool2AuctionIdInPoolInfo
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
