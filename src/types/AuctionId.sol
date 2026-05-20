// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { AssetConfig } from "./AssetConfig.sol";

type AuctionId is bytes32;

using {equals as ==} for AuctionId global;

function equals(AuctionId auctionId, AuctionId other) pure returns (bool) {
    return AuctionId.unwrap(auctionId) == AuctionId.unwrap(other);
}

library AuctionIdLibrary {

    function createId(AssetConfig[] memory assets) internal pure returns (AuctionId) {
        // sort asset token addresses then hash for a stable, order-independent ID
        address[] memory addrs = new address[](assets.length);
        for (uint256 i = 0; i < assets.length; i++) {
            addrs[i] = assets[i].assetToken;
        }
        _sortAddresses(addrs);
        return AuctionId.wrap(keccak256(abi.encode(addrs)));
    }

    function _sortAddresses(address[] memory addrs) internal pure {
        uint256 n = addrs.length;
        for (uint256 i = 0; i < n - 1; i++) {
            for (uint256 j = 0; j < n - i - 1; j++) {
                if (addrs[j] > addrs[j + 1]) {
                    address temp = addrs[j];
                    addrs[j] = addrs[j + 1];
                    addrs[j + 1] = temp;
                }
            }
        }
    }
}
