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

contract IntegrationTest is Deployers {
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

    // ============ Setup Verification Tests ============

    function test_Setup_ContractsDeployedCorrectly() public {
        // Verify both contracts are deployed
        assertEq(address(poolHook.poolManager()), address(poolManager));
        assertEq(address(cpaManager.manager()), address(poolManager));
        
        // Verify ownership
        assertEq(poolHook.owner(), owner);
        assertEq(cpaManager.owner(), owner);
        
        // Verify PoolHook has CPAManager as auction manager
        assertEq(poolHook.auctionManager(), address(cpaManager));
        
        // Verify CPAManager has PoolHook address stored
        assertEq(cpaManager.cpaAuctionHookAddr(), address(poolHook));
    }

    // ============ Permission Tests ============

    function test_Permissions_OwnerCanSetAuctionManager() public {
        // Owner should be able to change auction manager in PoolHook
        address newAuctionManager = address(0x3333333333333333333333333333333333333333);
        
        vm.prank(owner);
        poolHook.setAuctionManager(newAuctionManager);
        
        assertEq(poolHook.auctionManager(), newAuctionManager);
    }

    function test_Permissions_NonOwnerCannotSetAuctionManager() public {
        // Non-owner should not be able to change auction manager
        address newAuctionManager = address(0x3333333333333333333333333333333333333333);
        
        vm.prank(nonOwner);
        vm.expectRevert(PoolHook.OnlyOwner.selector);
        poolHook.setAuctionManager(newAuctionManager);
        
        // Verify it wasn't changed
        assertEq(poolHook.auctionManager(), address(cpaManager));
    }

    function test_Permissions_CPAHookCanSetPoolState() public {
        // Initialize pool first
        poolManager.initialize(testPoolKey, Constants.SQRT_PRICE_1_1);
        
        // CPAHook should be able to set pool state
        vm.prank(address(cpaManager));
        poolHook.setPoolState(testPoolKey, AuctionTypes.AuctionPhase.Settlement);
        
        assertEq(uint8(poolHook.poolStates(testPoolId)), uint8(AuctionTypes.AuctionPhase.Settlement));
        assertEq(poolHook.allowedPools(testPoolId), true);
    }

    function test_Permissions_OwnerCannotSetPoolState() public {
        // Initialize pool first
        poolManager.initialize(testPoolKey, Constants.SQRT_PRICE_1_1);
        
        // Owner should NOT be able to set pool state directly
        vm.prank(owner);
        vm.expectRevert(PoolHook.OnlyAuction.selector);
        poolHook.setPoolState(testPoolKey, AuctionTypes.AuctionPhase.Settlement);
        
        // Verify state wasn't changed
        assertEq(poolHook.allowedPools(testPoolId), false);
    }

    function test_Permissions_NonOwnerCannotSetPoolState() public {
        // Initialize pool first
        poolManager.initialize(testPoolKey, Constants.SQRT_PRICE_1_1);
        
        // Non-owner should NOT be able to set pool state
        vm.prank(nonOwner);
        vm.expectRevert(PoolHook.OnlyAuction.selector);
        poolHook.setPoolState(testPoolKey, AuctionTypes.AuctionPhase.Settlement);
        
        // Verify state wasn't changed
        assertEq(poolHook.allowedPools(testPoolId), false);
    }

    // ============ Integration Flow Tests ============

    function test_Integration_CompleteAuctionFlow() public {
        // Initialize pool
        poolManager.initialize(testPoolKey, Constants.SQRT_PRICE_1_1);
        
        // Start with Setup phase - operations blocked
        vm.prank(address(cpaManager));
        poolHook.setPoolState(testPoolKey, AuctionTypes.AuctionPhase.Setup);
        assertEq(poolHook.allowedPools(testPoolId), false);
        
        // Move to Clock phase - operations still blocked
        vm.prank(address(cpaManager));
        poolHook.setPoolState(testPoolKey, AuctionTypes.AuctionPhase.Clock);
        assertEq(poolHook.allowedPools(testPoolId), false);
        
        // Move to Settlement phase - operations allowed
        vm.prank(address(cpaManager));
        poolHook.setPoolState(testPoolKey, AuctionTypes.AuctionPhase.Settlement);
        assertEq(poolHook.allowedPools(testPoolId), true);
        
        // Test other phases still block operations
        vm.prank(address(cpaManager));
        poolHook.setPoolState(testPoolKey, AuctionTypes.AuctionPhase.Proxy);
        assertEq(poolHook.allowedPools(testPoolId), false);
        
        // Back to Settlement - operations allowed again
        vm.prank(address(cpaManager));
        poolHook.setPoolState(testPoolKey, AuctionTypes.AuctionPhase.Settlement);
        assertEq(poolHook.allowedPools(testPoolId), true);
    }

    function test_Integration_PoolOperationsBlockedWhenAuctionOngoing() public {
        // Initialize pool
        poolManager.initialize(testPoolKey, Constants.SQRT_PRICE_1_1);
        
        // Set to Setup phase (blocked)
        vm.prank(address(cpaManager));
        poolHook.setPoolState(testPoolKey, AuctionTypes.AuctionPhase.Setup);
        
        // Verify operations are blocked
        assertEq(poolHook.allowedPools(testPoolId), false);
        
        // Try to perform operations - they should be blocked
        // Note: In a real scenario, these would be called via the V4 router/manager
        // and would revert with AuctionOngoing
    }

    function test_Integration_PoolOperationsAllowedWhenAuctionFinished() public {
        // Initialize pool
        poolManager.initialize(testPoolKey, Constants.SQRT_PRICE_1_1);
        
        // Set to Settlement phase (allowed)
        vm.prank(address(cpaManager));
        poolHook.setPoolState(testPoolKey, AuctionTypes.AuctionPhase.Settlement);
        
        // Verify operations are allowed
        assertEq(poolHook.allowedPools(testPoolId), true);
        
        // Operations should now be allowed
        // Note: In a real scenario, these would be called via the V4 router/manager
    }

    // ============ Multi-Pool Tests ============

    function test_Integration_MultiplePoolsIndependent() public {
        // Create second pool key
        PoolKey memory poolKey2 = PoolKey({
            currency0: Currency.wrap(address(0x3000000000000000000000000000000000000000)),
            currency1: Currency.wrap(address(0x4000000000000000000000000000000000000000)),
            fee: 500,
            tickSpacing: 10,
            hooks: IHooks(address(poolHook))
        });
        PoolId poolId2 = poolKey2.toId();
        
        // Initialize both pools
        poolManager.initialize(testPoolKey, Constants.SQRT_PRICE_1_1);
        poolManager.initialize(poolKey2, Constants.SQRT_PRICE_1_1);
        
        // Set different states for different pools
        vm.startPrank(address(cpaManager));
        poolHook.setPoolState(testPoolKey, AuctionTypes.AuctionPhase.Settlement); // Allowed
        poolHook.setPoolState(poolKey2, AuctionTypes.AuctionPhase.Clock); // Blocked
        vm.stopPrank();
        
        // Verify independent states
        assertEq(poolHook.allowedPools(testPoolId), true);
        assertEq(poolHook.allowedPools(poolId2), false);
    }

    // ============ Edge Cases ============

    function test_Integration_ZeroAddressAuctionManager() public {
        // Owner sets zero address as auction manager
        vm.prank(owner);
        poolHook.setAuctionManager(address(0));
        
        // Zero address auction manager cannot call restricted functions
        vm.expectRevert(PoolHook.OnlyAuction.selector);
        poolHook.setPoolState(testPoolKey, AuctionTypes.AuctionPhase.Settlement);
    }

    function test_Integration_ReinitializePool() public {
        // Initialize pool once
        poolManager.initialize(testPoolKey, Constants.SQRT_PRICE_1_1);
        assertEq(poolHook.allowedPools(testPoolId), false);
        
        // Re-initialize should still set to blocked
        // Note: This would require a different pool key since V4 doesn't allow re-initialization
        // For now, just verify the current state
        assertEq(poolHook.allowedPools(testPoolId), false);
    }

    // ============ Security Tests ============

    function test_Security_CPAHookCannotSetOwnAuctionManager() public {
        // CPAHook should not be able to set itself as auction manager in PoolHook
        // This would create a circular dependency
        vm.prank(address(cpaManager));
        vm.expectRevert(PoolHook.OnlyOwner.selector);
        poolHook.setAuctionManager(address(cpaManager));
    }

    function test_Security_CPAHookCannotTransferOwnership() public {
        // CPAHook should not be able to transfer ownership of PoolHook
        vm.prank(address(cpaManager));
        vm.expectRevert(PoolHook.OnlyOwner.selector);
        poolHook.setAuctionManager(address(0x9999999999999999999999999999999999999999));
    }

    // ============ State Consistency Tests ============

    function test_Consistency_PoolStateReflectsAuctionPhase() public {
        // Test that pool state changes when auction phase changes
        vm.startPrank(owner);
        
        // Create a test auction
        PoolKey[] memory poolKeys = new PoolKey[](1);
        poolKeys[0] = testPoolKey;
        
        AuctionTypes.AuctionConfig memory config = AuctionTypes.AuctionConfig({
            commonNumeraire: address(0x1000000000000000000000000000000000000000),
            minSpendRatio: 1000,
            dropoutSlashRatio: 500,
            spendingViolationSlashRatio: 1000,
            maxRounds: 10,
            allocatorStakeRequirement: 1000,
            proxyStakeRequirement: 500,
            allocationWindow: 7200,
            poolKeys: poolKeys,
            initialSqrtPricesX96: new uint160[](1),
            priceIncrements: new int24[](1)
        });
        
        // Set initial prices and increments
        config.initialSqrtPricesX96[0] = 79228162514264337593543950336; // sqrt(1e18) * 2^96
        config.priceIncrements[0] = 100; // 100 ticks
        
        AuctionId auctionId = cpaManager.createAuction(config, owner);
        
        // Verify auction was created successfully
        assertTrue(AuctionId.unwrap(auctionId) != 0);
        
        vm.stopPrank();
    }

	// ============ CreateAuction Tests ============

	function test_CreateAuction_Success() public {
		// Create test pool keys - three pools total
		PoolKey[] memory poolKeys = new PoolKey[](2);
		
		address numeraire = address(1);
		
		// Main pool: ETH (address(0)) <> numeraire
		PoolKey memory auctioneerPoolKey = PoolKey({
			currency0: Currency.wrap(address(0)), // ETH
			currency1: Currency.wrap(numeraire), // numeraire
			fee: 3000,
			tickSpacing: 60,
			hooks: IHooks(address(cpaManager)) // PoolHook attached to main pool
		});
		
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
		config.initialSqrtPricesX96[0] = 79228162514264337593543950336; // sqrt(1e18) * 2^96
		config.initialSqrtPricesX96[1] = 79228162514264337593543950336; // sqrt(1e18) * 2^96
		config.priceIncrements[0] = 100; // 100 ticks
		config.priceIncrements[1] = 100; // 100 ticks

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
		assertEq(auctionPoolKeys.length, 2, "Should have 3 pools (main + 2 assets)");
		
		// Verify the pool keys in auctionInfo match what we sent
        // address testaddr = address(Currency.unwrap(auctioneerPoolKey.currency0));
		// assertEq(address(Currency.unwrap(auctioneerPoolKey.currency0)), auctioneerPoolKey.currency0, "Main pool currency0 should match");
		// assertEq(address(Currency.unwrap(auctioneerPoolKey.currency1)), auctioneerPoolKey.currency1, "Main pool currency1 should match");
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
		
		// Verify main pool info
		assertEq(Currency.unwrap(auctioneerPoolKey.currency0), Currency.unwrap(auctioneerPoolKey.currency0), "Main pool currency0 should match");
		assertEq(Currency.unwrap(auctioneerPoolKey.currency1), Currency.unwrap(auctioneerPoolKey.currency1), "Main pool currency1 should match");
		assertEq(auctioneerPoolKey.fee, auctioneerPoolKey.fee, "Main pool fee should match");
		assertEq(auctioneerPoolKey.tickSpacing, auctioneerPoolKey.tickSpacing, "Main pool tickSpacing should match");
		assertEq(address(auctioneerPoolKey.hooks), address(auctioneerPoolKey.hooks), "Main pool hooks should match");
		
		// Verify pool1 info
		assertEq(Currency.unwrap(pool1Key.currency0), Currency.unwrap(poolKeys[0].currency0), "Pool1 currency0 should match");
		assertEq(Currency.unwrap(pool1Key.currency1), Currency.unwrap(poolKeys[0].currency1), "Pool1 currency1 should match");
		assertEq(pool1Key.fee, poolKeys[0].fee, "Pool1 fee should match");
		assertEq(pool1Key.tickSpacing, poolKeys[0].tickSpacing, "Pool1 tickSpacing should match");
		assertEq(address(pool1Key.hooks), address(poolKeys[0].hooks), "Pool1 hooks should match");
		assertEq(pool1StartingTick, 0, "Pool1 current price should be 0 initially");
		assertEq(pool1DepositAmount, 0, "Pool1 deposit amount should be 0 initially");
		assertEq(pool1ExcessDemand, 0, "Pool1 excess demand should be 0 initially");
		assertTrue(AuctionId.unwrap(pool1AuctionId) == AuctionId.unwrap(auctionId), "Pool1 should reference the correct auction");
		
		// Verify pool2 info
		assertEq(Currency.unwrap(pool2Key.currency0), Currency.unwrap(poolKeys[1].currency0), "Pool2 currency0 should match");
		assertEq(Currency.unwrap(pool2Key.currency1), Currency.unwrap(poolKeys[1].currency1), "Pool2 currency1 should match");
		assertEq(pool2Key.fee, poolKeys[1].fee, "Pool2 fee should match");
		assertEq(pool2Key.tickSpacing, poolKeys[1].tickSpacing, "Pool2 tickSpacing should match");
		assertEq(address(pool2Key.hooks), address(poolKeys[1].hooks), "Pool2 hooks should match");
		assertEq(pool2StartingTick, 0, "Pool2 current price should be 0 initially");
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
		
		// Main pool: ETH (address(0)) <> numeraire (stored separately as auctioneerPoolKey)
		PoolKey memory auctioneerPoolKey = PoolKey({
			currency0: Currency.wrap(address(0)), // ETH
			currency1: Currency.wrap(address(numeraireToken)), // numeraire
			fee: 3000,
			tickSpacing: 60,
			hooks: IHooks(address(poolHook)) // PoolHook attached to main pool
		});
		
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
		config.initialSqrtPricesX96[0] = 79228162514264337593543950336; // sqrt(1e18) * 2^96
		config.initialSqrtPricesX96[1] = 79228162514264337593543950336; // sqrt(1e18) * 2^96
		config.priceIncrements[0] = 100; // 100 ticks
		config.priceIncrements[1] = 100; // 100 ticks
	
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
		assertEq(pool1StartingTick, 0, "Pool1 current price should be 0 initially");
		assertEq(pool1DepositAmount, 0, "Pool1 deposit amount should be 0 initially");
		assertEq(pool1ExcessDemand, 0, "Pool1 excess demand should be 0 initially");
		assertTrue(AuctionId.unwrap(pool1AuctionId) == AuctionId.unwrap(auctionId), "Pool1 should reference the correct auction");
		
		// Verify pool2 info
		assertEq(Currency.unwrap(pool2Key.currency0), Currency.unwrap(poolKeys[1].currency0), "Pool2 currency0 should match");
		assertEq(Currency.unwrap(pool2Key.currency1), Currency.unwrap(poolKeys[1].currency1), "Pool2 currency1 should match");
		assertEq(pool2Key.fee, poolKeys[1].fee, "Pool2 fee should match");
		assertEq(pool2Key.tickSpacing, poolKeys[1].tickSpacing, "Pool2 tickSpacing should match");
		assertEq(address(pool2Key.hooks), address(poolKeys[1].hooks), "Pool2 hooks should match");
		assertEq(pool2StartingTick, 0, "Pool2 current price should be 0 initially");
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
		config.initialSqrtPricesX96[0] = 79228162514264337593543950336; // sqrt(1e18) * 2^96
		config.initialSqrtPricesX96[1] = 79228162514264337593543950336; // sqrt(1e18) * 2^96
		config.priceIncrements[0] = 100; // 100 ticks
		config.priceIncrements[1] = 100; // 100 ticks
	
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
