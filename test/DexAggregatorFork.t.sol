// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {DexAggregatorV1} from "../src/DexAggregatorV1.sol";
import {IUniswapV2Factory} from "../src/interfaces/IUniswapV2Factory.sol";
import {IUniswapV3Factory} from "../src/interfaces/IUniswapV3Factory.sol";

/// @title Fork tests against real Uniswap V2/V3 deployments on Sepolia
/// @notice Run with: forge test --fork-url $SEPOLIA_RPC_URL --match-contract DexAggregatorFork
contract DexAggregatorForkTest is Test {
    // Sepolia Uniswap addresses
    address constant V2_ROUTER = 0xeE567Fe1712Faf6149d80dA1E6934E354124CfE3;
    address constant V2_FACTORY = 0xF62c03E08ada871A0bEb309762E260a7a6a880E6;
    address constant V3_ROUTER = 0x3bFA4769FB09eefC5a80d6E87c3B9C650f7Ae48E;
    address constant V3_FACTORY = 0x0227628f3F023bb0B980b67D528571c95c6DaC1c;
    address constant V3_QUOTER = 0xEd1f6473345F45b75F8179591dd5bA1888cf2FB3;
    address constant WETH = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;

    // Well-known Sepolia test tokens (may or may not have liquidity)
    address constant USDC_SEPOLIA = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238; // Circle USDC
    address constant UNI_SEPOLIA = 0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984; // UNI (has pool)

    DexAggregatorV1 public agg;
    address public admin = address(0xA11CE);

    function setUp() public {
        // Fork Sepolia — requires SEPOLIA_RPC_URL env var
        vm.createSelectFork(vm.envString("SEPOLIA_RPC_URL"));

        // Deploy implementation + proxy on the forked state
        DexAggregatorV1 impl = new DexAggregatorV1();

        bytes memory initData = abi.encodeCall(
            DexAggregatorV1.initialize, (V2_ROUTER, V2_FACTORY, V3_ROUTER, V3_FACTORY, V3_QUOTER, WETH, admin)
        );

        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        agg = DexAggregatorV1(address(proxy));
    }

    // ═══════════════ CONFIGURATION CHECKS ════════════════════════

    function test_Fork_ConfigSetCorrectly() public view {
        assertEq(agg.getV2Router(), V2_ROUTER);
        assertEq(agg.getV2Factory(), V2_FACTORY);
        assertEq(agg.getV3Router(), V3_ROUTER);
        assertEq(agg.getV3Factory(), V3_FACTORY);
        assertEq(agg.getV3Quoter(), V3_QUOTER);
        assertEq(agg.getWeth(), WETH);
    }

    function test_Fork_V3FactoryReachable() public view {
        // Sanity: call a view on the real V3 factory
        address pool = IUniswapV3Factory(V3_FACTORY).getPool(WETH, UNI_SEPOLIA, 3000);
        // Pool may or may not exist; assertion is that the call doesn't revert
        console.log("WETH/UNI 0.3%% pool:", pool);
    }

    function test_Fork_V2FactoryReachable() public view {
        address pair = IUniswapV2Factory(V2_FACTORY).getPair(WETH, UNI_SEPOLIA);
        console.log("WETH/UNI V2 pair:", pair);
    }

    // ═══════════════ QUOTING AGAINST REAL STATE ══════════════════

    /// @notice Try to quote 0.01 WETH -> UNI via V2 on real Sepolia state.
    ///         Skips gracefully if the pair has no liquidity.
    function test_Fork_GetV2Quote_WETH_UNI() public {
        uint256 amountIn = 0.01 ether;
        uint256 out = agg.getV2Quote(WETH, UNI_SEPOLIA, amountIn);
        console.log("V2 quote 0.01 WETH -> UNI:", out);
        // We only assert that the call completes. Non-zero out implies live liquidity.
    }

    /// @notice Try all 4 fee tiers on V3 for WETH -> UNI
    function test_Fork_GetBestV3Quote_WETH_UNI() public {
        uint256 amountIn = 0.01 ether;
        (uint256 out, uint24 fee) = agg.getBestV3Quote(WETH, UNI_SEPOLIA, amountIn);
        console.log("Best V3 quote 0.01 WETH -> UNI:", out);
        console.log("Best fee tier:", fee);
    }

    /// @notice End-to-end quoting: aggregate V2 + V3
    function test_Fork_GetQuote_WETH_UNI() public {
        uint256 amountIn = 0.01 ether;
        DexAggregatorV1.Quote memory q = agg.getQuote(WETH, UNI_SEPOLIA, amountIn);
        console.log("Best venue (0=NONE, 1=V2, 2=V3):", uint256(q.dex));
        console.log("Best amountOut:", q.amountOut);
        console.log("V3 fee (if applicable):", q.v3Fee);
    }

    /// @notice Quote a nonexistent token pair — must NOT revert, just return zero
    function test_Fork_GetQuote_NoRouteReturnsNone() public {
        address fakeTokenA = address(0xdeAD1111111111111111111111111111111111De);
        address fakeTokenB = address(0xBEEF2222222222222222222222222222222222ef);

        DexAggregatorV1.Quote memory q = agg.getQuote(fakeTokenA, fakeTokenB, 1 ether);
        assertEq(uint256(q.dex), uint256(DexAggregatorV1.DexType.NONE));
        assertEq(q.amountOut, 0);
    }

    /// @notice Admin role is correctly configured on fork
    function test_Fork_AdminHasRole() public view {
        assertTrue(agg.hasRole(agg.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(agg.hasRole(agg.OPERATOR_ROLE(), admin));
    }
}
