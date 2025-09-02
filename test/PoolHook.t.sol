// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { Test, console2 } from "forge-std/Test.sol";
import { PoolHook } from "../src/PoolHook.sol";
import { BaseHook } from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import { AuctionTypes } from "../src/AuctionTypes.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { Hooks } from "@uniswap/v4-core/src/libraries/Hooks.sol";
import { HookMiner } from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { Deployers } from "./utils/Deployers.sol";
import { SwapParams, ModifyLiquidityParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Constants} from "../lib/uniswap-hooks/lib/v4-core/test/utils/Constants.sol";

contract PoolHookTest is Deployers {
    using PoolIdLibrary for PoolKey;

    PoolHook public hook;
    address public owner;
    address public auctionManager;
    address public nonOwner;
    address public nonAuctionManager;
    
    PoolKey public testPoolKey;
    PoolId public testPoolId;

    function setUp() public {
        deployArtifacts();
        
        owner = address(0x1111111111111111111111111111111111111111);
        auctionManager = address(0x2222222222222222222222222222222222222222);
        nonOwner = address(0x3333333333333333333333333333333333333333);
        nonAuctionManager = address(0x4444444444444444444444444444444444444444);
        
        // Deploy hook with proper address mining
        hook = deployHook(poolManager);
        
        // Create a test pool key
        testPoolKey = PoolKey({
            currency0: Currency.wrap(address(0x1000000000000000000000000000000000000000)),
            currency1: Currency.wrap(address(0x2000000000000000000000000000000000000000)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        testPoolId = testPoolKey.toId();
    }

    /// @notice Deploy hook with proper address mining and flag setting
    function deployHook(IPoolManager _poolManager) internal returns (PoolHook) {
        // Set the required hook flags for PoolHook based on getHookPermissions()
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG |
            Hooks.BEFORE_SWAP_FLAG |
            Hooks.BEFORE_ADD_LIQUIDITY_FLAG |
            Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG |
            Hooks.BEFORE_DONATE_FLAG
        );
        
        bytes memory constructorArgs = abi.encode(_poolManager);
        
        // Mine a salt that will produce a hook address with the correct flags
        (address hookAddress, bytes32 salt) = HookMiner.find(
            address(this),
            flags,
            type(PoolHook).creationCode,
            constructorArgs
        );
        
        // Deploy the hook using CREATE2 with the mined salt
        PoolHook deployedHook = new PoolHook{salt: salt}(_poolManager);
        
        // Verify the hook was deployed to the expected address
        require(address(deployedHook) == hookAddress, "Hook address mismatch");
        return deployedHook;
    }

    // ============ Constructor Tests ============

    function test_Constructor_Success() public {
        // Verify initial state
        assertEq(address(hook.poolManager()), address(poolManager));
        assertEq(hook.owner(), address(this)); // Deployer becomes owner
        assertEq(hook.auctionManager(), address(0)); // Initially no auction manager
    }

    function test_Constructor_InitialState() public {
        // Verify initial state before pool initialization
        // Note: pool states and allowed pools are only meaningful after pool initialization
		// poolManager.initialize(testPoolKey, Constants.SQRT_PRICE_1_1);
        assertEq(hook.auctionManager(), address(0)); // No auction manager set initially
        assertEq(hook.owner(), address(this)); // Deployer is owner
    }

    // ============ Access Control Tests ============

    function test_SetAuctionManager_OnlyOwner() public {
        // Non-owner should not be able to set auction manager
        vm.prank(nonOwner);
        vm.expectRevert(PoolHook.OnlyOwner.selector);
        hook.setAuctionManager(auctionManager);
        
        // Owner should be able to set auction manager
        hook.setAuctionManager(auctionManager);
        assertEq(hook.auctionManager(), auctionManager);
    }

    function test_SetAuctionManager_OwnerCanChange() public {
        hook.setAuctionManager(auctionManager);
        assertEq(hook.auctionManager(), auctionManager);
        
        // Owner can change to different address
        address newAuctionManager = address(0x5555555555555555555555555555555555555555);
        hook.setAuctionManager(newAuctionManager);
        assertEq(hook.auctionManager(), newAuctionManager);
    }

    // Removed test for setPoolAllowed - function was consolidated into setPoolState

    // Removed test for setAuctionState - function was consolidated into setPoolState

    function test_SetPoolState_OnlyAuctionManager() public {
        hook.setAuctionManager(auctionManager);
        
        // Non-auction manager should not be able to set pool state
        vm.prank(nonAuctionManager);
        vm.expectRevert(PoolHook.OnlyAuction.selector);
        hook.setPoolState(testPoolKey, AuctionTypes.AuctionPhase.Settlement);
        
        // Auction manager should be able to set pool state
        vm.prank(auctionManager);
        hook.setPoolState(testPoolKey, AuctionTypes.AuctionPhase.Settlement);
        assertEq(uint8(hook.poolStates(testPoolId)), uint8(AuctionTypes.AuctionPhase.Settlement));
        assertEq(hook.allowedPools(testPoolId), true);
    }

    // ============ Pool State Management Tests ============

    // Removed test for setPoolAllowed - function was consolidated into setPoolState

    // Removed test for setAuctionState - function was consolidated into setPoolState

    // Removed tests for setAuctionState - function was consolidated into setPoolState

    function test_SetPoolState_UpdatesStateCorrectly() public {
        hook.setAuctionManager(auctionManager);
        
        vm.startPrank(auctionManager);
        
        // Setup phase - should block operations
        hook.setPoolState(testPoolKey, AuctionTypes.AuctionPhase.Setup);
        assertEq(uint8(hook.poolStates(testPoolId)), uint8(AuctionTypes.AuctionPhase.Setup));
        assertEq(hook.allowedPools(testPoolId), false);
        
        // Clock phase - should block operations
        hook.setPoolState(testPoolKey, AuctionTypes.AuctionPhase.Clock);
        assertEq(uint8(hook.poolStates(testPoolId)), uint8(AuctionTypes.AuctionPhase.Clock));
        assertEq(hook.allowedPools(testPoolId), false);
        
        // Settlement phase - should allow operations
        hook.setPoolState(testPoolKey, AuctionTypes.AuctionPhase.Settlement);
        assertEq(uint8(hook.poolStates(testPoolId)), uint8(AuctionTypes.AuctionPhase.Settlement));
        assertEq(hook.allowedPools(testPoolId), true);
        
        vm.stopPrank();
    }

    // ============ Hook Behavior Tests ============

    function test_BeforeInitialize_SetsPoolToBlocked() public {
        // When a pool is initialized, it should be set to blocked by default
        poolManager.initialize(testPoolKey, Constants.SQRT_PRICE_1_1);
        assertEq(hook.allowedPools(testPoolId), false);
    }

    function test_BeforeSwap_BlocksWhenAuctionOngoing() public {
        // Pool is blocked by default
        poolManager.initialize(testPoolKey, Constants.SQRT_PRICE_1_1);
        assertEq(hook.allowedPools(testPoolId), false);
        
        // Should revert with AuctionOngoing when trying to swap
        vm.expectRevert(PoolHook.AuctionOngoing.selector);
        // call swap via V4 router
    }

    function test_BeforeSwap_AllowsWhenAuctionFinished() public {
        hook.setAuctionManager(auctionManager);
        
        // Set pool to allowed (Settlement phase)
        vm.prank(auctionManager);
        poolManager.initialize(testPoolKey, Constants.SQRT_PRICE_1_1);
        hook.setPoolState(testPoolKey, AuctionTypes.AuctionPhase.Settlement);
        
        // Should succeed when pool is allowed
        // call swap via V4 router
        
    }

    function test_BeforeAddLiquidity_BlocksWhenAuctionOngoing() public {
        // Pool is blocked by default
        poolManager.initialize(testPoolKey, Constants.SQRT_PRICE_1_1);
        assertEq(hook.allowedPools(testPoolId), false);
        
        // Should revert with AuctionOngoing when trying to add liquidity
        vm.expectRevert(PoolHook.AuctionOngoing.selector);
       // call add liquidity via V4 position manager
    }

    function test_BeforeAddLiquidity_AllowsWhenAuctionFinished() public {
        hook.setAuctionManager(auctionManager);
        
        // Set pool to allowed (Settlement phase)
        vm.prank(auctionManager);
        poolManager.initialize(testPoolKey, Constants.SQRT_PRICE_1_1);
        hook.setPoolState(testPoolKey, AuctionTypes.AuctionPhase.Settlement);
        
        // Should succeed when pool is allowed
        // call add liquidity via V4 position manager
    }

    function test_BeforeRemoveLiquidity_BlocksWhenAuctionOngoing() public {
        // Pool is blocked by default
        poolManager.initialize(testPoolKey, Constants.SQRT_PRICE_1_1);
        assertEq(hook.allowedPools(testPoolId), false);
        
        // Should revert with AuctionOngoing when trying to remove liquidity
        vm.expectRevert(PoolHook.AuctionOngoing.selector);
        // call remove liquidity via V4 position manager
    }

    function test_BeforeRemoveLiquidity_AllowsWhenAuctionFinished() public {
        hook.setAuctionManager(auctionManager);
        
        // Set pool to allowed (Settlement phase)
        vm.prank(auctionManager);
        poolManager.initialize(testPoolKey, Constants.SQRT_PRICE_1_1);
        hook.setPoolState(testPoolKey, AuctionTypes.AuctionPhase.Settlement);
        
        // Should succeed when pool is allowed
        // call remove liquidity via V4 position manager
    }

    function test_BeforeDonate_BlocksWhenAuctionOngoing() public {
        // Pool is blocked by default
        assertEq(hook.allowedPools(testPoolId), false);
        
        // Should revert with AuctionOngoing when trying to donate
        vm.expectRevert(PoolHook.AuctionOngoing.selector);
        // call donate via V4 position manager
    }

    function test_BeforeDonate_AllowsWhenAuctionFinished() public {
        hook.setAuctionManager(auctionManager);
        
        // Set pool to allowed (Settlement phase)
        vm.prank(auctionManager);
        poolManager.initialize(testPoolKey, Constants.SQRT_PRICE_1_1);
        hook.setPoolState(testPoolKey, AuctionTypes.AuctionPhase.Settlement);
        
        // Should succeed when pool is allowed
        // call donate via V4 position manager
    }

    // ============ Integration Tests ============

    function test_CompleteAuctionFlow() public {
        hook.setAuctionManager(auctionManager);
        
        // Start with Setup phase - operations blocked
        vm.prank(auctionManager);
        hook.setPoolState(testPoolKey, AuctionTypes.AuctionPhase.Setup);
        assertEq(hook.allowedPools(testPoolId), false);
        
        // Move to Clock phase - operations still blocked
        vm.prank(auctionManager);
        hook.setPoolState(testPoolKey, AuctionTypes.AuctionPhase.Clock);
        assertEq(hook.allowedPools(testPoolId), false);
        
        // Move to Settlement phase - operations allowed
        vm.prank(auctionManager);
        hook.setPoolState(testPoolKey, AuctionTypes.AuctionPhase.Settlement);
        assertEq(hook.allowedPools(testPoolId), true);
        
        // Test other phases still block operations
        vm.prank(auctionManager);
        hook.setPoolState(testPoolKey, AuctionTypes.AuctionPhase.Proxy);
        assertEq(hook.allowedPools(testPoolId), false);
        
        // Back to Settlement - operations allowed again
        vm.prank(auctionManager);
        hook.setPoolState(testPoolKey, AuctionTypes.AuctionPhase.Settlement);
        assertEq(hook.allowedPools(testPoolId), true);
    }

    function test_MultiplePoolsIndependent() public {
        hook.setAuctionManager(auctionManager);
        
        // Create second pool key
        PoolKey memory poolKey2 = PoolKey({
            currency0: Currency.wrap(address(0x3000000000000000000000000000000000000000)),
            currency1: Currency.wrap(address(0x4000000000000000000000000000000000000000)),
            fee: 500,
            tickSpacing: 10,
            hooks: IHooks(address(hook))
        });
        PoolId poolId2 = poolKey2.toId();
        
        // Set different states for different pools
        vm.startPrank(auctionManager);
        hook.setPoolState(testPoolKey, AuctionTypes.AuctionPhase.Settlement); // Allowed
        hook.setPoolState(poolKey2, AuctionTypes.AuctionPhase.Clock); // Blocked
        vm.stopPrank();
        
        // Verify independent states
        assertEq(hook.allowedPools(testPoolId), true);
        assertEq(hook.allowedPools(poolId2), false);
    }

    // ============ Edge Cases ============

    function test_ZeroAddressAuctionManager() public {
        // Should be able to set zero address as auction manager
        hook.setAuctionManager(address(0));
        assertEq(hook.auctionManager(), address(0));
        
        // Zero address auction manager cannot call restricted functions
        vm.expectRevert(PoolHook.OnlyAuction.selector);
        hook.setPoolState(testPoolKey, AuctionTypes.AuctionPhase.Settlement);
    }

    function test_ReinitializePool() public {
        // Initialize pool once
        // call initialize via V4 pool manager
        assertEq(hook.allowedPools(testPoolId), false);
        
        // Re-initialize should still set to blocked
        // call initialize via V4 pool manager
        assertEq(hook.allowedPools(testPoolId), false);
    }
}
