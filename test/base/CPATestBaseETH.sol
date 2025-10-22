// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { MockERC20 } from "solmate/src/test/utils/mocks/MockERC20.sol";
import { CPATestBase } from "./CPATestBase.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { PriceUtils } from "../../src/utils/PriceUtils.sol";
import { CurrencyDecimals } from "../../src/utils/CurrencyDecimals.sol";

/**
 * @title CPATestBaseETH
 * @notice Test base for CPA tests using ETH as numeraire
 * @dev This class overrides deployTokens to use ETH (address(0)) as numeraire
 *      and standard ERC20 assets. Tests ETH handling in auctions.
 */
abstract contract CPATestBaseETH is CPATestBase {
    /// @notice Deploy test tokens with ETH as numeraire
    function deployTokens() internal override {
        // ETH numeraire - we can't create a MockERC20 for ETH
        // Instead, we'll use a special approach for ETH testing
        numeraireToken = MockERC20(address(0)); // This will be handled specially in tests
        
        // 18-decimal asset (standard ERC20)
        asset1Token = new MockERC20("Asset 1 Token (18 Decimals)", "AST1_18", 18);
        // 6-decimal asset (USDT-like)
        asset2Token = new MockERC20("Asset 2 Token (6 Decimals)", "AST2_6", 6);
        
        // Label tokens for easier tracking in test output
        vm.label(address(0), "ETH_NUMERAIRE");
        vm.label(address(asset1Token), "ASSET1_18DEC");
        vm.label(address(asset2Token), "ASSET2_6DEC");
        
        numeraireCurrencyId = uint256(uint160(address(0))); // ETH currency ID
        
        // Set reference prices (actual prices come from pools)
        // Prices are in 18-decimal terms for ETH numeraire
        asset1InitialPrice = 1 * 10**9; // 1 ETH per Asset1
        asset2InitialPrice = 2 * 10**9; // 2 ETH per Asset2
    }

    /// @notice Calculate bid value at current pool prices for ETH numeraire
    function calculateBidValue(uint256[] memory demands) internal view override returns (uint256) {
        uint256 totalValue = 0;
        PoolKey[] memory poolKeys = new PoolKey[](2);
        poolKeys[0] = asset1PoolKey;
        poolKeys[1] = asset2PoolKey;
        
        // ETH has 18 decimals
        uint8 numeraireDecimals = 18;
        
        for (uint256 i = 0; i < demands.length && i < poolKeys.length; i++) {
            uint256 price;
            if (Currency.unwrap(poolKeys[i].currency0) == address(0)) {
                price = PriceUtils.getPriceOfCurrency1(poolManager, poolKeys[i]);
            } else {
                price = PriceUtils.getPriceOfCurrency0(poolManager, poolKeys[i]);
            }
            
            // Get asset decimals for this pool
            address assetCurrency;
            if (Currency.unwrap(poolKeys[i].currency0) == address(0)) {
                assetCurrency = Currency.unwrap(poolKeys[i].currency1);
            } else {
                assetCurrency = Currency.unwrap(poolKeys[i].currency0);
            }
            uint8 assetDecimals = CurrencyDecimals.getDecimals(assetCurrency);
            
            // Apply the same decimal conversion formula as the contract:
            // (quantity * price * 10^numeraireDecimals) / (10^(18 + assetDecimals))
            totalValue += (demands[i] * price * (10**numeraireDecimals)) / (10**(18 + assetDecimals));
        }
        
        return totalValue;
    }
}
