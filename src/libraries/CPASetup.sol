// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { PoolId } from "@uniswap/v4-core/src/types/PoolId.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CurrencySettler} from "@openzeppelin/uniswap-hooks/src/utils/CurrencySettler.sol";

import { CPAStorage } from "../base/CPAStorage.sol";
import { IMathFacet } from "../interfaces/IMathFacet.sol";
import { IErrorsAndEvents } from "../utils/IErrorsAndEvents.sol";
import { AuctionTypes } from "../types/AuctionTypes.sol";
import { AuctionId, AuctionIdLibrary } from "../types/AuctionId.sol";

library CPASetup {
	using CurrencySettler for Currency;

	/**
	 * @notice Create a new auction with the given configuration
	 * @param self The contract instance
	 * @param config The auction configuration (includes pool keys, initial prices, and price increments)
	 * @param auctionOwner The auction owner
	 * @param auctionInfo Mapping for auction info
	 * @param poolToAuctionId Mapping for pool to auction ID
	 * @param poolInfo Mapping for pool info
	 */
	function createAuction(
		CPAStorage self,
		AuctionTypes.AuctionConfig memory config, 
		address auctionOwner,
		mapping(AuctionId => AuctionTypes.AuctionInfo) storage auctionInfo,
		mapping(PoolId => AuctionId) storage poolToAuctionId,
		mapping(PoolId => AuctionTypes.PoolInfo) storage poolInfo
	) internal returns (AuctionId) {
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
				
				poolToAuctionId[config.poolKeys[i].toId()] = auctionId; // set the auction id in poolToAuctionId
				
				// Convert sqrtPriceX96 to tick
				int24 startingTick = IMathFacet(self.mathFacet()).getTickAtSqrtPrice(config.initialSqrtPricesX96[i]);
				
				// Create and store PoolInfo for this pool
				PoolId poolId = config.poolKeys[i].toId();
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
				poolInfo[poolId] = poolInfoData;
				
				// Create the pool with initial sqrtPriceX96
				self.manager().initialize(config.poolKeys[i], config.initialSqrtPricesX96[i]);
			} else {
				revert IErrorsAndEvents.MismatchedNumeraires();
			}
			unchecked { ++i; }
		}

		// set the auction info
		auctionInfo[auctionId] = AuctionTypes.AuctionInfo({
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

		emit IErrorsAndEvents.AuctionCreated(auctionId, auctionOwner);

		return auctionId;
	}

	/**
	 * @notice Register pools for a new auction (step 1 of 2-step createAuction split)
	 * @dev Validates pools, writes poolInfo and poolToAuctionId, initializes pools in manager.
	 *      Call finalizeAuctionCreation as step 2 to complete the auction creation.
	 */
	function registerPoolsForAuction(
		CPAStorage self,
		AuctionTypes.AuctionConfig memory config,
		mapping(PoolId => AuctionId) storage poolToAuctionId,
		mapping(PoolId => AuctionTypes.PoolInfo) storage poolInfo
	) internal returns (AuctionId auctionId) {
		auctionId = AuctionIdLibrary.createId(config.poolKeys);
		address numeraireAddress = config.commonNumeraire;

		if (config.poolKeys.length != config.initialSqrtPricesX96.length || config.poolKeys.length != config.priceIncrements.length) {
			revert IErrorsAndEvents.InvalidBidsLength();
		}

		for (uint256 i = 0; i < config.poolKeys.length; ) {
			if (address(Currency.unwrap(config.poolKeys[i].currency0)) == numeraireAddress || address(Currency.unwrap(config.poolKeys[i].currency1)) == numeraireAddress) {
				if (address(config.poolKeys[i].hooks) != self.cpaAuctionHookAddr()) {
					revert IErrorsAndEvents.InvalidHook();
				}
				poolToAuctionId[config.poolKeys[i].toId()] = auctionId;
				int24 startingTick = IMathFacet(self.mathFacet()).getTickAtSqrtPrice(config.initialSqrtPricesX96[i]);
				PoolId poolId = config.poolKeys[i].toId();
				poolInfo[poolId] = AuctionTypes.PoolInfo({
					key: config.poolKeys[i],
					startingTick: startingTick,
					priceIncrement: config.priceIncrements[i],
					depositAmount: 0,
					excessDemand: 0,
					lastOversoldTick: 0,
					auctionId: auctionId,
					positionId: 0
				});
				self.manager().initialize(config.poolKeys[i], config.initialSqrtPricesX96[i]);
			} else {
				revert IErrorsAndEvents.MismatchedNumeraires();
			}
			unchecked { ++i; }
		}
	}

	/**
	 * @notice Write auctionInfo and emit AuctionCreated (step 2 of 2-step createAuction split)
	 * @dev Requires registerPoolsForAuction to have been called first.
	 */
	function finalizeAuctionCreation(
		AuctionTypes.AuctionConfig memory config,
		AuctionId auctionId,
		address auctionOwner,
		mapping(AuctionId => AuctionTypes.AuctionInfo) storage auctionInfo
	) internal {
		auctionInfo[auctionId] = AuctionTypes.AuctionInfo({
			auctionOwner: auctionOwner,
			commonNumeraire: config.commonNumeraire,
			config: config,
			currentPhase: AuctionTypes.AuctionPhase.Setup,
			currentStatus: AuctionTypes.AuctionStatus.Active,
			clockOpen: 1,
			currentRound: 0,
			poolKeys: config.poolKeys,
			allocatorReward: 0,
			changedPrices: new bool[](config.poolKeys.length),
			lastRevenue: 0,
			totalPauseDuration: 0
		});
		emit IErrorsAndEvents.AuctionCreated(auctionId, auctionOwner);
	}

	/**
	 * @notice Move deposits from auction owner to a single pool, giving ERC6909 claims to CPAHook
	 * @param self The contract instance
	 * @param auctionId The auction ID
	 * @param poolKey The pool key to deposit to
	 * @param depositAmount The amount to deposit
	 */
	function moveDeposit(
		CPAStorage self, 
		AuctionTypes.AuctionInfo storage auctionInfo,
		mapping(PoolId => AuctionTypes.PoolInfo) storage poolInfo,
		PoolKey memory poolKey,
		AuctionId auctionId, 
		uint256 depositAmount
	) internal {
		// confirm that the auction is in the Setup phase
		if (auctionInfo.currentPhase != AuctionTypes.AuctionPhase.Setup) {
			revert IErrorsAndEvents.InvalidPhase(AuctionTypes.AuctionPhase.Setup, auctionInfo.currentPhase);
		}

		// Update the deposit amount in poolInfo
		poolInfo[poolKey.toId()].depositAmount = depositAmount;
		
		// Determine which currency is the item (non-numeraire)
		address numeraireAddress = auctionInfo.commonNumeraire;
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
	 * @param self The contract instance
	 * @param operationData The encoded operation data
	 * @return returnData The encoded balance deltas
	 */
	function handleDepositTransfer(
		CPAStorage self, 
		AuctionTypes.AuctionInfo storage auctionInfo,
		mapping(PoolId => AuctionTypes.PoolInfo) storage poolInfo,
		bytes memory operationData
	) internal returns (bytes memory returnData) {
		// Decode callback data
		(PoolKey memory poolKey, Currency itemCurrency, uint256 depositAmount, AuctionId auctionId, address originalCaller) = 
			abi.decode(operationData, (PoolKey, Currency, uint256, AuctionId, address));
		
		// Verify this is a legitimate auction owner (original caller, not msg.sender)
		require(originalCaller == auctionInfo.auctionOwner, "Not auction owner");
		
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
			// casting to 'uint128' and 'int128' is safe because depositAmount is bounded by ERC20 token supply, far below int128 max
			// forge-lint: disable-next-line(unsafe-typecast)
			amount0 = int128(uint128(depositAmount)); // Positive because CPAHook received claims
		} else {
			// casting to 'uint128' and 'int128' is safe because depositAmount is bounded by ERC20 token supply, far below int128 max
			// forge-lint: disable-next-line(unsafe-typecast)
			amount1 = int128(uint128(depositAmount)); // Positive because CPAHook received claims
		}
		
		return abi.encode(toBalanceDelta(amount0, amount1), BalanceDeltaLibrary.ZERO_DELTA);
	}

    function confirmSetupComplete(
		CPAStorage self,
		AuctionId auctionId,
		AuctionTypes.AuctionInfo storage auctionInfo,
		mapping(PoolId => AuctionTypes.PoolInfo) storage poolInfo
	) internal view returns (bool) {
        // Check that auction is in Setup phase
        if (auctionInfo.currentPhase != AuctionTypes.AuctionPhase.Setup) {
            return false;
        }
        
        // Check that all asset pools have deposits
        PoolKey[] memory poolKeys = auctionInfo.poolKeys;
        for (uint256 i = 0; i < poolKeys.length; ) {
            PoolId poolId = poolKeys[i].toId();
            AuctionTypes.PoolInfo memory pool = poolInfo[poolId];
            
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
	 * @param self The contract instance
	 * @param auctionInfo The auction info storage
	 * @param poolInfo The pool info storage
	 * @param poolKeys Array of pool keys to deposit to
	 * @param amounts Array of deposit amounts
	 * @param auctionId The auction ID
	 */
	function depositAllAndStartClock(
		CPAStorage self,
		AuctionTypes.AuctionInfo storage auctionInfo,
		mapping(PoolId => AuctionTypes.PoolInfo) storage poolInfo,
		PoolKey[] memory poolKeys,
		uint256[] memory amounts,
		AuctionId auctionId
	) internal {
		// Validate array lengths match
		if (poolKeys.length != amounts.length) {
			revert IErrorsAndEvents.InvalidBidsLength();
		}

		// Validate pools, determine currencies, and approve to PositionManager in single loop
		address numeraireAddress = auctionInfo.commonNumeraire;
		Currency[] memory itemCurrencies = new Currency[](poolKeys.length);
		
		for (uint256 i = 0; i < poolKeys.length; ) {
			// Check that this pool is part of the auction
			// Cache poolId conversion outside inner loop for gas efficiency
			PoolId poolId = poolKeys[i].toId();
			bool found = false;
			uint256 innerLen = auctionInfo.poolKeys.length; // Cache length
			for (uint256 j = 0; j < innerLen; ) {
				if (PoolId.unwrap(poolId) == PoolId.unwrap(auctionInfo.poolKeys[j].toId())) {
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
		unchecked {
			auctionInfo.currentPhase = AuctionTypes.AuctionPhase.Clock;
			auctionInfo.clockOpen = 2; // Clock is now open
			auctionInfo.currentRound = 1; // Initialize to round 1
		}
		
		// Emit phase change event
		emit IErrorsAndEvents.AuctionPhaseChanged(auctionId, AuctionTypes.AuctionPhase.Clock);
		// Emit clock phase started event
		emit IErrorsAndEvents.ClockRoundOpened(auctionId, 1);
	}

}
