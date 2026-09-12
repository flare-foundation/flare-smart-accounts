// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {FacetsDeploy} from "../../utils/FacetsDeploy.t.sol";
import {ConfigureRemoteControllerHarness} from "../../utils/ConfigureRemoteControllerHarness.sol";
import {ConfigureRemoteController} from "../../../deployment/scripts/ConfigureRemoteController.s.sol";
import {PinnedControllerInitCode} from "../../../deployment/lib/PinnedControllerInitCode.sol";
import {MockSingletonFactory} from "../../../contracts/mock/MockSingletonFactory.sol";
import {PinnedControllerStub} from "../../utils/PinnedControllerStub.sol";
import {DiamondArgs} from "../../../contracts/diamond/implementation/Diamond.sol";
import {IDiamond} from "../../../contracts/diamond/interfaces/IDiamond.sol";
import {IDiamondCut} from "../../../contracts/diamond/interfaces/IDiamondCut.sol";
import {MasterAccountController} from "../../../contracts/smartAccounts/implementation/MasterAccountController.sol";
import {PauseFacet} from "../../../contracts/smartAccounts/facets/PauseFacet.sol";
import {TimelockFacet} from "../../../contracts/smartAccounts/facets/TimelockFacet.sol";
import {PersonalAccountsFacet} from "../../../contracts/smartAccounts/facets/PersonalAccountsFacet.sol";
import {SubaccountsFacet} from "../../../contracts/smartAccounts/facets/SubaccountsFacet.sol";
import {
    IIPersonalAccountsFacet
} from "../../../contracts/smartAccounts/interface/IIPersonalAccountsFacet.sol";
import {IISubaccountsFacet} from "../../../contracts/smartAccounts/interface/IISubaccountsFacet.sol";
import {IIPauseFacet} from "../../../contracts/smartAccounts/interface/IIPauseFacet.sol";
import {IITimelockFacet} from "../../../contracts/smartAccounts/interface/IITimelockFacet.sol";
import {IPauseFacet} from "../../../contracts/userInterfaces/facets/IPauseFacet.sol";
import {
    IPersonalAccountsFacet
} from "../../../contracts/userInterfaces/facets/IPersonalAccountsFacet.sol";
import {ISubaccountsFacet} from "../../../contracts/userInterfaces/facets/ISubaccountsFacet.sol";
import {ITimelockFacet} from "../../../contracts/userInterfaces/facets/ITimelockFacet.sol";
import {
    IIMorphoLoanMarketsFacet
} from "../../../contracts/smartAccounts/interface/IIMorphoLoanMarketsFacet.sol";
import {
    IIComposeTransportFacet
} from "../../../contracts/smartAccounts/interface/IIComposeTransportFacet.sol";

/**
 * @title ConfigureRemoteControllerGuardsTest
 * @notice The remote controller's configuration script: which chain and which diamond it will touch,
 * what it refuses to send, what calldata it hands governance, and that its read-back reads the chain
 * rather than repeating the file. The Sepolia chain config is used as it ships, so a section that
 * loses a value there is a failing test rather than a silent skip at deployment time.
 */
contract ConfigureRemoteControllerGuardsTest is Test, FacetsDeploy {
    uint256 private constant ETHEREUM = 1;
    uint256 private constant SEPOLIA = 11155111;
    uint256 private constant COSTON2 = 114;
    uint256 private constant DURATION = 3600;
    string private constant ZERO = "0x0000000000000000000000000000000000000000";
    string private constant SOME = "0x1111111111111111111111111111111111111111";
    string private constant GOVERNANCE = "0x7F40b5B310c6CCfd6025D9bFc1FE6dB30aa0741b";

    ConfigureRemoteControllerHarness private harness;
    address private diamond;

    function setUp() public {
        harness = new ConfigureRemoteControllerHarness();
    }

    function testTheScriptRefusesEveryChainButALoanChain() public {
        vm.chainId(COSTON2);
        vm.expectRevert(bytes("the remote controller lives on a loan chain"));
        harness.run("coston2", "prepare", "governance", "pinned");
    }

    function testTheScriptRefusesANetworkNameThatIsNotTheChainItIsPointedAt() public {
        // the wrapper dials the RPC by name while the script reads the chain id: a mismatch means
        // the configuration of one chain is about to be sent to another. Named exactly, since a
        // bare expectation would be satisfied by the missing-controller error further down
        vm.chainId(SEPOLIA);
        vm.expectRevert(bytes("RPC chain is sepolia, not the named network ethereum"));
        harness.run("ethereum", "prepare", "governance", "pinned");
    }

    function testTheScriptRefusesAChainWithNoControllerAtThePinnedAddress() public {
        vm.chainId(SEPOLIA);
        vm.expectRevert(bytes("no controller at the pinned address: run the bootstrap first"));
        harness.run("sepolia", "prepare", "governance", "pinned");
    }

    function testTheScriptRefusesAPhaseItDoesNotKnow() public {
        // a name that is not one of the three must not fall through to a phase that sends something
        vm.chainId(SEPOLIA);
        vm.etch(PinnedControllerInitCode.MASTER_ACCOUNT_CONTROLLER, hex"00");
        vm.expectRevert(bytes("unknown phase: prepare, execute or verify"));
        harness.run("sepolia", "apply", "governance", "pinned");
    }

    function testTheTargetIsNamedByTheCallerAndCheckedToBeWhatItClaims() public {
        // which diamond a run configures is not the script's assumption to make: the pinned
        // controller and the throwaway one are different deployments on the same chain
        vm.chainId(SEPOLIA);
        vm.etch(PinnedControllerInitCode.MASTER_ACCOUNT_CONTROLLER, hex"00");
        assertEq(
            harness.resolveDiamond("sepolia", "pinned"),
            PinnedControllerInitCode.MASTER_ACCOUNT_CONTROLLER
        );

        vm.expectRevert(bytes("unknown target: pinned or throwaway"));
        harness.resolveDiamond("sepolia", "the other one");
    }

    function testAThrowawayTargetIsResolvedFromItsRecordAndHeldToWhatAThrowawayIs() public {
        // driven through the resolver itself, over a record this test writes: the parse and the two
        // guards are what a run depends on, and each has to be reached by the path a run takes
        vm.chainId(SEPOLIA);
        address deployed = address(new MockSingletonFactory());
        string memory path = "deployment/output-internal/configure-remote-controller-record.json";
        // The ignored output directory is absent in clean checkouts.
        vm.createDir("deployment/output-internal", true);
        harness.setThrowawayRecordPath(path);

        vm.writeFile(path, _record(deployed));
        assertEq(harness.resolveDiamond("sepolia", "throwaway"), deployed);

        // a record naming the production controller is not a throwaway record, whatever it says
        vm.writeFile(path, _record(PinnedControllerInitCode.MASTER_ACCOUNT_CONTROLLER));
        vm.expectRevert(bytes("the throwaway record names the pinned controller: it is not a throwaway"));
        harness.resolveDiamond("sepolia", "throwaway");

        // and one naming an address with no code describes a deployment this chain does not have
        vm.writeFile(path, _record(makeAddr("never deployed")));
        vm.expectRevert(bytes("the throwaway record names an address with no code"));
        harness.resolveDiamond("sepolia", "throwaway");

        // a record without the controller at all
        vm.writeFile(
            path,
            string.concat(
                "[{\"name\": \"PauseFacet\", \"contractName\": \"PauseFacet.sol\", \"address\": \"", SOME, "\"}]"
            )
        );
        vm.expectRevert(bytes("the throwaway record holds no MasterAccountController"));
        harness.resolveDiamond("sepolia", "throwaway");

        // and no record at all, which is the state before the deploy has ever run
        vm.removeFile(path);
        vm.expectRevert(bytes("no throwaway record: run deploy_remote_controller_throwaway first"));
        harness.resolveDiamond("sepolia", "throwaway");
    }

    function testTheShippedSepoliaConfigurationIsRead() public view {
        // the file as it ships, so a value dropped from it fails here rather than at a deployment
        ConfigureRemoteController.Configuration memory config = harness.readConfiguration("sepolia");
        assertEq(config.governance, 0x7F40b5B310c6CCfd6025D9bFc1FE6dB30aa0741b);
        assertEq(config.timelockDurationSeconds, DURATION);
        assertEq(config.pausers.length, 0);
        assertEq(config.unpausers.length, 0);
        assertEq(config.subaccountType, 1);
        assertEq(config.transport.lzEndpoint, 0x6EDCE65403992e310A62460808c4b910D972f10f);
        assertEq(config.transport.oft, 0x81672c5d42F3573aD95A0bdfBE824FaaC547d4E6);
        assertEq(config.transport.originEid, 40294);
        // the origin peer is the Flare-side OFT adapter, which is what `setComposeTransport`
        // compares against the remote OFT's `peers(originEid)` - not the controller
        assertEq(
            config.transport.originPeer,
            bytes32(uint256(uint160(0xCd3d2127935Ae82Af54Fc31cCD9D3440dbF46639)))
        );
        assertEq(config.market.marketParams.lltv, 0.77e18);
        // the two the rehearsal has still to deploy
        assertEq(config.market.marketParams.loanToken, address(0));
        assertEq(config.market.marketParams.oracle, address(0));
        // the fee terms, decided 2026-09-11: a 7% floor, a 1% spread, the deployer collecting
        assertEq(config.fees.feeFloor, 0.07e18);
        assertEq(config.fees.feeSpread, 0.01e18);
        assertEq(config.fees.feeRecipient, 0x99E0770aa23CAA9071B6112208297E7a8d8F8a4A);
    }

    function testTheGovernanceSectionIsTheRolesThenTheDurationLast() public {
        ConfigureRemoteController.Configuration memory config = _configuration();
        ConfigureRemoteController.Call[] memory calls = harness.callsFor("governance", config);

        assertEq(calls.length, 3);
        assertEq(calls[0].description, "addPausers");
        assertEq(calls[0].data, abi.encodeCall(IIPauseFacet.addPausers, (config.pausers)));
        assertEq(calls[1].description, "addUnpausers");
        assertEq(calls[1].data, abi.encodeCall(IIPauseFacet.addUnpausers, (config.unpausers)));
        // last, because it is what makes every later timelocked call queue
        assertEq(calls[2].description, "setTimelockDuration");
        assertEq(calls[2].data, abi.encodeCall(IITimelockFacet.setTimelockDuration, (DURATION)));
    }

    function testAnEmptyRoleListProducesNoCallForIt() public {
        // Sepolia ships with both lists empty: a transaction that grants nobody anything is still a
        // transaction somebody has to review, so it is not offered
        ConfigureRemoteController.Configuration memory config = harness.readConfiguration("sepolia");
        ConfigureRemoteController.Call[] memory calls = harness.callsFor("governance", config);
        assertEq(calls.length, 1);
        assertEq(calls[0].description, "setTimelockDuration");
    }

    function testTheWiringSectionsAreOrderedTransportMarketFees() public {
        ConfigureRemoteController.Configuration memory config = _configuration();
        ConfigureRemoteController.Call[] memory calls = harness.callsFor("wiring", config);

        assertEq(calls.length, 3);
        // the transport first: the market validates its collateral token against the transport's OFT
        assertEq(calls[0].description, "setComposeTransport");
        assertEq(calls[1].description, "registerLoanMarket");
        assertEq(
            calls[1].data,
            abi.encodeCall(IIMorphoLoanMarketsFacet.registerLoanMarket, (config.subaccountType, config.market))
        );
        // the fee terms last of all: the first such call is the activation
        assertEq(calls[2].description, "setLoanFeeTerms");
    }

    function testASweepSetsTheDurationAfterTheWiringItAlsoCarries() public {
        // the whole run in one go, which is the throwaway flow: the duration must land after the
        // wiring, or the wiring queues behind it and a run that reports success has configured
        // nothing. The pinned flow runs the sections separately and does want B5 and B6 queued.
        ConfigureRemoteController.Configuration memory config = _configuration();
        ConfigureRemoteController.Call[] memory calls = harness.callsFor("all", config);

        assertEq(calls.length, 6);
        assertEq(calls[0].description, "addPausers");
        assertEq(calls[1].description, "addUnpausers");
        assertEq(calls[2].description, "setComposeTransport");
        assertEq(calls[3].description, "registerLoanMarket");
        assertEq(calls[4].description, "setLoanFeeTerms");
        assertEq(calls[5].description, "setTimelockDuration");
    }

    function testAnIncompleteSectionStopsTheRunWhenItIsNamedAndIsSkippedInASweep() public {
        ConfigureRemoteController.Configuration memory config = harness.readConfiguration("sepolia");

        // named on its own: asking for the market and getting nothing is not an answer
        vm.expectRevert(bytes("the loanMarket section is not filled in"));
        harness.callsFor("market", config);

        // the same config swept: the sections it has are prepared, the market is skipped
        ConfigureRemoteController.Call[] memory calls = harness.callsFor("wiring", config);
        assertEq(calls.length, 2);
        assertEq(calls[0].description, "setComposeTransport");
        assertEq(calls[1].description, "setLoanFeeTerms");
        assertTrue(harness.printed("SKIPPED: the loanMarket section is not filled in"));

        // the fee terms are ready on a recipient rather than on a rate, so that case is driven
        // over a configuration naming none - the shipped one names the deployer
        ConfigureRemoteController.Configuration memory noRecipient =
            harness.parseConfiguration(_configJson(_text()));
        vm.expectRevert(bytes("the loanFeeTerms section names no recipient"));
        harness.callsFor("fees", noRecipient);
        calls = harness.callsFor("wiring", noRecipient);
        assertEq(calls.length, 2);
        assertEq(calls[1].description, "registerLoanMarket");
        assertTrue(harness.printed("SKIPPED: the loanFeeTerms section names no recipient"));
    }

    function testAnIncompleteSectionStopsEveryPhase() public {
        // the readiness rule is not the prepare phase's alone: submitting or verifying a section
        // the config has not been given would report success over a section that does not exist
        _deployDiamond();
        ConfigureRemoteController.Configuration memory config = harness.readConfiguration("sepolia");

        vm.expectRevert(bytes("the loanMarket section is not filled in"));
        harness.submit(diamond, "market", config);
        vm.expectRevert(bytes("the loanMarket section is not filled in"));
        harness.requireApplied(diamond, "market", config);
        ConfigureRemoteController.Configuration memory noRecipient =
            harness.parseConfiguration(_configJson(_text()));
        vm.expectRevert(bytes("the loanFeeTerms section names no recipient"));
        harness.requireApplied(diamond, "fees", noRecipient);
    }

    function testAValueThatDoesNotFitItsFieldStopsTheRunInsteadOfWrapping() public {
        // driven through the reader, over a configuration that was never written to the tree: a fee
        // rate or an endpoint id too large for the field it is bound for would otherwise truncate
        // into a different, perfectly plausible value, and every later comparison would agree
        vm.expectRevert(bytes("the chain config's feeFloor does not fit its field"));
        harness.parseConfiguration(_configJson(_withFeeFloor("999999999999999999999")));
        vm.expectRevert(bytes("the chain config's feeSpread does not fit its field"));
        harness.parseConfiguration(_configJson(_withFeeSpread("999999999999999999999")));
        vm.expectRevert(bytes("the chain config's originEid does not fit its field"));
        harness.parseConfiguration(_configJson(_withOriginEid("4294967296")));
    }

    function testARepeatedRoleAddressIsRefusedRatherThanCountedTwice() public {
        // the read-back compares list lengths against the chain's: with [A, A] configured, a chain
        // holding [A, B] would pass a comparison that is supposed to be exact
        string memory twice = "[\"0x1111111111111111111111111111111111111111\", "
            "\"0x1111111111111111111111111111111111111111\"]";
        vm.expectRevert(bytes("the chain config's pausers list repeats an address"));
        harness.parseConfiguration(_configJson(_withPausers(twice)));
        vm.expectRevert(bytes("the chain config's unpausers list repeats an address"));
        harness.parseConfiguration(_configJson(_withUnpausers(twice)));
    }

    function testTheReaderRefusesAConfigurationMissingWhatEveryRunNeeds() public {
        // the three the script cannot proceed without, each driven: a zero governance leaves the
        // prepared calls with nobody to submit them, a zero duration is not a configuration, and a
        // zero subaccount type is the protocol's reserved one
        vm.expectRevert(bytes("the chain config names no governance"));
        harness.parseConfiguration(_configJson(_withGovernance(ZERO)));
        vm.expectRevert(bytes("the chain config's timelock duration is zero"));
        harness.parseConfiguration(_configJson(_withDuration("0")));
        vm.expectRevert(bytes("the chain config's subaccount type is zero"));
        harness.parseConfiguration(_configJson(_withSubaccountType("0")));
    }

    function testAnEmptyRoleListIsCalledOutRatherThanPassedOver() public {
        // Sepolia ships with both empty, which is a decision: with nobody holding the role the
        // pause path cannot be exercised, and after the duration lands adding someone takes it
        _deployDiamond();
        harness.prepare("sepolia", diamond, "governance", harness.readConfiguration("sepolia"));
        assertTrue(harness.printed("NOTE: no pausers configured"));
        assertTrue(harness.printed("NOTE: no unpausers configured"));
    }

    function testExecuteRefusesASignerThatIsNotTheOwnerAndADiamondAlreadyUnderTimelock() public {
        _deployDiamond();

        vm.expectRevert(
            bytes("execute needs the diamond's current owner to sign: use prepare for a multisig owner")
        );
        harness.requireExecutable(diamond, makeAddr("stranger"));

        // the owner signs, but the diamond already carries a duration: every call would queue, so
        // the phase that reports what it sent must not be the one used
        vm.prank(address(harness));
        IITimelockFacet(diamond).setTimelockDuration(DURATION);
        vm.expectRevert(bytes("the timelock is already set: these calls would queue - use prepare"));
        harness.requireExecutable(diamond, address(harness));
    }

    function testTheGovernanceSectionIsSubmittedAndThenReadBackOffTheChain() public {
        _deployDiamond();
        ConfigureRemoteController.Configuration memory config = _configuration();

        harness.requireExecutable(diamond, address(harness));
        harness.submit(diamond, "governance", config);

        assertTrue(IPauseFacet(diamond).isPauser(config.pausers[0]));
        assertTrue(IPauseFacet(diamond).isUnpauser(config.unpausers[0]));
        assertEq(ITimelockFacet(diamond).getTimelockDurationSeconds(), DURATION);
        harness.requireApplied(diamond, "governance", config);
        assertTrue(harness.printed("VERIFIED: timelockDurationSeconds 3600"));
    }

    function testPrepareEmitsTheExecuteLineForEveryCallOnceADurationIsInForce() public {
        // the pinned flow's whole output: a multisig submits these by hand, and after B4 each one
        // queues, so the calldata that lands it afterwards has to be printed beside it rather than
        // left for an operator to re-encode
        _deployDiamond();
        vm.prank(address(harness));
        IITimelockFacet(diamond).setTimelockDuration(DURATION);
        ConfigureRemoteController.Configuration memory config = _configuration();

        harness.prepare("sepolia", diamond, "transport", config);

        assertTrue(harness.printed("NOTE: the duration is 3600s"));
        bytes memory expected = abi.encodeCall(
            IIComposeTransportFacet.setComposeTransport,
            (config.transport)
        );
        string memory written = harness.written();
        assertTrue(_contains(written, vm.toString(expected)), "the call's own calldata");
        assertTrue(
            _contains(written, vm.toString(abi.encodeCall(ITimelockFacet.executeTimelockedCall, (expected)))),
            "the calldata that executes it after the delay"
        );
        assertEq(harness.writtenTo(), "deployment/output-internal/sepolia/configuration-transport.txt");
    }

    function testTheReadBackFailsOnARoleHolderNobodyConfigured() public {
        // the diamond's roles are a set, not a superset: a pauser from an earlier run or another
        // hand is a finding, and counting is what catches it
        _deployDiamond();
        ConfigureRemoteController.Configuration memory config = _configuration();
        address[] memory stranger = new address[](1);
        stranger[0] = makeAddr("uninvited");
        vm.prank(address(harness));
        IIPauseFacet(diamond).addPausers(stranger);

        harness.submit(diamond, "governance", config);
        vm.expectRevert(bytes("the pausers on chain are not the configured set"));
        harness.requireApplied(diamond, "governance", config);
    }

    function testTheReadBackFailsOnADurationThatIsNotTheConfiguredOne() public {
        // the shipped configuration, whose role lists are empty, so the duration is the only thing
        // left for the read-back to disagree about
        _deployDiamond();
        ConfigureRemoteController.Configuration memory config = harness.readConfiguration("sepolia");
        vm.prank(address(harness));
        IITimelockFacet(diamond).setTimelockDuration(DURATION + 1);

        vm.expectRevert(bytes("the timelock duration on chain is not the configured one"));
        harness.requireApplied(diamond, "governance", config);
    }

    /// Whether `_haystack` contains `_needle`, for asserting on one prepared line inside the file.
    function _contains(
        string memory _haystack,
        string memory _needle
    )
        private pure
        returns (bool)
    {
        bytes memory haystack = bytes(_haystack);
        bytes memory needle = bytes(_needle);
        if (needle.length > haystack.length) {
            return false;
        }
        for (uint256 i = 0; i <= haystack.length - needle.length; i++) {
            bool same = true;
            for (uint256 j = 0; j < needle.length; j++) {
                if (haystack[i + j] != needle[j]) {
                    same = false;
                    break;
                }
            }
            if (same) {
                return true;
            }
        }
        return false;
    }

    /// A deployment record naming `_controller`, as `save-deployed-addresses.ts mock` writes one.
    function _record(
        address _controller
    )
        private pure
        returns (string memory)
    {
        return string.concat(
            "[{\"name\": \"OwnershipFacet\", \"contractName\": \"OwnershipFacet.sol\", \"address\": \"", SOME, "\"},",
            "{\"name\": \"MasterAccountController\", ",
            "\"contractName\": \"MasterAccountController.sol\", \"address\": \"",
            vm.toString(_controller), "\"}]"
        );
    }

    /// A chain config as the reader takes it, with the fields a case is about spelled out. Written
    /// here rather than in the tree: a malformed configuration is exactly what must never be
    /// committed, and the reader is what has to refuse it. Carried in a struct because the coverage
    /// build compiles without the IR pipeline, where eight string arguments are stack-too-deep.
    struct ConfigText {
        string feeFloor;
        string feeSpread;
        string pausers;
        string unpausers;
        string originEid;
        string governance;
        string duration;
        string subaccountType;
    }

    function _text()
        private pure
        returns (ConfigText memory _config)
    {
        _config = ConfigText("0", "0", "[]", "[]", "40294", GOVERNANCE, "3600", "1");
    }

    function _configJson(
        ConfigText memory _config
    )
        private pure
        returns (string memory)
    {
        return string.concat(
            "{\"governance\": \"", _config.governance,
            "\", \"timelockDurationSeconds\": ", _config.duration,
            ", \"pausers\": ", _config.pausers,
            ", \"unpausers\": ", _config.unpausers,
            ", \"subaccountType\": ", _config.subaccountType,
            _transportJson(_config.originEid),
            _marketJson(),
            ", \"loanFeeTerms\": {\"feeFloor\": ", _config.feeFloor,
            ", \"feeSpread\": ", _config.feeSpread,
            ", \"feeRecipient\": \"", ZERO, "\"}}"
        );
    }

    function _transportJson(
        string memory _originEid
    )
        private pure
        returns (string memory)
    {
        return string.concat(
            ", \"composeTransport\": {\"lzEndpoint\": \"", SOME,
            "\", \"oft\": \"", SOME,
            "\", \"originEid\": ", _originEid,
            ", \"originPeer\": \"", SOME, "\"}"
        );
    }

    function _marketJson()
        private pure
        returns (string memory)
    {
        return string.concat(
            ", \"loanMarket\": {\"morpho\": \"", SOME,
            "\", \"loanToken\": \"", SOME,
            "\", \"collateralToken\": \"", SOME,
            "\", \"oracle\": \"", SOME,
            "\", \"irm\": \"", SOME,
            "\", \"lltv\": \"770000000000000000\"}"
        );
    }

    function _withFeeFloor(string memory _value) private pure returns (ConfigText memory _config) {
        _config = _text();
        _config.feeFloor = _value;
    }

    function _withFeeSpread(string memory _value) private pure returns (ConfigText memory _config) {
        _config = _text();
        _config.feeSpread = _value;
    }

    function _withOriginEid(string memory _value) private pure returns (ConfigText memory _config) {
        _config = _text();
        _config.originEid = _value;
    }

    function _withPausers(string memory _value) private pure returns (ConfigText memory _config) {
        _config = _text();
        _config.pausers = _value;
    }

    function _withUnpausers(string memory _value) private pure returns (ConfigText memory _config) {
        _config = _text();
        _config.unpausers = _value;
    }

    function _withGovernance(string memory _value) private pure returns (ConfigText memory _config) {
        _config = _text();
        _config.governance = _value;
    }

    function _withDuration(string memory _value) private pure returns (ConfigText memory _config) {
        _config = _text();
        _config.duration = _value;
    }

    function _withSubaccountType(string memory _value) private pure returns (ConfigText memory _config) {
        _config = _text();
        _config.subaccountType = _value;
    }

    /// A diamond with the two facets this script calls, owned by the harness so its calls carry the
    /// owner's authority.
    function testTheImplementationsSectionRegistersBothInOrder() public {
        ConfigureRemoteController.Configuration memory config = _withImplementations();
        ConfigureRemoteController.Call[] memory calls = harness.callsFor("implementations", config);

        assertEq(calls.length, 2);
        assertEq(calls[0].description, "setPersonalAccountImplementation");
        assertEq(
            calls[0].data,
            abi.encodeCall(
                IIPersonalAccountsFacet.setPersonalAccountImplementation,
                (config.personalAccountImplementation)
            )
        );
        assertEq(calls[1].description, "setSubaccountImplementation");
        assertEq(
            calls[1].data,
            abi.encodeCall(
                IISubaccountsFacet.setSubaccountImplementation,
                (config.subaccountType, config.loanSubaccountImplementation)
            )
        );
    }

    function testTheImplementationsSectionIsUnreadyUntilTheyAreDeployed() public {
        // neither named is the ordinary state of every run before the implementations exist, and
        // the chain config carries no such field, so this is what `_configuration` leaves behind
        ConfigureRemoteController.Configuration memory config = _configuration();

        vm.expectRevert(bytes("the deployment record names no remote implementations"));
        harness.callsFor("implementations", config);

        // swept, it is skipped with the note and the rest of the run is unaffected
        ConfigureRemoteController.Call[] memory calls = harness.callsFor("all", config);
        assertEq(calls.length, 6);
        assertTrue(harness.printed("SKIPPED: the deployment record names no remote implementations"));
    }

    function testASweepCarriesTheImplementationsBeforeTheWiringAndTheDurationLast() public {
        ConfigureRemoteController.Configuration memory config = _withImplementations();
        ConfigureRemoteController.Call[] memory calls = harness.callsFor("all", config);

        assertEq(calls.length, 8);
        assertEq(calls[0].description, "addPausers");
        assertEq(calls[1].description, "addUnpausers");
        assertEq(calls[2].description, "setPersonalAccountImplementation");
        assertEq(calls[3].description, "setSubaccountImplementation");
        assertEq(calls[4].description, "setComposeTransport");
        assertEq(calls[5].description, "registerLoanMarket");
        assertEq(calls[6].description, "setLoanFeeTerms");
        assertEq(calls[7].description, "setTimelockDuration");
    }

    function testTheWiringSweepLeavesTheImplementationsAlone() public {
        // `wiring` is what connects the two chains; registering an implementation out of a record
        // the caller never named is not part of that, and a sweep must not do it silently
        ConfigureRemoteController.Configuration memory config = _withImplementations();
        ConfigureRemoteController.Call[] memory calls = harness.callsFor("wiring", config);

        assertEq(calls.length, 3);
        assertEq(calls[0].description, "setComposeTransport");
        assertEq(calls[1].description, "registerLoanMarket");
        assertEq(calls[2].description, "setLoanFeeTerms");
    }

    function testTheImplementationsAreReadOutOfTheRecordByName() public {
        address personalAccount = makeAddr("personalAccountRemote");
        address loanSubaccount = makeAddr("loanSubaccountRemote");

        (address readPersonalAccount, address readLoanSubaccount) =
            harness.implementationsFromRecord(_recordWithImplementations(personalAccount, loanSubaccount));
        assertEq(readPersonalAccount, personalAccount);
        assertEq(readLoanSubaccount, loanSubaccount);

        // a record from before `deploy_remote_account_implementations` names neither, which is the
        // section's unready state rather than an error: nothing has been deployed to register
        (readPersonalAccount, readLoanSubaccount) = harness.implementationsFromRecord(_record(makeAddr("diamond")));
        assertEq(readPersonalAccount, address(0));
        assertEq(readLoanSubaccount, address(0));
    }

    function testEachTargetReadsItsOwnRecord() public {
        // the section's two addresses come from a record, and which record is the target's answer:
        // a pinned run reading the throwaway's would register the wrong deployment's contracts
        vm.chainId(SEPOLIA);
        vm.createDir("deployment/output-internal", true);
        string memory pinnedPath = "deployment/output-internal/configure-pinned-record.json";
        string memory throwawayPath = "deployment/output-internal/configure-throwaway-record.json";
        harness.setDeploymentRecordPath(pinnedPath);
        harness.setThrowawayRecordPath(throwawayPath);
        address pinnedAccount = makeAddr("pinned personal account");
        address pinnedSubaccount = makeAddr("pinned loan subaccount");
        address throwawayAccount = makeAddr("throwaway personal account");
        address throwawaySubaccount = makeAddr("throwaway loan subaccount");
        vm.writeFile(pinnedPath, _recordWithImplementations(pinnedAccount, pinnedSubaccount));
        vm.writeFile(throwawayPath, _recordWithImplementations(throwawayAccount, throwawaySubaccount));

        // through the seam a run builds its configuration with, not through the reader alone
        ConfigureRemoteController.Configuration memory config = harness.configurationFor("sepolia", "pinned");
        assertEq(config.personalAccountImplementation, pinnedAccount);
        assertEq(config.loanSubaccountImplementation, pinnedSubaccount);

        config = harness.configurationFor("sepolia", "throwaway");
        assertEq(config.personalAccountImplementation, throwawayAccount);
        assertEq(config.loanSubaccountImplementation, throwawaySubaccount);

        // and a record that does not exist yet - every run before the implementations are deployed -
        // leaves the section unready rather than stopping the run that is configuring something else
        vm.removeFile(pinnedPath);
        config = harness.configurationFor("sepolia", "pinned");
        assertEq(config.personalAccountImplementation, address(0));
        assertEq(config.loanSubaccountImplementation, address(0));
        vm.removeFile(throwawayPath);
    }

    function testAPreparedRunHandsOverTheAddressesTheRecordNames() public {
        // driven through the entry point rather than the seam behind it: what has to hold is that a
        // run reads a record at all, and that what it read reaches the calldata governance signs
        vm.chainId(SEPOLIA);
        address account = makeAddr("recorded personal account");
        address subaccount = makeAddr("recorded loan subaccount");
        string memory path = "deployment/output-internal/configure-run-record.json";
        vm.createDir("deployment/output-internal", true);
        vm.writeFile(path, _recordWithImplementations(account, subaccount));
        harness.setDeploymentRecordPath(path);
        // prepare asks the diamond who owns it and what its duration is, and nothing else
        vm.etch(PinnedControllerInitCode.MASTER_ACCOUNT_CONTROLLER, address(new PinnedControllerStub()).code);

        harness.run("sepolia", "prepare", "implementations", "pinned");

        string memory target = vm.toString(PinnedControllerInitCode.MASTER_ACCOUNT_CONTROLLER);
        uint256 subaccountType = harness.readConfiguration("sepolia").subaccountType;
        assertTrue(
            harness.printed(
                string.concat(
                    "1. setPersonalAccountImplementation | ", target, " | ",
                    vm.toString(
                        abi.encodeCall(IIPersonalAccountsFacet.setPersonalAccountImplementation, (account))
                    )
                )
            ),
            "the prepared call does not name the recorded Personal Account implementation"
        );
        assertTrue(
            harness.printed(
                string.concat(
                    "2. setSubaccountImplementation | ", target, " | ",
                    vm.toString(
                        abi.encodeCall(
                            IISubaccountsFacet.setSubaccountImplementation,
                            (subaccountType, subaccount)
                        )
                    )
                )
            ),
            "the prepared call does not name the recorded subaccount implementation"
        );
        vm.removeFile(path);
    }

    function testARecordThatNamesOneImplementationButNotTheOtherStopsEveryRun() public {
        // not the state of a deployment that has not got there yet: something was deployed and the
        // record is half written. A sweep that passed over it would arm the timelock on a
        // deployment whose accounts resolve no implementation at all
        ConfigureRemoteController.Configuration memory config = _withImplementations();
        config.loanSubaccountImplementation = address(0);

        vm.expectRevert(bytes("the deployment record names one remote implementation but not the other"));
        harness.callsFor("all", config);

        config.loanSubaccountImplementation = address(new PauseFacet());
        config.personalAccountImplementation = address(0);
        vm.expectRevert(bytes("the deployment record names one remote implementation but not the other"));
        harness.callsFor("all", config);
    }

    function testARecordThatNamesAnImplementationTwiceIsRefused() public {
        // the recorder updates the FIRST entry of a name; a reader taking the last would register
        // the address a re-deployment left behind
        address first = makeAddr("first");
        address second = makeAddr("second");
        string memory twice = string.concat(
            "[{\"name\": \"PersonalAccountRemoteImplementation\", ",
            "\"contractName\": \"PersonalAccountRemote.sol\", \"address\": \"", vm.toString(first), "\"},",
            "{\"name\": \"PersonalAccountRemoteImplementation\", ",
            "\"contractName\": \"PersonalAccountRemote.sol\", \"address\": \"", vm.toString(second), "\"}]"
        );
        vm.expectRevert(bytes("the deployment record names PersonalAccountRemoteImplementation twice"));
        harness.implementationsFromRecord(twice);

        string memory subaccountTwice = string.concat(
            "[{\"name\": \"MorphoLoanSubaccountRemoteImplementation\", ",
            "\"contractName\": \"MorphoLoanSubaccountRemote.sol\", \"address\": \"",
            vm.toString(first), "\"},",
            "{\"name\": \"MorphoLoanSubaccountRemoteImplementation\", ",
            "\"contractName\": \"MorphoLoanSubaccountRemote.sol\", \"address\": \"",
            vm.toString(second), "\"}]"
        );
        vm.expectRevert(bytes("the deployment record names MorphoLoanSubaccountRemoteImplementation twice"));
        harness.implementationsFromRecord(subaccountTwice);

        // and the shape a check on the ADDRESS would let through: a zero-valued entry is still an
        // entry, so the second one is a duplicate whatever the first one held
        string memory zeroThenReal = string.concat(
            "[{\"name\": \"PersonalAccountRemoteImplementation\", ",
            "\"contractName\": \"PersonalAccountRemote.sol\", \"address\": \"", vm.toString(address(0)), "\"},",
            "{\"name\": \"PersonalAccountRemoteImplementation\", ",
            "\"contractName\": \"PersonalAccountRemote.sol\", \"address\": \"", vm.toString(second), "\"}]"
        );
        vm.expectRevert(bytes("the deployment record names PersonalAccountRemoteImplementation twice"));
        harness.implementationsFromRecord(zeroThenReal);

        string memory zeroThenRealSubaccount = string.concat(
            "[{\"name\": \"MorphoLoanSubaccountRemoteImplementation\", ",
            "\"contractName\": \"MorphoLoanSubaccountRemote.sol\", \"address\": \"",
            vm.toString(address(0)), "\"},",
            "{\"name\": \"MorphoLoanSubaccountRemoteImplementation\", ",
            "\"contractName\": \"MorphoLoanSubaccountRemote.sol\", \"address\": \"",
            vm.toString(second), "\"}]"
        );
        vm.expectRevert(bytes("the deployment record names MorphoLoanSubaccountRemoteImplementation twice"));
        harness.implementationsFromRecord(zeroThenRealSubaccount);
    }

    function testTheImplementationsAreSubmittedAndThenReadBackOffTheChain() public {
        _deployDiamond();
        ConfigureRemoteController.Configuration memory config = _withImplementations();

        harness.submit(diamond, "implementations", config);
        harness.requireApplied(diamond, "implementations", config);

        assertEq(IPersonalAccountsFacet(diamond).implementation(), config.personalAccountImplementation);
        assertEq(
            ISubaccountsFacet(diamond).implementationForType(config.subaccountType),
            config.loanSubaccountImplementation
        );
    }

    function testTheReadBackFailsOnAnImplementationNobodyRecorded() public {
        // the registration is the deployment's one blind step - the setters check only for code -
        // so a registry pointing at something the record does not name is a finding, not a detail
        _deployDiamond();
        ConfigureRemoteController.Configuration memory config = _withImplementations();
        harness.submit(diamond, "implementations", config);

        // one field at a time, restored between: a memory struct assigned to a second variable is
        // the same struct, so there is no copy to mutate independently
        address recorded = config.personalAccountImplementation;
        config.personalAccountImplementation = address(new PauseFacet());
        vm.expectRevert(bytes("the Personal Account implementation on chain is not the recorded one"));
        harness.requireApplied(diamond, "implementations", config);

        config.personalAccountImplementation = recorded;
        config.loanSubaccountImplementation = address(new TimelockFacet());
        vm.expectRevert(bytes("the subaccount implementation on chain is not the recorded one"));
        harness.requireApplied(diamond, "implementations", config);
    }

    function _deployDiamond() private {
        DiamondArgs memory args = DiamondArgs({
            owner: address(harness),
            initAddress: address(0),
            initCalldata: ""
        });
        diamond = address(new MasterAccountController(deployBaseFacets(), args));
        IDiamond.FacetCut[] memory cuts = new IDiamond.FacetCut[](4);
        cuts[0] = _buildFacetCut(address(new PauseFacet()), "PauseFacet", IDiamond.FacetCutAction.Add);
        cuts[1] = _buildFacetCut(address(new TimelockFacet()), "TimelockFacet", IDiamond.FacetCutAction.Add);
        // the two registries the implementations section writes and reads back
        cuts[2] = _buildFacetCut(
            address(new PersonalAccountsFacet()),
            "PersonalAccountsFacet",
            IDiamond.FacetCutAction.Add
        );
        cuts[3] = _buildFacetCut(address(new SubaccountsFacet()), "SubaccountsFacet", IDiamond.FacetCutAction.Add);
        vm.prank(address(harness));
        IDiamondCut(diamond).diamondCut(cuts, address(0), "");
    }

    /// The configuration with the two deploy outputs the record would have supplied. Any address
    /// with code will do: the setters check for code, not for an artifact.
    function _withImplementations()
        private
        returns (ConfigureRemoteController.Configuration memory _config)
    {
        _config = _configuration();
        _config.personalAccountImplementation = address(new PauseFacet());
        _config.loanSubaccountImplementation = address(new TimelockFacet());
    }

    /// A deployment record naming both remote implementations, as either deploy path writes one.
    function _recordWithImplementations(
        address _personalAccount,
        address _loanSubaccount
    )
        private pure
        returns (string memory)
    {
        return string.concat(
            "[{\"name\": \"PersonalAccountRemoteImplementation\", ",
            "\"contractName\": \"PersonalAccountRemote.sol\", \"address\": \"",
            vm.toString(_personalAccount), "\"},",
            "{\"name\": \"MorphoLoanSubaccountRemoteImplementation\", ",
            "\"contractName\": \"MorphoLoanSubaccountRemote.sol\", \"address\": \"",
            vm.toString(_loanSubaccount), "\"}]"
        );
    }

    /// The shipped Sepolia configuration with the values it is still waiting for filled in, so the
    /// ordering and the read-back can be exercised end to end.
    function _configuration()
        private
        returns (ConfigureRemoteController.Configuration memory _config)
    {
        _config = harness.readConfiguration("sepolia");
        _config.pausers = new address[](1);
        _config.pausers[0] = makeAddr("pauser");
        _config.unpausers = new address[](1);
        _config.unpausers[0] = makeAddr("unpauser");
        _config.market.marketParams.loanToken = makeAddr("loanToken");
        _config.market.marketParams.oracle = makeAddr("oracle");
        _config.fees.feeRecipient = makeAddr("feeCollector");
    }
}
