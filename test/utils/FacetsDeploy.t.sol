// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {IISingletonFactory} from "../../contracts/smartAccounts/interface/IISingletonFactory.sol";
import {MockSingletonFactory} from "../../contracts/mock/MockSingletonFactory.sol";
import {IDiamond} from "../../contracts/diamond/interfaces/IDiamond.sol";

// facets
import {DiamondLoupeFacet} from "../../contracts/diamond/facets/DiamondLoupeFacet.sol";
import {OwnershipFacet} from "../../contracts/diamond/facets/OwnershipFacet.sol";
import {DiamondCutFacet} from "../../contracts/smartAccounts/facets/DiamondCutFacet.sol";
import {AgentVaultsFacet} from "../../contracts/smartAccounts/facets/AgentVaultsFacet.sol";
import {ExecutorsFacet} from "../../contracts/smartAccounts/facets/ExecutorsFacet.sol";
import {InstructionFeesFacet} from "../../contracts/smartAccounts/facets/InstructionFeesFacet.sol";
import {InstructionsFacet} from "../../contracts/smartAccounts/facets/InstructionsFacet.sol";
import {PaymentProofsFacet} from "../../contracts/smartAccounts/facets/PaymentProofsFacet.sol";
import {PersonalAccountsFacet} from "../../contracts/smartAccounts/facets/PersonalAccountsFacet.sol";
import {SwapFacet} from "../../contracts/smartAccounts/facets/SwapFacet.sol";
import {TimelockFacet} from "../../contracts/smartAccounts/facets/TimelockFacet.sol";
import {VaultsFacet} from "../../contracts/smartAccounts/facets/VaultsFacet.sol";
import {XrplProviderWalletsFacet} from "../../contracts/smartAccounts/facets/XrplProviderWalletsFacet.sol";

contract FacetsDeploy is Test {
    address private constant SINGLETON_FACTORY = 0xce0042B868300000d44A59004Da54A005ffdcf9f;

    constructor() {
        MockSingletonFactory mockFactory = new MockSingletonFactory();
        vm.etch(SINGLETON_FACTORY, address(mockFactory).code);
    }


    function deployBaseFacets() internal returns (IDiamond.FacetCut[] memory) {
        IDiamond.FacetCut[] memory baseCuts = new IDiamond.FacetCut[](3);
        bytes memory bytecode = abi.encodePacked(
            type(DiamondCutFacet).creationCode
        );
        address diamondCutFacet = IISingletonFactory(SINGLETON_FACTORY).deploy(bytecode, 0);
        baseCuts[0] = _buildFacetCut(diamondCutFacet, "DiamondCutFacet", IDiamond.FacetCutAction.Add);

        bytecode = abi.encodePacked(
            type(DiamondLoupeFacet).creationCode
        );
        address diamondLoupeFacet = IISingletonFactory(SINGLETON_FACTORY).deploy(bytecode, 0);
        baseCuts[1] = _buildFacetCut(diamondLoupeFacet, "DiamondLoupeFacet", IDiamond.FacetCutAction.Add);

        bytecode = abi.encodePacked(
            type(OwnershipFacet).creationCode
        );
        address ownershipFacet = IISingletonFactory(SINGLETON_FACTORY).deploy(bytecode, 0);
        baseCuts[2] = _buildFacetCut(ownershipFacet, "OwnershipFacet", IDiamond.FacetCutAction.Add);

        return baseCuts;
    }

    function deploySmartAccountsFacets() internal returns (IDiamond.FacetCut[] memory) {
        IDiamond.FacetCut[] memory diamondCuts = new IDiamond.FacetCut[](10);

        diamondCuts[0] = _buildFacetCut(
            address(new AgentVaultsFacet()), "AgentVaultsFacet", IDiamond.FacetCutAction.Add
        );
        diamondCuts[1] = _buildFacetCut(
            address(new ExecutorsFacet()), "ExecutorsFacet", IDiamond.FacetCutAction.Add
        );
        diamondCuts[2] = _buildFacetCut(
            address(new InstructionFeesFacet()), "InstructionFeesFacet", IDiamond.FacetCutAction.Add
        );
        diamondCuts[3] = _buildFacetCut(
            address(new InstructionsFacet()), "InstructionsFacet", IDiamond.FacetCutAction.Add
        );
        diamondCuts[4] = _buildFacetCut(
            address(new PaymentProofsFacet()), "PaymentProofsFacet", IDiamond.FacetCutAction.Add
        );
        diamondCuts[5] = _buildFacetCut(
            address(new PersonalAccountsFacet()), "PersonalAccountsFacet", IDiamond.FacetCutAction.Add
        );
        diamondCuts[6] = _buildFacetCut(
            address(new SwapFacet()), "SwapFacet", IDiamond.FacetCutAction.Add
        );
        diamondCuts[7] = _buildFacetCut(
            address(new TimelockFacet()), "TimelockFacet", IDiamond.FacetCutAction.Add
        );
        diamondCuts[8] = _buildFacetCut(
            address(new VaultsFacet()), "VaultsFacet", IDiamond.FacetCutAction.Add
        );
        diamondCuts[9] = _buildFacetCut(
            address(new XrplProviderWalletsFacet()), "XrplProviderWalletsFacet", IDiamond.FacetCutAction.Add
        );
        return diamondCuts;
    }

    function _buildFacetCut(
        address _facetAddr,
        string memory _facetName,
        IDiamond.FacetCutAction _action
    )
        internal
        returns (IDiamond.FacetCut memory)
    {
        string[] memory cmds = new string[](3);
        // cmds[0] = "bash";
        // cmds[1] = "scripts/master-controller-selectors.sh";
        cmds[0] = "node";
        cmds[1] = "scripts/master-controller-selectors.js";
        cmds[2] = _facetName;
        bytes memory out = vm.ffi(cmds);
        bytes4[] memory selectors = abi.decode(out, (bytes4[]));
        return IDiamond.FacetCut({
            facetAddress: _facetAddr,
            action: _action,
            functionSelectors: selectors
        });
    }

}