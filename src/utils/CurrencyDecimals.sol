// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { IERC20 } from "forge-std/interfaces/IERC20.sol";

/**
 * @title CurrencyDecimals
 * @notice Helper library to safely get decimal precision for both native ETH and ERC20 tokens
 * @dev Handles the special case where address(0) represents native ETH
 * @author Clock-Proxy Auction Team
 */
library CurrencyDecimals {
    /**
     * @notice Get the decimal precision for a currency
     * @param currency The currency address (address(0) for native ETH)
     * @return decimals The number of decimals (18 for ETH, token.decimals() for ERC20)
     */
    function getDecimals(address currency) internal view returns (uint8) {
        if (currency == address(0)) {
            return 18; // Native ETH has 18 decimals
        }
        return IERC20(currency).decimals();
    }
}

