// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { Test, console } from "forge-std/Test.sol";
import { IERC20 } from "forge-std/interfaces/IERC20.sol";

import { CPAManager } from "../../src/CPAManager.sol";
import { ICPAManager } from "../../src/interfaces/ICPAManager.sol";
import { IDiamondCut } from "../../src/interfaces/IDiamondCut.sol";
import { MathFacet } from "../../src/facets/MathFacet.sol";
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
import { SettlementClaimFacet } from "../../src/facets/SettlementPhaseFacet.sol";
import { SettlementMiscFacet } from "../../src/facets/SettlementMiscFacet.sol";
import { FinishedPhaseFacet } from "../../src/facets/FinishedPhaseFacet.sol";
import { AuctionFlowFacet } from "../../src/facets/AuctionFlowFacet.sol";
import { ProceedsFacet } from "../../src/facets/ProceedsFacet.sol";
import { AuctionTypes } from "../../src/types/AuctionTypes.sol";
import { AuctionId } from "../../src/types/AuctionId.sol";
import { AssetConfig, AssetId, AssetIdLibrary } from "../../src/types/AssetConfig.sol";
import { MockERC20 } from "solmate/src/test/utils/mocks/MockERC20.sol";
import { IErrorsAndEvents } from "../../src/utils/IErrorsAndEvents.sol";
import { CommitReveal } from "../../src/utils/CommitReveal.sol";
import { BundleId, BundleIdLibrary } from "../../src/types/BundleId.sol";

abstract contract CPATestBase is Test {
    // Core contracts
    ICPAManager public cpaManager;
    MathFacet public mathFacet;

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

    // Auction data
    AuctionId public auctionId;
    uint256 public allocatorRewardPct;

    // Price / supply parameters
    uint256 public asset1StartingPrice  = 1e18;
    uint256 public asset2StartingPrice  = 2e18;
    uint256 public asset1PriceIncrement = 0.1e18;
    uint256 public asset2PriceIncrement = 0.2e18;
    uint256 public depositAmount1       = 100_000e18;
    uint256 public depositAmount2       = 150_000e18;

    function setUp() public virtual {
        deployTokens();
        setupAccounts();
        deployContracts();
    }

    function deployTokens() internal virtual {
        numeraireToken = new MockERC20("Numeraire Token", "NUM", 18);
        asset1Token    = new MockERC20("Asset 1 Token",   "AST1", 18);
        asset2Token    = new MockERC20("Asset 2 Token",   "AST2", 18);

        vm.label(address(numeraireToken), "NUMERAIRE");
        vm.label(address(asset1Token),    "ASSET1");
        vm.label(address(asset2Token),    "ASSET2");
    }

    function setupAccounts() internal {
        protocolOwner = makeAddr("protocolOwner");
        auctioneer    = makeAddr("auctioneer");
        bidder1       = makeAddr("bidder1");
        bidder2       = makeAddr("bidder2");
        proxy1        = makeAddr("proxy1");
        proxy2        = makeAddr("proxy2");
        bidder3       = makeAddr("bidder3");
        proxy3        = makeAddr("proxy3");
        bidder4       = makeAddr("bidder4");
        proxy4        = makeAddr("proxy4");
    }

    function deployContracts() internal {
        vm.startPrank(protocolOwner);

        mathFacet = new MathFacet();
        CPAManager diamond = new CPAManager(protocolOwner, address(this), 100, address(mathFacet));
        cpaManager = ICPAManager(address(diamond));
        _registerProtocolFacets(diamond);

        vm.stopPrank();
    }

    function _registerProtocolFacets(CPAManager diamond) internal {
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](19);

        address po  = protocolOwner;
        address pw  = address(this);
        uint256 fee = 100;
        address mf  = address(mathFacet);

        cuts[0]  = _cut(address(new CoreFacet(po, pw, fee, mf)),
                        _sel4(CoreFacet.pause.selector, CoreFacet.unpause.selector,
                              CoreFacet.cancelAuction.selector, CoreFacet.forceCancelAuction.selector));
        cuts[1]  = _cut(address(new SetupFacet(po, pw, fee, mf)),
                        _sel1(SetupFacet.initAuction.selector));
        cuts[2]  = _cut(address(new SetupFinalizeFacet(po, pw, fee, mf)),
                        _sel1(SetupFinalizeFacet.finalizeAuction.selector));
        cuts[3]  = _cut(address(new DepositFacet(po, pw, fee, mf)),
                        _sel2(DepositFacet.moveDeposit.selector, DepositFacet.depositAllAndStartClock.selector));
        cuts[4]  = _cut(address(new ClockStartFacet(po, pw, fee, mf)),
                        _sel1(ClockStartFacet.startClockPhase.selector));
        cuts[5]  = _cut(address(new ClockBidFacet(po, pw, fee, mf)),
                        _sel1(ClockBidFacet.submitBid.selector));
        cuts[6]  = _cut(address(new ClockCommitFacet(po, pw, fee, mf)),
                        _sel3(ClockCommitFacet.commitToBidder.selector,
                              ClockCommitFacet.registerCommit.selector,
                              ClockCommitFacet.dropout.selector));
        cuts[7]  = _cut(address(new ClockEndFacet(po, pw, fee, mf)),
                        _sel1(ClockEndFacet.endClockPhase.selector));
        cuts[8]  = _cut(address(new ClockEndRoundFacet(po, pw, fee, mf)),
                        _sel1(ClockEndRoundFacet.processClockRoundStep.selector));
        cuts[9]  = _cut(address(new ClockFinalizeRoundFacet(po, pw, fee, mf)),
                        _sel1(ClockFinalizeRoundFacet.finalizeClockRound.selector));
        cuts[10] = _cut(address(new ProxyPhaseFacet(po, pw, fee, mf)),
                        _sel1(ProxyPhaseFacet.submitBundle.selector));
        cuts[11] = _cut(address(new AllocationTransitionFacet(po, pw, fee, mf)),
                        _sel1(AllocationTransitionFacet.transitionToAllocation.selector));
        cuts[12] = _cut(address(new AllocationSubmitFacet(po, pw, fee, mf)),
                        _sel1(AllocationSubmitFacet.submitAllocation.selector));
        cuts[13] = _cut(address(new SettlementTransitionFacet(po, pw, fee, mf)),
                        _sel1(SettlementTransitionFacet.selectAuctionWinner.selector));
        cuts[14] = _cut(address(new SettlementClaimFacet(po, pw, fee, mf)),
                        _sel2(SettlementClaimFacet.reveal.selector, SettlementClaimFacet.claimAllTokens.selector));
        cuts[15] = _cut(address(new SettlementMiscFacet(po, pw, fee, mf)),
                        _sel3(SettlementMiscFacet.claimAllocatorReward.selector,
                              SettlementMiscFacet.reclaimStake.selector,
                              SettlementMiscFacet.transitionToFinished.selector));
        cuts[16] = _cut(address(new FinishedPhaseFacet(po, pw, fee, mf)),
                        _sel1(FinishedPhaseFacet.forfeit.selector));
        cuts[17] = _cut(address(new AuctionFlowFacet(po, pw, fee, mf)),
                        _sel3(AuctionFlowFacet.createAuction.selector,
                              AuctionFlowFacet.endClockRound.selector,
                              AuctionFlowFacet.transitionToSettlement.selector));
        cuts[18] = _cut(address(new ProceedsFacet(po, pw, fee, mf)),
                        _sel2(ProceedsFacet.returnProceeds.selector, ProceedsFacet.withdrawProtocolFees.selector));

        // View facet — register getters on the diamond itself (already in CPAManager storage)
        // No separate ViewFacet needed; getters are on CPAStorage via the diamond fallback.
        // Placeholder cut[19] reserved; shrink array if not needed.
        // Use the SetupFacet slot for view functions if a dedicated view facet exists.
        // For now, re-use an existing facet address to register view selectors.
        // Check if a ViewFacet exists:
        diamond.diamondCut(cuts, address(0), "");
    }

    // ---- selector helpers ----
    function _cut(address facet, bytes4[] memory sels) internal pure returns (IDiamondCut.FacetCut memory) {
        return IDiamondCut.FacetCut({ facetAddress: facet, action: IDiamondCut.FacetCutAction.Add, functionSelectors: sels });
    }
    function _sel1(bytes4 a) internal pure returns (bytes4[] memory s) { s = new bytes4[](1); s[0]=a; }
    function _sel2(bytes4 a, bytes4 b) internal pure returns (bytes4[] memory s) { s = new bytes4[](2); s[0]=a; s[1]=b; }
    function _sel3(bytes4 a, bytes4 b, bytes4 c) internal pure returns (bytes4[] memory s) { s = new bytes4[](3); s[0]=a; s[1]=b; s[2]=c; }
    function _sel4(bytes4 a, bytes4 b, bytes4 c, bytes4 d) internal pure returns (bytes4[] memory s) {
        s = new bytes4[](4); s[0]=a; s[1]=b; s[2]=c; s[3]=d;
    }

    // ---- auction config builders ----

    function createStandardAuctionConfig() internal returns (AuctionTypes.AuctionConfig memory) {
        AssetConfig[] memory assets = new AssetConfig[](2);
        assets[0] = AssetConfig({
            assetToken:     address(asset1Token),
            startingPrice:  asset1StartingPrice,
            priceIncrement: asset1PriceIncrement,
            supply:         depositAmount1
        });
        assets[1] = AssetConfig({
            assetToken:     address(asset2Token),
            startingPrice:  asset2StartingPrice,
            priceIncrement: asset2PriceIncrement,
            supply:         depositAmount2
        });

        uint256[] memory phaseDurations = new uint256[](3); // [proxy, allocation, settlement]
        phaseDurations[0] = 3600;
        phaseDurations[1] = 1800;
        phaseDurations[2] = 3600;

        allocatorRewardPct = 100;

        return AuctionTypes.AuctionConfig({
            commonNumeraire:             address(numeraireToken),
            minSpendRatio:               1000,
            dropoutSlashRatio:           1000,
            spendingViolationSlashRatio: 2000,
            allocatorRewardPct:          allocatorRewardPct,
            maxRounds:                   100,
            phaseDurations:              phaseDurations,
            assets:                      assets,
            createPoolOnFinish:          false
        });
    }

    function createNewAuctionConfig() internal returns (AuctionTypes.AuctionConfig memory) {
        MockERC20 newAsset1 = new MockERC20("New Asset 1", "NA1", 18);
        MockERC20 newAsset2 = new MockERC20("New Asset 2", "NA2", 18);

        AssetConfig[] memory assets = new AssetConfig[](2);
        assets[0] = AssetConfig({
            assetToken:     address(newAsset1),
            startingPrice:  1e18,
            priceIncrement: 0.1e18,
            supply:         100_000e18
        });
        assets[1] = AssetConfig({
            assetToken:     address(newAsset2),
            startingPrice:  2e18,
            priceIncrement: 0.2e18,
            supply:         150_000e18
        });

        uint256[] memory phaseDurations = new uint256[](3);
        phaseDurations[0] = 3600;
        phaseDurations[1] = 1800;
        phaseDurations[2] = 3600;

        return AuctionTypes.AuctionConfig({
            commonNumeraire:             address(numeraireToken),
            minSpendRatio:               1000,
            dropoutSlashRatio:           1000,
            spendingViolationSlashRatio: 2000,
            allocatorRewardPct:          100,
            maxRounds:                   100,
            phaseDurations:              phaseDurations,
            assets:                      assets,
            createPoolOnFinish:          false
        });
    }

    // ---- auction lifecycle helpers ----

    function createAuction(AuctionTypes.AuctionConfig memory config, address owner) internal returns (AuctionId) {
        return cpaManager.createAuction(config, owner);
    }

    function moveDeposit(AuctionId _auctionId, address assetToken, uint256 amount) internal {
        vm.prank(auctioneer);
        cpaManager.moveDeposit(_auctionId, assetToken, amount);
    }

    function depositAllAndStartClock(AuctionId _auctionId, uint256[] memory amounts) internal {
        vm.prank(auctioneer);
        cpaManager.depositAllAndStartClock(_auctionId, amounts);
    }

    function setupCompleteAuction() internal returns (AuctionId) {
        AuctionId id = createAuction(createStandardAuctionConfig(), auctioneer);

        asset1Token.mint(auctioneer, depositAmount1);
        asset2Token.mint(auctioneer, depositAmount2);
        vm.prank(auctioneer); asset1Token.approve(address(cpaManager), depositAmount1);
        vm.prank(auctioneer); asset2Token.approve(address(cpaManager), depositAmount2);

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = depositAmount1;
        amounts[1] = depositAmount2;
        depositAllAndStartClock(id, amounts);

        return id;
    }

    function endClockRound(AuctionId _auctionId) internal {
        vm.prank(auctioneer);
        cpaManager.endClockRound(_auctionId);
    }

    function transitionToSettlement(AuctionId _auctionId) internal {
        cpaManager.transitionToSettlement(_auctionId);
    }

    function getBidderDemands(AuctionId _auctionId, address _bidder) internal view returns (uint256[] memory) {
        return cpaManager.getBidderDemands(_auctionId, _bidder);
    }

    // ---- bidder helpers ----

    function createBidder(address bidder, uint256 numeraireAmount) internal {
        numeraireToken.mint(bidder, numeraireAmount);
    }

    function approveNumeraireForBidder(address bidder, uint256 amount) internal {
        vm.prank(bidder);
        numeraireToken.approve(address(cpaManager), amount);
    }

    function mintTokensToAuctioneer(uint256 amount) internal {
        asset1Token.mint(auctioneer, amount);
        asset2Token.mint(auctioneer, amount);
    }

    function approveTokens(address token, address spender, uint256 amount) internal {
        vm.prank(auctioneer);
        IERC20(token).approve(spender, amount);
    }

    // ---- price helpers ----

    function calculateBidValue(uint256[] memory demands) internal view virtual returns (uint256) {
        AuctionTypes.AuctionInfo memory info = cpaManager.getAuctionInfo(auctionId);
        uint256 total = 0;
        for (uint256 i = 0; i < demands.length; i++) {
            AssetId assetId = AssetIdLibrary.createId(auctionId, info.assets[i].assetToken);
            AuctionTypes.AssetInfo memory asset = cpaManager.getAssetInfo(assetId);
            uint8 dec = IERC20(info.assets[i].assetToken).decimals();
            total += (demands[i] * asset.currentPrice) / (10 ** dec);
        }
        return total;
    }

    // ---- proxy/bundle helpers ----

    function submitTestBundle(
        AuctionId _auctionId,
        address _proxy,
        address _bidder,
        uint256[] memory _quantities,
        string memory _saltA,
        string memory _saltB
    ) internal returns (BundleId bundleId) {
        bytes32 saltA = keccak256(bytes(_saltA));
        bytes32 saltB = keccak256(bytes(_saltB));
        bytes32 commitHash = CommitReveal.generateCommitHash(_bidder, _proxy, saltA, saltB);

        vm.prank(_proxy);
        cpaManager.commitToBidder(_auctionId, commitHash);

        AuctionTypes.Bundle memory bundleData = AuctionTypes.Bundle({
            auctionId:  _auctionId,
            commitHash: commitHash,
            value:      2000 * 10**18,
            quantities: _quantities,
            timestamp:  block.timestamp
        });

        vm.prank(_proxy);
        cpaManager.submitBundle(_auctionId, commitHash, bundleData);

        bundleId = BundleIdLibrary.createId(commitHash, keccak256(abi.encode(_quantities)));
    }

    function createOverAllocationBundles(AuctionId _auctionId) internal returns (BundleId bundleId3, BundleId bundleId4) {
        uint256[] memory fullDemands = new uint256[](2);
        fullDemands[0] = 1000 * 10**18;
        fullDemands[1] = 1000 * 10**18;

        bytes32 saltA1_alt = keccak256("saltA1_alt");
        bytes32 saltB1_alt = keccak256("saltB1_alt");
        bytes32 commitHash1_alt = CommitReveal.generateCommitHash(bidder1, proxy1, saltA1_alt, saltB1_alt);

        vm.prank(proxy1);
        cpaManager.commitToBidder(_auctionId, commitHash1_alt);

        AuctionTypes.Bundle memory bundleData3 = AuctionTypes.Bundle({
            auctionId:  _auctionId,
            commitHash: commitHash1_alt,
            value:      2000 * 10**18,
            quantities: fullDemands,
            timestamp:  block.timestamp
        });

        vm.prank(proxy1);
        cpaManager.submitBundle(_auctionId, commitHash1_alt, bundleData3);
        bundleId3 = BundleIdLibrary.createId(commitHash1_alt, keccak256(abi.encode(fullDemands)));

        uint256[] memory partialDemands = new uint256[](2);
        partialDemands[0] = 200 * 10**18;
        partialDemands[1] = 300 * 10**18;

        bytes32 saltA2_alt = keccak256("saltA2_alt");
        bytes32 saltB2_alt = keccak256("saltB2_alt");
        bytes32 commitHash2_alt = CommitReveal.generateCommitHash(bidder2, proxy2, saltA2_alt, saltB2_alt);

        vm.prank(proxy2);
        cpaManager.commitToBidder(_auctionId, commitHash2_alt);

        AuctionTypes.Bundle memory bundleData4 = AuctionTypes.Bundle({
            auctionId:  _auctionId,
            commitHash: commitHash2_alt,
            value:      2000 * 10**18,
            quantities: partialDemands,
            timestamp:  block.timestamp
        });

        vm.prank(proxy2);
        cpaManager.submitBundle(_auctionId, commitHash2_alt, bundleData4);
        bundleId4 = BundleIdLibrary.createId(commitHash2_alt, keccak256(abi.encode(partialDemands)));
    }
}
