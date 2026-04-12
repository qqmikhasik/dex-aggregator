// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {DexAggregatorV1} from "../src/DexAggregatorV1.sol";

contract DeployScript is Script {
    // Sepolia Uniswap addresses
    address constant SEPOLIA_V2_ROUTER = 0xeE567Fe1712Faf6149d80dA1E6934E354124CfE3;
    address constant SEPOLIA_V2_FACTORY = 0xF62c03E08ada871A0bEb309762E260a7a6a880E6;
    address constant SEPOLIA_V3_ROUTER = 0x3bFA4769FB09eefC5a80d6E87c3B9C650f7Ae48E;
    address constant SEPOLIA_V3_FACTORY = 0x0227628f3F023bb0B980b67D528571c95c6DaC1c;
    address constant SEPOLIA_V3_QUOTER = 0xEd1f6473345F45b75F8179591dd5bA1888cf2FB3;
    address constant SEPOLIA_WETH = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Deployer:", deployer);

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy implementation
        DexAggregatorV1 impl = new DexAggregatorV1();
        console.log("Implementation:", address(impl));

        // 2. Deploy proxy with initialization
        bytes memory initData = abi.encodeCall(
            DexAggregatorV1.initialize,
            (
                SEPOLIA_V2_ROUTER,
                SEPOLIA_V2_FACTORY,
                SEPOLIA_V3_ROUTER,
                SEPOLIA_V3_FACTORY,
                SEPOLIA_V3_QUOTER,
                SEPOLIA_WETH,
                deployer
            )
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        console.log("Proxy:", address(proxy));

        vm.stopBroadcast();
    }
}
