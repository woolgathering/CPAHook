// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IPositionManager } from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

import { CPAManager } from "../../src/CPAManager.sol";
import { IDiamondCut } from "../../src/interfaces/IDiamondCut.sol";
import { CoreFacet } from "../../src/facets/CoreFacet.sol";
import { SetupFacet } from "../../src/facets/SetupFacet.sol";
import { SetupFinalizeFacet } from "../../src/facets/SetupFinalizeFacet.sol";
import { DepositFacet } from "../../src/facets/DepositFacet.sol";
import { ClockStartFacet } from "../../src/facets/ClockPhaseFacet.sol";
import { ClockBidFacet } from "../../src/facets/ClockBidFacet.sol";
import { ClockCommitFacet } from "../../src/facets/ClockBidderFacet.sol";
import { ClockEndFacet } from "../../src/facets/ClockEndFacet.sol";
import { ClockEndRoundFacet } from "../../src/facets/ClockEndRoundFacet.sol";
import { ClockFinalizeRoundFacet } from "../../src/facets/ClockFinalizeRoundFacet.sol";
import { ProxyPhaseFacet } from "../../src/facets/ProxyPhaseFacet.sol";
import { AllocationTransitionFacet } from "../../src/facets/AllocationPhaseFacet.sol";
import { AllocationSubmitFacet } from "../../src/facets/AllocationSubmitFacet.sol";
import { SettlementTransitionFacet } from "../../src/facets/SettlementTransitionFacet.sol";
import { SettlementTransferFacet } from "../../src/facets/SettlementTransferFacet.sol";
import { SettlementMintFacet } from "../../src/facets/SettlementMintFacet.sol";
import { SettlementClaimFacet } from "../../src/facets/SettlementPhaseFacet.sol";
import { SettlementMiscFacet } from "../../src/facets/SettlementMiscFacet.sol";
import { FinishedPhaseFacet } from "../../src/facets/FinishedPhaseFacet.sol";
import { AuctionFlowFacet } from "../../src/facets/AuctionFlowFacet.sol";
import { CallbackRouterFacet } from "../../src/facets/CallbackRouterFacet.sol";
import { CallbacksClockFacet } from "../../src/facets/CallbacksFacet.sol";
import { CallbacksDepositFacet } from "../../src/facets/CallbacksDepositFacet.sol";
import { CallbacksClaimTokenFacet } from "../../src/facets/CallbacksClaimTokenFacet.sol";
import { CallbacksRefundFacet } from "../../src/facets/CallbacksRefundFacet.sol";
import { CallbacksSettlementFacet } from "../../src/facets/CallbacksSettlementFacet.sol";

/**
 * @title DiamondDeployHelper
 * @notice Deployment helper for registering all protocol facets in the CPAManager diamond.
 * @dev Mirrors CPATestBase._registerProtocolFacets and _registerCallbackFacets exactly.
 *      The 6-element args array convention: a = [poolManager, owner, hookAddr, positionManager, protocolWallet, mathFacet].
 */
abstract contract DiamondDeployHelper {

    /// @notice Deploy all 21 protocol facets and register their selectors via diamondCut.
    function _deployAndRegisterFacets(CPAManager diamond, address[6] memory a) internal {
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](21);
        cuts[0]  = _cut(address(new CoreFacet(IPoolManager(a[0]), a[1], a[2], IPositionManager(a[3]), a[4], a[5])),
                        _sel5(0x80dbeb9a, 0xed56531a, 0x2f4dae9f, 0x3ef4d130, 0xb062d33d));
        cuts[1]  = _cut(address(new SetupFacet(IPoolManager(a[0]), a[1], a[2], IPositionManager(a[3]), a[4], a[5])),
                        _sel1(0x9bf2aeb5));
        cuts[2]  = _cut(address(new SetupFinalizeFacet(IPoolManager(a[0]), a[1], a[2], IPositionManager(a[3]), a[4], a[5])),
                        _sel1(0x474da4e4));
        cuts[3]  = _cut(address(new DepositFacet(IPoolManager(a[0]), a[1], a[2], IPositionManager(a[3]), a[4], a[5])),
                        _sel2(0x66773ddf, 0x36819016));
        cuts[4]  = _cut(address(new ClockStartFacet(IPoolManager(a[0]), a[1], a[2], IPositionManager(a[3]), a[4], a[5])),
                        _sel1(0x0ee5b80b));
        cuts[5]  = _cut(address(new ClockBidFacet(IPoolManager(a[0]), a[1], a[2], IPositionManager(a[3]), a[4], a[5])),
                        _sel1(0xe89329b3));
        cuts[6]  = _cut(address(new ClockCommitFacet(IPoolManager(a[0]), a[1], a[2], IPositionManager(a[3]), a[4], a[5])),
                        _sel3(0xc91db482, 0xb6283c64, 0x6cd5dacf));
        cuts[7]  = _cut(address(new ClockEndFacet(IPoolManager(a[0]), a[1], a[2], IPositionManager(a[3]), a[4], a[5])),
                        _sel1(0x31248695));
        cuts[8]  = _cut(address(new ClockEndRoundFacet(IPoolManager(a[0]), a[1], a[2], IPositionManager(a[3]), a[4], a[5])),
                        _sel1(0x3209185c));
        cuts[9]  = _cut(address(new ClockFinalizeRoundFacet(IPoolManager(a[0]), a[1], a[2], IPositionManager(a[3]), a[4], a[5])),
                        _sel1(0xafa9c445));
        cuts[10] = _cut(address(new ProxyPhaseFacet(IPoolManager(a[0]), a[1], a[2], IPositionManager(a[3]), a[4], a[5])),
                        _sel1(0x88e7cf2b));
        cuts[11] = _cut(address(new AllocationTransitionFacet(IPoolManager(a[0]), a[1], a[2], IPositionManager(a[3]), a[4], a[5])),
                        _sel1(0x00ae879c));
        cuts[12] = _cut(address(new AllocationSubmitFacet(IPoolManager(a[0]), a[1], a[2], IPositionManager(a[3]), a[4], a[5])),
                        _sel1(0x512ba771));
        cuts[13] = _cut(address(new SettlementTransitionFacet(IPoolManager(a[0]), a[1], a[2], IPositionManager(a[3]), a[4], a[5])),
                        _sel1(0xf242b7a4));
        cuts[14] = _cut(address(new SettlementTransferFacet(IPoolManager(a[0]), a[1], a[2], IPositionManager(a[3]), a[4], a[5])),
                        _sel1(0xf14c9a84));
        cuts[15] = _cut(address(new SettlementMintFacet(IPoolManager(a[0]), a[1], a[2], IPositionManager(a[3]), a[4], a[5])),
                        _sel1(0x194b7b8e));
        cuts[16] = _cut(address(new SettlementClaimFacet(IPoolManager(a[0]), a[1], a[2], IPositionManager(a[3]), a[4], a[5])),
                        _sel3(0x54a9395d, 0xa5a9acd2, 0xd5756da3));
        cuts[17] = _cut(address(new SettlementMiscFacet(IPoolManager(a[0]), a[1], a[2], IPositionManager(a[3]), a[4], a[5])),
                        _sel3(0x332ccba9, 0x32d3ffd3, 0x935f2189));
        cuts[18] = _cut(address(new FinishedPhaseFacet(IPoolManager(a[0]), a[1], a[2], IPositionManager(a[3]), a[4], a[5])),
                        _sel2(0x6dab7661, 0xded97a8d));
        cuts[19] = _cut(address(new CallbackRouterFacet(IPoolManager(a[0]), a[1], a[2], IPositionManager(a[3]), a[4], a[5])),
                        _sel1(0x91dd7346));
        cuts[20] = _cut(address(new AuctionFlowFacet(IPoolManager(a[0]), a[1], a[2], IPositionManager(a[3]), a[4], a[5])),
                        _sel3(0x6c8c9d4c, 0x047d82d1, 0x1555221e));
        diamond.diamondCut(cuts, address(0), "");
    }

    /// @notice Deploy the 5 callback sub-facets and register their op-type mappings.
    function _registerCallbackFacets(CPAManager diamond, address[6] memory a) internal {
        address cbClock  = address(new CallbacksClockFacet(IPoolManager(a[0]), a[1], a[2], IPositionManager(a[3]), a[4], a[5]));
        address cbDep    = address(new CallbacksDepositFacet(IPoolManager(a[0]), a[1], a[2], IPositionManager(a[3]), a[4], a[5]));
        address cbClaim  = address(new CallbacksClaimTokenFacet(IPoolManager(a[0]), a[1], a[2], IPositionManager(a[3]), a[4], a[5]));
        address cbRefund = address(new CallbacksRefundFacet(IPoolManager(a[0]), a[1], a[2], IPositionManager(a[3]), a[4], a[5]));
        address cbSettle = address(new CallbacksSettlementFacet(IPoolManager(a[0]), a[1], a[2], IPositionManager(a[3]), a[4], a[5]));

        uint8[] memory opTypes = new uint8[](10);
        address[] memory facets_ = new address[](10);
        opTypes[0] = 0; facets_[0] = cbClock;
        opTypes[1] = 1; facets_[1] = cbDep;
        opTypes[2] = 2; facets_[2] = cbClock;
        opTypes[3] = 3; facets_[3] = cbClock;
        opTypes[4] = 4; facets_[4] = cbClaim;
        opTypes[5] = 5; facets_[5] = cbRefund;
        opTypes[6] = 6; facets_[6] = cbRefund;
        opTypes[7] = 7; facets_[7] = cbSettle;
        opTypes[8] = 8; facets_[8] = cbDep;
        opTypes[9] = 9; facets_[9] = cbClock;
        diamond.setCallbackFacets(opTypes, facets_);
    }

    // ---- selector helpers ----

    function _cut(address facet, bytes4[] memory sels) internal pure returns (IDiamondCut.FacetCut memory) {
        return IDiamondCut.FacetCut({ facetAddress: facet, action: IDiamondCut.FacetCutAction.Add, functionSelectors: sels });
    }

    function _sel1(bytes4 a) internal pure returns (bytes4[] memory s) { s = new bytes4[](1); s[0]=a; }
    function _sel2(bytes4 a, bytes4 b) internal pure returns (bytes4[] memory s) { s = new bytes4[](2); s[0]=a; s[1]=b; }
    function _sel3(bytes4 a, bytes4 b, bytes4 c) internal pure returns (bytes4[] memory s) { s = new bytes4[](3); s[0]=a; s[1]=b; s[2]=c; }
    function _sel5(bytes4 a, bytes4 b, bytes4 c, bytes4 d, bytes4 e) internal pure returns (bytes4[] memory s) {
        s = new bytes4[](5); s[0]=a; s[1]=b; s[2]=c; s[3]=d; s[4]=e;
    }
}
