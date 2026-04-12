// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {DexAggregatorV1} from "../src/DexAggregatorV1.sol";

contract ConfigureScript is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address proxyAddress = vm.envAddress("PROXY_ADDRESS");

        vm.startBroadcast(deployerPrivateKey);

        DexAggregatorV1 agg = DexAggregatorV1(proxyAddress);

        // Set protocol fee to 0.1% (10 bps)
        agg.setProtocolFee(10, vm.addr(deployerPrivateKey));
        console.log("Protocol fee set to 0.1%");

        console.log("Version:", agg.version());

        vm.stopBroadcast();
    }
}
