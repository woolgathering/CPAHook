// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { console2 } from "forge-std/console2.sol";
import { CPAManager } from "../src/CPAManager.sol";
import { MathFacet } from "../src/facets/MathFacet.sol";
import { AuctionTypes } from "../src/types/AuctionTypes.sol";
import { AuctionId } from "../src/types/AuctionId.sol";
import { CPATestBase } from "./base/CPATestBase.sol";

contract CPAManagerTest is CPATestBase {
    address public nonOwner;

    function setUp() public override {
        super.setUp();
        nonOwner = makeAddr("nonOwner");
    }

    function test_Constructor_Success() public view {
        // Verify owner is set correctly (inherited from Ownable)
        assertEq(ICPAManagerOwner(address(cpaManager)).owner(), protocolOwner);
    }

    function test_Constructor_OwnerCanTransferOwnership() public {
        // Owner should be able to transfer ownership
        vm.prank(protocolOwner);
        ICPAManagerOwner(address(cpaManager)).transferOwnership(nonOwner);

        // Verify ownership transfer
        assertEq(ICPAManagerOwner(address(cpaManager)).owner(), nonOwner);
    }

    function test_Constructor_NonOwnerCannotTransferOwnership() public {
        // Non-owner should not be able to transfer ownership
        vm.prank(nonOwner);
        vm.expectRevert(); // OwnableUnauthorizedAccount(address)
        ICPAManagerOwner(address(cpaManager)).transferOwnership(nonOwner);
    }

    function test_Constructor_GasUsage() public {
        // Test gas usage for a fresh diamond deployment
        MathFacet mf = new MathFacet();
        uint256 gasBefore = gasleft();
        new CPAManager(protocolOwner, address(this), 100, address(mf));
        uint256 gasUsed = gasBefore - gasleft();

        console2.log("CPAManager constructor gas used:", gasUsed);

        // Gas usage should be reasonable
        assertLt(gasUsed, 100_000_000);
    }

    function test_Constructor_MultipleInstances() public {
        // Test creating multiple instances
        MathFacet mf = new MathFacet();
        CPAManager manager1 = new CPAManager(protocolOwner, address(this), 100, address(mf));
        CPAManager manager2 = new CPAManager(nonOwner,       address(this), 100, address(mf));

        // Each instance should have its own state
        assertEq(manager1.owner(), protocolOwner);
        assertEq(manager2.owner(), nonOwner);
    }

    function test_CreateAuction_Success() public {
        AuctionTypes.AuctionConfig memory config = createStandardAuctionConfig();
        AuctionId id = createAuction(config, auctioneer);

        // Verify auction was created
        AuctionTypes.AuctionInfo memory info = cpaManager.getAuctionInfo(id);
        assertEq(info.config.commonNumeraire, address(numeraireToken));
        assertEq(info.config.assets.length, 2);
        assertEq(info.config.assets[0].assetToken, address(asset1Token));
        assertEq(info.config.assets[1].assetToken, address(asset2Token));
        assertEq(info.config.phaseDurations.length, 3);
    }

    function test_CreateAuction_PhaseDurationsLength() public {
        AuctionTypes.AuctionConfig memory config = createStandardAuctionConfig();
        AuctionId id = createAuction(config, auctioneer);

        AuctionTypes.AuctionInfo memory info = cpaManager.getAuctionInfo(id);
        // phaseDurations: [proxy, allocation, settlement]
        assertEq(info.config.phaseDurations.length, 3);
        assertEq(info.config.phaseDurations[0], 3600); // proxy
        assertEq(info.config.phaseDurations[1], 1800); // allocation
        assertEq(info.config.phaseDurations[2], 3600); // settlement
    }
}

// Minimal interface to call Ownable methods on the diamond
interface ICPAManagerOwner {
    function owner() external view returns (address);
    function transferOwnership(address newOwner) external;
}
