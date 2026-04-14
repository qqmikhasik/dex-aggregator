// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title DexAggregatorLib — Pure helper functions for AMM calculations
library DexAggregatorLib {
    error InsufficientReserves();
    error ZeroAmountIn();

    /// @notice Calculate Uniswap V2 output amount using constant product formula
    /// @dev amountOut = (reserveOut * amountIn * 997) / (reserveIn * 1000 + amountIn * 997)
    /// This matches the exact Uniswap V2 formula with 0.3% fee
    function calcV2AmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut)
        internal
        pure
        returns (uint256 amountOut)
    {
        if (amountIn == 0) revert ZeroAmountIn();
        if (reserveIn == 0 || reserveOut == 0) revert InsufficientReserves();

        uint256 amountInWithFee = amountIn * 997;
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = (reserveIn * 1000) + amountInWithFee;
        amountOut = numerator / denominator;
    }

    /// @notice Encode a V3 multi-hop path (token0 + fee + token1 + fee + token2 ...)
    function encodePath(address[] memory tokens, uint24[] memory fees) internal pure returns (bytes memory path) {
        require(tokens.length == fees.length + 1, "Invalid path lengths");

        path = abi.encodePacked(tokens[0]);
        for (uint256 i = 0; i < fees.length; i++) {
            path = abi.encodePacked(path, fees[i], tokens[i + 1]);
        }
    }

    /// @notice Check if actual amount is within acceptable slippage of expected
    function isWithinSlippage(uint256 actual, uint256 expected, uint256 maxSlippageBps) internal pure returns (bool) {
        if (expected == 0) return actual == 0;
        uint256 minAcceptable = (expected * (10000 - maxSlippageBps)) / 10000;
        return actual >= minAcceptable;
    }
}
