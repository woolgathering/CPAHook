// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { BaseHook } from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { Hooks } from "@uniswap/v4-core/src/libraries/Hooks.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { PoolUtils } from "../utils/PoolUtils.sol";
import { AuctionTypes } from "../AuctionTypes.sol";
import { CPAStorage } from "../base/CPAStorage.sol";
import { IClockProxyAuction } from "../interfaces/IClockProxyAuction.sol";
import { IErrorsAndEvents } from "../utils/IErrorsAndEvents.sol";

library CPASetup {
	using PoolUtils for IPoolManager;

    /**
	 * @notice Validate pool addition and return pool info
	 * @param poolKey The V4 pool key
	 * @param depositAmount Amount deposited for auction
	 * @param _poolManager The pool manager
	 * @param _commonNumeraire The common numeraire token
	 * @return poolId The pool ID
	 * @return poolInfo The pool info struct
	 * @return isCurrency0Numeraire Whether currency0 is the numeraire
	 */
	function validateAndPreparePool(
		PoolKey calldata poolKey,
		uint256 depositAmount,
		IPoolManager _poolManager,
		address _commonNumeraire
	) external view returns (PoolId poolId, AuctionTypes.PoolInfo memory poolInfo, bool isCurrency0Numeraire) {
		// Ensure one of the currencies is the common numeraire
		if (address(Currency.unwrap(poolKey.currency1)) != _commonNumeraire && address(Currency.unwrap(poolKey.currency0)) != _commonNumeraire) {
			revert IErrorsAndEvents.InvalidNumeraire();
		}

		// assure that this is a new pool that hasn't been initialized by PoolManager
		if (_poolManager.poolExists(poolKey)) {
			revert IErrorsAndEvents.PoolAlreadyExists();
		}

		poolId = poolKey.toId();
		isCurrency0Numeraire = address(Currency.unwrap(poolKey.currency0)) == _commonNumeraire;
		
		poolInfo = AuctionTypes.PoolInfo({
			key: poolKey,
			currentPrice: 0,         // Will be set during clock phase
			depositAmount: depositAmount,
			excessDemand: 0          // Will be calculated during clock phase
		});
	}

    function confirmSetupComplete(CPAStorage self) internal view returns (bool) {
        // go through the pools and check that the deposit amounts match
        // for now we're just storing the deposits in the hook itself

        PoolId[] memory pools = self.getAllPools();
        for (uint256 i = 0; i < pools.length; i++) {
            PoolId poolId = pools[i];
            (PoolKey memory key, uint256 currentPrice, uint256 depositAmount, uint256 excessDemand) = self.poolInfo(poolId);
            // Check if the non-numeraire token balance matches the deposit amount
            if (IERC20(Currency.unwrap(key.currency0)).balanceOf(address(this)) != depositAmount && 
                IERC20(Currency.unwrap(key.currency1)).balanceOf(address(this)) != depositAmount) {
                return false;
            }
        }
        return true;
    }
}
