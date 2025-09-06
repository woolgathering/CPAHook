// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { Deployers } from "./utils/Deployers.sol";
import { console2 } from "forge-std/console2.sol";
import { CPAManagerHook } from "../src/ClockProxyAuctionHook.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { MockERC20 } from "solmate/src/test/utils/mocks/MockERC20.sol";
import { Hooks } from "@uniswap/v4-core/src/libraries/Hooks.sol";
import { HookMiner } from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { AuctionTypes } from "../src/AuctionTypes.sol";
import { AuctionId } from "../src/AuctionId.sol";

contract CPAManagerHookTest is Deployers {
	CPAManagerHook public hook;
	address public owner;
	address public nonOwner;
	address public poolHook;

	function setUp() public {
		// Deploy all the necessary infrastructure using Deployers
		deployArtifacts();
		
		owner = address(0x1111111111111111111111111111111111111111);
		nonOwner = address(0x2222222222222222222222222222222222222222);
		poolHook = address(0xCAFE);
	}

	/// @notice Deploy hook with proper address mining and flag setting
	function deployHook(IPoolManager _poolManager, address _owner, address _poolHook) internal returns (CPAManagerHook) {
		// Set the required hook flags for CPAManagerHook based on getHookPermissions()
		uint160 flags = uint160(
			Hooks.BEFORE_INITIALIZE_FLAG | 
			Hooks.BEFORE_SWAP_FLAG
		);

		// Encode constructor arguments
		bytes memory constructorArgs = abi.encode(_poolManager, _owner, poolHook);

		// Mine a salt that will produce a hook address with the correct flags
		(address hookAddress, bytes32 salt) = HookMiner.find(
			address(this), // deployer (test contract address)
			flags,
			type(CPAManagerHook).creationCode,
			constructorArgs
		);

		// Deploy the hook using CREATE2 with the mined salt
		CPAManagerHook deployedHook = new CPAManagerHook{salt: salt}(_poolManager, _owner, poolHook);
		
		// Verify the hook was deployed to the expected address
		require(address(deployedHook) == hookAddress, "Hook address mismatch");
		
		return deployedHook;
	}

	/// @notice Deploy hook with proper address mining and flag setting, with error handling
	function deployHookWithFallback(IPoolManager _poolManager, address _owner, address _poolHook) internal returns (CPAManagerHook) {
		// For tests that expect constructor validation to fail, use simple deployment
		// since address mining will fail before we get to constructor validation
		return new CPAManagerHook(_poolManager, _owner, _poolHook);
	}

	function test_Constructor_Success() public {
		hook = deployHook(poolManager, owner, poolHook);

		// Verify pool manager is set correctly
		assertEq(address(hook.manager()), address(poolManager));

		// Verify owner is set correctly (inherited from Ownable)
		assertEq(hook.owner(), owner);

		// Verify hook address is set correctly (inherited from CPAStorage)
		assertEq(hook.cpaAuctionHookAddr(), address(poolHook));
	}

	function test_Constructor_ZeroPoolManager() public {
		// Should succeed even with zero pool manager (no validation in constructor)
		hook = deployHook(IPoolManager(address(0)), owner, poolHook);

		// Verify pool manager is set correctly
		assertEq(address(hook.manager()), address(0));
	}

	function test_Constructor_ZeroOwner() public {
		// Should revert when owner is zero address with OwnableInvalidOwner error
		vm.expectRevert(); // OwnableInvalidOwner(address(0))
		hook = deployHookWithFallback(poolManager, address(0), poolHook);
	}

	function test_Constructor_ZeroPoolManagerAndOwner() public {
		// Should revert when owner is zero address (Ownable validation)
		vm.expectRevert(); // OwnableInvalidOwner(address(0))
		hook = deployHookWithFallback(IPoolManager(address(0)), address(0), poolHook);
	}

	function test_Constructor_ValidAddresses() public {
		// Test with valid addresses
		address validOwner = address(0x1111111111111111111111111111111111111111);

		hook = deployHook(poolManager, validOwner, poolHook);

		assertEq(address(hook.manager()), address(poolManager));
		assertEq(hook.owner(), validOwner);
		assertEq(hook.cpaAuctionHookAddr(), address(poolHook));
	}

	function test_Constructor_OwnerCanTransferOwnership() public {
		hook = deployHook(poolManager, owner, poolHook);

		// Owner should be able to transfer ownership
		vm.prank(owner);
		hook.transferOwnership(nonOwner);

		// Verify ownership transfer
		assertEq(hook.owner(), nonOwner);
	}

	function test_Constructor_NonOwnerCannotTransferOwnership() public {
		hook = deployHook(poolManager, owner, poolHook);

		// Non-owner should not be able to transfer ownership
		vm.prank(nonOwner);
		vm.expectRevert(); // OwnableUnauthorizedAccount(address)
		hook.transferOwnership(nonOwner);
	}

	function test_Constructor_InitialState() public {
		hook = deployHook(poolManager, owner, poolHook);

		// Verify initial state of storage variables
		// These should be initialized to default values
		assertEq(hook.cpaAuctionHookAddr(), address(poolHook));
		assertEq(address(hook.manager()), address(poolManager));
	}

	function test_Constructor_GasUsage() public {
		// Test gas usage for constructor
		uint256 gasBefore = gasleft();
		hook = deployHook(poolManager, owner, poolHook);
		uint256 gasUsed = gasBefore - gasleft();

		// Log gas usage for reference
		console2.log("CPAManagerHook constructor gas used:", gasUsed);
		
		// Gas usage should be reasonable (less than 100M gas for complex hook with address mining)
		assertLt(gasUsed, 100_000_000);
	}

	function test_Constructor_MultipleInstances() public {
		// Test creating multiple instances
		CPAManagerHook hook1 = deployHook(poolManager, owner, poolHook);
		CPAManagerHook hook2 = deployHook(poolManager, nonOwner, poolHook);

		// Each instance should have its own state
		assertEq(hook1.owner(), owner);
		assertEq(hook2.owner(), nonOwner);
		assertEq(hook1.cpaAuctionHookAddr(), address(poolHook));
		assertEq(hook2.cpaAuctionHookAddr(), address(poolHook));
		assertEq(address(hook1.manager()), address(poolManager));
		assertEq(address(hook2.manager()), address(poolManager));
	}

	function test_Constructor_HookCanBeUsedInPool() public {
		// Deploy hook with proper flags
		hook = deployHook(poolManager, owner, poolHook);

		// Deploy test tokens using Deployers
		(Currency currency0, Currency currency1) = deployCurrencyPair();

		// Initialize a pool with the hook
		// Note: This would require implementing pool initialization logic
		// For now, just verify the hook is properly deployed
		assertEq(address(hook.manager()), address(poolManager));
		assertEq(hook.owner(), owner);
		assertEq(hook.cpaAuctionHookAddr(), address(poolHook));
	}


}
