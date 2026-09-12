// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {FacetsDeploy} from "../../utils/FacetsDeploy.t.sol";
import {TransferOwnershipHarness} from "../../utils/TransferOwnershipHarness.sol";
import {PinnedControllerStub} from "../../utils/PinnedControllerStub.sol";
import {PinnedControllerInitCode} from "../../../deployment/lib/PinnedControllerInitCode.sol";
import {DiamondArgs} from "../../../contracts/diamond/implementation/Diamond.sol";
import {MasterAccountController} from "../../../contracts/smartAccounts/implementation/MasterAccountController.sol";
import {IERC173} from "../../../contracts/diamond/interfaces/IERC173.sol";

/**
 * @title TransferOwnershipGuardsTest
 * @notice The pinned controller's ownership handover, which is the one call of a deployment that
 * cannot be undone: one step, no acceptance from the new owner, no timelock. Every test here is a
 * way of sending it wrongly, and what stops it.
 */
contract TransferOwnershipGuardsTest is Test, FacetsDeploy {
    uint256 private constant SEPOLIA = 11155111;
    uint256 private constant ETHEREUM = 1;
    uint256 private constant COSTON2 = 114;

    TransferOwnershipHarness private harness;
    address private diamond;
    address private owner;

    function setUp() public {
        harness = new TransferOwnershipHarness();
        owner = makeAddr("owner");
        DiamondArgs memory args = DiamondArgs({owner: owner, initAddress: address(0), initCalldata: ""});
        diamond = address(new MasterAccountController(deployBaseFacets(), args));
    }

    function testTheScriptRefusesEveryChainButALoanChain() public {
        // a Flare-family controller is governance-owned: its handover is a multisig transaction,
        // not something a key here could sign
        vm.chainId(COSTON2);
        vm.expectRevert(bytes("the pinned controller lives on a loan chain"));
        harness.run("coston2", "verify", owner, makeAddr("newOwner"));
    }

    function testTheScriptRefusesANetworkNameThatIsNotTheChainItIsPointedAt() public {
        // the wrapper dials the RPC by name while the script reads the chain id: a mismatch means
        // the handover of one chain's diamond is about to be sent to another. Named exactly, since
        // a bare expectation would be satisfied by the missing-controller error further down
        vm.chainId(SEPOLIA);
        vm.expectRevert(bytes("RPC chain is sepolia, not the named network ethereum"));
        harness.run("ethereum", "verify", owner, makeAddr("newOwner"));
    }

    function testTheHandoverIsSentAndReadBackThroughTheEntryPoint() public {
        // the checks above are reached through their own functions; this is the path an operator
        // takes, and what proves the entry point runs the preflight and then the transfer at all
        vm.chainId(SEPOLIA);
        address deployer = vm.addr(1);
        vm.setEnv("DEPLOYER_PRIVATE_KEY", "1");
        _etchPinnedOwner(deployer);
        address safe = address(new PinnedControllerStub());

        harness.run("sepolia", "execute", deployer, safe);
        assertEq(IERC173(PinnedControllerInitCode.MASTER_ACCOUNT_CONTROLLER).owner(), safe);

        // and the phase that proves it, through the same entry point
        harness.run("sepolia", "verify", deployer, safe);
        assertTrue(harness.printed(string.concat("VERIFIED: owner ", vm.toString(safe))));

        // which must fail for an owner the chain does not hold, or it proves nothing
        vm.expectRevert(bytes("the owner on chain is not the one the transfer named"));
        harness.run("sepolia", "verify", deployer, deployer);
    }

    function testTheEntryPointRefusesWhatThePreflightWouldStop() public {
        // the preflight has to be reached BY the entry point: checks it never calls are decoration
        vm.chainId(SEPOLIA);
        vm.setEnv("DEPLOYER_PRIVATE_KEY", "1");
        _etchPinnedOwner(makeAddr("somebody else"));

        vm.expectRevert(bytes("the diamond's owner is not the one named: check the network and the address"));
        harness.run("sepolia", "execute", vm.addr(1), makeAddr("newOwner"));
    }

    function testTheTransferRefusesAnOwnerThatIsNotTheOneNamed() public {
        // the argument is the guard, not a formality: read the owner and proceed, and a run pointed
        // at the wrong network hands away whatever diamond it found
        vm.expectRevert(bytes("the diamond's owner is not the one named: check the network and the address"));
        harness.requireTransferable(diamond, makeAddr("somebodyElse"), makeAddr("newOwner"), owner);
    }

    function testTheTransferRefusesANewOwnerThatWouldEndGovernance() public {
        vm.expectRevert(bytes("the new owner is the zero address: that would end governance"));
        harness.requireTransferable(diamond, owner, address(0), owner);

        vm.expectRevert(bytes("the new owner is the diamond itself: that would end governance"));
        harness.requireTransferable(diamond, owner, diamond, owner);

        // not destructive, but it is not what the operator meant, and a transfer nobody needed is
        // a signal that an address was copied from the wrong line
        vm.expectRevert(bytes("the new owner already owns the diamond: nothing to transfer"));
        harness.requireTransferable(diamond, owner, owner, owner);
    }

    function testTheTransferRefusesASignerThatIsNotTheOwner() public {
        // it would revert on chain anyway; refusing here costs no gas and says which of the two
        // addresses is wrong
        vm.expectRevert(bytes("the signing key is not the diamond's owner"));
        harness.requireTransferable(diamond, owner, makeAddr("newOwner"), makeAddr("stranger"));
    }

    function testAnOrdinaryAccountAsTheNewOwnerIsCalledOutRatherThanRefused() public {
        // a handover to a deployer or a hardware wallet is legitimate; one meant for a multisig and
        // typed a character wrong looks exactly the same, so it is said out loud
        harness.requireTransferable(diamond, owner, makeAddr("newOwner"), owner);
        assertTrue(
            harness.printed("NOTE: the new owner has no code, so it is an ordinary account rather than a contract")
        );

        // a contract as the new owner - the Safe case - passes without the note. Checked on a
        // second harness, since the first has already recorded one
        TransferOwnershipHarness second = new TransferOwnershipHarness();
        second.requireTransferable(diamond, owner, address(second), owner);
        assertFalse(
            second.printed("NOTE: the new owner has no code, so it is an ordinary account rather than a contract")
        );
    }

    function testTheOwnerIsReadBackAfterTheTransfer() public {
        vm.prank(owner);
        IERC173(diamond).transferOwnership(makeAddr("newOwner"));

        harness.requireOwner(diamond, makeAddr("newOwner"));
        assertTrue(harness.printed(string.concat("VERIFIED: owner ", vm.toString(makeAddr("newOwner")))));

        // the read-back is what proves the transfer, so it must fail on the address that did not get it
        vm.expectRevert(bytes("the owner on chain is not the one the transfer named"));
        harness.requireOwner(diamond, owner);
    }

    function testTheScriptRefusesAChainWithNoControllerAtThePinnedAddress() public {
        vm.chainId(ETHEREUM);
        vm.expectRevert(bytes("no controller at the pinned address: run the bootstrap first"));
        harness.run("ethereum", "verify", owner, makeAddr("newOwner"));
    }

    function testTheScriptRefusesAPhaseItDoesNotKnow() public {
        // a name that is not one of the two must not fall through to the phase that sends
        vm.chainId(SEPOLIA);
        vm.etch(PinnedControllerInitCode.MASTER_ACCOUNT_CONTROLLER, hex"00");
        vm.expectRevert(bytes("unknown phase: execute or verify"));
        harness.run("sepolia", "transfer", owner, makeAddr("newOwner"));
    }

    function _etchPinnedOwner(
        address _owner
    )
        private
    {
        vm.etch(PinnedControllerInitCode.MASTER_ACCOUNT_CONTROLLER, address(new PinnedControllerStub()).code);
        PinnedControllerStub(PinnedControllerInitCode.MASTER_ACCOUNT_CONTROLLER).setOwner(_owner);
    }
}
