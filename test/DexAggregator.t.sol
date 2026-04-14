// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DexAggregatorV1} from "../src/DexAggregatorV1.sol";
import {DexAggregatorV2} from "../src/DexAggregatorV2.sol";
import {TestToken} from "../src/TestToken.sol";
import {DexAggregatorLib} from "../src/libraries/DexAggregatorLib.sol";

// ═══════════════ MOCK CONTRACTS ═══════════════════════════════

contract MockV2Factory {
    mapping(bytes32 => address) private _pairs;

    function setPair(address tokenA, address tokenB, address pair) external {
        bytes32 key = keccak256(abi.encodePacked(tokenA < tokenB ? tokenA : tokenB, tokenA < tokenB ? tokenB : tokenA));
        _pairs[key] = pair;
    }

    function getPair(address tokenA, address tokenB) external view returns (address) {
        bytes32 key = keccak256(abi.encodePacked(tokenA < tokenB ? tokenA : tokenB, tokenA < tokenB ? tokenB : tokenA));
        return _pairs[key];
    }
}

contract MockV2Pair {
    address public token0;
    address public token1;
    uint112 private _reserve0;
    uint112 private _reserve1;

    constructor(address _token0, address _token1, uint112 r0, uint112 r1) {
        token0 = _token0 < _token1 ? _token0 : _token1;
        token1 = _token0 < _token1 ? _token1 : _token0;
        _reserve0 = _token0 < _token1 ? r0 : r1;
        _reserve1 = _token0 < _token1 ? r1 : r0;
    }

    function getReserves() external view returns (uint112, uint112, uint32) {
        return (_reserve0, _reserve1, uint32(block.timestamp));
    }
}

contract MockV2Router {
    function getAmountsOut(uint256 amountIn, address[] calldata path) external pure returns (uint256[] memory amounts) {
        amounts = new uint256[](path.length);
        amounts[0] = amountIn;
        amounts[1] = (amountIn * 997) / 1000; // simplified
    }

    function swapExactTokensForTokens(uint256 amountIn, uint256, address[] calldata path, address to, uint256)
        external
        returns (uint256[] memory amounts)
    {
        amounts = new uint256[](path.length);
        amounts[0] = amountIn;
        uint256 out = (amountIn * 997) / 1000;
        amounts[1] = out;

        IERC20(path[0]).transferFrom(msg.sender, address(this), amountIn);
        // Mint output to recipient (mock behavior)
        TestToken(path[path.length - 1]).mint(to, out);
    }
}

contract MockV3Factory {
    mapping(bytes32 => address) private _pools;

    function setPool(address tokenA, address tokenB, uint24 fee, address pool) external {
        _pools[keccak256(abi.encodePacked(tokenA, tokenB, fee))] = pool;
    }

    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address) {
        address pool = _pools[keccak256(abi.encodePacked(tokenA, tokenB, fee))];
        if (pool != address(0)) return pool;
        return _pools[keccak256(abi.encodePacked(tokenB, tokenA, fee))];
    }
}

contract MockV3Quoter {
    uint256 private _mockAmountOut;

    function setMockAmountOut(uint256 amount) external {
        _mockAmountOut = amount;
    }

    function quoteExactInputSingle(IQuoterV2Params memory)
        external
        view
        returns (uint256 amountOut, uint160, uint32, uint256)
    {
        return (_mockAmountOut, 0, 0, 0);
    }
}

struct IQuoterV2Params {
    address tokenIn;
    address tokenOut;
    uint256 amountIn;
    uint24 fee;
    uint160 sqrtPriceLimitX96;
}

contract MockV3Router {
    function exactInputSingle(MockExactInputSingleParams calldata params) external returns (uint256) {
        IERC20(params.tokenIn).transferFrom(msg.sender, address(this), params.amountIn);
        uint256 out = (params.amountIn * 9985) / 10000; // 0.15% simulated fee
        TestToken(params.tokenOut).mint(params.recipient, out);
        return out;
    }
}

struct MockExactInputSingleParams {
    address tokenIn;
    address tokenOut;
    uint24 fee;
    address recipient;
    uint256 amountIn;
    uint256 amountOutMinimum;
    uint160 sqrtPriceLimitX96;
}

// ═══════════════ MAIN TEST CONTRACT ═══════════════════════════

contract DexAggregatorTest is Test {
    DexAggregatorV1 public aggregator;
    ERC1967Proxy public proxy;
    DexAggregatorV1 public impl;

    MockV2Factory public v2Factory;
    MockV2Router public v2Router;
    MockV3Factory public v3Factory;
    MockV3Router public v3Router;
    MockV3Quoter public v3Quoter;

    TestToken public tokenA;
    TestToken public tokenB;
    TestToken public weth;

    address public admin = address(this);
    address public operator = address(0xCAFE);
    address public user = address(0xBEEF);

    function setUp() public {
        // Deploy mock infrastructure
        v2Factory = new MockV2Factory();
        v2Router = new MockV2Router();
        v3Factory = new MockV3Factory();
        v3Router = new MockV3Router();
        v3Quoter = new MockV3Quoter();

        // Deploy test tokens
        tokenA = new TestToken("Token A", "TKA", admin);
        tokenB = new TestToken("Token B", "TKB", admin);
        weth = new TestToken("Wrapped ETH", "WETH", admin);

        // Deploy aggregator with UUPS proxy
        impl = new DexAggregatorV1();
        bytes memory initData = abi.encodeCall(
            DexAggregatorV1.initialize,
            (
                address(v2Router),
                address(v2Factory),
                address(v3Router),
                address(v3Factory),
                address(v3Quoter),
                address(weth),
                admin
            )
        );
        proxy = new ERC1967Proxy(address(impl), initData);
        aggregator = DexAggregatorV1(address(proxy));

        // Grant operator role
        aggregator.grantRole(aggregator.OPERATOR_ROLE(), operator);

        // Set up V2 pair with reserves
        MockV2Pair pair = new MockV2Pair(
            address(tokenA),
            address(tokenB),
            100_000 ether, // reserveA
            200_000 ether // reserveB
        );
        v2Factory.setPair(address(tokenA), address(tokenB), address(pair));

        // Set up V3 pool
        v3Factory.setPool(address(tokenA), address(tokenB), 3000, address(1));

        // Mint tokens for user
        tokenA.mint(user, 10_000 ether);
        tokenB.mint(user, 10_000 ether);
    }

    function agg() internal view returns (DexAggregatorV1) {
        return aggregator;
    }

    // ═══════════════ TEST 1: Deploy and Initialize ═══════════════

    function test_DeployAndInitialize() public view {
        assertEq(agg().version(), "1.0.0");
        assertEq(agg().getV2Router(), address(v2Router));
        assertEq(agg().getV2Factory(), address(v2Factory));
        assertEq(agg().getV3Router(), address(v3Router));
        assertEq(agg().getV3Factory(), address(v3Factory));
        assertEq(agg().getV3Quoter(), address(v3Quoter));
        assertEq(agg().getWeth(), address(weth));
        assertTrue(agg().hasRole(agg().DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(agg().hasRole(agg().OPERATOR_ROLE(), admin));
        assertTrue(agg().hasRole(agg().OPERATOR_ROLE(), operator));
    }

    // ═══════════════ TEST 2: Initialize reverts with zero address ═══

    function test_InitializeRevertsZeroAddress() public {
        DexAggregatorV1 newImpl = new DexAggregatorV1();
        bytes memory initData = abi.encodeCall(
            DexAggregatorV1.initialize,
            (
                address(0),
                address(v2Factory),
                address(v3Router),
                address(v3Factory),
                address(v3Quoter),
                address(weth),
                admin
            )
        );
        vm.expectRevert(DexAggregatorV1.ZeroAddress.selector);
        new ERC1967Proxy(address(newImpl), initData);
    }

    // ═══════════════ TEST 3: V2 Quote ════════════════════════════

    function test_GetV2Quote() public view {
        uint256 quote = agg().getV2Quote(address(tokenA), address(tokenB), 1 ether);
        // With reserves 100k/200k, input 1 ether:
        // amountOut = (200000 * 1 * 997) / (100000 * 1000 + 1 * 997)
        // = 199400 / 100000.997 ≈ 1.993980...
        assertTrue(quote > 0, "V2 quote should be positive");
        assertTrue(quote < 2 ether, "V2 quote should be less than 2 ether");
    }

    // ═══════════════ TEST 4: V2 Quote returns 0 for missing pair ══

    function test_GetV2QuoteNoPair() public view {
        uint256 quote = agg().getV2Quote(address(tokenA), address(weth), 1 ether);
        assertEq(quote, 0, "Quote should be 0 for missing pair");
    }

    // ═══════════════ TEST 5: Access Control — Only admin can upgrade ═

    function test_OnlyAdminCanUpgrade() public {
        DexAggregatorV2 implV2 = new DexAggregatorV2();

        vm.prank(user);
        vm.expectRevert();
        agg().upgradeToAndCall(address(implV2), "");
    }

    // ═══════════════ TEST 6: Access Control — Only operator can pause ═

    function test_OnlyOperatorCanPause() public {
        vm.prank(user);
        vm.expectRevert();
        agg().pause();
    }

    function test_OperatorCanPause() public {
        vm.prank(operator);
        agg().pause();
        assertTrue(agg().paused());
    }

    // ═══════════════ TEST 7: Pause blocks swaps ═══════════════════

    function test_PauseBlocksSwap() public {
        agg().pause();

        vm.prank(user);
        vm.expectRevert();
        agg().swap(address(tokenA), address(tokenB), 1 ether, 0, user, block.timestamp + 100);
    }

    // ═══════════════ TEST 8: Unpause allows swaps ═════════════════

    function test_UnpauseAllowsSwap() public {
        agg().pause();
        assertTrue(agg().paused());

        agg().unpause();
        assertFalse(agg().paused());
    }

    // ═══════════════ TEST 9: Deadline protection ══════════════════

    function test_DeadlineExpired() public {
        vm.warp(1000);

        vm.prank(user);
        vm.expectRevert(DexAggregatorV1.DeadlineExpired.selector);
        agg().swap(address(tokenA), address(tokenB), 1 ether, 0, user, 500);
    }

    // ═══════════════ TEST 10: Zero amount reverts ═════════════════

    function test_ZeroAmountReverts() public {
        vm.prank(user);
        vm.expectRevert(DexAggregatorV1.ZeroAmount.selector);
        agg().swap(address(tokenA), address(tokenB), 0, 0, user, block.timestamp + 100);
    }

    // ═══════════════ TEST 11: Zero recipient reverts ══════════════

    function test_ZeroRecipientReverts() public {
        vm.prank(user);
        vm.expectRevert(DexAggregatorV1.ZeroAddress.selector);
        agg().swap(address(tokenA), address(tokenB), 1 ether, 0, address(0), block.timestamp + 100);
    }

    // ═══════════════ TEST 12: Protocol fee configuration ══════════

    function test_SetProtocolFee() public {
        agg().setProtocolFee(50, address(0xFEE));
        assertEq(agg().getProtocolFeeBps(), 50);
        assertEq(agg().getFeeRecipient(), address(0xFEE));
    }

    function test_ProtocolFeeTooHigh() public {
        vm.expectRevert(DexAggregatorV1.FeeTooHigh.selector);
        agg().setProtocolFee(1001, address(0xFEE));
    }

    function test_OnlyAdminCanSetFee() public {
        vm.prank(operator);
        vm.expectRevert();
        agg().setProtocolFee(50, address(0xFEE));
    }

    // ═══════════════ TEST 13: Upgrade to V2 ═══════════════════════

    function test_UpgradeToV2() public {
        DexAggregatorV2 implV2 = new DexAggregatorV2();

        address[] memory intermediateTokens = new address[](1);
        intermediateTokens[0] = address(weth);

        agg().upgradeToAndCall(address(implV2), abi.encodeCall(DexAggregatorV2.initializeV2, (intermediateTokens)));

        DexAggregatorV2 aggV2 = DexAggregatorV2(address(proxy));
        assertEq(aggV2.version(), "2.0.0");

        address[] memory tokens = aggV2.getIntermediateTokens();
        assertEq(tokens.length, 1);
        assertEq(tokens[0], address(weth));
    }

    // ═══════════════ TEST 14: Upgrade preserves storage ═══════════

    function test_UpgradePreservesStorage() public {
        agg().setProtocolFee(42, address(0xFEE));

        DexAggregatorV2 implV2 = new DexAggregatorV2();
        address[] memory intermediateTokens = new address[](0);
        agg().upgradeToAndCall(address(implV2), abi.encodeCall(DexAggregatorV2.initializeV2, (intermediateTokens)));

        DexAggregatorV2 aggV2 = DexAggregatorV2(address(proxy));
        assertEq(aggV2.getProtocolFeeBps(), 42);
        assertEq(aggV2.getFeeRecipient(), address(0xFEE));
        assertEq(aggV2.getV2Router(), address(v2Router));
        assertTrue(aggV2.hasRole(aggV2.DEFAULT_ADMIN_ROLE(), admin));
    }

    // ═══════════════ TEST 15: Cannot reinitialize ═════════════════

    function test_CannotReinitialize() public {
        vm.expectRevert();
        agg()
            .initialize(
                address(v2Router),
                address(v2Factory),
                address(v3Router),
                address(v3Factory),
                address(v3Quoter),
                address(weth),
                admin
            );
    }
}

// ═══════════════ LIBRARY TESTS ════════════════════════════════

contract DexAggregatorLibTest is Test {
    function test_CalcV2AmountOut_BasicCase() public pure {
        // reserves: 100k / 200k, input: 1 ether
        uint256 out = DexAggregatorLib.calcV2AmountOut(1 ether, 100_000 ether, 200_000 ether);
        // Expected: (200000 * 1 * 997) / (100000 * 1000 + 1 * 997) = 199400 / 100000997 ≈ 1.994e18
        assertGt(out, 1.99 ether);
        assertLt(out, 2 ether);
    }

    function test_CalcV2AmountOut_SmallInput() public pure {
        uint256 out = DexAggregatorLib.calcV2AmountOut(1, 100_000 ether, 200_000 ether);
        assertEq(out, 1); // very small input, approximately 2x output ratio
    }

    function test_CalcV2AmountOut_ZeroInput() public {
        LibRevertHelper helper = new LibRevertHelper();
        vm.expectRevert(DexAggregatorLib.ZeroAmountIn.selector);
        helper.calcV2(0, 100_000 ether, 200_000 ether);
    }

    function test_CalcV2AmountOut_ZeroReserve() public {
        LibRevertHelper helper = new LibRevertHelper();
        vm.expectRevert(DexAggregatorLib.InsufficientReserves.selector);
        helper.calcV2(1 ether, 0, 200_000 ether);
    }

    function test_EncodePath() public pure {
        address[] memory tokens = new address[](3);
        tokens[0] = address(0x1);
        tokens[1] = address(0x2);
        tokens[2] = address(0x3);

        uint24[] memory fees = new uint24[](2);
        fees[0] = 500;
        fees[1] = 3000;

        bytes memory path = DexAggregatorLib.encodePath(tokens, fees);
        assertGt(path.length, 0);
    }

    function test_IsWithinSlippage_Pass() public pure {
        assertTrue(DexAggregatorLib.isWithinSlippage(99, 100, 200)); // 1% diff, 2% tolerance
    }

    function test_IsWithinSlippage_Fail() public pure {
        assertFalse(DexAggregatorLib.isWithinSlippage(95, 100, 200)); // 5% diff, 2% tolerance
    }

    function test_IsWithinSlippage_Exact() public pure {
        assertTrue(DexAggregatorLib.isWithinSlippage(100, 100, 0)); // no slippage tolerance, exact match
    }
}

/// @dev Helper contract to test library reverts via external call
contract LibRevertHelper {
    function calcV2(uint256 amountIn, uint256 reserveIn, uint256 reserveOut) external pure returns (uint256) {
        return DexAggregatorLib.calcV2AmountOut(amountIn, reserveIn, reserveOut);
    }
}
