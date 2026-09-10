// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import {Script, console2} from "forge-std/Script.sol";
import {LoanSubaccount} from "../../contracts/smartAccounts/implementation/LoanSubaccount.sol";
import {DeployNetworks} from "./DeployNetworks.sol";

// solhint-disable no-console
contract DeployLoanSubaccountImplementation is Script {
    function run(
        string calldata _expectedNetwork,
        bool _staging
    )
        external
    {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        // the Flare-side implementation lays out storage for the Flare proxy lineage; the loan
        // chains register MorphoLoanSubaccountRemote instead (see DeployRemoteAccountImplementations)
        require(
            DeployNetworks.isFlareFamily(block.chainid) || DeployNetworks.isDeclaredLocal(_expectedNetwork),
            "the Flare-side loan implementation belongs on a Flare-family chain"
        );

        string memory network = DeployNetworks.networkName(block.chainid);
        DeployNetworks.requireExpectedNetwork(network, _expectedNetwork);
        if (_staging) {
            network = string.concat(network, "-staging");
        }

        vm.startBroadcast(deployerPrivateKey);
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
