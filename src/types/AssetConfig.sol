// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { AuctionId } from "./AuctionId.sol";

/// @notice Configuration for a single auctioned asset
struct AssetConfig {
    address assetToken;     // ERC20 token being auctioned
    uint256 startingPrice;  // numeraire per asset token (in numeraire decimals)
    uint256 priceIncrement; // added to price each clock round (in numeraire decimals)
    uint256 supply;         // total tokens deposited for auction
}

type AssetId is bytes32;

using { assetIdEquals as == } for AssetId global;

function assetIdEquals(AssetId a, AssetId b) pure returns (bool) {
    return AssetId.unwrap(a) == AssetId.unwrap(b);
}

library AssetIdLibrary {
    function createId(AuctionId auctionId, address assetToken) internal pure returns (AssetId) {
        return AssetId.wrap(keccak256(abi.encode(auctionId, assetToken)));
    }
}
