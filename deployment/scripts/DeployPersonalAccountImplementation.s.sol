// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import {Script, console2} from "forge-std/Script.sol";
import {PersonalAccount} from "../../contracts/smartAccounts/implementation/PersonalAccount.sol";

// solhint-disable no-console
contract DeployPersonalAccountImplementation is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        string memory network = _getNetwork(block.chainid);

        vm.startBroadcast(deployerPrivateKey);
        PersonalAccount personalAccountImpl = new PersonalAccount();
        vm.stopBroadcast();

        address personalAccountImplAddress = address(personalAccountImpl);

        console2.log(string.concat("NETWORK: ", network));
        console2.log(
            string.concat(
                "DEPLOYED: PersonalAccountImplementation, ",
                "PersonalAccount.sol: ",
                vm.toString(personalAccountImplAddress)
            )
        );
    }

    function _getNetwork(uint256 _chainId) private pure returns (string memory) {
        if (_chainId == 14) {
            return "flare";
        } else if (_chainId == 114) {
            return "coston2";
        } else {
            return "scdev";
        }
    }
}
