// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import {Script, console2} from "forge-std/Script.sol";
import {LoanSubaccount} from "../../contracts/smartAccounts/implementation/LoanSubaccount.sol";
import {DeployNetworks} from "../lib/DeployNetworks.sol";

// solhint-disable no-console
contract DeployLoanSubaccountImplementation is Script {
    function run(
        string calldata _expectedNetwork,
        bool _staging
    )
        external
    {

        // the Flare-side implementation lays out storage for the Flare proxy lineage; the loan
        // chains register MorphoLoanSubaccountRemote instead (see DeployRemoteAccountImplementations)
        require(
            DeployNetworks.isFlareFamily(block.chainid),
            "the Flare-side loan implementation belongs on a Flare-family chain"
        );

        string memory network = DeployNetworks.networkName(block.chainid);
        DeployNetworks.requireExpectedNetwork(network, _expectedNetwork);
        if (_staging) {
            network = string.concat(network, "-staging");
        }

        // The signer is forge's, resolved from whatever the wrapper passed - a raw key, a keystore
        // or a Ledger - and `msg.sender` is that account. Reading DEPLOYER_PRIVATE_KEY here would
        // check one account and sign as another the moment the two differ, which is exactly what a
        // hardware run is. Note this validates the sender forge was GIVEN; a device whose address
        // is not that one fails later, at signing, rather than here.
        vm.startBroadcast(msg.sender);
        LoanSubaccount loanSubaccountImpl = new LoanSubaccount();
        vm.stopBroadcast();

        address loanSubaccountImplAddress = address(loanSubaccountImpl);

        console2.log(string.concat("NETWORK: ", network));
        console2.log(
            string.concat(
                "DEPLOYED: LoanSubaccountImplementation, ",
                "LoanSubaccount.sol: ",
                vm.toString(loanSubaccountImplAddress)
            )
        );
    }
}
