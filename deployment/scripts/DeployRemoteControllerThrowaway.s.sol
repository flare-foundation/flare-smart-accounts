// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import {Script, console2} from "forge-std/Script.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {DiamondArgs} from "../../contracts/diamond/implementation/Diamond.sol";
import {IDiamond} from "../../contracts/diamond/interfaces/IDiamond.sol";
import {IDiamondCut} from "../../contracts/diamond/interfaces/IDiamondCut.sol";
import {IERC165} from "../../contracts/diamond/interfaces/IERC165.sol";
import {IERC173} from "../../contracts/diamond/interfaces/IERC173.sol";
import {DiamondCutFacet} from "../../contracts/smartAccounts/facets/DiamondCutFacet.sol";
import {DiamondLoupeFacet} from "../../contracts/diamond/facets/DiamondLoupeFacet.sol";
import {OwnershipFacet} from "../../contracts/diamond/facets/OwnershipFacet.sol";
import {ComposeTransportFacet} from "../../contracts/smartAccounts/facets/ComposeTransportFacet.sol";
import {EthereumControllerInit} from "../../contracts/smartAccounts/facets/EthereumControllerInit.sol";
import {MorphoLoanMarketsFacet} from "../../contracts/smartAccounts/facets/MorphoLoanMarketsFacet.sol";
import {PauseFacet} from "../../contracts/smartAccounts/facets/PauseFacet.sol";
import {PersonalAccountsFacet} from "../../contracts/smartAccounts/facets/PersonalAccountsFacet.sol";
import {SubaccountsFacet} from "../../contracts/smartAccounts/facets/SubaccountsFacet.sol";
import {TimelockFacet} from "../../contracts/smartAccounts/facets/TimelockFacet.sol";
import {MasterAccountController} from "../../contracts/smartAccounts/implementation/MasterAccountController.sol";
import {
    MorphoLoanSubaccountRemote
} from "../../contracts/smartAccounts/implementation/MorphoLoanSubaccountRemote.sol";
import {PersonalAccountRemote} from "../../contracts/smartAccounts/implementation/PersonalAccountRemote.sol";
import {IIPersonalAccountsFacet} from "../../contracts/smartAccounts/interface/IIPersonalAccountsFacet.sol";
import {IISingletonFactory} from "../../contracts/smartAccounts/interface/IISingletonFactory.sol";
import {IISubaccountsFacet} from "../../contracts/smartAccounts/interface/IISubaccountsFacet.sol";
import {DeployNetworks} from "../lib/DeployNetworks.sol";
import {PinnedControllerInitCode} from "../lib/PinnedControllerInitCode.sol";
import {SUBACCOUNT_TYPE_MORPHO_LOAN} from "../lib/SubaccountTypes.sol";

/**
 * @title DeployRemoteControllerThrowaway
 * @notice A remote controller built from current source and owned by the deployer: the throwaway
 * mode of [`RUNBOOK.md`](../RUNBOOK.md) Part B, the loan chain's counterpart to what
 * `deploy_contracts` does on the Flare side with a zero `initialOwner`.
 *
 * It is NOT the production path. Current source deliberately cannot reproduce the historical init
 * code, so the controller lands at another address - which is the point: everything downstream of
 * the bootstrap can be rehearsed by one key, with mistakes costing a redeploy rather than a
 * permanent registry entry at a frozen address. The pinned bootstrap is
 * `deploy_remote_controller_pinned`, and this script refuses to be mistaken for it.
 *
 * Address parity with the Flare side is what makes the rehearsal worth anything, so nothing here
 * may vary between the two chains: the base facets go through the same singleton factory at salt
 * zero, and the controller's constructor takes those facets and the deployer as owner, with no
 * init - exactly as `DeploySmartAccounts` builds it. Both sides must therefore run the SAME build.
 *
 * What it leaves alone: roles, the timelock duration, the transport, the market and the fee terms.
 * Those are `configure_remote_controller`'s, whose `execute` phase is this mode's other half.
 */
// solhint-disable no-console
contract DeployRemoteControllerThrowaway is Script {

    /// @dev EIP-2470, at the same address on every chain, which is what makes the derivation match.
    address private constant SINGLETON_FACTORY = 0xce0042B868300000d44A59004Da54A005ffdcf9f;
    bytes32 private constant SALT = bytes32(0);

    function run(
        string calldata _expectedNetwork
    )
        external
    {
        // the remote implementations and the loan facet set lay out and serve the loan chains'
        // proxy lineages; a copy on a Flare-family chain would look like a legitimate artifact
        require(DeployNetworks.isLoanChain(block.chainid), "the remote controller belongs on a loan chain");
        string memory network = DeployNetworks.networkName(block.chainid);
        DeployNetworks.requireExpectedNetwork(network, _expectedNetwork);

        // The signer is forge's, resolved from whatever the wrapper passed - a raw key, a keystore
        // or a Ledger - and `msg.sender` is that account. Reading DEPLOYER_PRIVATE_KEY here would
        // check one account and sign as another the moment the two differ, which is exactly what a
        // hardware run is. Note this validates the sender forge was GIVEN; a device whose address
        // is not that one fails later, at signing, rather than here.
        address deployer = _signer();
        console2.log(string.concat("NETWORK: ", network));

        vm.startBroadcast(_signer());
        IDiamond.FacetCut[] memory baseFacets = _deployBaseFacets();
        address controller = _deployController(baseFacets, deployer);
        address init = _deployThroughFactory(type(EthereumControllerInit).creationCode);
        // every step here is derived and reused rather than freshly created, so a run that died
        // half way through is resumed by running it again. The cut is the one step that cannot
        // repeat - a second Add of the same selector reverts - so the init's own flag is what says
        // whether it has happened: nothing sets those four before the cut's init runs
        IDiamond.FacetCut[] memory remoteFacets;
        if (IERC165(controller).supportsInterface(type(IERC173).interfaceId)) {
            // derived, not deployed: a rerun whose first attempt recorded nothing must still be
            // able to write a complete record, so the facets are reported either way
            console2.log("REUSED: the controller is already cut, leaving its facets alone");
            remoteFacets = _remoteFacetCuts(false);
        } else {
            remoteFacets = _cutRemoteFacets(controller, init);
        }
        address personalAccount = _deployThroughFactory(type(PersonalAccountRemote).creationCode);
        address loanSubaccount = _deployThroughFactory(type(MorphoLoanSubaccountRemote).creationCode);
        // both registrations apply on the spot: the duration is still zero until
        // configure_remote_controller sets it, which is why that step comes after this one
        IIPersonalAccountsFacet(controller).setPersonalAccountImplementation(personalAccount);
        IISubaccountsFacet(controller).setSubaccountImplementation(SUBACCOUNT_TYPE_MORPHO_LOAN, loanSubaccount);
        vm.stopBroadcast();

        _logDeployed("DiamondCutFacet", "DiamondCutFacet.sol", baseFacets[0].facetAddress);
        _logDeployed("DiamondLoupeFacet", "DiamondLoupeFacet.sol", baseFacets[1].facetAddress);
        _logDeployed("OwnershipFacet", "OwnershipFacet.sol", baseFacets[2].facetAddress);
        _logDeployed("MasterAccountController", "MasterAccountController.sol", controller);
        _logDeployed("EthereumControllerInit", "EthereumControllerInit.sol", init);
        string[] memory names = _facetNames();
        for (uint256 i = 0; i < remoteFacets.length; i++) {
            _logDeployed(names[i], string.concat(names[i], ".sol"), remoteFacets[i].facetAddress);
        }
        _logDeployed("PersonalAccountRemoteImplementation", "PersonalAccountRemote.sol", personalAccount);
        _logDeployed(
            "MorphoLoanSubaccountRemoteImplementation",
            "MorphoLoanSubaccountRemote.sol",
            loanSubaccount
        );
        console2.log(
            string.concat(
                "OWNER: ", vm.toString(deployer),
                " - transfer it to the intended governance before anyone relies on this deployment"
            )
        );
    }

    /// @notice The address this build lands the controller at for `_owner`, derived and not
    /// deployed: run it on both chains before deploying anything, since a rehearsal whose two sides
    /// disagree is no rehearsal, and the only way they can disagree is a different build.
    function controllerAddress(
        address _owner
    )
        public
        returns (address)
    {
        return _derive(_controllerInitCode(_baseFacetCuts(), _owner));
    }

    /// @dev The three base facets as the controller's constructor takes them: their derived
    /// addresses, which one build gives on every chain, and the selectors their artifacts expose.
    /// Derivation only - {_deployBaseFacets} is what puts code there.
    function _baseFacetCuts()
        internal
        returns (IDiamond.FacetCut[] memory _facets)
    {
        _facets = new IDiamond.FacetCut[](3);
        _facets[0] = _facetCut(_derive(type(DiamondCutFacet).creationCode), "DiamondCutFacet");
        _facets[1] = _facetCut(_derive(type(DiamondLoupeFacet).creationCode), "DiamondLoupeFacet");
        _facets[2] = _facetCut(_derive(type(OwnershipFacet).creationCode), "OwnershipFacet");
    }

    /// @dev The same three with code at those addresses: deployed through the singleton factory at
    /// salt zero, or left alone where a previous run already put them there.
    function _deployBaseFacets()
        internal
        returns (IDiamond.FacetCut[] memory _facets)
    {
        _deployThroughFactory(type(DiamondCutFacet).creationCode);
        _deployThroughFactory(type(DiamondLoupeFacet).creationCode);
        _deployThroughFactory(type(OwnershipFacet).creationCode);
        _facets = _baseFacetCuts();
    }

    /// @dev The controller's init code: the compiled contract, the base facets with their
    /// selectors, and the owner - every input that moves its address.
    function _controllerInitCode(
        IDiamond.FacetCut[] memory _baseFacets,
        address _owner
    )
        internal pure
        returns (bytes memory)
    {
        DiamondArgs memory args = DiamondArgs({owner: _owner, initAddress: address(0), initCalldata: ""});
        return abi.encodePacked(type(MasterAccountController).creationCode, abi.encode(_baseFacets, args));
    }

    /// @dev The controller itself, through the same factory and with the same constructor shape the
    /// Flare deploy uses - the base facets and the owner, no init - so that one build lands one
    /// address on both chains. Refuses to be the pinned controller: reaching that address from
    /// current source would mean the historical bytes had been reproduced after all, and this is
    /// the script that must never claim it.
    function _deployController(
        IDiamond.FacetCut[] memory _baseFacets,
        address _owner
    )
        internal
        returns (address _controller)
    {
        _controller = _deployThroughFactory(_controllerInitCode(_baseFacets, _owner));
        require(
            _controller != PinnedControllerInitCode.MASTER_ACCOUNT_CONTROLLER,
            "this would be the pinned controller: use deploy_remote_controller_pinned"
        );
    }

    /// @dev The loan chain's facet set, in one cut with the init that sets the four ERC-165 flags.
    /// `MasterAccountControllerInit` is the Flare side's and is skipped here.
    function _cutRemoteFacets(
        address _controller,
        address _init
    )
        internal
        returns (IDiamond.FacetCut[] memory _cuts)
    {
        _cuts = _remoteFacetCuts(true);
        IDiamondCut(_controller).diamondCut(
            _cuts,
            _init,
            abi.encodeCall(EthereumControllerInit.init, ())
        );
    }

    /// @dev The six the loan chain runs, through the same factory at salt zero as everything else
    /// here - so a resumed run derives the very addresses the first one cut in, and can report them
    /// even though it does not cut again. `_deploy` false derives without deploying.
    function _remoteFacetCuts(
        bool _deploy
    )
        internal
        returns (IDiamond.FacetCut[] memory _cuts)
    {
        bytes[] memory creationCodes = new bytes[](6);
        creationCodes[0] = type(SubaccountsFacet).creationCode;
        creationCodes[1] = type(TimelockFacet).creationCode;
        creationCodes[2] = type(PauseFacet).creationCode;
        creationCodes[3] = type(PersonalAccountsFacet).creationCode;
        creationCodes[4] = type(ComposeTransportFacet).creationCode;
        creationCodes[5] = type(MorphoLoanMarketsFacet).creationCode;
        string[] memory names = _facetNames();
        _cuts = new IDiamond.FacetCut[](6);
        for (uint256 i = 0; i < _cuts.length; i++) {
            address facet = _deploy ? _deployThroughFactory(creationCodes[i]) : _derive(creationCodes[i]);
            _cuts[i] = _facetCut(facet, names[i]);
        }
    }

    /// @dev CREATE2 through the singleton factory, reusing whatever is already at the derived
    /// address: a rerun after a partial failure must not fail on what already exists.
    function _deployThroughFactory(
        bytes memory _bytecode
    )
        internal
        returns (address _deployed)
    {
        address expected = _derive(_bytecode);
        if (expected.code.length > 0) {
            return expected;
        }
        _deployed = IISingletonFactory(SINGLETON_FACTORY).deploy(_bytecode, SALT);
        require(_deployed == expected && _deployed.code.length > 0, "singleton factory deployment failed");
    }

    /// @dev The address `_bytecode` lands at through the factory at salt zero.
    function _derive(
        bytes memory _bytecode
    )
        internal pure
        returns (address)
    {
        return Create2.computeAddress(SALT, keccak256(_bytecode), SINGLETON_FACTORY);
    }

    /// @dev The facet's selectors come from its artifact, the same helper the Flare deploy uses, so
    /// the cut carries exactly what the contract exposes.
    function _facetCut(
        address _facet,
        string memory _name
    )
        internal
        returns (IDiamond.FacetCut memory)
    {
        string[] memory cmds = new string[](3);
        cmds[0] = "node";
        cmds[1] = "scripts/master-controller-selectors.js";
        cmds[2] = _name;
        bytes4[] memory selectors = abi.decode(vm.ffi(cmds), (bytes4[]));
        return IDiamond.FacetCut({
            facetAddress: _facet,
            action: IDiamond.FacetCutAction.Add,
            functionSelectors: selectors
        });
    }

    /// @dev The recorder's line, which the wrapper pipes into the throwaway `_mock` record.
    function _logDeployed(
        string memory _name,
        string memory _contractName,
        address _address
    )
        internal virtual
    {
        console2.log(deployedLine(_name, _contractName, _address));
    }

    /// @notice The line itself, in the shape `save-deployed-addresses.ts` parses. Built here rather
    /// than inline so a test asserting what a run would record asserts the operator's own format.
    function deployedLine(
        string memory _name,
        string memory _contractName,
        address _address
    )
        public pure
        returns (string memory)
    {
        return string.concat("DEPLOYED: ", _name, ", ", _contractName, ": ", vm.toString(_address));
    }

    function _facetNames()
        internal pure
        returns (string[] memory _names)
    {
        _names = new string[](6);
        _names[0] = "SubaccountsFacet";
        _names[1] = "TimelockFacet";
        _names[2] = "PauseFacet";
        _names[3] = "PersonalAccountsFacet";
        _names[4] = "ComposeTransportFacet";
        _names[5] = "MorphoLoanMarketsFacet";
    }

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

}
