// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {ExecuteDiamondCutHarness} from "./ExecuteDiamondCutHarness.sol";

/**
 * @title ExecuteDiamondCutGuardsTest
 * @notice The cut executor turns facet and initializer names into artifact paths, so a path
 * alias (`./OwnershipFacet`) or a case alias (`ownershipfacet`, on a case-insensitive
 * filesystem) resolves the same artifact while evading the exact-match pinned branch. These
 * tests pin the guards' accept/reject behavior.
 */
contract ExecuteDiamondCutGuardsTest is Test {
    ExecuteDiamondCutHarness private harness;

    function setUp() public {
        harness = new ExecuteDiamondCutHarness();
    }

    function testRejectsFacetPathAliases() public {
        vm.expectRevert(bytes("contract names must be Solidity identifiers"));
        harness.validateFacetName("./OwnershipFacet");
        vm.expectRevert(bytes("contract names must be Solidity identifiers"));
        harness.validateFacetName("");
        vm.expectRevert(bytes("contract names must be Solidity identifiers"));
        harness.validateFacetName("Ownership/../CutFacet");
        vm.expectRevert(bytes("contract names must be Solidity identifiers"));
        harness.validateFacetName("1LeadingDigit");
        vm.expectRevert(bytes("contract names must be Solidity identifiers"));
        harness.validateFacetName("Ownership Facet");
    }

    function testRejectsFacetCaseAliasesOfPinnedNames() public {
        vm.expectRevert(bytes("pinned base facet names must use their canonical spelling"));
        harness.validateFacetName("ownershipfacet");
        vm.expectRevert(bytes("pinned base facet names must use their canonical spelling"));
        harness.validateFacetName("DIAMONDCUTFACET");
        vm.expectRevert(bytes("pinned base facet names must use their canonical spelling"));
        harness.validateFacetName("diamondLoupeFacet");
    }

    function testRejectsControllerAsFacetInAnyCasing() public {
        vm.expectRevert(bytes("MasterAccountController is not a facet"));
        harness.validateFacetName("MasterAccountController");
        vm.expectRevert(bytes("MasterAccountController is not a facet"));
        harness.validateFacetName("masteraccountcontroller");
        vm.expectRevert(bytes("MasterAccountController is not a facet"));
        harness.validateFacetName("MASTERACCOUNTCONTROLLER");
    }

    function testRejectsPinnedNamesAsInitInAnyCasing() public {
        vm.expectRevert(bytes("pinned names cannot be used as the init contract"));
        harness.validateInitName("MasterAccountController");
        vm.expectRevert(bytes("pinned names cannot be used as the init contract"));
        harness.validateInitName("DiamondCutFacet");
        vm.expectRevert(bytes("pinned names cannot be used as the init contract"));
        harness.validateInitName("DiamondLoupeFacet");
        vm.expectRevert(bytes("pinned names cannot be used as the init contract"));
        harness.validateInitName("OwnershipFacet");
        vm.expectRevert(bytes("pinned names cannot be used as the init contract"));
        harness.validateInitName("ownershipfacet");
    }

    function testAcceptsOrdinaryInitNames() public {
        // a real initializer passes; a longer name sharing a protected prefix is not an alias
        harness.validateInitName("MasterAccountControllerInit");
        vm.expectRevert(bytes("contract names must be Solidity identifiers"));
        harness.validateInitName("./MasterAccountController");
    }

    function testAcceptsOrdinaryFacetNames() public view {
        harness.validateFacetName("LoanSubaccountsFacet");
        harness.validateFacetName("EthereumLoanSettingsFacet");
        harness.validateFacetName("_Facet123");
        // the canonical spellings are valid facet names: they take the pinned branch
        harness.validateFacetName("DiamondCutFacet");
        harness.validateFacetName("DiamondLoupeFacet");
        harness.validateFacetName("OwnershipFacet");
    }
}
