// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { Script, console } from "forge-std/Script.sol";
import { CPAManager } from "../src/CPAManager.sol";
import { CPAHook } from "../src/CPAHook.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { Hooks } from "@uniswap/v4-core/src/libraries/Hooks.sol";
import { HookMiner } from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

/**
 * @title DeployCPA
 * @notice Deploy script for CPAManager and CPAHook contracts
 * @dev Run with: forge script script/DeployCPA.s.sol --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast
 */
contract DeployCPA is Script {
    function run() external {
        // Load environment variables
        address deployer = vm.addr(vm.envUint("PRIVATE_KEY"));
        address poolManagerAddress = vm.envAddress("POOL_MANAGER_ADDRESS");
        address protocolOwner = vm.envOr("PROTOCOL_OWNER", deployer);

        console.log("Deploying from address:", deployer);
        console.log("PoolManager address:", poolManagerAddress);
        console.log("Protocol owner:", protocolOwner);
        console.log("Deployer balance:", deployer.balance);

        // Start broadcasting transactions
        vm.startBroadcast();

        // Deploy CPAHook with proper address mining (required for V4 hooks)
        console.log("Deploying CPAHook with address mining...");
        CPAHook cpaHook = deployCPAHook(IPoolManager(poolManagerAddress), protocolOwner);
        console.log("CPAHook deployed at:", address(cpaHook));

        // Deploy CPAManager with PoolManager and CPAHook addresses
        console.log("Deploying CPAManager...");
        CPAManager cpaManager = new CPAManager(
            IPoolManager(poolManagerAddress),
            protocolOwner,
            address(cpaHook),
            protocolOwner
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
        console.log("Protocol Owner:", protocolOwner);
        console.log("Deployer:", deployer);

        // Save addresses to file for easy reference
        string memory addresses = string(abi.encodePacked(
            "CPAManager=", vm.toString(address(cpaManager)), "\n",
            "CPAHook=", vm.toString(address(cpaHook)), "\n",
            "PoolManager=", vm.toString(poolManagerAddress), "\n",
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
