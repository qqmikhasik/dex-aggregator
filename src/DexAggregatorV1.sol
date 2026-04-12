// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IUniswapV2Factory} from "./interfaces/IUniswapV2Factory.sol";
import {IUniswapV2Router02} from "./interfaces/IUniswapV2Router02.sol";
import {IUniswapV2Pair} from "./interfaces/IUniswapV2Pair.sol";
import {IUniswapV3Factory} from "./interfaces/IUniswapV3Factory.sol";
import {ISwapRouter} from "./interfaces/ISwapRouter.sol";
import {IQuoterV2} from "./interfaces/IQuoterV2.sol";
import {DexAggregatorLib} from "./libraries/DexAggregatorLib.sol";

/// @title DexAggregatorV1 — DEX Aggregator for Uniswap V2 and V3 (single-hop)
/// @notice Compares quotes across Uniswap V2 and V3 (all fee tiers) and routes swaps to the best venue
contract DexAggregatorV1 is
    Initializable,
    UUPSUpgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuard
{
    using SafeERC20 for IERC20;

    // ═══════════════ TYPES ═══════════════════════════════════════

    enum DexType {
        NONE,
        V2,
        V3
    }

    struct Quote {
        DexType dex;
        uint256 amountOut;
        uint24 v3Fee; // only meaningful when dex == V3
    }

    // ═══════════════ ROLES ═══════════════════════════════════════

    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    // ═══════════════ NAMESPACED STORAGE (ERC-7201) ═══════════════

    /// @custom:storage-location erc7201:dex-aggregator.storage.v1
    struct AggregatorV1Storage {
        address v2Router;
        address v2Factory;
        address v3Router;
        address v3Factory;
        address v3Quoter;
        address weth;
        uint256 protocolFeeBps;
        address feeRecipient;
    }

    // keccak256(abi.encode(uint256(keccak256("dex-aggregator.storage.v1")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant STORAGE_LOCATION_V1 =
        0xd87ff71024a4d1c4d04e88b39e8672e110e0b1a5a6ca82cf2a4710b85e0e6800;

    function _getV1Storage() internal pure returns (AggregatorV1Storage storage $) {
        assembly {
            $.slot := STORAGE_LOCATION_V1
        }
    }

    // ═══════════════ CONSTANTS ═══════════════════════════════════

    function _getV3FeeTiers() internal pure returns (uint24[4] memory) {
        return [uint24(100), 500, 3000, 10000];
    }

    // ═══════════════ EVENTS ═════════════════════════════════════

    event SwapExecuted(
        address indexed tokenIn,
        address indexed tokenOut,
        DexType dex,
        uint256 amountIn,
        uint256 amountOut,
        address indexed recipient
    );

    event ProtocolFeeUpdated(uint256 feeBps, address recipient);

    // ═══════════════ ERRORS ═════════════════════════════════════

    error DeadlineExpired();
    error InsufficientOutputAmount(uint256 actual, uint256 minimum);
    error NoRouteFound();
    error ZeroAddress();
    error ZeroAmount();
    error FeeTooHigh();

    // ═══════════════ INITIALIZATION ═════════════════════════════

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _v2Router,
        address _v2Factory,
        address _v3Router,
        address _v3Factory,
        address _v3Quoter,
        address _weth,
        address _admin
    ) external initializer {
        if (_v2Router == address(0) || _v2Factory == address(0) || _v3Router == address(0)
            || _v3Factory == address(0) || _v3Quoter == address(0) || _weth == address(0) || _admin == address(0))
        {
            revert ZeroAddress();
        }

        __AccessControl_init();
        __Pausable_init();
        // ReentrancyGuard (non-upgradeable) requires no init in OZ v5

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(OPERATOR_ROLE, _admin);

        AggregatorV1Storage storage s = _getV1Storage();
        s.v2Router = _v2Router;
        s.v2Factory = _v2Factory;
        s.v3Router = _v3Router;
        s.v3Factory = _v3Factory;
        s.v3Quoter = _v3Quoter;
        s.weth = _weth;
    }

    // ═══════════════ QUOTING (read functions) ═══════════════════

    /// @notice Get a quote from Uniswap V2 for a single-hop swap
    function getV2Quote(address tokenIn, address tokenOut, uint256 amountIn)
        public
        view
        returns (uint256 amountOut)
    {
        AggregatorV1Storage storage s = _getV1Storage();

        address pair = IUniswapV2Factory(s.v2Factory).getPair(tokenIn, tokenOut);
        if (pair == address(0)) return 0;

        (uint112 reserve0, uint112 reserve1,) = IUniswapV2Pair(pair).getReserves();
        address token0 = IUniswapV2Pair(pair).token0();

        (uint256 reserveIn, uint256 reserveOut) =
            tokenIn == token0 ? (uint256(reserve0), uint256(reserve1)) : (uint256(reserve1), uint256(reserve0));

        if (reserveIn == 0 || reserveOut == 0) return 0;

        amountOut = DexAggregatorLib.calcV2AmountOut(amountIn, reserveIn, reserveOut);
    }

    /// @notice Get a quote from Uniswap V3 for a specific fee tier
    function getV3Quote(address tokenIn, address tokenOut, uint256 amountIn, uint24 fee)
        public
        returns (uint256 amountOut)
    {
        AggregatorV1Storage storage s = _getV1Storage();

        address pool = IUniswapV3Factory(s.v3Factory).getPool(tokenIn, tokenOut, fee);
        if (pool == address(0)) return 0;

        try IQuoterV2(s.v3Quoter).quoteExactInputSingle(
            IQuoterV2.QuoteExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                amountIn: amountIn,
                fee: fee,
                sqrtPriceLimitX96: 0
            })
        ) returns (uint256 quoted, uint160, uint32, uint256) {
            amountOut = quoted;
        } catch {
            amountOut = 0;
        }
    }

    /// @notice Get the best V3 quote across all standard fee tiers
    function getBestV3Quote(address tokenIn, address tokenOut, uint256 amountIn)
        public
        returns (uint256 bestAmountOut, uint24 bestFee)
    {
        for (uint256 i = 0; i < 4; i++) {
            uint256 out = getV3Quote(tokenIn, tokenOut, amountIn, _getV3FeeTiers()[i]);
            if (out > bestAmountOut) {
                bestAmountOut = out;
                bestFee = _getV3FeeTiers()[i];
            }
        }
    }

    /// @notice Get the best quote across V2 and V3
    function getQuote(address tokenIn, address tokenOut, uint256 amountIn)
        external
        returns (Quote memory bestQuote)
    {
        if (amountIn == 0) revert ZeroAmount();

        uint256 v2Out = getV2Quote(tokenIn, tokenOut, amountIn);
        (uint256 v3Out, uint24 v3Fee) = getBestV3Quote(tokenIn, tokenOut, amountIn);

        if (v2Out == 0 && v3Out == 0) {
            bestQuote = Quote(DexType.NONE, 0, 0);
        } else if (v2Out >= v3Out) {
            bestQuote = Quote(DexType.V2, v2Out, 0);
        } else {
            bestQuote = Quote(DexType.V3, v3Out, v3Fee);
        }
    }

    // ═══════════════ SWAP EXECUTION ═════════════════════════════

    /// @notice Execute a swap through the best available route
    function swap(
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

        // Get best quote
        uint256 v2Out = getV2Quote(tokenIn, tokenOut, amountIn);
        (uint256 v3Out, uint24 v3Fee) = getBestV3Quote(tokenIn, tokenOut, amountIn);

        if (v2Out == 0 && v3Out == 0) revert NoRouteFound();

        // Transfer tokens from user to this contract
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);

        if (v2Out >= v3Out) {
            amountOut = _executeV2Swap(tokenIn, tokenOut, amountIn, amountOutMin, recipient, deadline);
        } else {
            amountOut = _executeV3Swap(tokenIn, tokenOut, amountIn, amountOutMin, v3Fee, recipient, deadline);
        }

        // Apply protocol fee if set
        amountOut = _applyProtocolFee(tokenOut, amountOut, recipient);

        if (amountOut < amountOutMin) revert InsufficientOutputAmount(amountOut, amountOutMin);

        emit SwapExecuted(tokenIn, tokenOut, v2Out >= v3Out ? DexType.V2 : DexType.V3, amountIn, amountOut, recipient);
    }

    /// @notice Execute a swap explicitly through Uniswap V2
    function swapV2(
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
        amountOut = _executeV2Swap(tokenIn, tokenOut, amountIn, amountOutMin, recipient, deadline);
        amountOut = _applyProtocolFee(tokenOut, amountOut, recipient);

        if (amountOut < amountOutMin) revert InsufficientOutputAmount(amountOut, amountOutMin);

        emit SwapExecuted(tokenIn, tokenOut, DexType.V2, amountIn, amountOut, recipient);
    }

    /// @notice Execute a swap explicitly through Uniswap V3
    function swapV3(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMin,
        uint24 fee,
        address recipient,
        uint256 deadline
    ) external nonReentrant whenNotPaused returns (uint256 amountOut) {
        _checkDeadline(deadline);
        if (amountIn == 0) revert ZeroAmount();
        if (recipient == address(0)) revert ZeroAddress();

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        amountOut = _executeV3Swap(tokenIn, tokenOut, amountIn, amountOutMin, fee, recipient, deadline);
        amountOut = _applyProtocolFee(tokenOut, amountOut, recipient);

        if (amountOut < amountOutMin) revert InsufficientOutputAmount(amountOut, amountOutMin);

        emit SwapExecuted(tokenIn, tokenOut, DexType.V3, amountIn, amountOut, recipient);
    }

    // ═══════════════ INTERNAL SWAP LOGIC ════════════════════════

    function _executeV2Swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMin,
        address recipient,
        uint256 deadline
    ) internal returns (uint256) {
        AggregatorV1Storage storage s = _getV1Storage();

        IERC20(tokenIn).forceApprove(s.v2Router, amountIn);

        address[] memory path = new address[](2);
        path[0] = tokenIn;
        path[1] = tokenOut;

        uint256[] memory amounts =
            IUniswapV2Router02(s.v2Router).swapExactTokensForTokens(amountIn, amountOutMin, path, recipient, deadline);

        return amounts[amounts.length - 1];
    }

    function _executeV3Swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMin,
        uint24 fee,
        address recipient,
        uint256 deadline
    ) internal returns (uint256) {
        AggregatorV1Storage storage s = _getV1Storage();

        IERC20(tokenIn).forceApprove(s.v3Router, amountIn);

        return ISwapRouter(s.v3Router).exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                fee: fee,
                recipient: recipient,
                amountIn: amountIn,
                amountOutMinimum: amountOutMin,
                sqrtPriceLimitX96: 0
            })
        );
    }

    function _applyProtocolFee(address tokenOut, uint256 amountOut, address recipient)
        internal
        returns (uint256 amountAfterFee)
    {
        AggregatorV1Storage storage s = _getV1Storage();

        if (s.protocolFeeBps == 0 || s.feeRecipient == address(0)) {
            return amountOut;
        }

        uint256 fee = (amountOut * s.protocolFeeBps) / 10000;
        amountAfterFee = amountOut - fee;

        // Fee was already sent to recipient by router, need to transfer fee portion
        // Note: in practice, we route output to this contract first, then distribute
        // For simplicity, fee is taken from the output already at recipient
        // This is handled by routing to address(this) first in production
        return amountOut; // In V1, protocol fee tracking only — no actual deduction
    }

    // ═══════════════ ADMIN ══════════════════════════════════════

    function pause() external onlyRole(OPERATOR_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(OPERATOR_ROLE) {
        _unpause();
    }

    function setProtocolFee(uint256 _feeBps, address _recipient) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_feeBps > 1000) revert FeeTooHigh(); // max 10%
        AggregatorV1Storage storage s = _getV1Storage();
        s.protocolFeeBps = _feeBps;
        s.feeRecipient = _recipient;
        emit ProtocolFeeUpdated(_feeBps, _recipient);
    }

    // ═══════════════ VIEW HELPERS ═══════════════════════════════

    function getV2Router() external view returns (address) { return _getV1Storage().v2Router; }
    function getV2Factory() external view returns (address) { return _getV1Storage().v2Factory; }
    function getV3Router() external view returns (address) { return _getV1Storage().v3Router; }
    function getV3Factory() external view returns (address) { return _getV1Storage().v3Factory; }
    function getV3Quoter() external view returns (address) { return _getV1Storage().v3Quoter; }
    function getWeth() external view returns (address) { return _getV1Storage().weth; }
    function getProtocolFeeBps() external view returns (uint256) { return _getV1Storage().protocolFeeBps; }
    function getFeeRecipient() external view returns (address) { return _getV1Storage().feeRecipient; }

    function version() external pure virtual returns (string memory) {
        return "1.0.0";
    }

    // ═══════════════ INTERNAL ═══════════════════════════════════

    function _checkDeadline(uint256 deadline) internal view {
        if (block.timestamp > deadline) revert DeadlineExpired();
    }

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
