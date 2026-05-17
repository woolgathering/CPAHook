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
        poolManager.initialize(asset1PoolKey, 79228162514264337593543950336);

        uint256 asset1PriceInNumeraire = PriceUtils.getPriceOfCurrency(
            poolManager, asset1PoolKey, address(asset1Token), address(mathFacet)
        );
        uint256 numerairePriceInAsset1 = PriceUtils.getPriceOfCurrency(
            poolManager, asset1PoolKey, address(numeraireToken), address(mathFacet)
        );

        assertApproxEqRel(asset1PriceInNumeraire, 1e18, 0.01e18, "Asset1 price should be ~1 numeraire");
        assertApproxEqRel(numerairePriceInAsset1, 1e18, 0.01e18, "Numeraire price should be ~1 asset1");
    }

    function testAsset2PoolPrices() public {
        poolManager.initialize(asset2PoolKey, 112045541949572287496682733568);

        uint256 asset2PriceInNumeraire = PriceUtils.getPriceOfCurrency(
            poolManager, asset2PoolKey, address(asset2Token), address(mathFacet)
        );
        uint256 numerairePriceInAsset2 = PriceUtils.getPriceOfCurrency(
            poolManager, asset2PoolKey, address(numeraireToken), address(mathFacet)
        );

        assertApproxEqRel(asset2PriceInNumeraire, 2e18, 0.02e18, "Asset2 price should be ~2 numeraire");
        assertApproxEqRel(numerairePriceInAsset2, 0.5e18, 0.005e18, "Numeraire price should be ~0.5 asset2");
    }

    function testCurrency0AndCurrency1Prices() public {
        poolManager.initialize(asset1PoolKey, 79228162514264337593543950336);
        poolManager.initialize(asset2PoolKey, 112045541949572287496682733568);

        uint256 asset1Price0 = PriceUtils.getPriceOfCurrency0(poolManager, asset1PoolKey, address(mathFacet));
        uint256 asset1Price1 = PriceUtils.getPriceOfCurrency1(poolManager, asset1PoolKey, address(mathFacet));

        uint256 asset2Price0 = PriceUtils.getPriceOfCurrency0(poolManager, asset2PoolKey, address(mathFacet));
        uint256 asset2Price1 = PriceUtils.getPriceOfCurrency1(poolManager, asset2PoolKey, address(mathFacet));

        assertApproxEqRel(asset1Price0, 1e18, 0.01e18, "Asset1 currency0 price should be ~1");
        assertApproxEqRel(asset1Price1, 1e18, 0.01e18, "Asset1 currency1 price should be ~1");
        assertApproxEqRel(asset2Price0, 2e18, 0.02e18, "Asset2 currency0 price should be ~2");
        assertApproxEqRel(asset2Price1, 0.5e18, 0.005e18, "Asset2 currency1 price should be ~0.5");
    }

    function testPriceConsistency() public {
        poolManager.initialize(asset1PoolKey, 79228162514264337593543950336);
        poolManager.initialize(asset2PoolKey, 112045541949572287496682733568);

        uint256 asset1DirectPrice = PriceUtils.getPriceOfCurrency(
            poolManager, asset1PoolKey, address(asset1Token), address(mathFacet)
        );
        uint256 asset1Currency0Price = PriceUtils.getPriceOfCurrency0(poolManager, asset1PoolKey, address(mathFacet));

        if (Currency.unwrap(asset1PoolKey.currency0) == address(asset1Token)) {
            assertEq(asset1DirectPrice, asset1Currency0Price, "Direct price should match currency0 price");
        } else {
            assertEq(asset1DirectPrice, PriceUtils.getPriceOfCurrency1(poolManager, asset1PoolKey, address(mathFacet)), "Direct price should match currency1 price");
        }

        uint256 asset2DirectPrice = PriceUtils.getPriceOfCurrency(
            poolManager, asset2PoolKey, address(asset2Token), address(mathFacet)
        );
        uint256 asset2Currency0Price = PriceUtils.getPriceOfCurrency0(poolManager, asset2PoolKey, address(mathFacet));

        if (Currency.unwrap(asset2PoolKey.currency0) == address(asset2Token)) {
            assertEq(asset2DirectPrice, asset2Currency0Price, "Direct price should match currency0 price");
        } else {
            assertEq(asset2DirectPrice, PriceUtils.getPriceOfCurrency1(poolManager, asset2PoolKey, address(mathFacet)), "Direct price should match currency1 price");
        }
    }

    function testPriceUtilsBasic() public {
        uint160 testPrice = 79228162514264337593543950336;
        poolManager.initialize(asset1PoolKey, testPrice);

        uint256 price = PriceUtils.getPriceOfCurrency(poolManager, asset1PoolKey, address(asset1Token), address(mathFacet));
        assertGt(price, 0, "Price should be positive");
    }
}
