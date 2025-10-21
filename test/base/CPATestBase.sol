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
import { IERC20 } from "forge-std/interfaces/IERC20.sol";
import { IERC6909Claims } from "@uniswap/v4-core/src/interfaces/external/IERC6909Claims.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { Constants } from "../../lib/uniswap-hooks/lib/v4-core/test/utils/Constants.sol";
import { FixedPointMathLib } from "solmate/src/utils/FixedPointMathLib.sol";
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol"; 

import { CPAManager } from "../../src/CPAManager.sol";
import { CPAHook } from "../../src/CPAHook.sol";
import { AuctionTypes } from "../../src/types/AuctionTypes.sol";
import { AuctionId } from "../../src/types/AuctionId.sol";
import { MockERC20 } from "solmate/src/test/utils/mocks/MockERC20.sol";
import { IErrorsAndEvents } from "../../src/utils/IErrorsAndEvents.sol";
import { CommitReveal } from "../../src/utils/CommitReveal.sol";
import { BundleId, BundleIdLibrary } from "../../src/types/BundleId.sol";
import { LPFeeLibrary } from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import { PriceUtils } from "../../src/utils/PriceUtils.sol";

/// @title CPATestBase
/// @notice Abstract base contract for CPA tests that provides common deployment and setup functionality
abstract contract CPATestBase is Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using FixedPointMathLib for uint256;
    using StateLibrary for IPoolManager;
    using PriceUtils for IPoolManager;
    
    // Core contracts
    CPAManager public cpaManager;
    CPAHook public cpaHook;
    
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
    
    // Additional test accounts for over-allocation testing
    address public bidder3;
    address public proxy3;
    address public bidder4;
    address public proxy4;
    
    // Pool keys
    PoolKey public asset1PoolKey;
    PoolKey public asset2PoolKey;
    
    // Auction data
    AuctionId public auctionId;
    uint256 public numeraireCurrencyId;
    uint256 public allocatorRewardPct;
    
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
    function deployTokens() internal virtual {
        numeraireToken = new MockERC20("Numeraire Token", "NUM", 18);
        asset1Token = new MockERC20("Asset 1 Token", "AST1", 18);
        asset2Token = new MockERC20("Asset 2 Token", "AST2", 18);
        
        // Label tokens for easier tracking in test output
        vm.label(address(numeraireToken), "NUMERAIRE");
        vm.label(address(asset1Token), "ASSET1");
        vm.label(address(asset2Token), "ASSET2");
        
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
        
        // Additional accounts for over-allocation testing
        bidder3 = makeAddr("bidder3");
        proxy3 = makeAddr("proxy3");
        bidder4 = makeAddr("bidder4");
        proxy4 = makeAddr("proxy4");
    }

    /// @notice Deploy core contracts
    function deployContracts() internal {
        vm.startPrank(protocolOwner);
        
        // Deploy CPAHook with proper address mining
        cpaHook = deployCPAHook(poolManager);
        
        // Deploy CPAManager (no longer a hook, simple deployment)
        cpaManager = new CPAManager(poolManager, protocolOwner, address(cpaHook), address(this));
        
        // Set auction manager in pool hook
        cpaHook.setAuctionManager(address(cpaManager));
        
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
            hooks: IHooks(address(cpaHook))
        });

        asset2PoolKey = PoolKey({
            currency0: Currency.wrap(address(asset2Token)),
            currency1: Currency.wrap(address(numeraireToken)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(cpaHook))
        });

        // Sort currencies by address
        (asset1PoolKey.currency0, asset1PoolKey.currency1) = asset1PoolKey.currency0 < asset1PoolKey.currency1
            ? (asset1PoolKey.currency0, asset1PoolKey.currency1)
            : (asset1PoolKey.currency1, asset1PoolKey.currency0);

        (asset2PoolKey.currency0, asset2PoolKey.currency1) = asset2PoolKey.currency0 < asset2PoolKey.currency1
            ? (asset2PoolKey.currency0, asset2PoolKey.currency1)
            : (asset2PoolKey.currency1, asset2PoolKey.currency0);
    }

    /// @notice Deploy CPAHook with proper address mining and flag setting
    function deployCPAHook(IPoolManager _poolManager) internal returns (CPAHook) {
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
            type(CPAHook).creationCode,
            constructorArgs
        );
        
        CPAHook deployedHook = new CPAHook{salt: salt}(_poolManager);
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

    /// @notice Create a new auction configuration with different pool keys for testing
    function createNewAuctionConfig() internal returns (AuctionTypes.AuctionConfig memory) {
        // Create new tokens for a separate auction
        MockERC20 newAsset1Token = new MockERC20("New Asset 1", "NA1", 18);
        MockERC20 newAsset2Token = new MockERC20("New Asset 2", "NA2", 18);
        
        // Create new pool keys with different tokens
        PoolKey memory newAsset1PoolKey = PoolKey({
            currency0: Currency.wrap(address(newAsset1Token)),
            currency1: Currency.wrap(address(numeraireToken)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(cpaHook))
        });

        PoolKey memory newAsset2PoolKey = PoolKey({
            currency0: Currency.wrap(address(newAsset2Token)),
            currency1: Currency.wrap(address(numeraireToken)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(cpaHook))
        });

        // Sort currencies by address
        (newAsset1PoolKey.currency0, newAsset1PoolKey.currency1) = newAsset1PoolKey.currency0 < newAsset1PoolKey.currency1
            ? (newAsset1PoolKey.currency0, newAsset1PoolKey.currency1)
            : (newAsset1PoolKey.currency1, newAsset1PoolKey.currency0);

        (newAsset2PoolKey.currency0, newAsset2PoolKey.currency1) = newAsset2PoolKey.currency0 < newAsset2PoolKey.currency1
            ? (newAsset2PoolKey.currency0, newAsset2PoolKey.currency1)
            : (newAsset2PoolKey.currency1, newAsset2PoolKey.currency0);

        // Create auction config with new pool keys
        PoolKey[] memory newPoolKeys = new PoolKey[](2);
        newPoolKeys[0] = newAsset1PoolKey;
        newPoolKeys[1] = newAsset2PoolKey;

        uint160[] memory newInitialSqrtPricesX96 = new uint160[](2);
        newInitialSqrtPricesX96[0] = 79228162514264337593543950336; // Price = 1
        newInitialSqrtPricesX96[1] = 112045541949572287496682733568; // Price = 2

        int24[] memory newPriceIncrements = new int24[](2);
        newPriceIncrements[0] = 60 * 10; // 600 ticks
        newPriceIncrements[1] = 60 * 5; // 300 ticks

        uint256[] memory phaseDurations = new uint256[](4);
        phaseDurations[0] = 3600; // 1 hour
        phaseDurations[1] = 1800; // 30 minutes
        phaseDurations[2] = 3600; // 1 hour
        phaseDurations[3] = 3600; // 1 hour

        allocatorRewardPct = 100; // 1% reward

        return AuctionTypes.AuctionConfig({
            commonNumeraire: address(numeraireToken),
            minSpendRatio: 1000,
            dropoutSlashRatio: 1000,
            spendingViolationSlashRatio: 2000,
            allocatorRewardPct: allocatorRewardPct, // 1% reward
            maxRounds: 100,
            phaseDurations: phaseDurations,
            poolKeys: newPoolKeys,
            initialSqrtPricesX96: newInitialSqrtPricesX96,
            priceIncrements: newPriceIncrements
        });
    }

    /// @notice Create a standard auction configuration for testing
    function createStandardAuctionConfig() internal returns (AuctionTypes.AuctionConfig memory) {
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

        uint256[] memory phaseDurations = new uint256[](4);
        phaseDurations[0] = 3600; // 1 hour
        phaseDurations[1] = 1800; // 30 minutes
        phaseDurations[2] = 3600; // 1 hour
        phaseDurations[3] = 3600; // 1 hour

        allocatorRewardPct = 100; // 1% reward

        return AuctionTypes.AuctionConfig({
            commonNumeraire: address(numeraireToken),
            minSpendRatio: 1000,
            dropoutSlashRatio: 1000, // 10%
            spendingViolationSlashRatio: 2000, // 20%
            allocatorRewardPct: allocatorRewardPct, // 1% reward
            maxRounds: 100,
            phaseDurations: phaseDurations,
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

    /// @notice Deposit to all pools and start clock phase in one transaction
    function depositAllAndStartClock(
        AuctionId _auctionId,
        PoolKey[] memory poolKeys,
        uint256[] memory amounts
    ) internal {
        vm.prank(auctioneer);
        cpaManager.depositAllAndStartClock(_auctionId, poolKeys, amounts);
    }

    /// @notice Setup complete auction with deposits and clock phase started
    function setupCompleteAuction() internal returns (AuctionId) {
        // Create auction
        AuctionId auctionId = createAuction(createStandardAuctionConfig(), auctioneer);
        
        // Mint tokens to auctioneer
        uint256 tokenAmount = 100000 * 10**18;
        asset1Token.mint(auctioneer, tokenAmount);
        asset2Token.mint(auctioneer, tokenAmount);
        
        // Approve CPAManager for both tokens
        vm.prank(auctioneer);
        asset1Token.approve(address(cpaManager), tokenAmount);
        vm.prank(auctioneer);
        asset2Token.approve(address(cpaManager), tokenAmount);
        
        // Prepare batch deposit data
        PoolKey[] memory poolKeys = new PoolKey[](2);
        uint256[] memory amounts = new uint256[](2);
        
        poolKeys[0] = asset1PoolKey;
        poolKeys[1] = asset2PoolKey;
        amounts[0] = 50000 * 10**18;
        amounts[1] = 60000 * 10**18;
        
        // Deposit to all pools and start clock phase
        depositAllAndStartClock(auctionId, poolKeys, amounts);
        
        return auctionId;
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
        
        // Get numeraire decimals for proper conversion
        uint8 numeraireDecimals = IERC20(address(numeraireToken)).decimals();
        
        for (uint256 i = 0; i < demands.length && i < poolKeys.length; i++) {
            uint256 price;
            if (Currency.unwrap(poolKeys[i].currency0) == address(numeraireToken)) {
                price = poolManager.getPriceOfCurrency1(poolKeys[i]);
            } else {
                price = poolManager.getPriceOfCurrency0(poolKeys[i]);
            }
            
            // Get asset decimals for this pool
            address assetCurrency;
            if (Currency.unwrap(poolKeys[i].currency0) == address(numeraireToken)) {
                assetCurrency = Currency.unwrap(poolKeys[i].currency1);
            } else {
                assetCurrency = Currency.unwrap(poolKeys[i].currency0);
            }
            uint8 assetDecimals = IERC20(assetCurrency).decimals();
            
            // Apply the same decimal conversion formula as the contract:
            // (quantity * price * 10^numeraireDecimals) / (10^(18 + assetDecimals))
            totalValue += (demands[i] * price * (10**numeraireDecimals)) / (10**(18 + assetDecimals));
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
    
    /// @notice Submit bundles during proxy phase with specific quantities for testing
    /// @param _auctionId The auction ID
    /// @param _proxy The proxy address
    /// @param _bidder The bidder address  
    /// @param _quantities Array of quantities for each asset
    /// @param _saltA Salt for bidder
    /// @param _saltB Salt for proxy
    /// @return bundleId The created bundle ID
    function submitTestBundle(
        AuctionId _auctionId,
        address _proxy,
        address _bidder,
        uint256[] memory _quantities,
        string memory _saltA,
        string memory _saltB
    ) internal returns (BundleId bundleId) {
        // Create commit-reveal data
        bytes32 saltA = keccak256(bytes(_saltA));
        bytes32 saltB = keccak256(bytes(_saltB));
        bytes32 commitHash = CommitReveal.generateCommitHash(_bidder, _proxy, saltA, saltB);
        
        // Set up proxy commitment
        vm.prank(_proxy);
        cpaManager.commitToBidder(_auctionId, commitHash);
        
        // Submit bundle
        AuctionTypes.Bundle memory bundleData = AuctionTypes.Bundle({
            auctionId: _auctionId,
            commitHash: commitHash,
            value: 2000 * 10**18,
            quantities: _quantities,
            timestamp: block.timestamp
        });
        
        vm.prank(_proxy);
        cpaManager.submitBundle(_auctionId, commitHash, bundleData);
        
        // Generate bundle ID
        bundleId = BundleIdLibrary.createId(commitHash, keccak256(abi.encode(_quantities)));
        
        return bundleId;
    }

    /// @notice Create additional bundles for over-allocation testing during proxy phase
    /// @param _auctionId The auction ID
    /// @return bundleId3 Bundle ID for proxy1 with full deposit amounts (over-allocation)
    /// @return bundleId4 Bundle ID for proxy2 with partial amounts (valid allocation)
    function createOverAllocationBundles(AuctionId _auctionId) internal returns (BundleId bundleId3, BundleId bundleId4) {
        // Create additional bundle from proxy1 that demands full deposit amounts (guaranteed over-allocation)
        // Reuse existing proxy1 commitment but with different quantities
        uint256[] memory fullDemands = new uint256[](2);
        fullDemands[0] = 1000 * 10**18; // Full asset1 deposit
        fullDemands[1] = 1000 * 10**18; // Full asset2 deposit
        
        // Create new commit hash for proxy1 with different quantities
        bytes32 saltA1_alt = keccak256("saltA1_alt");
        bytes32 saltB1_alt = keccak256("saltB1_alt");
        bytes32 commitHash1_alt = CommitReveal.generateCommitHash(bidder1, proxy1, saltA1_alt, saltB1_alt);
        
        // Set up proxy commitment for the alternative bundle
        vm.prank(proxy1);
        cpaManager.commitToBidder(_auctionId, commitHash1_alt);
        
        // Submit the full deposit bundle
        AuctionTypes.Bundle memory bundleData3 = AuctionTypes.Bundle({
            auctionId: _auctionId,
            commitHash: commitHash1_alt,
            value: 2000 * 10**18,
            quantities: fullDemands,
            timestamp: block.timestamp
        });
        
        vm.prank(proxy1);
        cpaManager.submitBundle(_auctionId, commitHash1_alt, bundleData3);
        bundleId3 = BundleIdLibrary.createId(commitHash1_alt, keccak256(abi.encode(fullDemands)));
        
        // Create additional bundle from proxy2 with smaller amounts (for valid allocation testing)
        uint256[] memory partialDemands = new uint256[](2);
        partialDemands[0] = 200 * 10**18; // Smaller asset1 quantity
        partialDemands[1] = 300 * 10**18; // Smaller asset2 quantity
        
        // Create new commit hash for proxy2 with different quantities
        bytes32 saltA2_alt = keccak256("saltA2_alt");
        bytes32 saltB2_alt = keccak256("saltB2_alt");
        bytes32 commitHash2_alt = CommitReveal.generateCommitHash(bidder2, proxy2, saltA2_alt, saltB2_alt);
        
        // Set up proxy commitment for the alternative bundle
        vm.prank(proxy2);
        cpaManager.commitToBidder(_auctionId, commitHash2_alt);
        
        // Submit the smaller quantity bundle
        AuctionTypes.Bundle memory bundleData4 = AuctionTypes.Bundle({
            auctionId: _auctionId,
            commitHash: commitHash2_alt,
            value: 2000 * 10**18,
            quantities: partialDemands,
            timestamp: block.timestamp
        });
        
        vm.prank(proxy2);
        cpaManager.submitBundle(_auctionId, commitHash2_alt, bundleData4);
        bundleId4 = BundleIdLibrary.createId(commitHash2_alt, keccak256(abi.encode(partialDemands)));
        
        return (bundleId3, bundleId4);
    }
}
