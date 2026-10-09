// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {FacetsDeploy} from "../../utils/FacetsDeploy.t.sol";
import {IDiamond} from "../../../contracts/diamond/interfaces/IDiamond.sol";
import {IDiamondCut} from "../../../contracts/diamond/interfaces/IDiamondCut.sol";
import {IDiamondLoupe} from "../../../contracts/diamond/interfaces/IDiamondLoupe.sol";
import {IERC165} from "../../../contracts/diamond/interfaces/IERC165.sol";
import {IERC173} from "../../../contracts/diamond/interfaces/IERC173.sol";
import {DiamondArgs} from "../../../contracts/diamond/implementation/Diamond.sol";
import {MasterAccountController} from "../../../contracts/smartAccounts/implementation/MasterAccountController.sol";
import {EthereumControllerInit} from "../../../contracts/smartAccounts/facets/EthereumControllerInit.sol";
import {PersonalAccountsFacet} from "../../../contracts/smartAccounts/facets/PersonalAccountsFacet.sol";
import {IPersonalAccountsFacet} from "../../../contracts/userInterfaces/facets/IPersonalAccountsFacet.sol";
import {IBeacon} from "@openzeppelin/contracts/proxy/beacon/IBeacon.sol";

/**
 * @title EthereumControllerInitTest
 * @notice The loan-chain cut's init: `MasterAccountControllerInit` is Flare-specific and is
 * skipped there, so the ERC-165 flags - and nothing else - are set by
 * {EthereumControllerInit}.
 */
contract EthereumControllerInitTest is Test, FacetsDeploy {

    address private initialOwner;

    function setUp() public {
        initialOwner = makeAddr("initialOwner");
    }

    function testInitRegistersTheErc165Flags() public {
        address diamond = _deployWithEthereumInit();

        assertTrue(IERC165(diamond).supportsInterface(type(IERC165).interfaceId));
        assertTrue(IERC165(diamond).supportsInterface(type(IDiamondCut).interfaceId));
        assertTrue(IERC165(diamond).supportsInterface(type(IDiamondLoupe).interfaceId));
        assertTrue(IERC165(diamond).supportsInterface(type(IERC173).interfaceId));
        // nothing beyond the four: an unrelated id must still answer false
        assertFalse(IERC165(diamond).supportsInterface(type(IPersonalAccountsFacet).interfaceId));
        assertEq(IERC173(diamond).owner(), initialOwner);
    }

    function testInitWritesNoAccountState() public {
        // the Personal Account beacon and each type's implementation stay unset: they are
        // timelocked governance calls made after the cut, never init writes
        address diamond = _deployWithEthereumInit();
        IDiamond.FacetCut[] memory cut = new IDiamond.FacetCut[](1);
        cut[0] = _buildFacetCut(
            address(new PersonalAccountsFacet()),
            "PersonalAccountsFacet",
            IDiamond.FacetCutAction.Add
        );
        vm.prank(initialOwner);
        IDiamondCut(diamond).diamondCut(cut, address(0), "");

        assertEq(IBeacon(diamond).implementation(), address(0));
    }

    function _deployWithEthereumInit() private returns (address) {
        DiamondArgs memory args = DiamondArgs({
            owner: initialOwner,
            initAddress: address(new EthereumControllerInit()),
            initCalldata: abi.encodeCall(EthereumControllerInit.init, ())
        });
        return address(new MasterAccountController(deployBaseFacets(), args));
    }
}
