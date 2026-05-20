// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

interface IMathFacet {
    function getTickAtSqrtPrice(uint160 sqrtPriceX96) external pure returns (int24);
    function getSqrtPriceAtTick(int24 tick) external pure returns (uint160);
    function getLiquidityForAmount0(uint160 sqrtRatioAx96, uint160 sqrtRatioBx96, uint256 amount0) external pure returns (uint128);
    function getLiquidityForAmount1(uint160 sqrtRatioAx96, uint160 sqrtRatioBx96, uint256 amount1) external pure returns (uint128);
    function mulDiv(uint256 a, uint256 b, uint256 denominator) external pure returns (uint256);
    function mulDivRoundingUp(uint256 a, uint256 b, uint256 denominator) external pure returns (uint256);
    function calculateBidValueFromPools(
        uint256[] calldata demands,
        address numeraire,
        address poolManagerAddr,
        bytes32[] calldata poolIds,
        address[] calldata currency0s,
        address[] calldata currency1s
    ) external view returns (uint256 totalValue);
}
