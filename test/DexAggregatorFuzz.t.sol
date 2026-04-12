// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {DexAggregatorLib} from "../src/libraries/DexAggregatorLib.sol";

contract DexAggregatorFuzzTest is Test {
    /// @notice Fuzz: output should NEVER exceed reserveOut
    function testFuzz_CalcV2AmountOut_NeverExceedsReserve(
        uint256 amountIn,
        uint112 reserveIn,
        uint112 reserveOut
    ) public pure {
        // Bound to reasonable values
        vm.assume(amountIn > 0 && amountIn < type(uint112).max);
        vm.assume(reserveIn > 0 && reserveOut > 0);

        uint256 out = DexAggregatorLib.calcV2AmountOut(amountIn, uint256(reserveIn), uint256(reserveOut));
        assertLt(out, uint256(reserveOut), "Output must never exceed reserve");
    }

    /// @notice Fuzz: output should be monotonically increasing with input
    function testFuzz_CalcV2AmountOut_Monotonic(
        uint256 amountIn1,
        uint256 amountIn2,
        uint112 reserveIn,
        uint112 reserveOut
    ) public pure {
        vm.assume(reserveIn > 0 && reserveOut > 0);
        vm.assume(amountIn1 > 0 && amountIn2 > amountIn1);
        vm.assume(amountIn2 < type(uint112).max);

        uint256 out1 = DexAggregatorLib.calcV2AmountOut(amountIn1, uint256(reserveIn), uint256(reserveOut));
        uint256 out2 = DexAggregatorLib.calcV2AmountOut(amountIn2, uint256(reserveIn), uint256(reserveOut));

        assertGe(out2, out1, "Larger input must produce >= output");
    }

    /// @notice Fuzz: slippage check should be consistent
    function testFuzz_IsWithinSlippage_Consistent(
        uint256 actual,
        uint256 expected,
        uint256 maxSlippageBps
    ) public pure {
        vm.assume(expected > 0 && expected < type(uint128).max);
        vm.assume(actual < type(uint128).max);
        vm.assume(maxSlippageBps <= 10000);

        bool result = DexAggregatorLib.isWithinSlippage(actual, expected, maxSlippageBps);

        uint256 minAcceptable = (expected * (10000 - maxSlippageBps)) / 10000;
        if (actual >= minAcceptable) {
            assertTrue(result, "Should be within slippage");
        } else {
            assertFalse(result, "Should be outside slippage");
        }
    }

    /// @notice Fuzz: zero amountIn should always revert
    function testFuzz_CalcV2AmountOut_ZeroInputReverts(uint112 reserveIn, uint112 reserveOut) public {
        vm.assume(reserveIn > 0 && reserveOut > 0);

        FuzzLibHelper helper = new FuzzLibHelper();
        vm.expectRevert(DexAggregatorLib.ZeroAmountIn.selector);
        helper.calcV2(0, uint256(reserveIn), uint256(reserveOut));
    }
}

contract FuzzLibHelper {
    function calcV2(uint256 amountIn, uint256 reserveIn, uint256 reserveOut) external pure returns (uint256) {
        return DexAggregatorLib.calcV2AmountOut(amountIn, reserveIn, reserveOut);
    }
}
