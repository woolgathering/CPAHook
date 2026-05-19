// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IPositionManager } from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import { CPABase } from "../base/CPABase.sol";
import { LibDiamond } from "../libraries/LibDiamond.sol";

contract CallbackRouterFacet is CPABase {

    constructor(
        IPoolManager _poolManager,
        address _owner,
        address _cpaAuctionHookAddr,
        IPositionManager _positionManager,
        address _protocolWallet,
        address _mathFacet
    ) CPABase(_poolManager, _owner, _cpaAuctionHookAddr, _positionManager, _protocolWallet, _mathFacet) {}

    // Single registered handler for unlockCallback(bytes) selector in the diamond.
    // Decodes the operation type, looks up the appropriate callback sub-facet, and
    // delegatecalls it. Both hops run in diamond storage context (delegatecall preserves
    // address(this) and msg.sender throughout, so onlyPoolManager and storage access
    // are correct at each level).
    function unlockCallback(bytes calldata rawData)
        external
        onlyPoolManager
        returns (bytes memory)
    {
        (uint8 operationType,) = abi.decode(rawData, (uint8, bytes));
        address target = LibDiamond.getCallbackFacet(operationType);
        require(target != address(0), "CallbackRouter: unknown op type");
        (bool ok, bytes memory result) = target.delegatecall(
            abi.encodeWithSelector(this.unlockCallback.selector, rawData)
        );
        if (!ok) {
            // Bubble up revert data verbatim to preserve custom errors and panics.
            assembly { revert(add(result, 0x20), mload(result)) }
        }
        return result;
    }
}
