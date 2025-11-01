// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CurrencySettler} from "@openzeppelin/uniswap-hooks/src/utils/CurrencySettler.sol";

import { CPAStorage } from "../base/CPAStorage.sol";
import { StorageAccess } from "../utils/StorageAccess.sol";
import { IErrorsAndEvents } from "../utils/IErrorsAndEvents.sol";
import { AuctionTypes } from "../types/AuctionTypes.sol";
import { AuctionId, AuctionIdLibrary } from "../types/AuctionId.sol";

contract CPASetup {
	using CurrencySettler for Currency;
	using StorageAccess for *;

	/**
	 * @notice Create a new auction with the given configuration
	 * @param self The contract instance (CPAManager via DELEGATECALL)
	 * @param config The auction configuration (includes pool keys, initial prices, and price increments)
	 * @param auctionOwner The auction owner
	 * @dev Storage mappings are accessed directly via self since DELEGATECALL executes in CPAManager's storage context
	 */
	function createAuction(
		CPAStorage self,
		AuctionTypes.AuctionConfig memory config, 
		address auctionOwner
	) public returns (AuctionId) {
		// we need to create the auction id
		// then we need to check that all the pools have the same numeraire
		// then we need to check that the hook in the pools matches the cpaAuctionHookAddr
		// then we need to do the following mappings:
		// - auction id to auction owner
		// - auction id to auction config
		// - auction id to auction info 
		// - auction id to pool info for each pool
		// - auction id to common numeraire

		// create the auction id
		AuctionId auctionId = AuctionIdLibrary.createId(config.poolKeys);

		// ensure all pools share the same numeraire and are controlled by the correct auction hook.
		// map each pool to the new auctionId and set up core auction state.
		address numeraireAddress = config.commonNumeraire;
		
		// Note: commonNumeraire is now stored in auctionInfo, not in a separate mapping
		
		// Validate array lengths match
		if (config.poolKeys.length != config.initialSqrtPricesX96.length || config.poolKeys.length != config.priceIncrements.length) {
			revert IErrorsAndEvents.InvalidBidsLength();
		}

		for (uint256 i = 0; i < config.poolKeys.length; ) {
			if (address(Currency.unwrap(config.poolKeys[i].currency0)) == numeraireAddress || address(Currency.unwrap(config.poolKeys[i].currency1)) == numeraireAddress) {
				// check that the hook in the pool matches the cpaAuctionHookAddr
				if (address(config.poolKeys[i].hooks) != self.cpaAuctionHookAddr()) {
					revert IErrorsAndEvents.InvalidHook();
				}
				
				// Access storage via StorageAccess - DELEGATECALL executes in CPAManager's storage context
				PoolId poolId = config.poolKeys[i].toId();
				StorageAccess.setPoolToAuctionId(poolId, auctionId);
				
				// Convert sqrtPriceX96 to tick
				int24 startingTick = TickMath.getTickAtSqrtPrice(config.initialSqrtPricesX96[i]);
				
				// Create and store PoolInfo for this pool
				AuctionTypes.PoolInfo memory poolInfoData = AuctionTypes.PoolInfo({
					key: config.poolKeys[i],
					startingTick: startingTick,
					priceIncrement: config.priceIncrements[i],
					depositAmount: 0, // Will be set during moveDeposit
					excessDemand: 0,
					lastOversoldTick: 0,
					auctionId: auctionId,
					positionId: 0
				});
				// Access poolInfo via StorageAccess - executes in CPAManager context via DELEGATECALL
				StorageAccess.setPoolInfo(poolId, poolInfoData);
				
				// Create the pool with initial sqrtPriceX96
				self.manager().initialize(config.poolKeys[i], config.initialSqrtPricesX96[i]);
			} else {
				revert IErrorsAndEvents.MismatchedNumeraires();
			}
			unchecked { ++i; }
		}

		// set the auction info
		AuctionTypes.AuctionInfo memory auctionInfoData = AuctionTypes.AuctionInfo({
			auctionOwner: auctionOwner,
			commonNumeraire: numeraireAddress,
			config: config,
			currentPhase: AuctionTypes.AuctionPhase.Setup,
			currentStatus: AuctionTypes.AuctionStatus.Active,
			clockOpen: 1,
			// roundBids: new AuctionTypes.Bid[](0),
			currentRound: 0,
			poolKeys: config.poolKeys,
			allocatorReward: 0,
			changedPrices: new bool[](config.poolKeys.length),
			lastRevenue: 0,
			totalPauseDuration: 0
		});
		// Access auctionInfo via StorageAccess - executes in CPAManager context via DELEGATECALL
		StorageAccess.setAuctionInfo(auctionId, auctionInfoData);

		emit IErrorsAndEvents.AuctionCreated(auctionId, auctionOwner);

		return auctionId;
	}

	/**
	 * @notice Move deposits from auction owner to a single pool, giving ERC6909 claims to CPAHook
	 * @param self The contract instance (CPAManager via DELEGATECALL)
	 * @param auctionId The auction ID
	 * @param poolKey The pool key to deposit to
	 * @param depositAmount The amount to deposit
	 * @dev Storage mappings are accessed via helpers since DELEGATECALL executes in CPAManager's storage context
	 */
	function moveDeposit(
		CPAStorage self, 
		PoolKey memory poolKey,
		AuctionId auctionId, 
		uint256 depositAmount
	) public {
		// Get auctionInfo to check phase
		AuctionTypes.AuctionInfo memory auctionInfoData = StorageAccess.getAuctionInfo(auctionId);
		
		// confirm that the auction is in the Setup phase
		if (auctionInfoData.currentPhase != AuctionTypes.AuctionPhase.Setup) {
			revert IErrorsAndEvents.InvalidPhase(AuctionTypes.AuctionPhase.Setup, auctionInfoData.currentPhase);
		}

		// Update the deposit amount in poolInfo
		StorageAccess.setPoolInfoDepositAmount(poolKey.toId(), depositAmount);
		
		// Determine which currency is the item (non-numeraire)
		address numeraireAddress = auctionInfoData.commonNumeraire;
		Currency itemCurrency;
		
		if (address(Currency.unwrap(poolKey.currency0)) == numeraireAddress) {
			itemCurrency = poolKey.currency1;
		} else {
			itemCurrency = poolKey.currency0;
		}
		
		// Create callback data for the unlock callback
		bytes memory operationData = abi.encode(
			poolKey,
			itemCurrency,
			depositAmount,
			auctionId,
			msg.sender  // Pass the original caller (auction owner)
		);
		
		bytes memory callbackData = abi.encode(
			uint8(1), // operationType = 1 for deposit transfer
			operationData
		);

		// Call poolManager.unlock() which will trigger unlockCallback
		self.manager().unlock(callbackData);

		// Approve asset currency to Permit2 for PositionManager for when we deposit assets to the pool before settlement
		IERC20(Currency.unwrap(itemCurrency)).approve(
			address(self.permit2()), 
			type(uint256).max
		);
		self.permit2().approve(Currency.unwrap(itemCurrency), address(self.positionManager()), type(uint160).max, type(uint48).max);

		// Emit event for tracking
		emit IErrorsAndEvents.AssetsDeposited(auctionId, poolKey.toId(), address(Currency.unwrap(itemCurrency)), depositAmount, self.cpaAuctionHookAddr());
	}

	/**
	 * @notice Handle deposit transfer operation (setup)
	 * @param self The contract instance (CPAManager via DELEGATECALL)
	 * @param operationData The encoded operation data
	 * @return returnData The encoded balance deltas
	 * @dev Storage mappings are accessed via helpers since DELEGATECALL executes in CPAManager's storage context
	 */
	function handleDepositTransfer(
		CPAStorage self, 
		bytes memory operationData
	) public returns (bytes memory returnData) {
		// Decode callback data
		(PoolKey memory poolKey, Currency itemCurrency, uint256 depositAmount, AuctionId auctionId, address originalCaller) = 
			abi.decode(operationData, (PoolKey, Currency, uint256, AuctionId, address));
		
		// Get auctionInfo to verify owner
		AuctionTypes.AuctionInfo memory auctionInfoData = StorageAccess.getAuctionInfo(auctionId);
		
		// Verify this is a legitimate auction owner (original caller, not msg.sender)
		require(originalCaller == auctionInfoData.auctionOwner, "Not auction owner");
		
		// Directly transfer assets using V4's settle/take mechanism
		// This bypasses V4's native liquidity functionality
		
		// First, settle (send) tokens from auction owner to pool
		itemCurrency.settle(self.manager(), originalCaller, depositAmount, false);
		
		// Then, take (mint) ERC6909 tokens to be received by CPAHook
		itemCurrency.take(self.manager(), address(self), depositAmount, true);
		
		// Return the actual balance changes that occurred
		// CPAHook received depositAmount as ERC6909 claims (positive delta)
		// No fees were collected (zero delta)
		int128 amount0 = 0;
		int128 amount1 = 0;
		
		// Determine which currency changed and set the appropriate delta
		if (address(Currency.unwrap(poolKey.currency0)) == address(Currency.unwrap(itemCurrency))) {
			amount0 = int128(uint128(depositAmount)); // Positive because CPAHook received claims
		} else {
			amount1 = int128(uint128(depositAmount)); // Positive because CPAHook received claims
		}
		
		return abi.encode(toBalanceDelta(amount0, amount1), BalanceDeltaLibrary.ZERO_DELTA);
	}

    function confirmSetupComplete(
		CPAStorage self,
		AuctionId auctionId
	) public view returns (bool) {
        // Get auctionInfo to check phase
        AuctionTypes.AuctionInfo memory auctionInfoData = StorageAccess.getAuctionInfo(auctionId);
        
        // Check that auction is in Setup phase
        if (auctionInfoData.currentPhase != AuctionTypes.AuctionPhase.Setup) {
            return false;
        }
        
        // Check that all asset pools have deposits
        PoolKey[] memory poolKeys = auctionInfoData.poolKeys;
        for (uint256 i = 0; i < poolKeys.length; ) {
            PoolId poolId = poolKeys[i].toId();
            AuctionTypes.PoolInfo memory pool = StorageAccess.getPoolInfo(poolId);
            
            // Each asset pool must have some deposit amount
            if (pool.depositAmount == 0) {
                return false;
            }
            unchecked { ++i; }
        }
        
        return true;
    }

	/**
	 * @notice Deposit to all pools and start clock phase in one transaction
	 * @param self The contract instance (CPAManager via DELEGATECALL)
	 * @param poolKeys Array of pool keys to deposit to
	 * @param amounts Array of deposit amounts
	 * @param auctionId The auction ID
	 * @dev Storage mappings are accessed via helpers since DELEGATECALL executes in CPAManager's storage context
	 */
	function depositAllAndStartClock(
		CPAStorage self,
		PoolKey[] memory poolKeys,
		uint256[] memory amounts,
		AuctionId auctionId
	) public {
		// Validate array lengths match
		if (poolKeys.length != amounts.length) {
			revert IErrorsAndEvents.InvalidBidsLength();
		}

		// Get auctionInfo to access auction data
		AuctionTypes.AuctionInfo memory auctionInfoData = StorageAccess.getAuctionInfo(auctionId);
		
		// Validate pools, determine currencies, and approve to PositionManager in single loop
		address numeraireAddress = auctionInfoData.commonNumeraire;
		Currency[] memory itemCurrencies = new Currency[](poolKeys.length);
		
		for (uint256 i = 0; i < poolKeys.length; ) {
			// Check that this pool is part of the auction
			// Cache poolId conversion outside inner loop for gas efficiency
			PoolId poolId = poolKeys[i].toId();
			bool found = false;
			uint256 innerLen = auctionInfoData.poolKeys.length; // Cache length
			for (uint256 j = 0; j < innerLen; ) {
				if (PoolId.unwrap(poolId) == PoolId.unwrap(auctionInfoData.poolKeys[j].toId())) {
					found = true;
					break;
				}
				unchecked { ++j; } // Use unchecked increment for gas savings
			}
			if (!found) {
				revert IErrorsAndEvents.InvalidPool();
			}
			
			// Determine item currency (non-numeraire)
			if (address(Currency.unwrap(poolKeys[i].currency0)) == numeraireAddress) {
				itemCurrencies[i] = poolKeys[i].currency1;
			} else {
				itemCurrencies[i] = poolKeys[i].currency0;
			}
			
			// Approve asset currency to Permit2 for PositionManager
			IERC20(Currency.unwrap(itemCurrencies[i])).approve(
				address(self.permit2()), 
				type(uint256).max
			);
			self.permit2().approve(Currency.unwrap(itemCurrencies[i]), address(self.positionManager()), type(uint160).max, type(uint48).max);
			unchecked { ++i; }
		}

		// Create callback data for batch deposit
		AuctionTypes.CallbackDataBatchDeposit memory batchData = AuctionTypes.CallbackDataBatchDeposit({
			poolKeys: poolKeys,
			itemCurrencies: itemCurrencies,
			depositAmounts: amounts,
			auctionId: auctionId,
			originalCaller: msg.sender
		});

		bytes memory callbackData = abi.encode(
			uint8(8), // operationType = 8 for batch deposit transfer
			abi.encode(batchData)
		);

		// Call poolManager.unlock() which will trigger unlockCallback
		self.manager().unlock(callbackData);
		
		// After successful batch deposit, start the clock phase
		// This is done here because we know all deposits succeeded
		// Update auctionInfo via StorageAccess
		auctionInfoData.currentPhase = AuctionTypes.AuctionPhase.Clock;
		auctionInfoData.clockOpen = 2; // Clock is now open
		auctionInfoData.currentRound = 1; // Initialize to round 1
		StorageAccess.setAuctionInfo(auctionId, auctionInfoData);
		
		// Emit phase change event
		emit IErrorsAndEvents.AuctionPhaseChanged(auctionId, AuctionTypes.AuctionPhase.Clock);
		// Emit clock phase started event
		emit IErrorsAndEvents.ClockRoundOpened(auctionId, 1);
	}

}
