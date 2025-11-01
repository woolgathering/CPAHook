// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { Script, console } from "forge-std/Script.sol";
import { CPAManager } from "../src/CPAManager.sol";
import { CPAHook } from "../src/CPAHook.sol";
import { CPASetup } from "../src/libraries/CPASetup.sol";
import { CPAClockPhase } from "../src/libraries/CPAClockPhase.sol";
import { CPAProxyPhase } from "../src/libraries/CPAProxyPhase.sol";
import { CPAAllocationPhase } from "../src/libraries/CPAAllocationPhase.sol";
import { CPASettlementPhase } from "../src/libraries/CPASettlementPhase.sol";
import { CPAFinishedPhase } from "../src/libraries/CPAFinishedPhase.sol";
import { CPAAuctionControl } from "../src/libraries/CPAAuctionControl.sol";
import { CPACallbacks } from "../src/libraries/CPACallbacks.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IPositionManager } from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import { Hooks } from "@uniswap/v4-core/src/libraries/Hooks.sol";
import { HookMiner } from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

/**
 * @title DeployCPA
 * @notice Deploy script for CPAManager and CPAHook contracts
 * @dev Run with: forge script script/DeployCPA.s.sol --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast
 * 
 * Required environment variables:
 * - PRIVATE_KEY: Private key for deployment
 * - POOL_MANAGER_ADDRESS: V4 PoolManager address
 * - POSITION_MANAGER_ADDRESS: V4 PositionManager address
 * - PROTOCOL_OWNER: Protocol owner address (optional, defaults to deployer)
 * 
 * PositionManager addresses by chain:
 * - Mainnet: TBD (deployer must provide actual address)
 * - Sepolia: TBD (deployer must provide actual address)  
 * - Base: TBD (deployer must provide actual address)
 * 
 * Note: Deployer must provide correct PositionManager address for their target chain
 */
contract DeployCPA is Script {
    function run() external {
        // Load environment variables
        address deployer = vm.addr(vm.envUint("PRIVATE_KEY"));
        address poolManagerAddress = vm.envAddress("POOL_MANAGER_ADDRESS");
        address positionManagerAddress = vm.envAddress("POSITION_MANAGER_ADDRESS");
        address protocolOwner = vm.envOr("PROTOCOL_OWNER", deployer);

        console.log("Deploying from address:", deployer);
        console.log("PoolManager address:", poolManagerAddress);
        console.log("PositionManager address:", positionManagerAddress);
        console.log("Protocol owner:", protocolOwner);
        console.log("Deployer balance:", deployer.balance);

        // Start broadcasting transactions
        vm.startBroadcast();

        // Deploy CPAHook with proper address mining (required for V4 hooks)
        console.log("Deploying CPAHook with address mining...");
        CPAHook cpaHook = deployCPAHook(IPoolManager(poolManagerAddress), protocolOwner);
        console.log("CPAHook deployed at:", address(cpaHook));

        // Deploy CPAManager with PoolManager, PositionManager, and CPAHook addresses
        console.log("Deploying phase libraries...");
        address setupLib = address(new CPASetup());
        address clockPhaseLib = address(new CPAClockPhase());
        address proxyPhaseLib = address(new CPAProxyPhase());
        address allocationPhaseLib = address(new CPAAllocationPhase());
        address settlementPhaseLib = address(new CPASettlementPhase());
        address finishedPhaseLib = address(new CPAFinishedPhase());
        address auctionControlLib = address(new CPAAuctionControl());
        address callbackLib = address(new CPACallbacks());
        
        console.log("Deploying CPAManager...");
        CPAManager cpaManager = new CPAManager(
            IPoolManager(poolManagerAddress),
            protocolOwner,
            address(cpaHook),
            IPositionManager(positionManagerAddress),
            protocolOwner,
            setupLib,
            clockPhaseLib,
            proxyPhaseLib,
            allocationPhaseLib,
            settlementPhaseLib,
            finishedPhaseLib,
            auctionControlLib,
            callbackLib
        );
        console.log("CPAManager deployed at:", address(cpaManager));

        // Set auction manager in CPAHook
        console.log("Setting auction manager in CPAHook...");
        cpaHook.setAuctionManager(address(cpaManager));

        vm.stopBroadcast();

        // Log deployment summary
        console.log("\n=== Deployment Summary ===");
        console.log("CPAManager:", address(cpaManager));
        console.log("CPAHook:", address(cpaHook));
        console.log("PoolManager:", poolManagerAddress);
        console.log("PositionManager:", positionManagerAddress);
        console.log("Protocol Owner:", protocolOwner);
        console.log("Deployer:", deployer);

        // Save addresses to file for easy reference
        string memory addresses = string(abi.encodePacked(
            "CPAManager=", vm.toString(address(cpaManager)), "\n",
            "CPAHook=", vm.toString(address(cpaHook)), "\n",
            "PoolManager=", vm.toString(poolManagerAddress), "\n",
            "PositionManager=", vm.toString(positionManagerAddress), "\n",
            "ProtocolOwner=", vm.toString(protocolOwner), "\n",
            "Deployer=", vm.toString(deployer), "\n"
        ));
        
        vm.writeFile("deployments.txt", addresses);
        console.log("Deployment addresses saved to deployments.txt");
    }

    /// @notice Deploy CPAHook with proper address mining and flag setting
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
