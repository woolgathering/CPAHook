// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { PoolHook } from "../src/PoolHook.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

contract PoolHookTest is Test {
	PoolHook public poolHook;
	address public auction;
	address public poolManager;

	function setUp() public {
		auction = address(0x123);
		poolManager = address(0x456);
		
		poolHook = new PoolHook(IPoolManager(poolManager), auction);
	}

	function test_Constructor() public {
		assertEq(poolHook.auction(), auction);
		assertEq(poolHook.blocked(), false);
	}

	function test_SetBlocked_OnlyAuction() public {
		// Should fail if not called by auction
		vm.expectRevert(PoolHook.OnlyAuction.selector);
		poolHook.setBlocked(true);
	}

	function test_SetBlocked_Success() public {
		// Should succeed if called by auction
		vm.prank(auction);
		poolHook.setBlocked(true);
		assertEq(poolHook.blocked(), true);
	}
}
