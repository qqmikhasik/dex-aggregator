// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {DexAggregatorV1} from "./DexAggregatorV1.sol";
import {IUniswapV2Router02} from "./interfaces/IUniswapV2Router02.sol";
import {ISwapRouter} from "./interfaces/ISwapRouter.sol";
import {DexAggregatorLib} from "./libraries/DexAggregatorLib.sol";

/// @title DexAggregatorV2 — Adds multi-hop routing through intermediate tokens
/// @notice Extends V1 with the ability to route swaps through intermediate tokens (e.g., A→WETH→B)
contract DexAggregatorV2 is DexAggregatorV1 {
    using SafeERC20 for IERC20;

    // ═══════════════ V2 NAMESPACED STORAGE (ERC-7201) ═══════════

    /// @custom:storage-location erc7201:dex-aggregator.storage.v2
    struct AggregatorV2Storage {
        address[] intermediateTokens; // e.g., [WETH, USDC, DAI]
    }

    // keccak256(abi.encode(uint256(keccak256("dex-aggregator.storage.v2")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant STORAGE_LOCATION_V2 = 0xa5bf72dab67a7a6fc6bb5ea14dfbd2fdb29a5b1c5a1a2b2eab5c9e0d7f8c9a00;

    function _getV2Storage() private pure returns (AggregatorV2Storage storage $) {
        assembly {
            $.slot := STORAGE_LOCATION_V2
        }
    }

    // ═══════════════ TYPES ══════════════════════════════════════

    struct MultiHopQuote {
        DexType dex;
        uint256 amountOut;
        uint24 v3Fee1;
        uint24 v3Fee2;
        address intermediateToken;
        bool isMultiHop;
    }

    // ═══════════════ EVENTS ════════════════════════════════════

    event IntermediateTokensUpdated(address[] tokens);

    // ═══════════════ INITIALIZATION ════════════════════════════

    function initializeV2(address[] calldata _intermediateTokens) external reinitializer(2) {
        AggregatorV2Storage storage s = _getV2Storage();
        s.intermediateTokens = _intermediateTokens;
        emit IntermediateTokensUpdated(_intermediateTokens);
    }

    // ═══════════════ MULTI-HOP QUOTING ════════════════════════

    /// @notice Get the best quote including multi-hop routes through intermediate tokens
    function getMultiHopQuote(address tokenIn, address tokenOut, uint256 amountIn)
        external
        returns (MultiHopQuote memory best)
    {
        if (amountIn == 0) revert ZeroAmount();

        // First check single-hop (from V1)
        uint256 v2Direct = getV2Quote(tokenIn, tokenOut, amountIn);
        (uint256 v3Direct, uint24 v3Fee) = getBestV3Quote(tokenIn, tokenOut, amountIn);

        if (v2Direct >= v3Direct && v2Direct > 0) {
            best = MultiHopQuote(DexType.V2, v2Direct, 0, 0, address(0), false);
        } else if (v3Direct > 0) {
            best = MultiHopQuote(DexType.V3, v3Direct, v3Fee, 0, address(0), false);
        }

        // Then check multi-hop through each intermediate token (V2 only for simplicity)
        AggregatorV2Storage storage s = _getV2Storage();
        for (uint256 i = 0; i < s.intermediateTokens.length; i++) {
            address mid = s.intermediateTokens[i];
            if (mid == tokenIn || mid == tokenOut) continue;

            // V2 multi-hop: tokenIn → mid → tokenOut
            uint256 midOut = getV2Quote(tokenIn, mid, amountIn);
            if (midOut == 0) continue;

            uint256 finalOut = getV2Quote(mid, tokenOut, midOut);
            if (finalOut > best.amountOut) {
                best = MultiHopQuote(DexType.V2, finalOut, 0, 0, mid, true);
            }

            // V3 multi-hop: try best fee for each leg
            (uint256 v3MidOut, uint24 fee1) = getBestV3Quote(tokenIn, mid, amountIn);
            if (v3MidOut == 0) continue;

            (uint256 v3FinalOut, uint24 fee2) = getBestV3Quote(mid, tokenOut, v3MidOut);
            if (v3FinalOut > best.amountOut) {
                best = MultiHopQuote(DexType.V3, v3FinalOut, fee1, fee2, mid, true);
            }
        }
    }

    /// @notice Execute a swap through the best multi-hop route
    function swapMultiHop(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMin,
        address recipient,
        uint256 deadline
    ) external nonReentrant whenNotPaused returns (uint256 amountOut) {
        _checkDeadline(deadline);
        if (amountIn == 0) revert ZeroAmount();
        if (recipient == address(0)) revert ZeroAddress();

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);

        // Find best route (including multi-hop)
        // For execution simplicity, we re-quote and route
        uint256 v2Direct = getV2Quote(tokenIn, tokenOut, amountIn);
        (uint256 v3Direct, uint24 v3Fee) = getBestV3Quote(tokenIn, tokenOut, amountIn);

        uint256 bestOut = v2Direct > v3Direct ? v2Direct : v3Direct;
        bool useV2 = v2Direct >= v3Direct;
        bool isMultiHop = false;
        address bestMid;
        uint24 bestFee1;
        uint24 bestFee2;

        // Check multi-hop routes
        AggregatorV2Storage storage s = _getV2Storage();
        for (uint256 i = 0; i < s.intermediateTokens.length; i++) {
            address mid = s.intermediateTokens[i];
            if (mid == tokenIn || mid == tokenOut) continue;

            uint256 midOut = getV2Quote(tokenIn, mid, amountIn);
            if (midOut > 0) {
                uint256 finalOut = getV2Quote(mid, tokenOut, midOut);
                if (finalOut > bestOut) {
                    bestOut = finalOut;
                    useV2 = true;
                    isMultiHop = true;
                    bestMid = mid;
                }
            }

            (uint256 v3MidOut, uint24 fee1) = getBestV3Quote(tokenIn, mid, amountIn);
            if (v3MidOut > 0) {
                (uint256 v3FinalOut, uint24 fee2) = getBestV3Quote(mid, tokenOut, v3MidOut);
                if (v3FinalOut > bestOut) {
                    bestOut = v3FinalOut;
                    useV2 = false;
                    isMultiHop = true;
                    bestMid = mid;
                    bestFee1 = fee1;
                    bestFee2 = fee2;
                }
            }
        }

        if (bestOut == 0) revert NoRouteFound();

        // Execute the best route
        if (!isMultiHop) {
            if (useV2) {
                amountOut = _executeV2Swap(tokenIn, tokenOut, amountIn, amountOutMin, recipient, deadline);
            } else {
                amountOut = _executeV3Swap(tokenIn, tokenOut, amountIn, amountOutMin, v3Fee, recipient, deadline);
            }
        } else if (useV2) {
            amountOut = _executeV2MultiHopSwap(tokenIn, bestMid, tokenOut, amountIn, amountOutMin, recipient, deadline);
        } else {
            amountOut = _executeV3MultiHopSwap(
                tokenIn, bestMid, tokenOut, amountIn, amountOutMin, bestFee1, bestFee2, recipient, deadline
            );
        }

        if (amountOut < amountOutMin) revert InsufficientOutputAmount(amountOut, amountOutMin);

        emit SwapExecuted(tokenIn, tokenOut, useV2 ? DexType.V2 : DexType.V3, amountIn, amountOut, recipient);
    }

    // ═══════════════ INTERNAL MULTI-HOP ════════════════════════

    function _executeV2MultiHopSwap(
        address tokenIn,
        address mid,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMin,
        address recipient,
        uint256 deadline
    ) internal returns (uint256) {
        AggregatorV1Storage storage sv1 = _getV1Storage();

        IERC20(tokenIn).forceApprove(sv1.v2Router, amountIn);

        address[] memory path = new address[](3);
        path[0] = tokenIn;
        path[1] = mid;
        path[2] = tokenOut;

        uint256[] memory amounts = IUniswapV2Router02(sv1.v2Router)
            .swapExactTokensForTokens(amountIn, amountOutMin, path, recipient, deadline);

        return amounts[amounts.length - 1];
    }

    function _executeV3MultiHopSwap(
        address tokenIn,
        address mid,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMin,
        uint24 fee1,
        uint24 fee2,
        address recipient,
        uint256 deadline
    ) internal returns (uint256) {
        AggregatorV1Storage storage sv1 = _getV1Storage();

        IERC20(tokenIn).forceApprove(sv1.v3Router, amountIn);

        address[] memory tokens = new address[](3);
        tokens[0] = tokenIn;
        tokens[1] = mid;
        tokens[2] = tokenOut;

        uint24[] memory fees = new uint24[](2);
        fees[0] = fee1;
        fees[1] = fee2;

        bytes memory path = DexAggregatorLib.encodePath(tokens, fees);

        return ISwapRouter(sv1.v3Router)
            .exactInput(
                ISwapRouter.ExactInputParams({
                    path: path, recipient: recipient, amountIn: amountIn, amountOutMinimum: amountOutMin
                })
            );
    }

    // ═══════════════ ADMIN ═════════════════════════════════════

    function setIntermediateTokens(address[] calldata _tokens) external onlyRole(OPERATOR_ROLE) {
        AggregatorV2Storage storage s = _getV2Storage();
        s.intermediateTokens = _tokens;
        emit IntermediateTokensUpdated(_tokens);
    }

    function getIntermediateTokens() external view returns (address[] memory) {
        return _getV2Storage().intermediateTokens;
    }

    // ═══════════════ VERSION ═══════════════════════════════════

    function version() external pure override returns (string memory) {
        return "2.0.0";
    }
}
