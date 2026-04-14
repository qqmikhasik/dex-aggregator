// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {DexAggregatorV1} from "../src/DexAggregatorV1.sol";
import {DexAggregatorV2} from "../src/DexAggregatorV2.sol";

contract UpgradeScript is Script {
    // Well-known intermediate tokens on Sepolia
    address constant SEPOLIA_WETH = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address proxyAddress = vm.envAddress("PROXY_ADDRESS");

        console.log("Upgrading proxy at:", proxyAddress);

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy new implementation
        DexAggregatorV2 implV2 = new DexAggregatorV2();
        console.log("V2 Implementation:", address(implV2));

        // 2. Configure intermediate tokens for multi-hop
        address[] memory intermediateTokens = new address[](1);
        intermediateTokens[0] = SEPOLIA_WETH;

        // 3. Upgrade via UUPS
        DexAggregatorV1(proxyAddress)
            .upgradeToAndCall(address(implV2), abi.encodeCall(DexAggregatorV2.initializeV2, (intermediateTokens)));
        console.log("Upgraded to V2");
        console.log("Version:", DexAggregatorV2(proxyAddress).version());

        vm.stopBroadcast();
    }
}
