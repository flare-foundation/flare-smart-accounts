// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import {Script, console2} from "forge-std/Script.sol";
import {LoanSubaccountRemote} from "../../contracts/smartAccounts/implementation/LoanSubaccountRemote.sol";
import {
    PersonalAccountRemote
} from "../../contracts/smartAccounts/implementation/PersonalAccountRemote.sol";

// solhint-disable no-console
contract DeployRemoteAccountImplementations is Script {
    function run(string calldata _expectedNetwork, bool _staging) external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        // the remote implementations lay out storage for the loan chain's proxy lineages; a copy
        // deployed and recorded on a Flare-family chain would look like a legitimate artifact
        // and, registered there, corrupt every Personal Account's storage
        require(!_isFlareFamily(block.chainid), "remote implementations do not belong on a Flare-family chain");

        string memory network = _getNetwork(block.chainid);
        _requireExpectedNetwork(network, _expectedNetwork);
        if (_staging) {
            network = string.concat(network, "-staging");
        }

        vm.startBroadcast(deployerPrivateKey);
        LoanSubaccountRemote loanSubaccountRemoteImpl = new LoanSubaccountRemote();
        PersonalAccountRemote personalAccountRemoteImpl = new PersonalAccountRemote();
        vm.stopBroadcast();

        console2.log(string.concat("NETWORK: ", network));
        console2.log(
            string.concat(
                "DEPLOYED: LoanSubaccountRemoteImplementation, ",
                "LoanSubaccountRemote.sol: ",
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

    function _isFlareFamily(uint256 _chainId) private pure returns (bool) {
        return _chainId == 14 || _chainId == 19 || _chainId == 16 || _chainId == 114;
    }

    /// @dev The wrapper picks the RPC by network name while this script derives the network
    /// from the chain id; the two must agree, or a mis-set RPC variable would silently
    /// retarget the whole flow to another chain.
    function _requireExpectedNetwork(
        string memory _derived,
        string calldata _expected
    )
        private pure
    {
        require(
            keccak256(bytes(_derived)) == keccak256(bytes(_expected)),
            string.concat("RPC chain is ", _derived, ", not the named network ", _expected)
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
