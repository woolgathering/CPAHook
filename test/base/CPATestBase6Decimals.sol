// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { CPATestBase } from "./CPATestBase.sol";
import { MockERC20 } from "solmate/src/test/utils/mocks/MockERC20.sol";

/**
 * @title CPATestBase6Decimals
 * @notice Test base with 6-decimal numeraire (USDC-like) and mixed asset decimals
 * @dev Tests the auction system with non-18-decimal tokens to ensure proper decimal handling
 * 
 * This test base extends CPATestBase to test scenarios with:
 * - 6-decimal numeraire (USDC-like)
 * - 18-decimal asset (standard ERC20)
 * - 6-decimal asset (USDT-like) for testing asset decimal variations
 * 
 * This ensures the auction system works correctly with mixed decimal precisions,
 * particularly testing the decimal conversion formulas in bid value calculations.
 */
abstract contract CPATestBase6Decimals is CPATestBase {
    function deployTokens() internal override {
        // 6-decimal numeraire (USDC-like)
        numeraireToken = new MockERC20("USDC", "USDC", 6);
        
        // 18-decimal asset (standard ERC20)
        asset1Token = new MockERC20("Asset 1", "AST1", 18);
        
        // 6-decimal asset (USDT-like) - tests asset decimal variations
        asset2Token = new MockERC20("Asset 2", "AST2", 6);
        
        vm.label(address(numeraireToken), "USDC");
        vm.label(address(asset1Token), "ASSET1_18D");
        vm.label(address(asset2Token), "ASSET2_6D");
        
        numeraireCurrencyId = uint256(uint160(address(numeraireToken)));
        
        // Reference prices (actual prices come from pools)
        // These are in 6-decimal USDC terms
        asset1InitialPrice = 1 * 10**6;  // 1 USDC per Asset1
        asset2InitialPrice = 2 * 10**6;  // 2 USDC per Asset2
    }
}
