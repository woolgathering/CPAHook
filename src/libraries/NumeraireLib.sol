// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Unified transfer helpers for ERC20 or native ETH numeraire.
///         address(0) is the sentinel for native ETH.
library NumeraireLib {
    using SafeERC20 for IERC20;

    function transfer(address token, address to, uint256 amount) internal {
        if (amount == 0) return;
        if (token == address(0)) {
            (bool ok,) = to.call{value: amount}("");
            require(ok, "ETH transfer failed");
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }

    /// @notice Pull tokens from `from` into this contract.
    ///         For ETH: validates that msg.value == amount (caller must be payable context).
    function transferFrom(address token, address from, uint256 amount, uint256 msgValue) internal {
        if (amount == 0) return;
        if (token == address(0)) {
            require(msgValue == amount, "ETH amount mismatch");
        } else {
            require(msgValue == 0, "ETH not accepted for ERC20 numeraire");
            IERC20(token).safeTransferFrom(from, address(this), amount);
        }
    }

    function balanceOf(address token, address account) internal view returns (uint256) {
        return token == address(0) ? account.balance : IERC20(token).balanceOf(account);
    }
}
