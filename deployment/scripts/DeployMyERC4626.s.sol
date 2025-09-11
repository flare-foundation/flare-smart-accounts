// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import {Script, console2} from "forge-std/Script.sol";
import {MyERC4626} from "../../contracts/mock/MyERC4626.sol";
import {IERC20} from "@openzeppelin-contracts/token/ERC20/IERC20.sol";

contract DeployMyERC4626 is Script {
    MyERC4626 private depositVault;

    function run() external {
        vm.startBroadcast();
        depositVault = new MyERC4626(
            IERC20(0x0b6A3645c240605887a5532109323A3E12273dc7),
            "TESTstXRP",
            "TESTstXRP"
        );
        vm.stopBroadcast();

        // Log deployment info for post-processing
        console2.log("Deposit Vault:", address(depositVault));
    }
}
