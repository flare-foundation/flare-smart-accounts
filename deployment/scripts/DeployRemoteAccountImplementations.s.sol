// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import {Script, console2} from "forge-std/Script.sol";
import {MorphoLoanSubaccountRemote} from "../../contracts/smartAccounts/implementation/MorphoLoanSubaccountRemote.sol";
import {DeployNetworks} from "../lib/DeployNetworks.sol";
import {
    PersonalAccountRemote
} from "../../contracts/smartAccounts/implementation/PersonalAccountRemote.sol";

// solhint-disable no-console
contract DeployRemoteAccountImplementations is Script {

    /**
     * @notice Deploys the remote implementations named, and only those.
     * @param _expectedNetwork The network the caller believes it is pointed at.
     * @param _staging Whether this is a staging deployment; the loan chains have none.
     * @param _contracts The artifact names to deploy. Empty deploys nothing, which is legitimate.
     * @dev The list is decided by `plan-remote-implementations.ts` and passed in rather than worked
     * out here: the comparison behind it is the cut planner's, over artifacts on disk and code on
     * chain, and reimplementing its metadata rules in Solidity would leave two copies to keep in
     * step.
     *
     * Names rather than a flag per implementation, because more subaccount types are expected
     * (`deployment/lib/SubaccountTypes.sol`) and a positional boolean each would become
     * `true false false true` at the call site - unreadable in a runbook and a miscount waiting to
     * happen. Adding one here is a branch in {_deploy} and a row in the TypeScript table; no
     * existing argument moves.
     *
     * An empty list is what the preflight produces when nothing has changed, and deploys nothing
     * while still naming the network, so an operator sees a run that did nothing rather than no
     * output at all. An unrecognized name is refused: it means the caller asked for something this
     * script cannot deploy, and carrying on would quietly deploy a shorter list than was asked for.
     */
    function run(
        string calldata _expectedNetwork,
        bool _staging,
        string[] calldata _contracts
    )
        external
    {
        // the remote implementations lay out storage for the loan chain's proxy lineages; a copy
        // deployed and recorded on a Flare-family chain would look like a legitimate artifact and,
        // registered there, run the loan chain's logic over every Personal Account
        require(DeployNetworks.isLoanChain(block.chainid), "remote implementations belong on a loan chain");
        // the loan chains have only the pinned deployment; the recorder refuses a staging name too
        require(!_staging, "the loan chains have no staging deployment");

        string memory network = DeployNetworks.networkName(block.chainid);
        DeployNetworks.requireExpectedNetwork(network, _expectedNetwork);

        _print(string.concat("NETWORK: ", network));

        if (_contracts.length == 0) {
            _print("NOTHING TO DEPLOY: every selected implementation is already on chain as this code");
            return;
        }

        for (uint256 i = 0; i < _contracts.length; i++) {
            _deploy(_contracts[i]);
        }
    }

    /**
     * @notice Deploys one named implementation and announces it.
     * @param _contract The artifact name.
     * @dev Only what was actually deployed is announced: the recorder writes one record entry per
     * `DEPLOYED:` line, so naming an implementation this run did not deploy would replace its
     * record with the address it already holds at best, and with a stale one at worst.
     */
    function _deploy(
        string calldata _contract
    )
        internal
    {
        bytes32 name = keccak256(bytes(_contract));
        if (name == keccak256("PersonalAccountRemote")) {
            vm.broadcast(_signer());
            PersonalAccountRemote deployed = new PersonalAccountRemote();
            _print(
                string.concat(
                    "DEPLOYED: PersonalAccountRemoteImplementation, ",
                    "PersonalAccountRemote.sol: ",
                    vm.toString(address(deployed))
                )
            );
            return;
        }
        if (name == keccak256("MorphoLoanSubaccountRemote")) {
            vm.broadcast(_signer());
            MorphoLoanSubaccountRemote deployed = new MorphoLoanSubaccountRemote();
            _print(
                string.concat(
                    "DEPLOYED: MorphoLoanSubaccountRemoteImplementation, ",
                    "MorphoLoanSubaccountRemote.sol: ",
                    vm.toString(address(deployed))
                )
            );
            return;
        }
        revert(string.concat("not a remote implementation this script can deploy: ", _contract));
    }

    /// @dev A seam, so a test can read what an operator reads without parsing forge's output.

    /**
     * @notice The account this run signs as.
     * @dev In a run this is the signer forge resolved from the command line - a raw key, a keystore
     * or a Ledger - so the account the script checks and the account that signs are the same one.
     * It is a seam because a test cannot name that account any other way: `vm.prank` and a
     * broadcast are mutually exclusive, so a harness overrides this instead.
     */
    function _signer()
        internal view virtual
        returns (address)
    {
        return msg.sender;
    }

    function _print(
        string memory _line
    )
        internal virtual
    {
        console2.log(_line);
    }
}
