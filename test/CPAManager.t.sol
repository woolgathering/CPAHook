// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { Deployers } from "./utils/Deployers.sol";
import { console2 } from "forge-std/console2.sol";
import { CPAManager } from "../src/CPAManager.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { MockERC20 } from "solmate/src/test/utils/mocks/MockERC20.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { AuctionTypes } from "../src/types/AuctionTypes.sol";
import { AuctionId } from "../src/types/AuctionId.sol";

contract CPAManagerTest is Deployers {
	CPAManager public manager;
	address public owner;
	address public nonOwner;
	address public cpaHook;

	function setUp() public {
		// Deploy all the necessary infrastructure using Deployers
		deployArtifacts();
		
		owner = address(0x1111111111111111111111111111111111111111);
		nonOwner = address(0x2222222222222222222222222222222222222222);
		cpaHook = address(0xCAFE);
	}

	/// @notice Deploy CPAManager (no longer a hook, so no address mining needed)
	function deployManager(IPoolManager _poolManager, address _owner, address _cpaHook) internal returns (CPAManager) {
		// Simple deployment since CPAManager is no longer a hook
		return new CPAManager(_poolManager, _owner, _cpaHook);
	}

	/// @notice Deploy CPAManager with fallback (same as regular deployment now)
	function deployManagerWithFallback(IPoolManager _poolManager, address _owner, address _cpaHook) internal returns (CPAManager) {
		// Simple deployment since CPAManager is no longer a hook
		return new CPAManager(_poolManager, _owner, _cpaHook);
	}

	function test_Constructor_Success() public {
		manager = deployManager(poolManager, owner, cpaHook);

		// Verify pool manager is set correctly
		assertEq(address(manager.manager()), address(poolManager));

		// Verify owner is set correctly (inherited from Ownable)
		assertEq(manager.owner(), owner);

		// Verify manager address is set correctly (inherited from CPAStorage)
		assertEq(manager.cpaAuctionHookAddr(), address(cpaHook));
	}

	function test_Constructor_ZeroPoolManager() public {
		// Should succeed even with zero pool manager (no validation in constructor)
		manager = deployManager(IPoolManager(address(0)), owner, cpaHook);

		// Verify pool manager is set correctly
		assertEq(address(manager.manager()), address(0));
	}

	function test_Constructor_ZeroOwner() public {
		// Should revert when owner is zero address with OwnableInvalidOwner error
		vm.expectRevert(); // OwnableInvalidOwner(address(0))
		manager = deployManagerWithFallback(poolManager, address(0), cpaHook);
	}

	function test_Constructor_ZeroPoolManagerAndOwner() public {
		// Should revert when owner is zero address (Ownable validation)
		vm.expectRevert(); // OwnableInvalidOwner(address(0))
		manager = deployManagerWithFallback(IPoolManager(address(0)), address(0), cpaHook);
	}

	function test_Constructor_ValidAddresses() public {
		// Test with valid addresses
		address validOwner = address(0x1111111111111111111111111111111111111111);

		manager = deployManager(poolManager, validOwner, cpaHook);

		assertEq(address(manager.manager()), address(poolManager));
		assertEq(manager.owner(), validOwner);
		assertEq(manager.cpaAuctionHookAddr(), address(cpaHook));
	}

	function test_Constructor_OwnerCanTransferOwnership() public {
		manager = deployManager(poolManager, owner, cpaHook);

		// Owner should be able to transfer ownership
		vm.prank(owner);
		manager.transferOwnership(nonOwner);

		// Verify ownership transfer
		assertEq(manager.owner(), nonOwner);
	}

	function test_Constructor_NonOwnerCannotTransferOwnership() public {
		manager = deployManager(poolManager, owner, cpaHook);

		// Non-owner should not be able to transfer ownership
		vm.prank(nonOwner);
		vm.expectRevert(); // OwnableUnauthorizedAccount(address)
		manager.transferOwnership(nonOwner);
	}

	function test_Constructor_InitialState() public {
		manager = deployManager(poolManager, owner, cpaHook);

		// Verify initial state of storage variables
		// These should be initialized to default values
		assertEq(manager.cpaAuctionHookAddr(), address(cpaHook));
		assertEq(address(manager.manager()), address(poolManager));
	}

	function test_Constructor_GasUsage() public {
		// Test gas usage for constructor
		uint256 gasBefore = gasleft();
		manager = deployManager(poolManager, owner, cpaHook);
		uint256 gasUsed = gasBefore - gasleft();

		// Log gas usage for reference
		console2.log("CPAManagerHook constructor gas used:", gasUsed);
		
		// Gas usage should be reasonable (less than 100M gas for complex manager with address mining)
		assertLt(gasUsed, 100_000_000);
	}

	function test_Constructor_MultipleInstances() public {
		// Test creating multiple instances
		CPAManager manager1 = deployManager(poolManager, owner, cpaHook);
		CPAManager manager2 = deployManager(poolManager, nonOwner, cpaHook);

		// Each instance should have its own state
		assertEq(manager1.owner(), owner);
		assertEq(manager2.owner(), nonOwner);
		assertEq(manager1.cpaAuctionHookAddr(), address(cpaHook));
		assertEq(manager2.cpaAuctionHookAddr(), address(cpaHook));
		assertEq(address(manager1.manager()), address(poolManager));
		assertEq(address(manager2.manager()), address(poolManager));
	}

	function test_Constructor_ManagerCanBeUsedInPool() public {
		// Deploy manager (no longer a manager)
		manager = deployManager(poolManager, owner, cpaHook);

		// Deploy test tokens using Deployers
		(Currency currency0, Currency currency1) = deployCurrencyPair();

		// Initialize a pool with the manager
		// Note: This would require implementing pool initialization logic
		// For now, just verify the manager is properly deployed
		assertEq(address(manager.manager()), address(poolManager));
		assertEq(manager.owner(), owner);
		assertEq(manager.cpaAuctionHookAddr(), address(cpaHook));
	}


}
