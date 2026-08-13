// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import {Script, console2} from "forge-std/Script.sol";
import {LoanSubaccount} from "../../contracts/smartAccounts/implementation/LoanSubaccount.sol";

// solhint-disable no-console
contract DeployLoanSubaccountImplementation is Script {
    function run(bool _staging) external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        string memory network = _getNetwork(block.chainid);
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

    function _getNetwork(uint256 _chainId) private pure returns (string memory) {
        if (_chainId == 14) {
            return "flare";
        } else if (_chainId == 19) {
            return "songbird";
        } else if (_chainId == 16) {
            return "coston";
        } else if (_chainId == 114) {
            return "coston2";
        } else if (_chainId == 1) {
            return "ethereum";
        } else {
            return "scdev";
        }
    }
}
