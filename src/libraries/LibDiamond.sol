// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

library LibDiamond {
    // Collision-resistant slot: keccak256("rok.diamond.storage") - 1
    bytes32 constant DIAMOND_STORAGE_SLOT =
        bytes32(uint256(keccak256("rok.diamond.storage")) - 1);

    struct DiamondStorage {
        // selector → facet address (for fallback routing)
        mapping(bytes4 => address) selectorToFacet;
        // ordered list of all registered selectors (for loupe)
        bytes4[] selectors;
        // facet address → its registered selectors (for loupe)
        mapping(address => bytes4[]) facetSelectors;
        // op type (0-9) → callback sub-facet address (used by CallbackRouterFacet)
        mapping(uint8 => address) callbackFacets;
    }

    function diamondStorage() internal pure returns (DiamondStorage storage ds) {
        bytes32 slot = DIAMOND_STORAGE_SLOT;
        assembly {
            ds.slot := slot
        }
    }

    function setFacet(bytes4 selector, address facet) internal {
        DiamondStorage storage ds = diamondStorage();
        require(facet != address(0), "LibDiamond: facet is zero address");
        if (ds.selectorToFacet[selector] == address(0)) {
            ds.selectors.push(selector);
        }
        ds.selectorToFacet[selector] = facet;
        bytes4[] storage existing = ds.facetSelectors[facet];
        for (uint256 i = 0; i < existing.length; ) {
            if (existing[i] == selector) return;
            unchecked { ++i; }
        }
        existing.push(selector);
    }

    function getFacet(bytes4 selector) internal view returns (address) {
        return diamondStorage().selectorToFacet[selector];
    }

    function setCallbackFacet(uint8 opType, address facet) internal {
        diamondStorage().callbackFacets[opType] = facet;
    }

    function getCallbackFacet(uint8 opType) internal view returns (address) {
        return diamondStorage().callbackFacets[opType];
    }
}
