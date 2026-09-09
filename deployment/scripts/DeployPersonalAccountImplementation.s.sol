// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import {Script, console2} from "forge-std/Script.sol";
import {PersonalAccount} from "../../contracts/smartAccounts/implementation/PersonalAccount.sol";
import {DeployNetworks} from "./DeployNetworks.sol";

// solhint-disable no-console
contract DeployPersonalAccountImplementation is Script {
    function run(string calldata _expectedNetwork, bool _staging) external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        // the Flare Personal Account lays out storage for the Flare PA proxy lineage; the loan
        // chains register PersonalAccountRemote instead (see DeployRemoteAccountImplementations).
        // Refused by family, not by one chain id - see DeployLoanSubaccountImplementation
        require(
            !DeployNetworks.isLoanChain(block.chainid),
            "the Flare Personal Account belongs on a Flare-family chain"
        );

        string memory network = DeployNetworks.networkName(block.chainid);
        DeployNetworks.requireExpectedNetwork(network, _expectedNetwork);
        if (_staging) {
            network = string.concat(network, "-staging");
        }

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
}
