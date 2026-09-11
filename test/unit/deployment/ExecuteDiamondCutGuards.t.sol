// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {ExecuteDiamondCutHarness} from "../../utils/ExecuteDiamondCutHarness.sol";
import {PinnedControllerInitCode} from "../../../deployment/lib/PinnedControllerInitCode.sol";
import {MockSingletonFactory} from "../../../contracts/mock/MockSingletonFactory.sol";
import {ExecuteDiamondCut} from "../../../deployment/scripts/ExecuteDiamondCut.s.sol";

/**
 * @title ExecuteDiamondCutGuardsTest
 * @notice The cut executor turns facet and initializer names into artifact paths, so a path
 * alias (`./OwnershipFacet`) or a case alias (`ownershipfacet`, on a case-insensitive
 * filesystem) resolves the same artifact while evading the exact-match pinned branch. These
 * tests pin the guards' accept/reject behavior. They cover the two pinned-bootstrap guards as
 * well: on a loan chain the cut may only target the pinned controller, and a pinned base facet
 * is cut at its pinned address only while the live code is the production runtime.
 */
contract ExecuteDiamondCutGuardsTest is Test {
    uint256 private constant ETHEREUM = 1;
    uint256 private constant SEPOLIA = 11155111;
    uint256 private constant COSTON2 = 114;
    address private constant STRANGER = 0x00000000000000000000000000000000DeaDBeef;

    ExecuteDiamondCutHarness private harness;
    ExecuteDiamondCut private executor;

    function setUp() public {
        harness = new ExecuteDiamondCutHarness();
        executor = new ExecuteDiamondCut();
    }

    function testTheExecutorItselfRefusesACutAimedAtAnotherDiamond() public {
        // the entry point, not the guard alone: a cut file naming another diamond must not get
        // past `run()` on a loan chain, whatever else the file says
        vm.chainId(SEPOLIA);
        vm.expectRevert(bytes("the loan-chain cut target must be the pinned MasterAccountController"));
        executor.run("sepolia", "refused-wrong-target", false);
    }

    function testTheExecutorItselfRefusesAPinnedFacetWithoutItsProductionRuntime() public {
        // likewise through `run()`: with nothing at the pinned address - a loan chain whose
        // bootstrap has not run - the cut stops instead of cutting an empty facet in
        vm.chainId(SEPOLIA);
        vm.expectRevert(bytes("OwnershipFacet: on-chain code does not match the pinned historical runtime"));
        executor.run("sepolia", "refused-pin-without-runtime", false);
    }

    function testTheCutTargetIsPinnedOnEveryLoanChain() public {
        // Sepolia reproduces Ethereum's controller at the same address, so the same rule holds
        // there: a cut file naming another diamond is refused before anything is deployed
        uint256[2] memory loan = [ETHEREUM, SEPOLIA];
        for (uint256 i = 0; i < loan.length; i++) {
            vm.chainId(loan[i]);
            vm.expectRevert(bytes("the loan-chain cut target must be the pinned MasterAccountController"));
            harness.requirePermittedCutTarget(STRANGER);
            harness.requirePermittedCutTarget(PinnedControllerInitCode.MASTER_ACCOUNT_CONTROLLER);
        }
        // a Flare-family chain has no pinned controller: its cut file names its own diamond
        vm.chainId(COSTON2);
        harness.requirePermittedCutTarget(STRANGER);
    }

    function testEveryPinnedFacetIsCutAtItsPinnedAddressOnlyWithTheProductionRuntime() public {
        // all three base facets are pinned as a set, so each is driven here: dropping any one
        // mapping would send that facet down the generic path, where current source would deploy
        // a replacement over the bootstrap's own
        string[3] memory names = ["DiamondCutFacet", "DiamondLoupeFacet", "OwnershipFacet"];
        address[3] memory pinnedAddresses = [
            PinnedControllerInitCode.DIAMOND_CUT_FACET,
            PinnedControllerInitCode.DIAMOND_LOUPE_FACET,
            PinnedControllerInitCode.OWNERSHIP_FACET
        ];
        uint256[2] memory loan = [ETHEREUM, SEPOLIA];
        for (uint256 i = 0; i < names.length; i++) {
            bytes memory reason =
                bytes(string.concat(names[i], ": on-chain code does not match the pinned historical runtime"));
            // with nothing at the pinned address - a fresh Sepolia before the bootstrap - the cut
            // stops on both loan chains rather than cutting an empty facet in
            for (uint256 j = 0; j < loan.length; j++) {
                vm.chainId(loan[j]);
                vm.expectRevert(reason);
                harness.pinnedFacetAddress(names[i]);
            }
            // and code that is merely present is not the pinned runtime: the comparison is the
            // hash, so a facet of the right shape at the right address is still refused
            vm.etch(pinnedAddresses[i], hex"6080604052348015600e575f80fd5b50");
            vm.expectRevert(reason);
            harness.pinnedFacetAddress(names[i]);
            vm.etch(pinnedAddresses[i], hex"");
        }
        // with the production runtime there, each facet is cut at its own pinned address. The
        // bytes are the pinned init code deployed through a CREATE2 factory at the singleton
        // address, so the runtime is the production one rather than a stand-in
        vm.etch(PinnedControllerInitCode.SINGLETON_FACTORY, type(MockSingletonFactory).runtimeCode);
        vm.chainId(SEPOLIA);
        for (uint256 i = 0; i < names.length; i++) {
            MockSingletonFactory(PinnedControllerInitCode.SINGLETON_FACTORY).deploy(
                vm.parseBytes(
                    vm.readFile(string.concat(PinnedControllerInitCode.INIT_CODE_DIR, names[i], ".hex"))
                ),
                PinnedControllerInitCode.SALT
            );
            (address addr, bool isPinned) = harness.pinnedFacetAddress(names[i]);
            assertTrue(isPinned, string.concat(names[i], " is a pinned base facet"));
            assertEq(addr, pinnedAddresses[i], string.concat(names[i], " is cut at its pinned address"));
        }
        // an ordinary facet is never pinned, on any chain
        (, bool ordinary) = harness.pinnedFacetAddress("SubaccountsFacet");
        assertFalse(ordinary, "an ordinary facet takes the generic path");
        // and on a Flare-family chain nothing is pinned, so the names go the generic way too
        vm.chainId(COSTON2);
        for (uint256 i = 0; i < names.length; i++) {
            (, bool onFlare) = harness.pinnedFacetAddress(names[i]);
            assertFalse(onFlare, "the pins are a loan-chain rule");
        }
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
        harness.validateFacetName("SubaccountsFacet");
        harness.validateFacetName("ComposeTransportFacet");
        harness.validateFacetName("MorphoLoanMarketsFacet");
        harness.validateFacetName("_Facet123");
        // the canonical spellings are valid facet names: they take the pinned branch
        harness.validateFacetName("DiamondCutFacet");
        harness.validateFacetName("DiamondLoupeFacet");
        harness.validateFacetName("OwnershipFacet");
    }
}
