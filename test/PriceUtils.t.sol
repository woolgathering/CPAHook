// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { CPATestBase } from "./base/CPATestBase.sol";
import { PriceUtils } from "../src/utils/PriceUtils.sol";
import { console } from "forge-std/console.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";

contract PriceUtilsTest is CPATestBase {

    function setUp() public override {
        super.setUp();
        
    }   

    function testPrintPrices() public {
        // Initialize asset1 pool
        poolManager.initialize(asset1PoolKey, 79228162514264337593543950336); // sqrtPriceX96 for price ~1
        
        // Initialize asset2 pool  
        poolManager.initialize(asset2PoolKey, 112045541949572287496682733568); // sqrtPriceX96 for price ~2

        // Test asset1 pool prices
        uint256 asset1Price0 = PriceUtils.getPriceOfCurrency0(poolManager, asset1PoolKey);
        uint256 asset1Price1 = PriceUtils.getPriceOfCurrency1(poolManager, asset1PoolKey);

        console.log("=== Asset1 Pool Prices ===");
        console.log("Price of Currency0 in terms of Currency1 (fixed-point):", asset1Price0);
        console.log("Price of Currency1 in terms of Currency0 (fixed-point):", asset1Price1);

        // Test asset2 pool prices
        uint256 asset2Price0 = PriceUtils.getPriceOfCurrency0(poolManager, asset2PoolKey);
        uint256 asset2Price1 = PriceUtils.getPriceOfCurrency1(poolManager, asset2PoolKey);

        console.log("=== Asset2 Pool Prices ===");
        console.log("Price of Currency0 in terms of Currency1 (fixed-point):", asset2Price0);
        console.log("Price of Currency1 in terms of Currency0 (fixed-point):", asset2Price1);

        // Test getting price of specific currencies
        uint256 asset1PriceInNumeraire = PriceUtils.getPriceOfCurrency(
            poolManager, 
            asset1PoolKey, 
            address(asset1Token)
        );
        uint256 asset2PriceInNumeraire = PriceUtils.getPriceOfCurrency(
            poolManager, 
            asset2PoolKey, 
            address(asset2Token)
        );

        console.log("=== Asset Prices in Numeraire ===");
        console.log("Asset1 price in numeraire:", asset1PriceInNumeraire);
        console.log("Asset2 price in numeraire:", asset2PriceInNumeraire);
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

    // Fuzz tests for comprehensive price testing
    function testFuzzPriceConsistency(uint160 sqrtPriceX96) public {
        // Bound the sqrtPriceX96 to reasonable values (avoiding overflow/underflow)
        vm.assume(sqrtPriceX96 >= 4295128739); // ~0.0001 price
        vm.assume(sqrtPriceX96 <= 79228162514264337593543950336); // ~1 price (more conservative upper bound)
        
        // Initialize pool with fuzzed price
        poolManager.initialize(asset1PoolKey, sqrtPriceX96);
        
        // Test that getPriceOfCurrency0 and getPriceOfCurrency1 are consistent
        uint256 price0 = PriceUtils.getPriceOfCurrency0(poolManager, asset1PoolKey);
        uint256 price1 = PriceUtils.getPriceOfCurrency1(poolManager, asset1PoolKey);
        
        // price0 * price1 should equal 1e18 (within precision tolerance)
        uint256 product = (price0 * price1) / 1e18;
        assertApproxEqRel(product, 1e18, 0.01e18, "Price0 * Price1 should equal 1e18");
    }

    function testFuzzDirectVsCurrencyFunctions(uint160 sqrtPriceX96) public {
        // Bound the sqrtPriceX96 to reasonable values
        vm.assume(sqrtPriceX96 >= 4295128739); // ~0.0001 price
        vm.assume(sqrtPriceX96 <= 79228162514264337593543950336); // ~1 price (more conservative upper bound)
        
        // Initialize pool with fuzzed price
        poolManager.initialize(asset1PoolKey, sqrtPriceX96);
        
        // Test that direct currency price matches currency0/currency1 functions
        uint256 directAsset1Price = PriceUtils.getPriceOfCurrency(
            poolManager, 
            asset1PoolKey, 
            address(asset1Token)
        );
        uint256 directNumerairePrice = PriceUtils.getPriceOfCurrency(
            poolManager, 
            asset1PoolKey, 
            address(numeraireToken)
        );
        
        uint256 currency0Price = PriceUtils.getPriceOfCurrency0(poolManager, asset1PoolKey);
        uint256 currency1Price = PriceUtils.getPriceOfCurrency1(poolManager, asset1PoolKey);
        
        // Check which currency is which and verify consistency
        if (Currency.unwrap(asset1PoolKey.currency0) == address(asset1Token)) {
            assertEq(directAsset1Price, currency0Price, "Direct asset1 price should match currency0 price");
            assertEq(directNumerairePrice, currency1Price, "Direct numeraire price should match currency1 price");
        } else {
            assertEq(directAsset1Price, currency1Price, "Direct asset1 price should match currency1 price");
            assertEq(directNumerairePrice, currency0Price, "Direct numeraire price should match currency0 price");
        }
    }

    function testFuzzPriceInversion(uint160 sqrtPriceX96) public {
        // Bound the sqrtPriceX96 to reasonable values
        vm.assume(sqrtPriceX96 >= 4295128739); // ~0.0001 price
        vm.assume(sqrtPriceX96 <= 79228162514264337593543950336); // ~1 price (more conservative upper bound)
        
        // Initialize pool with fuzzed price
        poolManager.initialize(asset1PoolKey, sqrtPriceX96);
        
        // Test price inversion: if asset1 costs X numeraire, then 1 numeraire should cost 1/X asset1
        uint256 asset1InNumeraire = PriceUtils.getPriceOfCurrency(
            poolManager, 
            asset1PoolKey, 
            address(asset1Token)
        );
        uint256 numeraireInAsset1 = PriceUtils.getPriceOfCurrency(
            poolManager, 
            asset1PoolKey, 
            address(numeraireToken)
        );
        
        // asset1InNumeraire * numeraireInAsset1 should equal 1e18 (within precision tolerance)
        uint256 product = (asset1InNumeraire * numeraireInAsset1) / 1e18;
        assertApproxEqRel(product, 1e18, 0.01e18, "Price inversion should be consistent");
    }

    function testFuzzPriceRange(uint160 sqrtPriceX96) public {
        // Bound the sqrtPriceX96 to reasonable values
        vm.assume(sqrtPriceX96 >= 4295128739); // ~0.0001 price
        vm.assume(sqrtPriceX96 <= 79228162514264337593543950336); // ~1 price (more conservative upper bound)
        
        // Initialize pool with fuzzed price
        poolManager.initialize(asset1PoolKey, sqrtPriceX96);
        
        // Test that prices are within reasonable bounds
        uint256 asset1Price = PriceUtils.getPriceOfCurrency(
            poolManager, 
            asset1PoolKey, 
            address(asset1Token)
        );
        
        // Price should be positive and not overflow
        assertGt(asset1Price, 0, "Price should be positive");
        assertLt(asset1Price, type(uint128).max, "Price should not overflow");
        
        // Test that the price calculation doesn't revert
        uint256 numerairePrice = PriceUtils.getPriceOfCurrency(
            poolManager, 
            asset1PoolKey, 
            address(numeraireToken)
        );
        assertGt(numerairePrice, 0, "Numeraire price should be positive");
    }

    function testFuzzMultiplePools(uint160 sqrtPriceX96_1, uint160 sqrtPriceX96_2) public {
        // Bound the sqrtPriceX96 values to reasonable ranges
        vm.assume(sqrtPriceX96_1 >= 4295128739 && sqrtPriceX96_1 <= 79228162514264337593543950336);
        vm.assume(sqrtPriceX96_2 >= 4295128739 && sqrtPriceX96_2 <= 79228162514264337593543950336);
        
        // Initialize both pools with different fuzzed prices
        poolManager.initialize(asset1PoolKey, sqrtPriceX96_1);
        poolManager.initialize(asset2PoolKey, sqrtPriceX96_2);
        
        // Test that both pools work independently
        uint256 asset1Price = PriceUtils.getPriceOfCurrency(
            poolManager, 
            asset1PoolKey, 
            address(asset1Token)
        );
        uint256 asset2Price = PriceUtils.getPriceOfCurrency(
            poolManager, 
            asset2PoolKey, 
            address(asset2Token)
        );
        
        // Both prices should be positive
        assertGt(asset1Price, 0, "Asset1 price should be positive");
        assertGt(asset2Price, 0, "Asset2 price should be positive");
        
        // Test that pools don't interfere with each other
        uint256 asset1PriceAgain = PriceUtils.getPriceOfCurrency(
            poolManager, 
            asset1PoolKey, 
            address(asset1Token)
        );
        assertEq(asset1Price, asset1PriceAgain, "Asset1 price should be consistent");
    }
}
