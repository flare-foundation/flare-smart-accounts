// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {DeployRemoteAccountImplementationsHarness} from
    "../../utils/DeployRemoteAccountImplementationsHarness.sol";
import {MorphoLoanSubaccountRemote} from
    "../../../contracts/smartAccounts/implementation/MorphoLoanSubaccountRemote.sol";
import {
    PersonalAccountRemote
} from "../../../contracts/smartAccounts/implementation/PersonalAccountRemote.sol";

/**
 * @title DeployRemoteAccountImplementationsTest
 * @notice What the run deploys for a given list of names, and what it announces. The list comes
 * from the preflight, which drops an implementation whose recorded address already carries this
 * code, so the script has to honour it exactly: deploying one the caller left out replaces a record
 * other tooling resolves through and buys a pointless timelocked re-registration, while skipping
 * one that was named leaves the operator believing an upgrade happened. The announcement matters
 * as much, because the recorder writes one record entry per `DEPLOYED:` line.
 *
 * Names rather than a flag each is the interface under test as much as the behavior: more
 * subaccount types are expected, and every one of them must be addressable without moving an
 * argument that already exists.
 *
 * The chain-family and staging guards are in `DeployNetworkGuards`, with the other deploy scripts'.
 */
contract DeployRemoteAccountImplementationsTest is Test {
    uint256 private constant SEPOLIA = 11155111;
    uint256 private constant DEPLOYER_KEY = 1;
    string private constant PERSONAL_ACCOUNT = "PersonalAccountRemote";
    string private constant LOAN_SUBACCOUNT = "MorphoLoanSubaccountRemote";

    DeployRemoteAccountImplementationsHarness private script;

    function setUp() public {
        vm.setEnv("DEPLOYER_PRIVATE_KEY", "1");
        script = new DeployRemoteAccountImplementationsHarness();
        vm.chainId(SEPOLIA);
    }

    function testEveryNamedImplementationIsDeployed() public {
        assertEq(_created(_names([PERSONAL_ACCOUNT, LOAN_SUBACCOUNT])), 2, "both were named");
        _assertAnnounced(0, "PersonalAccountRemoteImplementation", "PersonalAccountRemote.sol",
            type(PersonalAccountRemote).runtimeCode);
        _assertAnnounced(1, "MorphoLoanSubaccountRemoteImplementation", "MorphoLoanSubaccountRemote.sol",
            type(MorphoLoanSubaccountRemote).runtimeCode);
    }

    function testOnlyThePersonalAccountIsDeployedWhenOnlyItIsNamed() public {
        // the case a selection alone cannot express: the loan subaccount is unchanged, so the
        // preflight drops it, and redeploying it here would move a record nobody asked to move
        assertEq(_created(_names([PERSONAL_ACCOUNT])), 1, "one was named");
        _assertAnnounced(0, "PersonalAccountRemoteImplementation", "PersonalAccountRemote.sol",
            type(PersonalAccountRemote).runtimeCode);
        assertFalse(
            script.printed("DEPLOYED: MorphoLoanSubaccountRemoteImplementation"),
            "announcing one this run did not deploy would have the recorder rewrite its entry"
        );
    }

    function testOnlyTheLoanSubaccountIsDeployedWhenOnlyItIsNamed() public {
        assertEq(_created(_names([LOAN_SUBACCOUNT])), 1, "one was named");
        _assertAnnounced(0, "MorphoLoanSubaccountRemoteImplementation", "MorphoLoanSubaccountRemote.sol",
            type(MorphoLoanSubaccountRemote).runtimeCode);
        assertFalse(
            script.printed("DEPLOYED: PersonalAccountRemoteImplementation"),
            "announcing one this run did not deploy would have the recorder rewrite its entry"
        );
    }

    function testTheNamesAreTakenInTheOrderGiven() public {
        // the deployed addresses depend on the deployer's nonce, so the order the preflight chose
        // has to be the order the run takes; a set would make it arbitrary
        script.run("sepolia", false, _names([LOAN_SUBACCOUNT, PERSONAL_ACCOUNT]));
        assertEq(script.lineCount(), 3, "the network and one line per deployment");
        _assertAnnounced(0, "MorphoLoanSubaccountRemoteImplementation", "MorphoLoanSubaccountRemote.sol",
            type(MorphoLoanSubaccountRemote).runtimeCode);
        _assertAnnounced(1, "PersonalAccountRemoteImplementation", "PersonalAccountRemote.sol",
            type(PersonalAccountRemote).runtimeCode);
    }

    function testAnEmptyListDeploysNothingAtAll() public {
        // the preflight's answer when nothing has changed. A legitimate run rather than an error:
        // it must cost no deployment instead of refusing, or an operator would be pushed into a
        // redeploy to get past it
        assertEq(_created(new string[](0)), 0, "nothing was named");
        assertFalse(script.printed("DEPLOYED:"), "nothing was deployed, so nothing is recordable");
        assertTrue(script.printed("NOTHING TO DEPLOY:"));
    }

    function testARunThatDeploysNothingStillNamesTheNetwork() public {
        // silence would read as a run that never started, and the operator would try again
        script.run("sepolia", false, new string[](0));
        assertTrue(script.printed("NETWORK: sepolia"));
        assertEq(script.lineCount(), 2, "the network and the reason, and nothing else");
    }

    function testTheNetworkIsNamedOnEveryRun() public {
        // the name says which chain the deployment landed on, so it is not conditional on what the
        // run turned out to do
        script.run("sepolia", false, _names([PERSONAL_ACCOUNT]));
        assertTrue(_startsWith(script.lines(0), "NETWORK: sepolia"));
    }

    function testANameTheScriptCannotDeployIsRefused() public {
        // carrying on would deploy a shorter list than the caller asked for and report success,
        // which is how an implementation gets left behind by a typo
        vm.expectRevert(
            bytes("not a remote implementation this script can deploy: PersonalAccount")
        );
        script.run("sepolia", false, _names(["PersonalAccount"]));
    }

    function testAnUnknownNameStopsTheRunBeforeTheOnesAfterIt() public {
        // the refusal is not a warning to be collected at the end: an implementation deployed
        // beside a refused one leaves a contract on chain that no record will ever name
        address deployer = vm.addr(DEPLOYER_KEY);
        uint256 before = vm.getNonce(deployer);
        vm.expectRevert(bytes("not a remote implementation this script can deploy: LoanSubaccount"));
        script.run("sepolia", false, _names(["LoanSubaccount", PERSONAL_ACCOUNT]));
        assertEq(vm.getNonce(deployer), before, "nothing was deployed");
    }

    /// @dev Contracts created by the run: under a broadcast the deployer's nonce moves per `new`.
    function _created(
        string[] memory _contracts
    )
        private
        returns (uint256)
    {
        address deployer = vm.addr(DEPLOYER_KEY);
        uint256 before = vm.getNonce(deployer);
        script.run("sepolia", false, _contracts);
        return vm.getNonce(deployer) - before;
    }

    /**
     * @dev Asserts the nth announcement (the network line is the 0th, so `_deployment` counts from
     * the first `DEPLOYED:`): its record name, its source file and the runtime actually at the
     * address it names. Names and counts alone would pass while the dispatch deployed the wrong
     * contract under the right label, which is the one mistake this script can make that every
     * later check inherits - the recorder writes that address under that name, and the registration
     * follows it.
     */
    function _assertAnnounced(
        uint256 _deployment,
        string memory _recordName,
        string memory _sourceFile,
        bytes memory _expectedRuntime
    )
        private view
    {
        string memory line = script.lines(_deployment + 1);
        assertTrue(
            _startsWith(line, string.concat("DEPLOYED: ", _recordName, ", ", _sourceFile, ": ")),
            string.concat("the announcement does not name ", _recordName, " from ", _sourceFile)
        );
        address deployed = vm.parseAddress(_tail(line, 42));
        assertEq(
            keccak256(deployed.code),
            keccak256(_expectedRuntime),
            string.concat("the address announced as ", _recordName, " does not carry its code")
        );
    }

    function _names(
        string[1] memory _one
    )
        private pure
        returns (string[] memory)
    {
        string[] memory names = new string[](1);
        names[0] = _one[0];
        return names;
    }

    function _names(
        string[2] memory _two
    )
        private pure
        returns (string[] memory)
    {
        string[] memory names = new string[](2);
        names[0] = _two[0];
        names[1] = _two[1];
        return names;
    }

    /// @dev The last `_length` characters of `_line`: the announcement ends with the address.
    function _tail(
        string memory _line,
        uint256 _length
    )
        private pure
        returns (string memory)
    {
        bytes memory line = bytes(_line);
        require(line.length >= _length, "line shorter than the tail asked for");
        bytes memory tail = new bytes(_length);
        for (uint256 i = 0; i < _length; i++) {
            tail[i] = line[line.length - _length + i];
        }
        return string(tail);
    }

    function _startsWith(
        string memory _line,
        string memory _prefix
    )
        private pure
        returns (bool)
    {
        bytes memory line = bytes(_line);
        bytes memory prefix = bytes(_prefix);
        if (line.length < prefix.length) {
            return false;
        }
        for (uint256 i = 0; i < prefix.length; i++) {
            if (line[i] != prefix[i]) {
                return false;
            }
        }
        return true;
    }
}
