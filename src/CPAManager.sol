// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import { CPAStorage } from "./base/CPAStorage.sol";
import { LibDiamond } from "./libraries/LibDiamond.sol";
import { IDiamondCut } from "./interfaces/IDiamondCut.sol";
import { IDiamondLoupe } from "./interfaces/IDiamondLoupe.sol";
import { IErrorsAndEvents } from "./utils/IErrorsAndEvents.sol";
import { AuctionId } from "./types/AuctionId.sol";

/**
 * @title CPAManager
 * @notice EIP-2535 diamond proxy. All protocol logic lives in facets under src/facets/.
 *         This contract holds all shared storage (via CPAStorage), routes calls to facets
 *         via delegatecall, and exposes DiamondCut / DiamondLoupe interfaces.
 */
contract CPAManager is Ownable, CPAStorage, ReentrancyGuard, IDiamondCut, IDiamondLoupe, IErrorsAndEvents {

    constructor(
        address _owner,
        address _protocolWallet,
        uint256 _protocolFeeBps,
        address _mathFacet
    ) Ownable(_owner) CPAStorage(_mathFacet, _protocolWallet, _protocolFeeBps) {}

    // ========================================
    // EIP-2535: DiamondCut
    // ========================================

    function diamondCut(
        FacetCut[] calldata _diamondCut,
        address _init,
        bytes calldata _calldata
    ) external override onlyOwner {
        for (uint256 i = 0; i < _diamondCut.length; ) {
            FacetCut calldata cut = _diamondCut[i];
            require(
                cut.action == FacetCutAction.Add || cut.action == FacetCutAction.Replace,
                "DiamondCut: Remove not supported"
            );
            for (uint256 j = 0; j < cut.functionSelectors.length; ) {
                LibDiamond.setFacet(cut.functionSelectors[j], cut.facetAddress);
                unchecked { ++j; }
            }
            unchecked { ++i; }
        }
        emit DiamondCut(_diamondCut, _init, _calldata);
        if (_init != address(0)) {
            (bool ok, bytes memory err) = _init.delegatecall(_calldata);
            if (!ok) {
                assembly { revert(add(err, 0x20), mload(err)) }
            }
        }
    }

    // ========================================
    // EIP-2535: DiamondLoupe
    // ========================================

    function facets() external view override returns (Facet[] memory facets_) {
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        address[] memory seen = new address[](ds.selectors.length);
        uint256 uniqueCount;
        for (uint256 i = 0; i < ds.selectors.length; ) {
            address f = ds.selectorToFacet[ds.selectors[i]];
            bool found;
            for (uint256 k = 0; k < uniqueCount; ) {
                if (seen[k] == f) { found = true; break; }
                unchecked { ++k; }
            }
            if (!found) seen[uniqueCount++] = f;
            unchecked { ++i; }
        }
        facets_ = new Facet[](uniqueCount);
        for (uint256 i = 0; i < uniqueCount; ) {
            facets_[i] = Facet({
                facetAddress: seen[i],
                functionSelectors: ds.facetSelectors[seen[i]]
            });
            unchecked { ++i; }
        }
    }

    function facetFunctionSelectors(address _facet)
        external view override returns (bytes4[] memory)
    {
        return LibDiamond.diamondStorage().facetSelectors[_facet];
    }

    function facetAddresses() external view override returns (address[] memory addrs) {
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        address[] memory tmp = new address[](ds.selectors.length);
        uint256 count;
        for (uint256 i = 0; i < ds.selectors.length; ) {
            address f = ds.selectorToFacet[ds.selectors[i]];
            bool found;
            for (uint256 k = 0; k < count; ) {
                if (tmp[k] == f) { found = true; break; }
                unchecked { ++k; }
            }
            if (!found) tmp[count++] = f;
            unchecked { ++i; }
        }
        addrs = new address[](count);
        for (uint256 i = 0; i < count; ) {
            addrs[i] = tmp[i];
            unchecked { ++i; }
        }
    }

    function facetAddress(bytes4 _functionSelector)
        external view override returns (address)
    {
        return LibDiamond.getFacet(_functionSelector);
    }

    // ========================================
    // Native view helpers
    // ========================================

    function getBidderDemands(AuctionId auctionId, address bidder) external view returns (uint256[] memory) {
        return bids[auctionId][bidder];
    }

    // ========================================
    // ERC-165
    // ========================================

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return
            interfaceId == type(IDiamondCut).interfaceId ||
            interfaceId == type(IDiamondLoupe).interfaceId ||
            interfaceId == 0x01ffc9a7;
    }

    // ========================================
    // Fallback — routes all protocol calls to facets
    // ========================================

    fallback() external payable {
        address facet = LibDiamond.getFacet(msg.sig);
        require(facet != address(0), "Diamond: function not found");
        assembly {
            calldatacopy(0, 0, calldatasize())
            let result := delegatecall(gas(), facet, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch result
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }

    receive() external payable {}
}
