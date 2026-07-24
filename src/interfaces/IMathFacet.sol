// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

interface IMathFacet {
    function mulDiv(uint256 a, uint256 b, uint256 denominator) external pure returns (uint256);
    function mulDivRoundingUp(uint256 a, uint256 b, uint256 denominator) external pure returns (uint256);
}
