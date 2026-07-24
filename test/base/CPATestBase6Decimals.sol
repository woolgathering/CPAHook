// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { CPATestBase } from "./CPATestBase.sol";
import { MockERC20 } from "solmate/src/test/utils/mocks/MockERC20.sol";

/// @notice Test base with 6-decimal numeraire (USDC-like) and mixed asset decimals.
abstract contract CPATestBase6Decimals is CPATestBase {
    function deployTokens() internal override {
        numeraireToken = new MockERC20("USDC",    "USDC", 6);
        asset1Token    = new MockERC20("Asset 1", "AST1", 18);
        asset2Token    = new MockERC20("Asset 2", "AST2", 6);

        vm.label(address(numeraireToken), "USDC");
        vm.label(address(asset1Token),    "ASSET1_18D");
        vm.label(address(asset2Token),    "ASSET2_6D");

        // Starting prices in 6-decimal (USDC) terms
        asset1StartingPrice  = 1e6;
        asset2StartingPrice  = 2e6;
        asset1PriceIncrement = 0.1e6;
        asset2PriceIncrement = 0.2e6;
    }
}
