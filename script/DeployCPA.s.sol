// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { Script, console } from "forge-std/Script.sol";
import { CPAManager } from "../src/CPAManager.sol";
import { CPAHook } from "../src/CPAHook.sol";
import { MathFacet } from "../src/facets/MathFacet.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IPositionManager } from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import { Hooks } from "@uniswap/v4-core/src/libraries/Hooks.sol";
import { HookMiner } from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import { DiamondDeployHelper } from "./base/DiamondDeployHelper.sol";

/**
 * @title DeployCPA
 * @notice Deploy script for CPAManager diamond and CPAHook contracts
 * @dev Run with: forge script script/DeployCPA.s.sol --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast
 *
 * Required environment variables:
 * - PRIVATE_KEY: Private key for deployment
 * - POOL_MANAGER_ADDRESS: V4 PoolManager address
 * - POSITION_MANAGER_ADDRESS: V4 PositionManager address
 * - PROTOCOL_OWNER: Protocol owner address (optional, defaults to deployer)
 * - PROTOCOL_WALLET: Protocol fee-collection wallet (optional, defaults to PROTOCOL_OWNER)
 *
 * PositionManager addresses by chain:
 * - Mainnet: TBD (deployer must provide actual address)
 * - Sepolia: TBD (deployer must provide actual address)
 * - Base: TBD (deployer must provide actual address)
 *
 * Note: Deployer must provide correct PositionManager address for their target chain.
 * Individual facet addresses are not logged here; use `cast call <diamond> "facets()"` post-deploy.
 */
contract DeployCPA is Script, DiamondDeployHelper {
    function run() external {
        // Load environment variables
        address deployer = vm.addr(vm.envUint("PRIVATE_KEY"));
        address poolManagerAddress = vm.envAddress("POOL_MANAGER_ADDRESS");
        address positionManagerAddress = vm.envAddress("POSITION_MANAGER_ADDRESS");
        address protocolOwner = vm.envOr("PROTOCOL_OWNER", deployer);
        address protocolWallet = vm.envOr("PROTOCOL_WALLET", protocolOwner);

        console.log("Deploying from address:", deployer);
        console.log("PoolManager address:", poolManagerAddress);
        console.log("PositionManager address:", positionManagerAddress);
        console.log("Protocol owner:", protocolOwner);
        console.log("Protocol wallet:", protocolWallet);
        console.log("Deployer balance:", deployer.balance);

        vm.startBroadcast();

        // Deploy CPAHook with address mining (required for V4 hooks)
        console.log("Deploying CPAHook with address mining...");
        CPAHook cpaHook = deployCPAHook(IPoolManager(poolManagerAddress), protocolOwner);
        console.log("CPAHook deployed at:", address(cpaHook));

        // Deploy MathFacet first — no constructor args; address passed to all other facets
        console.log("Deploying MathFacet...");
        MathFacet mathFacet = new MathFacet();
        console.log("MathFacet deployed at:", address(mathFacet));

        // Deploy CPAManager diamond proxy
        console.log("Deploying CPAManager diamond...");
        CPAManager cpaManager = new CPAManager(
            IPoolManager(poolManagerAddress),
            protocolOwner,
            address(cpaHook),
            IPositionManager(positionManagerAddress),
            protocolWallet,
            address(mathFacet)
        );
        console.log("CPAManager deployed at:", address(cpaManager));

        // Register all facets and callback sub-facets in the diamond
        console.log("Registering facets...");
        address[6] memory a = [
            poolManagerAddress,
            protocolOwner,
            address(cpaHook),
            positionManagerAddress,
            protocolWallet,
            address(mathFacet)
        ];
        _deployAndRegisterFacets(cpaManager, a);
        _registerCallbackFacets(cpaManager, a);
        console.log("All facets registered.");

        // Wire CPAHook to the diamond
        console.log("Setting auction manager in CPAHook...");
        cpaHook.setAuctionManager(address(cpaManager));

        vm.stopBroadcast();

        // Deployment summary
        console.log("\n=== Deployment Summary ===");
        console.log("CPAManager:", address(cpaManager));
        console.log("CPAHook:", address(cpaHook));
        console.log("MathFacet:", address(mathFacet));
        console.log("PoolManager:", poolManagerAddress);
        console.log("PositionManager:", positionManagerAddress);
        console.log("Protocol Owner:", protocolOwner);
        console.log("Protocol Wallet:", protocolWallet);
        console.log("Deployer:", deployer);

        string memory addresses = string(abi.encodePacked(
            "CPAManager=", vm.toString(address(cpaManager)), "\n",
            "CPAHook=", vm.toString(address(cpaHook)), "\n",
            "MathFacet=", vm.toString(address(mathFacet)), "\n",
            "PoolManager=", vm.toString(poolManagerAddress), "\n",
            "PositionManager=", vm.toString(positionManagerAddress), "\n",
            "ProtocolOwner=", vm.toString(protocolOwner), "\n",
            "ProtocolWallet=", vm.toString(protocolWallet), "\n",
            "Deployer=", vm.toString(deployer), "\n"
        ));

        vm.writeFile("deployments.txt", addresses);
        console.log("Deployment addresses saved to deployments.txt");
    }

    /// @notice Deploy CPAHook with required flag bits mined into the address
    function deployCPAHook(IPoolManager _poolManager, address _protocolOwner) internal returns (CPAHook) {
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG |
            Hooks.BEFORE_SWAP_FLAG |
            Hooks.BEFORE_ADD_LIQUIDITY_FLAG |
            Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG |
            Hooks.BEFORE_DONATE_FLAG
        );

        bytes memory constructorArgs = abi.encode(_poolManager);

        (address hookAddress, bytes32 salt) = HookMiner.find(
            _protocolOwner,
            flags,
            type(CPAHook).creationCode,
            constructorArgs
        );

        CPAHook deployedHook = new CPAHook{salt: salt}(_poolManager);
        require(address(deployedHook) == hookAddress, "Hook address mismatch");
        return deployedHook;
    }
}
