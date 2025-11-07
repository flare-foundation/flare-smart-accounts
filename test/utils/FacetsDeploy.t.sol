// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import {Test,console2} from "forge-std/Test.sol";
import {IISingletonFactory} from "../../contracts/smartAccounts/interface/IISingletonFactory.sol";
import {MockSingletonFactory} from "../../contracts/mock/MockSingletonFactory.sol";
import {IDiamond} from "../../contracts/diamond/interfaces/IDiamond.sol";

// facets
import {DiamondCutFacet} from "../../contracts/diamond/facets/DiamondCutFacet.sol";
import {DiamondLoupeFacet} from "../../contracts/diamond/facets/DiamondLoupeFacet.sol";
import {OwnershipFacet} from "../../contracts/diamond/facets/OwnershipFacet.sol";
import {AgentVaultsFacet} from "../../contracts/smartAccounts/facets/AgentVaultsFacet.sol";
import {ExecutorsFacet} from "../../contracts/smartAccounts/facets/ExecutorsFacet.sol";
import {InstructionFeesFacet} from "../../contracts/smartAccounts/facets/InstructionFeesFacet.sol";
import {InstructionsFacet} from "../../contracts/smartAccounts/facets/InstructionsFacet.sol";
import {PaymentProofsFacet} from "../../contracts/smartAccounts/facets/PaymentProofsFacet.sol";
import {PersonalAccountsFacet} from "../../contracts/smartAccounts/facets/PersonalAccountsFacet.sol";
import {SwapFacet} from "../../contracts/smartAccounts/facets/SwapFacet.sol";
import {VaultsFacet} from "../../contracts/smartAccounts/facets/VaultsFacet.sol";
import {XrplProviderWalletsFacet} from "../../contracts/smartAccounts/facets/XrplProviderWalletsFacet.sol";

contract FacetsDeploy is Test {
    address private constant SINGLETON_FACTORY = 0xce0042B868300000d44A59004Da54A005ffdcf9f;
    IDiamond.FacetCut[] public diamondCuts;

    constructor() {
        MockSingletonFactory mockFactory = new MockSingletonFactory();
        vm.etch(SINGLETON_FACTORY, address(mockFactory).code);
    }


    function deployBaseFacets() internal returns (IDiamond.FacetCut[] memory) {
        delete diamondCuts;

        bytes memory bytecode = abi.encodePacked(
            type(DiamondCutFacet).creationCode
        );
        address diamondCutFacet = IISingletonFactory(SINGLETON_FACTORY).deploy(bytecode, 0);
        addFacetData(diamondCutFacet, "DiamondCutFacet");

        bytecode = abi.encodePacked(
            type(DiamondLoupeFacet).creationCode
        );
        address diamondLoupeFacet = IISingletonFactory(SINGLETON_FACTORY).deploy(bytecode, 0);
        addFacetData(diamondLoupeFacet, "DiamondLoupeFacet");

        bytecode = abi.encodePacked(
            type(OwnershipFacet).creationCode
        );
        address ownershipFacet = IISingletonFactory(SINGLETON_FACTORY).deploy(bytecode, 0);
        addFacetData(ownershipFacet, "OwnershipFacet");

        return diamondCuts;
    }

    function deploySmartAccountFacets() internal returns (IDiamond.FacetCut[] memory) {
        delete diamondCuts;

        addFacetData(address(new AgentVaultsFacet()), "AgentVaultsFacet");
        addFacetData(address(new ExecutorsFacet()), "ExecutorsFacet");
        addFacetData(address(new InstructionFeesFacet()), "InstructionFeesFacet");
        addFacetData(address(new InstructionsFacet()), "InstructionsFacet");
        addFacetData(address(new PaymentProofsFacet()), "PaymentProofsFacet");
        addFacetData(address(new PersonalAccountsFacet()), "PersonalAccountsFacet");
        addFacetData(address(new SwapFacet()), "SwapFacet");
        addFacetData(address(new VaultsFacet()), "VaultsFacet");
        addFacetData(address(new XrplProviderWalletsFacet()), "XrplProviderWalletsFacet");

        return diamondCuts;
    }

    function addFacetData(address facetAddr, string memory facetName) internal {
        string[] memory cmds = new string[](3);
        // cmds[0] = "bash";
        // cmds[1] = "scripts/master-controller-selectors.sh";
        cmds[0] = "node";
        cmds[1] = "scripts/master-controller-selectors.js";
        cmds[2] = facetName;
        bytes memory out = vm.ffi(cmds);
        bytes4[] memory selectors = abi.decode(out, (bytes4[]));
        diamondCuts.push(IDiamond.FacetCut({
            facetAddress: facetAddr,
            action: IDiamond.FacetCutAction.Add,
            functionSelectors: selectors
        }));
    }

}