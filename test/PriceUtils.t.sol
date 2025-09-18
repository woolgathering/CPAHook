// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { CPATestBase } from "./base/CPATestBase.sol";
import { PriceUtils } from "../src/utils/PriceUtils.sol";
import { console } from "forge-std/console.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { FullMath } from "@uniswap/v4-core/src/libraries/FullMath.sol";
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

contract PriceUtilsTest is CPATestBase {

    function setUp() public override {
        super.setUp();
        
    }

    function testAsset1PoolPrices() public {
        // Initialize asset1 pool with price ~1
        poolManager.initialize(asset1PoolKey, 79228162514264337593543950336); // sqrtPriceX96 for price ~1
        
        // Asset1 pool should have price ~1 (1 numeraire per asset1)
        uint256 asset1PriceInNumeraire = PriceUtils.getPriceOfCurrency(
            poolManager, 
            asset1PoolKey, 
            address(asset1Token)
        );
        uint256 numerairePriceInAsset1 = PriceUtils.getPriceOfCurrency(
            poolManager, 
            asset1PoolKey, 
            address(numeraireToken)
        );

        // Asset1 should cost ~1 numeraire (with 1% tolerance)
        assertApproxEqRel(asset1PriceInNumeraire, 1e18, 0.01e18, "Asset1 price should be ~1 numeraire");
        
        // 1 numeraire should cost ~1 asset1 (with 1% tolerance)
        assertApproxEqRel(numerairePriceInAsset1, 1e18, 0.01e18, "Numeraire price should be ~1 asset1");
    }

    function testAsset2PoolPrices() public {
        // Initialize asset2 pool with price ~2
        poolManager.initialize(asset2PoolKey, 112045541949572287496682733568); // sqrtPriceX96 for price ~2
        
        // Asset2 pool should have price ~2 (2 numeraire per asset2)
        uint256 asset2PriceInNumeraire = PriceUtils.getPriceOfCurrency(
            poolManager, 
            asset2PoolKey, 
            address(asset2Token)
        );
        uint256 numerairePriceInAsset2 = PriceUtils.getPriceOfCurrency(
            poolManager, 
            asset2PoolKey, 
            address(numeraireToken)
        );

        // Asset2 should cost ~2 numeraire (with 1% tolerance)
        assertApproxEqRel(asset2PriceInNumeraire, 2e18, 0.02e18, "Asset2 price should be ~2 numeraire");
        
        // 1 numeraire should cost ~0.5 asset2 (with 1% tolerance)
        assertApproxEqRel(numerairePriceInAsset2, 0.5e18, 0.005e18, "Numeraire price should be ~0.5 asset2");
    }

    function testCurrency0AndCurrency1Prices() public {
        // Initialize both pools
        poolManager.initialize(asset1PoolKey, 79228162514264337593543950336); // sqrtPriceX96 for price ~1
        poolManager.initialize(asset2PoolKey, 112045541949572287496682733568); // sqrtPriceX96 for price ~2
        
        // Test the getPriceOfCurrency0 and getPriceOfCurrency1 functions
        uint256 asset1Price0 = PriceUtils.getPriceOfCurrency0(poolManager, asset1PoolKey);
        uint256 asset1Price1 = PriceUtils.getPriceOfCurrency1(poolManager, asset1PoolKey);
        
        uint256 asset2Price0 = PriceUtils.getPriceOfCurrency0(poolManager, asset2PoolKey);
        uint256 asset2Price1 = PriceUtils.getPriceOfCurrency1(poolManager, asset2PoolKey);

        // For asset1 pool: currency0 should be asset1, currency1 should be numeraire
        // Asset1 (currency0) should cost ~1 numeraire (currency1)
        assertApproxEqRel(asset1Price0, 1e18, 0.01e18, "Asset1 currency0 price should be ~1");
        
        // Numeraire (currency1) should cost ~1 asset1 (currency0)
        assertApproxEqRel(asset1Price1, 1e18, 0.01e18, "Asset1 currency1 price should be ~1");

        // For asset2 pool: currency0 should be asset2, currency1 should be numeraire
        // Asset2 (currency0) should cost ~2 numeraire (currency1)
        assertApproxEqRel(asset2Price0, 2e18, 0.02e18, "Asset2 currency0 price should be ~2");
        
        // Numeraire (currency1) should cost ~0.5 asset2 (currency0)
        assertApproxEqRel(asset2Price1, 0.5e18, 0.005e18, "Asset2 currency1 price should be ~0.5");
    }

    function testPriceConsistency() public {
        // Initialize both pools
        poolManager.initialize(asset1PoolKey, 79228162514264337593543950336); // sqrtPriceX96 for price ~1
        poolManager.initialize(asset2PoolKey, 112045541949572287496682733568); // sqrtPriceX96 for price ~2
        
        // Test that prices are consistent between different methods
        uint256 asset1DirectPrice = PriceUtils.getPriceOfCurrency(
            poolManager, 
            asset1PoolKey, 
            address(asset1Token)
        );
        uint256 asset1Currency0Price = PriceUtils.getPriceOfCurrency0(poolManager, asset1PoolKey);
        
        // These should be the same (assuming asset1 is currency0)
        if (Currency.unwrap(asset1PoolKey.currency0) == address(asset1Token)) {
            assertEq(asset1DirectPrice, asset1Currency0Price, "Direct price should match currency0 price");
        } else {
            assertEq(asset1DirectPrice, PriceUtils.getPriceOfCurrency1(poolManager, asset1PoolKey), "Direct price should match currency1 price");
        }

        uint256 asset2DirectPrice = PriceUtils.getPriceOfCurrency(
            poolManager, 
            asset2PoolKey, 
            address(asset2Token)
        );
        uint256 asset2Currency0Price = PriceUtils.getPriceOfCurrency0(poolManager, asset2PoolKey);
        
        // These should be the same (assuming asset2 is currency0)
        if (Currency.unwrap(asset2PoolKey.currency0) == address(asset2Token)) {
            assertEq(asset2DirectPrice, asset2Currency0Price, "Direct price should match currency0 price");
        } else {
            assertEq(asset2DirectPrice, PriceUtils.getPriceOfCurrency1(poolManager, asset2PoolKey), "Direct price should match currency1 price");
        }
    }

    // Simple test to verify PriceUtils works
    function testPriceUtilsBasic() public {
        // Use a reasonable price that should work
        uint160 testPrice = 79228162514264337593543950336; // sqrtPriceX96 for price ~1
        poolManager.initialize(asset1PoolKey, testPrice);
        
        // This should work without reverting
        uint256 price = PriceUtils.getPriceOfCurrency(poolManager, asset1PoolKey, address(asset1Token));
        assertGt(price, 0, "Price should be positive");
    }

}
