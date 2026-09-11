// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import {Script, console2} from "forge-std/Script.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {IISingletonFactory} from "../../contracts/smartAccounts/interface/IISingletonFactory.sol";
import {PinnedControllerInitCode} from "../lib/PinnedControllerInitCode.sol";
import {DeployNetworks} from "../lib/DeployNetworks.sol";

/**
 * Reproduces the production MasterAccountController deployment on a loan chain - Ethereum, or
 * Sepolia as its rehearsal - from the pinned historical init code, never from rebuilt sources,
 * which have drifted and derive a different address. Every contract is verified twice before
 * broadcasting: the pinned file must hash to its fixture, and the CREATE2 derivation from that
 * hash must equal the known production address. Deployment itself is permissionless (CREATE2
 * through the EIP-2470 factory is sender-independent), and the factory sits at the same address
 * on both chains, so the same init code lands the same four addresses on Sepolia.
 *
 * This script only reproduces the diamond with its three base facets. The follow-up cut that
 * installs the Ethereum facet set (SubaccountsFacet, TimelockFacet, PauseFacet,
 * PersonalAccountsFacet, ComposeTransportFacet, MorphoLoanMarketsFacet) is owner-gated: the fresh
 * diamond is owned by the historical
 * `DiamondArgs.owner` EOA. Confirm that key is still controlled before deploying here.
 *
 * The loan chains only, held to the name the wrapper dialed the RPC by (a fork of either, under
 * its real name, for rehearsals). It prints the recorder's `NETWORK:`/`DEPLOYED:` lines so the
 * wrapper records the four contracts in `deployment/deploys/<network>.json` when - and only
 * when - they exist there.
 */
// solhint-disable no-console
contract DeployEthereumController is Script {
    function run(
        string calldata _expectedNetwork
    )
        external
    {
        require(DeployNetworks.isLoanChain(block.chainid), "the pinned bootstrap runs on a loan chain");
        string memory network = DeployNetworks.networkName(block.chainid);
        DeployNetworks.requireExpectedNetwork(network, _expectedNetwork);
        console2.log(string.concat("NETWORK: ", network));

        vm.startBroadcast();
        // base facets first: the diamond constructor cuts them and requires their code
        _deployPinned(
            "DiamondCutFacet",
            PinnedControllerInitCode.DIAMOND_CUT_FACET_INIT_CODE_HASH,
            PinnedControllerInitCode.DIAMOND_CUT_FACET,
            PinnedControllerInitCode.DIAMOND_CUT_FACET_RUNTIME_CODE_HASH
        );
        _deployPinned(
            "DiamondLoupeFacet",
            PinnedControllerInitCode.DIAMOND_LOUPE_FACET_INIT_CODE_HASH,
            PinnedControllerInitCode.DIAMOND_LOUPE_FACET,
            PinnedControllerInitCode.DIAMOND_LOUPE_FACET_RUNTIME_CODE_HASH
        );
        _deployPinned(
            "OwnershipFacet",
            PinnedControllerInitCode.OWNERSHIP_FACET_INIT_CODE_HASH,
            PinnedControllerInitCode.OWNERSHIP_FACET,
            PinnedControllerInitCode.OWNERSHIP_FACET_RUNTIME_CODE_HASH
        );
        _deployPinned(
            "MasterAccountController",
            PinnedControllerInitCode.MASTER_ACCOUNT_CONTROLLER_INIT_CODE_HASH,
            PinnedControllerInitCode.MASTER_ACCOUNT_CONTROLLER,
            PinnedControllerInitCode.MASTER_ACCOUNT_CONTROLLER_RUNTIME_CODE_HASH
        );
        vm.stopBroadcast();

        console2.log(
            "NOTE: the diamond is owned by the historical initial owner; the facet cut must",
            "be executed by",
            PinnedControllerInitCode.INITIAL_OWNER
        );
    }

    function _deployPinned(
        string memory _name,
        bytes32 _expectedInitCodeHash,
        address _expectedAddress,
        bytes32 _expectedRuntimeCodeHash
    )
        private
    {
        bytes memory initCode = vm.parseBytes(
            vm.readFile(
                string.concat(PinnedControllerInitCode.INIT_CODE_DIR, _name, ".hex")
            )
        );
        require(
            keccak256(initCode) == _expectedInitCodeHash,
            string.concat(_name, ": pinned init code does not match its hash fixture")
        );
        require(
            Create2.computeAddress(
                PinnedControllerInitCode.SALT,
                _expectedInitCodeHash,
                PinnedControllerInitCode.SINGLETON_FACTORY
            ) == _expectedAddress,
            string.concat(_name, ": derivation does not reproduce the production address")
        );

        if (_expectedAddress.code.length > 0) {
            console2.log(string.concat(_name, " already deployed, skipping:"), _expectedAddress);
        } else {
            address deployed = IISingletonFactory(PinnedControllerInitCode.SINGLETON_FACTORY)
                .deploy(initCode, PinnedControllerInitCode.SALT);
            require(
                deployed == _expectedAddress && _expectedAddress.code.length > 0,
                string.concat(_name, ": deployment failed")
            );
        }
        // postcondition, whether freshly deployed or skipped: the runtime code must be
        // byte-identical to the Flare production deployment - never trust existing code
        require(
            _expectedAddress.codehash == _expectedRuntimeCodeHash,
            string.concat(_name, ": runtime code does not match the Flare production fixture")
        );
        console2.log(
            string.concat("DEPLOYED: ", _name, ", ", _name, ".sol: "),
            vm.toString(_expectedAddress)
        );
    }
}
