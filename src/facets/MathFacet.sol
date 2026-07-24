// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { FullMath } from "@uniswap/v4-core/src/libraries/FullMath.sol";

contract MathFacet {

    function mulDiv(uint256 a, uint256 b, uint256 denominator) external pure returns (uint256) {
        return FullMath.mulDiv(a, b, denominator);
    }

    function mulDivRoundingUp(uint256 a, uint256 b, uint256 denominator) external pure returns (uint256) {
        return FullMath.mulDivRoundingUp(a, b, denominator);
    }
}
