// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {
    DeployRemoteControllerThrowawayHarness
} from "../../utils/DeployRemoteControllerThrowawayHarness.sol";
import {PinnedControllerInitCode} from "../../../deployment/lib/PinnedControllerInitCode.sol";
import {SUBACCOUNT_TYPE_MORPHO_LOAN} from "../../../deployment/lib/SubaccountTypes.sol";
import {MockSingletonFactory} from "../../../contracts/mock/MockSingletonFactory.sol";
import {IDiamondCut} from "../../../contracts/diamond/interfaces/IDiamondCut.sol";
import {IDiamondLoupe} from "../../../contracts/diamond/interfaces/IDiamondLoupe.sol";
import {IERC165} from "../../../contracts/diamond/interfaces/IERC165.sol";
import {IERC173} from "../../../contracts/diamond/interfaces/IERC173.sol";
import {IBeacon} from "@openzeppelin/contracts/proxy/beacon/IBeacon.sol";
import {ISubaccountsFacet} from "../../../contracts/userInterfaces/facets/ISubaccountsFacet.sol";
import {IPauseFacet} from "../../../contracts/userInterfaces/facets/IPauseFacet.sol";
import {
    IPersonalAccountsFacet
} from "../../../contracts/userInterfaces/facets/IPersonalAccountsFacet.sol";
import {
    IComposeTransportFacet
} from "../../../contracts/userInterfaces/facets/IComposeTransportFacet.sol";
import {
    IMorphoLoanMarketsFacet
} from "../../../contracts/userInterfaces/facets/IMorphoLoanMarketsFacet.sol";
import {ITimelockFacet} from "../../../contracts/userInterfaces/facets/ITimelockFacet.sol";

/**
 * @title DeployRemoteControllerThrowawayTest
 * @notice The throwaway remote controller: a whole deployment from current source, driven end to
 * end against a local singleton factory. What it must produce is a diamond the rehearsal can use -
 * every facet cut, the ERC-165 flags set, both implementations registered - owned by the deploying
 * key and sitting at an address that is NOT the production one, since reaching that address from
 * current source is the one thing this script must never do.
 */
contract DeployRemoteControllerThrowawayTest is Test {
    uint256 private constant SEPOLIA = 11155111;
    uint256 private constant COSTON2 = 114;
    address private constant SINGLETON_FACTORY = 0xce0042B868300000d44A59004Da54A005ffdcf9f;
    /// The nine the loan chain runs: three base facets and the six of its own cut.
    uint256 private constant FACET_COUNT = 9;

    DeployRemoteControllerThrowawayHarness private script;
    address private deployer;

    function setUp() public {
        // the same value the other deployment suites write: `setEnv` is process-wide, so two suites
        // running concurrently with different keys would have one deploy from the other's address
        vm.setEnv("DEPLOYER_PRIVATE_KEY", "1");
        deployer = vm.addr(1);
        vm.etch(SINGLETON_FACTORY, address(new MockSingletonFactory()).code);
        script = new DeployRemoteControllerThrowawayHarness();
        // the script signs as this account, so the deterministic addresses and the ownership it
        // takes are the fixture's deployer rather than whatever called into the harness
        script.setSigner(deployer);
    }

    function testRefusesAFlareFamilyChain() public {
        // the facet set and both implementations are the remote side's: deployed on Coston2 they
        // would look like legitimate artifacts and serve every Personal Account there
        vm.chainId(COSTON2);
        vm.expectRevert(bytes("the remote controller belongs on a loan chain"));
        script.run("coston2");
    }

    function testRefusesANetworkNameThatIsNotTheChainItIsPointedAt() public {
        vm.chainId(SEPOLIA);
        vm.expectRevert(bytes("RPC chain is sepolia, not the named network ethereum"));
        script.run("ethereum");
    }

    function testDeploysADiamondTheRehearsalCanUseOwnedByTheDeployingKey() public {
        vm.chainId(SEPOLIA);
        script.run("sepolia");

        address controller = _controller();
        assertGt(controller.code.length, 0, "the controller has code");
        // the point of the mode: the address is NOT the production one, so nothing here can be
        // mistaken for - or collide with - the pinned deployment
        assertNotEq(controller, PinnedControllerInitCode.MASTER_ACCOUNT_CONTROLLER);
        assertEq(IERC173(controller).owner(), deployer, "the deploying key owns it");

        // the whole surface, not just the base facets the constructor cuts
        assertEq(IDiamondLoupe(controller).facets().length, FACET_COUNT);
        assertTrue(IERC165(controller).supportsInterface(type(IERC165).interfaceId));
        assertTrue(IERC165(controller).supportsInterface(type(IDiamondCut).interfaceId));
        assertTrue(IERC165(controller).supportsInterface(type(IDiamondLoupe).interfaceId));
        assertTrue(IERC165(controller).supportsInterface(type(IERC173).interfaceId));

        // both implementations registered, without which no account can be created at all
        assertGt(IBeacon(controller).implementation().code.length, 0, "the Personal Account beacon");
        assertGt(
            ISubaccountsFacet(controller).implementationForType(SUBACCOUNT_TYPE_MORPHO_LOAN).code.length,
            0,
            "the loan subaccount implementation"
        );

        // and the duration is still zero: configure_remote_controller sets it, last, which is why
        // the registrations above could apply immediately here
        assertEq(ITimelockFacet(controller).getTimelockDurationSeconds(), 0);
    }

    function testARerunReusesWhatTheFirstRunLeftRatherThanFailing() public {
        // a run that died between two of its deployments must be resumable: the factory refuses a
        // second deploy at the same salt, so the script reuses whatever already answers there
        vm.chainId(SEPOLIA);
        script.run("sepolia");
        address controller = _controller();
        IDiamondLoupe.Facet[] memory facets = IDiamondLoupe(controller).facets();

        script.run("sepolia");
        assertEq(_controller(), controller, "the same controller, not a failed or second one");
        // and the diamond is untouched: the cut cannot repeat, and the rerun must not have tried
        assertEq(IDiamondLoupe(controller).facets().length, facets.length);
    }

    function testAResumedRunRecordsTheSameCompleteSetAsTheFirst() public {
        // the recorder is fed from these lines and nothing else. A rerun after a run that broadcast
        // but failed to record must be able to write a complete record, so what the second run
        // reports is compared with the first, entry for entry, rather than counted
        vm.chainId(SEPOLIA);
        script.run("sepolia");
        string[] memory first = _recorded();

        script.clearRecorded();
        script.run("sepolia");
        string[] memory second = _recorded();

        assertEq(second.length, first.length, "the same entries");
        for (uint256 i = 0; i < first.length; i++) {
            assertEq(second[i], first[i]);
        }
    }

    function testEveryRecordedEntryNamesAnInstalledContractInTheRecordersOwnFormat() public {
        // what a run reports is what the deployment record becomes: a duplicated name, a shared
        // address or one that holds nothing would be recorded just as happily. Each entry is checked
        // against the diamond the run produced, and each installed facet must be named exactly once
        vm.chainId(SEPOLIA);
        script.run("sepolia");

        string[] memory lines = _recorded();
        assertEq(lines.length, FACET_COUNT + 4, "nine facets, the controller, its init, both accounts");
        address controller = _controller();
        IDiamondLoupe.Facet[] memory installed = IDiamondLoupe(controller).facets();
        uint256[] memory timesNamed = new uint256[](installed.length);

        for (uint256 i = 0; i < lines.length; i++) {
            (string memory name, string memory contractName, address recordedAddress) = _parse(lines[i]);
            assertEq(
                lines[i],
                script.deployedLine(name, contractName, recordedAddress),
                "the recorder's own format"
            );
            assertGt(recordedAddress.code.length, 0, name);
            // the record's names become artifact paths: `<contractName>` must be the source file of
            // the contract `<name>` stands for, and no name may appear twice
            assertEq(contractName, string.concat(_sourceName(name), ".sol"));
            for (uint256 j = i + 1; j < lines.length; j++) {
                (string memory otherName, , ) = _parse(lines[j]);
                assertTrue(
                    keccak256(bytes(name)) != keccak256(bytes(otherName)),
                    "a record name may not repeat"
                );
            }
            for (uint256 k = 0; k < installed.length; k++) {
                if (installed[k].facetAddress == recordedAddress) {
                    timesNamed[k]++;
                }
            }
        }

        // every facet the diamond runs, named once: counting matches would let one address stand in
        // for all six, since a name recorded six times over one address still matches six times
        for (uint256 k = 0; k < installed.length; k++) {
            assertEq(timesNamed[k], 1, "each installed facet is recorded exactly once");
        }
    }

    function testEachFacetIsRecordedUnderTheNameTheDiamondServesFromThatAddress() public {
        // and the names are not interchangeable: the address recorded for a facet must be the one
        // the diamond dispatches that facet's own selectors to
        vm.chainId(SEPOLIA);
        script.run("sepolia");

        address controller = _controller();
        string[6] memory names = [
            "SubaccountsFacet",
            "TimelockFacet",
            "PauseFacet",
            "PersonalAccountsFacet",
            "ComposeTransportFacet",
            "MorphoLoanMarketsFacet"
        ];
        bytes4[6] memory ownSelectors = [
            ISubaccountsFacet.implementationForType.selector,
            ITimelockFacet.getTimelockDurationSeconds.selector,
            IPauseFacet.isPauser.selector,
            IPersonalAccountsFacet.getPersonalAccount.selector,
            IComposeTransportFacet.getComposeTransport.selector,
            IMorphoLoanMarketsFacet.getLoanMarket.selector
        ];
        for (uint256 i = 0; i < names.length; i++) {
            assertEq(
                _recordedAddressOf(names[i]),
                IDiamondLoupe(controller).facetAddress(ownSelectors[i]),
                names[i]
            );
        }
    }

    /// The address a recorded entry names, by the name it was recorded under.
    function _recordedAddressOf(
        string memory _name
    )
        private view
        returns (address)
    {
        string[] memory lines = _recorded();
        for (uint256 i = 0; i < lines.length; i++) {
            (string memory name, , address recordedAddress) = _parse(lines[i]);
            if (keccak256(bytes(name)) == keccak256(bytes(_name))) {
                return recordedAddress;
            }
        }
        revert("nothing was recorded under that name");
    }

    /// The lines the run reported, in order.
    function _recorded()
        private view
        returns (string[] memory _lines)
    {
        _lines = new string[](script.recordedCount());
        for (uint256 i = 0; i < _lines.length; i++) {
            _lines[i] = script.recorded(i);
        }
    }

    /// One recorded line back into its three fields, the way the recorder's own regular expression
    /// splits it: `DEPLOYED: <name>, <contractName>: <address>`.
    function _parse(
        string memory _line
    )
        private pure
        returns (string memory _name, string memory _contractName, address _address)
    {
        string[] memory head = vm.split(_line, "DEPLOYED: ");
        string[] memory parts = vm.split(head[1], ", ");
        _name = parts[0];
        string[] memory tail = vm.split(parts[1], ": ");
        _contractName = tail[0];
        _address = vm.parseAddress(tail[1]);
    }

    /// The source a record name stands for: the implementations are recorded under a name of their
    /// own, everything else under the contract's.
    function _sourceName(
        string memory _name
    )
        private pure
        returns (string memory)
    {
        if (keccak256(bytes(_name)) == keccak256("PersonalAccountRemoteImplementation")) {
            return "PersonalAccountRemote";
        }
        if (keccak256(bytes(_name)) == keccak256("MorphoLoanSubaccountRemoteImplementation")) {
            return "MorphoLoanSubaccountRemote";
        }
        return _name;
    }

    /// The controller the run produced, read from the beacon the recorder's lines also name: the
    /// loupe of the one diamond this chain now has.
    function _controller()
        private
        returns (address)
    {
        // the script logs it, and the log is what the recorder parses; here the address is
        // recomputed the same way the script derives it, so the test does not parse console output
        return script.controllerAddress(deployer);
    }
}
