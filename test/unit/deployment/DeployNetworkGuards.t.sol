// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {DeployComposer} from "../../../deployment/scripts/DeployComposer.s.sol";
import {DeployNetworks} from "../../../deployment/scripts/DeployNetworks.sol";
import {DeployLoanSubaccountImplementation} from
    "../../../deployment/scripts/DeployLoanSubaccountImplementation.s.sol";
import {DeployPersonalAccountImplementation} from
    "../../../deployment/scripts/DeployPersonalAccountImplementation.s.sol";
import {DeployRemoteAccountImplementations} from
    "../../../deployment/scripts/DeployRemoteAccountImplementations.s.sol";

/**
 * @title DeployNetworkGuardsTest
 * @notice Each deploy script allows its own chain family and nothing else. What
 * that rules out: a guard keyed to a single chain id would let the Flare-side implementations
 * deploy - and be recorded as legitimate artifacts - on Sepolia or any other loan chain, where
 * they would run Flare's logic over every remote account; and a chain in neither family, which
 * nothing here knows how to record, is refused whatever the wrapper called it. The family sets
 * live in one library so the scripts cannot drift apart.
 */
contract DeployNetworkGuardsTest is Test {
    uint256 private constant ETHEREUM = 1;
    uint256 private constant SEPOLIA = 11155111;
    uint256 private constant FLARE = 14;
    uint256 private constant SONGBIRD = 19;
    uint256 private constant COSTON = 16;
    uint256 private constant COSTON2 = 114;
    /// @dev anvil's default: a chain in neither family, which no guard admits under any name.
    uint256 private constant UNKNOWN = 31337;

    DeployLoanSubaccountImplementation private loanScript;
    DeployPersonalAccountImplementation private personalAccountScript;
    DeployRemoteAccountImplementations private remoteScript;
    DeployComposer private composerScript;

    /// @dev an external seam, so `expectRevert` can watch the library's own revert
    function nameOf(
        uint256 _chainId
    )
        external pure
        returns (string memory)
    {
        return DeployNetworks.networkName(_chainId);
    }

    function setUp() public {
        // the scripts read the deployer key before anything else
        vm.setEnv("DEPLOYER_PRIVATE_KEY", "1");
        loanScript = new DeployLoanSubaccountImplementation();
        personalAccountScript = new DeployPersonalAccountImplementation();
        remoteScript = new DeployRemoteAccountImplementations();
        composerScript = new DeployComposer();
    }

    function testHomeImplementationsRefuseEveryLoanChain() public {
        // Ethereum for the pinned bootstrap's sake, Sepolia as a loan chain: a guard keyed to
        // Ethereum alone would deploy both home implementations there
        uint256[2] memory loan = [ETHEREUM, SEPOLIA];
        for (uint256 i = 0; i < loan.length; i++) {
            vm.chainId(loan[i]);
            string memory name = DeployNetworks.networkName(loan[i]);
            vm.expectRevert(bytes("the Flare-side loan implementation belongs on a Flare-family chain"));
            loanScript.run(name, false);
            vm.expectRevert(bytes("the Flare Personal Account belongs on a Flare-family chain"));
            personalAccountScript.run(name, false);
        }
        // DeploySmartAccounts carries the same guard; its cases live in DeploySmartAccountsGuards,
        // because that script only compiles under via-IR and coverage would otherwise refuse
        // this whole file
    }

    function testEachScriptRunsOnItsOwnFamily() public {
        // the refusals above would also pass a guard that refused everything; each script has
        // to get through on a chain it belongs on
        vm.chainId(COSTON2);
        loanScript.run("coston2", false);
        personalAccountScript.run("coston2", false);
        vm.chainId(ETHEREUM);
        remoteScript.run("ethereum", false);
        vm.chainId(SEPOLIA);
        remoteScript.run("sepolia", false);
    }

    function testAWrongNetworkNameIsRefusedOnAPermittedChain() public {
        // the family guard is the first gate and the RPC-versus-name check the second; a chain
        // the script belongs on must still be refused when the wrapper named a different one,
        // or a mis-set RPC variable would retarget the whole flow silently
        vm.chainId(COSTON2);
        vm.expectRevert(bytes("RPC chain is coston2, not the named network flare"));
        loanScript.run("flare", false);
        vm.expectRevert(bytes("RPC chain is coston2, not the named network songbird"));
        personalAccountScript.run("songbird", false);
        vm.chainId(ETHEREUM);
        vm.expectRevert(bytes("RPC chain is ethereum, not the named network sepolia"));
        remoteScript.run("sepolia", false);
    }

    function testRemoteImplementationsRefuseEveryFlareFamilyChain() public {
        uint256[4] memory flare = [FLARE, SONGBIRD, COSTON, COSTON2];
        for (uint256 i = 0; i < flare.length; i++) {
            vm.chainId(flare[i]);
            vm.expectRevert(bytes("remote implementations belong on a loan chain"));
            remoteScript.run(DeployNetworks.networkName(flare[i]), false);
        }
    }

    function testAnUnknownChainIsRefusedByEveryGuardUnderAnyName() public {
        // a chain in neither family has no record, chain config or cut directory here, so no
        // name the wrapper passes can open a guard for it - a local-development name included:
        // there is deliberately no such network, and a rehearsal forks a real chain under its name
        vm.chainId(UNKNOWN);
        vm.expectRevert(bytes("the Flare-side loan implementation belongs on a Flare-family chain"));
        loanScript.run("coston2", false);
        vm.expectRevert(bytes("the Flare-side loan implementation belongs on a Flare-family chain"));
        loanScript.run("scdev", false);
        vm.expectRevert(bytes("the Flare Personal Account belongs on a Flare-family chain"));
        personalAccountScript.run("flare", false);
        vm.expectRevert(bytes("the Flare Personal Account belongs on a Flare-family chain"));
        personalAccountScript.run("scdev", false);
        vm.expectRevert(bytes("remote implementations belong on a loan chain"));
        remoteScript.run("ethereum", false);
        vm.expectRevert(bytes("remote implementations belong on a loan chain"));
        remoteScript.run("scdev", false);
        vm.expectRevert(bytes("the composer belongs on a Flare-family chain"));
        composerScript.run("coston2", true);
        vm.expectRevert(bytes("the composer belongs on a Flare-family chain"));
        composerScript.run("scdev", true);
    }

    function testTheRemoteScriptRefusesAStagingAliasItself() public {
        // the wrappers refuse `ethereum-staging` and `sepolia-staging` first, but a direct forge run
        // reaches the script with `_staging` set; it must not deploy and print a name the recorder
        // then refuses, leaving implementations on chain that no record knows
        uint256[2] memory loan = [ETHEREUM, SEPOLIA];
        for (uint256 i = 0; i < loan.length; i++) {
            vm.chainId(loan[i]);
            vm.expectRevert(bytes("the loan chains have no staging deployment"));
            remoteScript.run(DeployNetworks.networkName(loan[i]), true);
        }
    }

    function testTheComposerIsHeldToTheFlareFamilyAndToItsName() public {
        // the composer is a Flare-side contract with a wrapper that dials the RPC by name: the
        // script refuses the loan chains, and a permitted chain under another name
        vm.chainId(ETHEREUM);
        vm.expectRevert(bytes("the composer belongs on a Flare-family chain"));
        composerScript.run("ethereum", true);
        vm.chainId(COSTON2);
        vm.expectRevert(bytes("RPC chain is coston2, not the named network flare"));
        composerScript.run("flare", true);
        // and gets through on its own chain under its own name, implementations only
        composerScript.run("coston2", true);
    }

    function testTheGuardFiresBeforeTheNetworkNameIsChecked() public {
        // a wrong family is refused for being the wrong family, not for a name mismatch, so
        // the wrapper's network argument cannot talk the script past it
        vm.chainId(SEPOLIA);
        vm.expectRevert(bytes("the Flare-side loan implementation belongs on a Flare-family chain"));
        loanScript.run("coston2", false);
    }

    function testEveryKnownIdHasItsOwnNameAndNoOtherIdHasOne() public {
        assertEq(DeployNetworks.networkName(FLARE), "flare");
        assertEq(DeployNetworks.networkName(SONGBIRD), "songbird");
        assertEq(DeployNetworks.networkName(COSTON), "coston");
        assertEq(DeployNetworks.networkName(COSTON2), "coston2");
        assertEq(DeployNetworks.networkName(ETHEREUM), "ethereum");
        assertEq(DeployNetworks.networkName(SEPOLIA), "sepolia");
        // an unknown id falls through to nothing: a record could not be written for a network
        // without a name, and the id is printed for the operator holding the mis-set RPC variable
        vm.expectRevert(bytes("chain id 31337 is not a known network"));
        this.nameOf(UNKNOWN);
    }

    function testTheTwoFamiliesArePinnedAndDisjoint() public pure {
        // pinned by member, not by iterating the library's own sets: a test that consults the
        // list it is testing loses its case the moment an id is dropped, and silently passes
        uint256[4] memory flare = [FLARE, SONGBIRD, COSTON, COSTON2];
        uint256[2] memory loan = [ETHEREUM, SEPOLIA];
        for (uint256 i = 0; i < flare.length; i++) {
            assertTrue(DeployNetworks.isFlareFamily(flare[i]), "a Flare-family id");
            assertFalse(DeployNetworks.isLoanChain(flare[i]), "is not a loan chain");
        }
        for (uint256 i = 0; i < loan.length; i++) {
            assertTrue(DeployNetworks.isLoanChain(loan[i]), "a loan-chain id");
            assertFalse(DeployNetworks.isFlareFamily(loan[i]), "is not Flare family");
        }
        assertFalse(DeployNetworks.isFlareFamily(UNKNOWN), "an unknown chain is in neither family");
        assertFalse(DeployNetworks.isLoanChain(UNKNOWN), "an unknown chain is in neither family");
    }
}
