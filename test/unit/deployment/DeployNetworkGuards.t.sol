// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {DeployNetworks} from "../../../deployment/scripts/DeployNetworks.sol";
import {DeployLoanSubaccountImplementation} from
    "../../../deployment/scripts/DeployLoanSubaccountImplementation.s.sol";
import {DeployPersonalAccountImplementation} from
    "../../../deployment/scripts/DeployPersonalAccountImplementation.s.sol";
import {DeployRemoteAccountImplementations} from
    "../../../deployment/scripts/DeployRemoteAccountImplementations.s.sol";

/**
 * @title DeployNetworkGuardsTest
 * @notice Each implementation deploy script allows its own chain family and a declared local
 * run, and nothing else. What that rules out: a guard keyed to a single chain id would let the
 * Flare-side implementations deploy - and be recorded as legitimate artifacts - on Sepolia or
 * any other loan chain, where they would run Flare's logic over every remote account. The
 * family sets live in one library so the scripts cannot drift apart.
 */
contract DeployNetworkGuardsTest is Test {
    uint256 private constant ETHEREUM = 1;
    uint256 private constant SEPOLIA = 11155111;
    uint256 private constant FLARE = 14;
    uint256 private constant SONGBIRD = 19;
    uint256 private constant COSTON = 16;
    uint256 private constant COSTON2 = 114;
    /// @dev anvil's default: a local chain in neither family, which a guard admits only when the
    /// wrapper declares `scdev`.
    uint256 private constant LOCAL = 31337;

    DeployLoanSubaccountImplementation private loanScript;
    DeployPersonalAccountImplementation private personalAccountScript;
    DeployRemoteAccountImplementations private remoteScript;

    function setUp() public {
        // the scripts read the deployer key before anything else
        vm.setEnv("DEPLOYER_PRIVATE_KEY", "1");
        loanScript = new DeployLoanSubaccountImplementation();
        personalAccountScript = new DeployPersonalAccountImplementation();
        remoteScript = new DeployRemoteAccountImplementations();
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
        // to get through on a chain it belongs on, not only on the unnamed local one
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

    function testADeclaredLocalRunPassesEveryGuard() public {
        // the one exception: a development chain has no fixed id, so a guard admits an unknown
        // chain only because the wrapper declared `scdev` - and only under that name
        vm.chainId(LOCAL);
        loanScript.run("scdev", false);
        personalAccountScript.run("scdev", false);
        remoteScript.run("scdev", false);
    }

    function testAKnownChainDeclaredLocalIsRefusedByName() public {
        // the declaration opens only the family guard; the name check still holds the RPC's chain
        // to the wrapper's name, so `scdev` cannot run a script on a known chain - not one of the
        // other family, which the guard let through on the declaration, and not one of its own
        uint256[6] memory known = [FLARE, SONGBIRD, COSTON, COSTON2, ETHEREUM, SEPOLIA];
        for (uint256 i = 0; i < known.length; i++) {
            vm.chainId(known[i]);
            bytes memory reason = bytes(
                string.concat("RPC chain is ", DeployNetworks.networkName(known[i]), ", not the named network scdev")
            );
            vm.expectRevert(reason);
            loanScript.run("scdev", false);
            vm.expectRevert(reason);
            personalAccountScript.run("scdev", false);
            vm.expectRevert(reason);
            remoteScript.run("scdev", false);
        }
    }

    function testAnUndeclaredUnknownChainIsRefusedByTheGuardItself() public {
        // the property the allow-list form buys: an unknown chain that nobody declared local is
        // refused for its family, before the name check gets to disagree about the name
        vm.chainId(LOCAL);
        vm.expectRevert(bytes("the Flare-side loan implementation belongs on a Flare-family chain"));
        loanScript.run("coston2", false);
        vm.expectRevert(bytes("the Flare Personal Account belongs on a Flare-family chain"));
        personalAccountScript.run("flare", false);
        vm.expectRevert(bytes("remote implementations belong on a loan chain"));
        remoteScript.run("ethereum", false);
    }

    function testTheGuardFiresBeforeTheNetworkNameIsChecked() public {
        // a wrong family is refused for being the wrong family, not for a name mismatch, so
        // the wrapper's network argument cannot talk the script past it
        vm.chainId(SEPOLIA);
        vm.expectRevert(bytes("the Flare-side loan implementation belongs on a Flare-family chain"));
        loanScript.run("coston2", false);
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
        assertFalse(DeployNetworks.isFlareFamily(LOCAL), "a local chain is in neither family");
        assertFalse(DeployNetworks.isLoanChain(LOCAL), "a local chain is in neither family");
    }

    function testEveryKnownIdHasItsOwnName() public pure {
        assertEq(DeployNetworks.networkName(FLARE), "flare");
        assertEq(DeployNetworks.networkName(SONGBIRD), "songbird");
        assertEq(DeployNetworks.networkName(COSTON), "coston");
        assertEq(DeployNetworks.networkName(COSTON2), "coston2");
        assertEq(DeployNetworks.networkName(ETHEREUM), "ethereum");
        // a known id must never fall through to the local name: the local record is the one
        // file that is gitignored and exempt from the replacement guard
        assertEq(DeployNetworks.networkName(SEPOLIA), "sepolia");
        assertEq(DeployNetworks.networkName(LOCAL), "scdev");
    }
}
