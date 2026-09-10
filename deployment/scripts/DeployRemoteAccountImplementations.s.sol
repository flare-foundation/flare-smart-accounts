// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import {Script, console2} from "forge-std/Script.sol";
import {MorphoLoanSubaccountRemote} from "../../contracts/smartAccounts/implementation/MorphoLoanSubaccountRemote.sol";
import {DeployNetworks} from "./DeployNetworks.sol";
import {
    PersonalAccountRemote
} from "../../contracts/smartAccounts/implementation/PersonalAccountRemote.sol";

// solhint-disable no-console
contract DeployRemoteAccountImplementations is Script {
    function run(
        string calldata _expectedNetwork,
        bool _staging
    )
        external
    {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        // the remote implementations lay out storage for the loan chain's proxy lineages; a copy
        // deployed and recorded on a Flare-family chain would look like a legitimate artifact and,
        // registered there, run the loan chain's logic over every Personal Account
        require(DeployNetworks.isLoanChain(block.chainid), "remote implementations belong on a loan chain");
        // the loan chains have only the pinned deployment; the recorder refuses a staging name too
        require(!_staging, "the loan chains have no staging deployment");

        string memory network = DeployNetworks.networkName(block.chainid);
        DeployNetworks.requireExpectedNetwork(network, _expectedNetwork);

        vm.startBroadcast(deployerPrivateKey);
        MorphoLoanSubaccountRemote loanSubaccountRemoteImpl = new MorphoLoanSubaccountRemote();
        PersonalAccountRemote personalAccountRemoteImpl = new PersonalAccountRemote();
        vm.stopBroadcast();

        console2.log(string.concat("NETWORK: ", network));
        console2.log(
            string.concat(
                "DEPLOYED: MorphoLoanSubaccountRemoteImplementation, ",
                "MorphoLoanSubaccountRemote.sol: ",
                vm.toString(address(loanSubaccountRemoteImpl))
            )
        );
        console2.log(
            string.concat(
                "DEPLOYED: PersonalAccountRemoteImplementation, ",
                "PersonalAccountRemote.sol: ",
                vm.toString(address(personalAccountRemoteImpl))
            )
        );
    }
}
