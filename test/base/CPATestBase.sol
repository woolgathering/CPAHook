// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { Test, console } from "forge-std/Test.sol";
import { Deployers } from "../utils/Deployers.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { Currency, CurrencyLibrary } from "@uniswap/v4-core/src/types/Currency.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IPositionManager } from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import { Hooks } from "@uniswap/v4-core/src/libraries/Hooks.sol";
import { HookMiner } from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC6909Claims } from "@uniswap/v4-core/src/interfaces/external/IERC6909Claims.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { Constants } from "../../lib/uniswap-hooks/lib/v4-core/test/utils/Constants.sol";
import { FixedPointMathLib } from "solmate/src/utils/FixedPointMathLib.sol";
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol"; 

import { CPAManager } from "../../src/CPAManager.sol";
import { PoolHook } from "../../src/PoolHook.sol";
import { AuctionTypes } from "../../src/AuctionTypes.sol";
import { AuctionId } from "../../src/AuctionId.sol";
import { MockERC20 } from "solmate/src/test/utils/mocks/MockERC20.sol";
import { IErrorsAndEvents } from "../../src/utils/IErrorsAndEvents.sol";
import { CommitReveal } from "../../src/CommitReveal.sol";
import { LPFeeLibrary } from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";

/// @title CPATestBase
/// @notice Abstract base contract for CPA tests that provides common deployment and setup functionality
abstract contract CPATestBase is Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using FixedPointMathLib for uint256;
    using StateLibrary for IPoolManager;

    // Core contracts
    CPAManager public cpaManager;
    PoolHook public poolHook;
    
    // Test tokens
    MockERC20 public numeraireToken;
    MockERC20 public asset1Token;
    MockERC20 public asset2Token;
    
    // Test accounts
    address public protocolOwner;
    address public auctioneer;
    address public bidder1;
    address public bidder2;
    address public proxy1;
    address public proxy2;
    
    // Pool keys
    PoolKey public asset1PoolKey;
    PoolKey public asset2PoolKey;
    
    // Auction data
    AuctionId public auctionId;
    uint256 public numeraireCurrencyId;
    
    // Price data (for reference, actual prices come from pools)
    uint256 public asset1InitialPrice;
    uint256 public asset2InitialPrice;

    function setUp() public virtual {
        deployArtifacts();
        deployTokens();
        setupAccounts();
        deployContracts();
        setupTwoPools();
    }

    /// @notice Deploy test tokens
    function deployTokens() internal {
        numeraireToken = new MockERC20("Numeraire Token", "NUM", 18);
        asset1Token = new MockERC20("Asset 1 Token", "AST1", 18);
        asset2Token = new MockERC20("Asset 2 Token", "AST2", 18);
        
        numeraireCurrencyId = uint256(uint160(address(numeraireToken)));
        
        // Set reference prices (actual prices come from pools)
        asset1InitialPrice = 1 * 10**18;
        asset2InitialPrice = 2 * 10**18;
    }

    /// @notice Set up test accounts
    function setupAccounts() internal {
        protocolOwner = makeAddr("protocolOwner");
        auctioneer = makeAddr("auctioneer");
        bidder1 = makeAddr("bidder1");
        bidder2 = makeAddr("bidder2");
        proxy1 = makeAddr("proxy1");
        proxy2 = makeAddr("proxy2");
    }

    /// @notice Deploy core contracts
    function deployContracts() internal {
        vm.startPrank(protocolOwner);
        
        // Deploy PoolHook with proper address mining
        poolHook = deployPoolHook(poolManager);
        
        // Deploy CPAManager (no longer a hook, simple deployment)
        cpaManager = new CPAManager(poolManager, protocolOwner, address(poolHook));
        
        // Set auction manager in pool hook
        poolHook.setAuctionManager(address(cpaManager));
        
        // Note: CPAManager no longer needs numeraire tokens since we call PoolManager directly
        
        vm.stopPrank();
    }

    /// @notice Set up pool keys and initialize pools
    function setupTwoPools() internal {
        // Create asset pool keys
        asset1PoolKey = PoolKey({
            currency0: Currency.wrap(address(asset1Token)),
            currency1: Currency.wrap(address(numeraireToken)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(poolHook))
        });

        asset2PoolKey = PoolKey({
            currency0: Currency.wrap(address(asset2Token)),
            currency1: Currency.wrap(address(numeraireToken)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(poolHook))
        });

        // Sort currencies by address
        (asset1PoolKey.currency0, asset1PoolKey.currency1) = asset1PoolKey.currency0 < asset1PoolKey.currency1
            ? (asset1PoolKey.currency0, asset1PoolKey.currency1)
            : (asset1PoolKey.currency1, asset1PoolKey.currency0);

        (asset2PoolKey.currency0, asset2PoolKey.currency1) = asset2PoolKey.currency0 < asset2PoolKey.currency1
            ? (asset2PoolKey.currency0, asset2PoolKey.currency1)
            : (asset2PoolKey.currency1, asset2PoolKey.currency0);
    }

    /// @notice Deploy PoolHook with proper address mining and flag setting
    function deployPoolHook(IPoolManager _poolManager) internal returns (PoolHook) {
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG |
            Hooks.BEFORE_SWAP_FLAG |
            Hooks.BEFORE_ADD_LIQUIDITY_FLAG |
            Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG |
            Hooks.BEFORE_DONATE_FLAG
        );
        
        bytes memory constructorArgs = abi.encode(_poolManager);
        
        (address hookAddress, bytes32 salt) = HookMiner.find(
            protocolOwner,
            flags,
            type(PoolHook).creationCode,
            constructorArgs
        );
        
        PoolHook deployedHook = new PoolHook{salt: salt}(_poolManager);
        require(address(deployedHook) == hookAddress, "Hook address mismatch");
        return deployedHook;
    }

    /// @notice Create a new auction with the given configuration
    function createAuction(
        AuctionTypes.AuctionConfig memory config,
        address owner
    ) internal returns (AuctionId) {
        vm.prank(owner);
        return cpaManager.createAuction(config, owner);
    }

    /// @notice Create a standard auction configuration for testing
    function createStandardAuctionConfig() internal view returns (AuctionTypes.AuctionConfig memory) {
        // Convert initial prices to sqrtPriceX96 based on currency ordering
        // uint160 asset1SqrtPriceX96 = convertAssetPriceToSqrtPriceX96(asset1PoolKey, asset1InitialPrice);
        // uint160 asset2SqrtPriceX96 = convertAssetPriceToSqrtPriceX96(asset2PoolKey, asset2InitialPrice);

        uint160 asset1SqrtPriceX96 = 79228162514264337593543950336;
        uint160 asset2SqrtPriceX96 = 112045541949572287496682733568;

        PoolKey[] memory poolKeys = new PoolKey[](2);
        poolKeys[0] = asset1PoolKey;
        poolKeys[1] = asset2PoolKey;

        uint160[] memory initialSqrtPricesX96 = new uint160[](2);
        initialSqrtPricesX96[0] = asset1SqrtPriceX96;
        initialSqrtPricesX96[1] = asset2SqrtPriceX96;

        int24[] memory priceIncrements = new int24[](2);
        priceIncrements[0] = asset1PoolKey.tickSpacing * 10; // 1 tick increment
        priceIncrements[1] = asset2PoolKey.tickSpacing * 5; // 1 tick increment

        return AuctionTypes.AuctionConfig({
            commonNumeraire: address(numeraireToken),
            minSpendRatio: 1000,
            dropoutSlashRatio: 1000, // 10%
            spendingViolationSlashRatio: 2000, // 20%
            maxRounds: 100,
            allocatorStakeRequirement: 10000 * 10**18,
            proxyStakeRequirement: 1000 * 10**18,
            allocationWindow: 1800,
            poolKeys: poolKeys,
            initialSqrtPricesX96: initialSqrtPricesX96,
            priceIncrements: priceIncrements
        });
    }

    /// @notice Convert asset price to sqrtPriceX96 based on currency ordering
    /// @param poolKey The pool key to determine currency ordering
    /// @param assetPrice The price of the asset in terms of numeraire (e.g., 2 means 2 numeraire per asset)
    /// @return sqrtPriceX96 The sqrt price in X96 format
    function convertAssetPriceToSqrtPriceX96(PoolKey memory poolKey, uint256 assetPrice) internal view returns (uint160) {
        // Determine which currency is the asset and which is the numeraire
        // Since currencies are sorted by address, we need to check which one is the numeraire
        address numeraireAddr = address(numeraireToken);
        address currency0Addr = Currency.unwrap(poolKey.currency0);
        address currency1Addr = Currency.unwrap(poolKey.currency1);
        
        if (currency0Addr == numeraireAddr) {
            // currency0 is numeraire, currency1 is asset
            // Uniswap price = currency0/currency1 = numeraire/asset
            // sqrtPriceX96 = sqrt(price) * 2^96
            uint256 priceX96 = (assetPrice * (2**96)) / 10**18;
            return uint160(priceX96.sqrt());
        } else {
            // currency1 is numeraire, currency0 is asset
            // Uniswap price = currency0/currency1 = asset/numeraire = 1/price
            // sqrtPriceX96 = sqrt(1/price) * 2^96
            uint256 invertedPriceX96 = ((10**18) * (2**96)) / assetPrice;
            return uint160(invertedPriceX96.sqrt());
        }
    }

    /// @notice Move deposit for a pool
    function moveDeposit(
        AuctionId _auctionId,
        PoolKey memory poolKey,
        uint256 depositAmount
    ) internal {
        vm.prank(auctioneer);
        cpaManager.moveDeposit(_auctionId, poolKey, depositAmount);
    }

    /// @notice Mint tokens to auctioneer for deposits
    function mintTokensToAuctioneer(uint256 amount) internal {
        asset1Token.mint(auctioneer, amount);
        asset2Token.mint(auctioneer, amount);
    }

    /// @notice Approve tokens for CPAManager
    function approveTokens(address token, address spender, uint256 amount) internal {
        vm.prank(auctioneer);
        IERC20(token).approve(spender, amount);
    }

    /// @notice Get current pool price from sqrtPriceX96
    /// @dev Returns raw price in terms of currency0/currency1
    function getCurrentPoolPrice(PoolId poolId) internal view returns (uint256) {
        (uint160 sqrtPriceX96, , , ) = poolManager.getSlot0(poolId);
        uint256 priceX96 = uint256(sqrtPriceX96) * uint256(sqrtPriceX96);
        return priceX96 / (2**192);
    }

    /// @notice Get current pool price accounting for currency ordering
    /// @dev Returns price in terms of numeraire per asset unit, accounting for which currency is which
    function getCurrentPoolPriceWithOrdering(PoolKey memory poolKey) internal view returns (uint256) {
        PoolId poolId = poolKey.toId();
        (uint160 sqrtPriceX96, , , ) = poolManager.getSlot0(poolId);
        
        // Determine which currency is the asset and which is the numeraire
        address numeraireAddr = address(numeraireToken);
        address currency0Addr = Currency.unwrap(poolKey.currency0);
        address currency1Addr = Currency.unwrap(poolKey.currency1);
        
        uint256 priceX96 = uint256(sqrtPriceX96) * uint256(sqrtPriceX96);
        
        if (currency0Addr == numeraireAddr) {
            // currency0 is numeraire, currency1 is asset
            // sqrtPriceX96 represents sqrt(currency0/currency1) = sqrt(numeraire/asset)
            // We need to invert to get asset/numeraire, then invert again to get numeraire/asset
            return (2**192) / priceX96;
        } else {
            // currency1 is numeraire, currency0 is asset
            // sqrtPriceX96 represents sqrt(currency1/currency0) = sqrt(numeraire/asset)
            // This is already what we want
            return priceX96 / (2**192);
        }
    }

    /// @notice Calculate bid value at current pool prices
    function calculateBidValue(uint256[] memory demands) internal view returns (uint256) {
        uint256 totalValue = 0;
        PoolKey[] memory poolKeys = new PoolKey[](2);
        poolKeys[0] = asset1PoolKey;
        poolKeys[1] = asset2PoolKey;
        
        for (uint256 i = 0; i < demands.length && i < poolKeys.length; i++) {
            uint256 price = getCurrentPoolPriceWithOrdering(poolKeys[i]);
            totalValue += (demands[i] * price) / 10**18;
        }
        
        return totalValue;
    }

    /// @notice Create a bidder with numeraire tokens
    function createBidder(address bidder, uint256 numeraireAmount) internal {
        vm.prank(protocolOwner);
        numeraireToken.mint(bidder, numeraireAmount);
    }

    /// @notice Approve numeraire tokens for a bidder
    function approveNumeraireForBidder(address bidder, uint256 amount) internal {
        vm.prank(bidder);
        numeraireToken.approve(address(cpaManager), amount);
    }

    /// @notice Convert sqrtPriceX96 to actual price accounting for currency ordering
    function convertSqrtPriceX96ToPrice(uint160 sqrtPriceX96, PoolKey memory poolKey) internal view returns (uint256) {
        // Convert sqrtPriceX96 to price
        // price = (sqrtPriceX96 / 2^96)^2
        uint256 price = (uint256(sqrtPriceX96) * uint256(sqrtPriceX96)) >> (96 * 2);
        
        // Determine if we need to invert the price based on currency ordering
        // If currency0 is the numeraire, we need to invert: price = 1/price
        bool currency0IsNumeraire = Currency.unwrap(poolKey.currency0) == address(numeraireToken);
        
        if (currency0IsNumeraire) {
            // Price is currency0/currency1, but we want currency1/currency0 (numeraire/asset)
            // So we need to invert: 1/price
            price = (1e18 * 1e18) / price;
        }
        
        return price;
    }
}
