// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import {Script, console2} from "forge-std/Script.sol";
import {IBeacon} from "@openzeppelin/contracts/proxy/beacon/IBeacon.sol";
import {IERC173} from "../../contracts/diamond/interfaces/IERC173.sol";
import {FunctionNotFound} from "../../contracts/diamond/implementation/Diamond.sol";
import {IIComposeTransportFacet} from "../../contracts/smartAccounts/interface/IIComposeTransportFacet.sol";
import {IIMorphoLoanMarketsFacet} from "../../contracts/smartAccounts/interface/IIMorphoLoanMarketsFacet.sol";
import {IIPauseFacet} from "../../contracts/smartAccounts/interface/IIPauseFacet.sol";
import {IIPersonalAccountsFacet} from "../../contracts/smartAccounts/interface/IIPersonalAccountsFacet.sol";
import {IISubaccountsFacet} from "../../contracts/smartAccounts/interface/IISubaccountsFacet.sol";
import {IITimelockFacet} from "../../contracts/smartAccounts/interface/IITimelockFacet.sol";
import {IComposeTransportFacet} from "../../contracts/userInterfaces/facets/IComposeTransportFacet.sol";
import {IMorphoLoanMarketsFacet} from "../../contracts/userInterfaces/facets/IMorphoLoanMarketsFacet.sol";
import {IPauseFacet} from "../../contracts/userInterfaces/facets/IPauseFacet.sol";
import {IPersonalAccountsFacet} from "../../contracts/userInterfaces/facets/IPersonalAccountsFacet.sol";
import {ISubaccountsFacet} from "../../contracts/userInterfaces/facets/ISubaccountsFacet.sol";
import {ITimelockFacet} from "../../contracts/userInterfaces/facets/ITimelockFacet.sol";
import {IMorpho} from "../../contracts/smartAccounts/interface/IMorpho.sol";
import {DeployNetworks} from "../lib/DeployNetworks.sol";
import {PinnedControllerInitCode} from "../lib/PinnedControllerInitCode.sol";

/**
 * @title ConfigureRemoteController
 * @notice Everything the remote controller is configured with after its cut, from one file -
 * `deployment/chain-config/<network>.json` - as calldata for the owner to submit, and as a
 * read-back afterwards. The step the Flare deploy performs inside its own run and the loan chains
 * had nowhere to do ([`RUNBOOK.md`](../RUNBOOK.md) B4 and B6).
 *
 * Five sections, each one governance group:
 *
 * - `governance`: the pauser and unpauser roles, and the timelock duration. The duration is emitted
 *   last of everything a run carries, not merely last of this section, because it is what makes
 *   every later timelocked call queue - a role change or a wiring call included. (`removeUnpausers`
 *   is immediate and unaffected.) So it is last wherever it appears, and the pinned flow, which
 *   runs the sections separately, leaves it to the end for the same reason ([`RUNBOOK.md`](../RUNBOOK.md) B7).
 * - `implementations`: the remote Personal Account and the type's remote subaccount. Alone among
 *   the sections its two addresses are not in the chain config: they are deploy outputs, read from
 *   the deployment record of whichever controller the run targets - `<network>.json` for the pinned
 *   one, the gitignored `<network>_mock.json` for a throwaway. A record that names neither leaves
 *   the section unready, which is what a run before `deploy_remote_account_implementations` is.
 *   The check that can still PREVENT a wrong implementation being registered is
 *   `verify_implementation --stage pre`, not this: the read-back here proves only what the registry
 *   ended up pointing at.
 * - `transport`: the LayerZero endpoint, the OFT and the pinned origin. It precedes the market,
 *   which validates the collateral token against the transport's OFT.
 * - `market`: the write-once market binding for the subaccount type.
 * - `fees`: the type's fee terms. The first such call is the activation - borrowing reverts until
 *   it lands - so it comes last of all.
 *
 * `wiring` is the last three together - the implementations are not part of it - and `all` is every
 * section. A section named on its own must
 * be complete in the file or the run stops naming what is missing; a sweep skips an incomplete one
 * with a note, so a config that does not yet carry a market still prepares the transport.
 *
 * Three phases, because who owns the diamond decides what is possible - the same split the Flare
 * deploy has, where a configured initial owner leaves the settings to governance and a zero one
 * leaves them to the deployer:
 *
 * - `prepare` sends nothing and wants no key: it writes and prints one line per call, in order,
 *   each with its target and its calldata, the way the cut files with `"execute": false` do. This
 *   is the pinned flow, where a multisig owns the diamond. Once the duration is set every later
 *   call queues and then needs `executeTimelockedCall` with the same calldata, which this phase
 *   emits too, so nobody has to re-encode it by hand.
 * - `execute` submits them, and is the throwaway flow's alone: it requires the signer to be the
 *   diamond's current owner, which a multisig can never be. Its own read-back sees SIMULATED state,
 *   since forge collects a script's transactions and broadcasts them after it returns - so it
 *   catches a configuration that cannot apply, not one that did not. The wrapper follows a
 *   successful broadcast with a separate `verify` run, which is the one that reads mined state.
 * - `verify` reads the chain back and fails unless it matches the file. That is the half
 *   `verify_diamond` does not cover: it checks ownership and the diamond's surface and says nothing
 *   about roles, delay, transport, market or fees.
 *
 * Which controller a run touches is the caller's to name, not the script's to assume: `pinned` is
 * the production one, `throwaway` the one built from current source, whose address only its
 * gitignored record knows.
 */
// solhint-disable no-console
contract ConfigureRemoteController is Script {

    struct Configuration {
        address governance;
        uint256 timelockDurationSeconds;
        address[] pausers;
        address[] unpausers;
        uint256 subaccountType;
        IComposeTransportFacet.Transport transport;
        IMorphoLoanMarketsFacet.Market market;
        IMorphoLoanMarketsFacet.FeeTerms fees;
        // not from the chain config: deploy outputs, filled in from the target's deployment record
        address personalAccountImplementation;
        address loanSubaccountImplementation;
    }

    struct Call {
        string description;
        bytes data;
    }

    /// @dev One deployment-record entry. The field ORDER is load-bearing: `vm.parseJson` decodes a
    /// JSON object's members in alphabetical order of their keys, which for this record is
    /// address, contractName, name.
    struct RecordedContract {
        address contractAddress;
        string contractName;
        string name;
    }

    /// @dev The marker on a sheet prepared before the cut, printed and written as the file's first
    /// line: the duration is unknown, so it carries no EXECUTE lines and is not the one to submit from.
    string internal constant PROVISIONAL =
        "PROVISIONAL: TimelockFacet is not cut, so the duration is UNKNOWN - an absent getter does not prove a "
        "zero delay - and this output has no EXECUTE lines. Run prepare again after the cut and submit from that";

    function run(
        string calldata _expectedNetwork,
        string calldata _phase,
        string calldata _section,
        string calldata _target
    )
        external
    {
        require(DeployNetworks.isLoanChain(block.chainid), "the remote controller lives on a loan chain");
        string memory network = DeployNetworks.networkName(block.chainid);
        DeployNetworks.requireExpectedNetwork(network, _expectedNetwork);

        address diamond = resolveDiamond(network, _target);
        Configuration memory config = configurationFor(network, _target);
        _print(string.concat("NETWORK: ", network));
        _print(string.concat("TARGET: ", vm.toString(diamond), " (", _target, ")"));
        bytes32 phase = keccak256(bytes(_phase));
        if (phase == keccak256("prepare")) {
            prepare(network, diamond, _section, config);
        } else if (phase == keccak256("execute")) {
            // The signer is forge's, resolved from whatever the wrapper passed - a raw key, a keystore
            // or a Ledger - and `msg.sender` is that account. Reading DEPLOYER_PRIVATE_KEY here would
            // check one account and sign as another the moment the two differ, which is exactly what a
            // hardware run is. Note this validates the sender forge was GIVEN; a device whose address
            // is not that one fails later, at signing, rather than here.
            requireExecutable(diamond, _signer());
            vm.startBroadcast(_signer());
            submit(diamond, _section, config);
            vm.stopBroadcast();
            requireApplied(diamond, _section, config);
        } else if (phase == keccak256("verify")) {
            requireApplied(diamond, _section, config);
        } else {
            revert("unknown phase: prepare, execute or verify");
        }
    }

    /// @notice The diamond a run configures, which the caller names rather than the script assumes.
    /// `pinned` is the production controller, at the address the bootstrap reproduces. `throwaway`
    /// is the one `deploy_remote_controller_throwaway` built from current source, found through the
    /// gitignored `_mock` record it writes - the only place its address exists, since current source
    /// is what decides it. Each is checked to be what it claims: a throwaway that came out at the
    /// pinned address would mean the historical bytes had been reproduced, and a pinned target with
    /// no code means the bootstrap has not run.
    function resolveDiamond(
        string memory _network,
        string memory _target
    )
        public view
        returns (address _diamond)
    {
        bytes32 target = keccak256(bytes(_target));
        if (target == keccak256("pinned")) {
            _diamond = PinnedControllerInitCode.MASTER_ACCOUNT_CONTROLLER;
            require(_diamond.code.length > 0, "no controller at the pinned address: run the bootstrap first");
        } else if (target == keccak256("throwaway")) {
            string memory path = throwawayRecordPath(_network);
            require(vm.exists(path), "no throwaway record: run deploy_remote_controller_throwaway first");
            _diamond = controllerFromRecord(vm.readFile(path));
            requireUsableThrowaway(_diamond);
        } else {
            revert("unknown target: pinned or throwaway");
        }
    }

    /// @notice Writes and prints the calls for governance to submit, with the `executeTimelockedCall`
    /// line beside each one once a duration is in force. Reports who actually holds the diamond: a
    /// configuration prepared for an owner that has not been handed it cannot be submitted by anyone.
    function prepare(
        string memory _network,
        address _diamond,
        string memory _section,
        Configuration memory _config
    )
        public virtual
    {
        // the owner is served by a pinned base facet and is always readable; the duration lives
        // on TimelockFacet, which the cut installs, so before the cut the read reverts. A prepare
        // before the cut is legitimate - the calls depend on the config and the record, not on
        // the chain - so that ONE revert is tolerated: the diamond's own answer for a selector it
        // does not serve. Any other failure of the read is a real one and stops the run, since
        // reporting it as "not cut yet" would promise immediate application over a diamond whose
        // calls in fact queue
        address owner = IERC173(_diamond).owner();
        uint256 duration = 0;
        bool timelockCut = true;
        try ITimelockFacet(_diamond).getTimelockDurationSeconds() returns (uint256 live) {
            duration = live;
        } catch (bytes memory reason) {
            bytes memory notServed = abi.encodeWithSelector(
                FunctionNotFound.selector,
                ITimelockFacet.getTimelockDurationSeconds.selector
            );
            require(
                keccak256(reason) == keccak256(notServed),
                string.concat(
                    "the timelock duration read reverted, and not because TimelockFacet is missing: ",
                    vm.toString(reason)
                )
            );
            timelockCut = false;
        }
        _print(string.concat("TARGET: ", vm.toString(_diamond)));
        _print(string.concat("SUBMIT FROM: ", vm.toString(owner)));
        if (owner != _config.governance) {
            _print(
                string.concat(
                    "NOTE: the configured governance does not hold the diamond yet: the config names ",
                    vm.toString(_config.governance)
                )
            );
        }
        // an absent getter does not prove a zero delay: a facet cut, set and removed leaves its
        // duration in storage while the read reverts exactly as on a fresh diamond. So the output
        // is marked, in the notes and in the file itself, and is not the one to submit from
        if (!timelockCut) {
            _print(PROVISIONAL);
        } else if (duration == 0) {
            _print("NOTE: the duration is zero, so each call below applies when it is submitted");
        } else {
            _print(
                string.concat(
                    "NOTE: the duration is ",
                    vm.toString(duration),
                    "s, so each call below queues and needs its EXECUTE line after that delay"
                )
            );
        }

        _warnOnEmptyRoles(_section, _config);
        Call[] memory calls = pendingCallsFor(_diamond, _section, _config);
        string memory lines = timelockCut ? "" : string.concat(PROVISIONAL, "\n");
        for (uint256 i = 0; i < calls.length; i++) {
            string memory line = string.concat(
                vm.toString(i + 1), ". ", calls[i].description, " | ",
                vm.toString(_diamond), " | ", vm.toString(calls[i].data)
            );
            _print(line);
            lines = string.concat(lines, line, "\n");
            if (duration > 0) {
                bytes memory execution = abi.encodeCall(ITimelockFacet.executeTimelockedCall, (calls[i].data));
                string memory executeLine = string.concat(
                    vm.toString(i + 1), ". EXECUTE ", calls[i].description, " | ",
                    vm.toString(_diamond), " | ", vm.toString(execution)
                );
                _print(executeLine);
                lines = string.concat(lines, executeLine, "\n");
            }
        }
        _writeCalls(_network, _section, lines);
    }

    /// @notice Sends the section's calls in order. Typed rather than encoded, so a revert arrives as
    /// the diamond's own error.
    function submit(
        address _diamond,
        string memory _section,
        Configuration memory _config
    )
        public virtual
    {
        bool sweep = _isSweep(_section);
        bool governance = _wants(_section, "governance");
        _warnOnEmptyRoles(_section, _config);
        if (governance) {
            if (_config.pausers.length > 0) {
                IIPauseFacet(_diamond).addPausers(_config.pausers);
                _print("SUBMITTED: addPausers");
            }
            if (_config.unpausers.length > 0) {
                IIPauseFacet(_diamond).addUnpausers(_config.unpausers);
                _print("SUBMITTED: addUnpausers");
            }
        }
        if (_wants(_section, "implementations") && _ready(_config, "implementations", sweep)) {
            // the same skip `prepare` makes, so the two phases send the same set: a registration
            // the diamond has already made costs a timelocked call to change nothing
            (address personalAccount, address subaccount, bool known) = _registeredImplementations(
                _diamond,
                _config.subaccountType
            );
            // the flag decides once, here, rather than qualifying each comparison below: an
            // unreadable registry reports the zero address, a configured implementation is never
            // zero, and a comparison that can only ever be false is not a guard - it is a reader's
            // trap. What "unknown" actually changes is that it is SAID
            bool skipPersonalAccount;
            bool skipSubaccount;
            if (known) {
                skipPersonalAccount = personalAccount == _config.personalAccountImplementation;
                skipSubaccount = subaccount == _config.loanSubaccountImplementation;
            } else {
                _print("NOTE: the implementation registry is not cut yet, so no registration is filtered");
            }
            if (skipPersonalAccount) {
                _print("SKIPPED: setPersonalAccountImplementation - already registered");
            } else {
                IIPersonalAccountsFacet(_diamond).setPersonalAccountImplementation(
                    _config.personalAccountImplementation
                );
                _print("SUBMITTED: setPersonalAccountImplementation");
            }
            if (skipSubaccount) {
                _print("SKIPPED: setSubaccountImplementation - already registered");
            } else {
                IISubaccountsFacet(_diamond).setSubaccountImplementation(
                    _config.subaccountType,
                    _config.loanSubaccountImplementation
                );
                _print("SUBMITTED: setSubaccountImplementation");
            }
        }
        if (_wants(_section, "transport") && _ready(_config, "transport", sweep)) {
            IIComposeTransportFacet(_diamond).setComposeTransport(_config.transport);
            _print("SUBMITTED: setComposeTransport");
        }
        if (_wants(_section, "market") && _ready(_config, "market", sweep)) {
            IIMorphoLoanMarketsFacet(_diamond).registerLoanMarket(_config.subaccountType, _config.market);
            _print("SUBMITTED: registerLoanMarket");
        }
        if (_wants(_section, "fees") && _ready(_config, "fees", sweep)) {
            IIMorphoLoanMarketsFacet(_diamond).setLoanFeeTerms(_config.subaccountType, _config.fees);
            _print("SUBMITTED: setLoanFeeTerms");
        }
        // last, so a run that also wires does not queue its own wiring behind the duration
        if (governance) {
            IITimelockFacet(_diamond).setTimelockDuration(_config.timelockDurationSeconds);
            _print("SUBMITTED: setTimelockDuration");
        }
    }

    /// @notice What the chain says once the calls have landed, not what any of them returned. Both
    /// role lists exactly as configured - no extra member either, so a role holder nobody configured
    /// is a finding rather than a detail - the duration to the second, and every wired field.
    function requireApplied(
        address _diamond,
        string memory _section,
        Configuration memory _config
    )
        public virtual
    {
        bool sweep = _isSweep(_section);
        if (_wants(_section, "governance")) {
            address[] memory pausers = IPauseFacet(_diamond).getPausers();
            address[] memory unpausers = IPauseFacet(_diamond).getUnpausers();
            require(pausers.length == _config.pausers.length, "the pausers on chain are not the configured set");
            require(
                unpausers.length == _config.unpausers.length,
                "the unpausers on chain are not the configured set"
            );
            for (uint256 i = 0; i < _config.pausers.length; i++) {
                require(
                    IPauseFacet(_diamond).isPauser(_config.pausers[i]),
                    "a configured pauser is not a pauser"
                );
            }
            for (uint256 i = 0; i < _config.unpausers.length; i++) {
                require(
                    IPauseFacet(_diamond).isUnpauser(_config.unpausers[i]),
                    "a configured unpauser is not an unpauser"
                );
            }
            uint256 duration = ITimelockFacet(_diamond).getTimelockDurationSeconds();
            require(
                duration == _config.timelockDurationSeconds,
                "the timelock duration on chain is not the configured one"
            );
            _print(string.concat("VERIFIED: pausers ", vm.toString(pausers.length)));
            _print(string.concat("VERIFIED: unpausers ", vm.toString(unpausers.length)));
            _print(string.concat("VERIFIED: timelockDurationSeconds ", vm.toString(duration)));
        }
        if (_wants(_section, "implementations") && _ready(_config, "implementations", sweep)) {
            require(
                IPersonalAccountsFacet(_diamond).implementation() == _config.personalAccountImplementation,
                "the Personal Account implementation on chain is not the recorded one"
            );
            require(
                ISubaccountsFacet(_diamond).implementationForType(_config.subaccountType) ==
                    _config.loanSubaccountImplementation,
                "the subaccount implementation on chain is not the recorded one"
            );
            _print("VERIFIED: implementations");
        }
        if (_wants(_section, "transport") && _ready(_config, "transport", sweep)) {
            IComposeTransportFacet.Transport memory live = IComposeTransportFacet(_diamond).getComposeTransport();
            require(
                live.lzEndpoint == _config.transport.lzEndpoint,
                "the endpoint on chain is not the configured one"
            );
            require(live.oft == _config.transport.oft, "the OFT on chain is not the configured one");
            require(
                live.originEid == _config.transport.originEid,
                "the origin eid on chain is not the configured one"
            );
            require(
                live.originPeer == _config.transport.originPeer,
                "the origin peer on chain is not the configured one"
            );
            _print("VERIFIED: composeTransport");
        }
        if (_wants(_section, "market") && _ready(_config, "market", sweep)) {
            IMorphoLoanMarketsFacet.Market memory live =
                IMorphoLoanMarketsFacet(_diamond).getLoanMarket(_config.subaccountType);
            require(live.morpho == _config.market.morpho, "the Morpho address on chain is not the configured one");
            require(
                keccak256(abi.encode(live.marketParams)) == keccak256(abi.encode(_config.market.marketParams)),
                "the market parameters on chain are not the configured ones"
            );
            _print("VERIFIED: loanMarket");
        }
        if (_wants(_section, "fees") && _ready(_config, "fees", sweep)) {
            IMorphoLoanMarketsFacet.FeeTerms memory live =
                IMorphoLoanMarketsFacet(_diamond).getLoanFeeTerms(_config.subaccountType);
            require(live.feeFloor == _config.fees.feeFloor, "the fee floor on chain is not the configured one");
            require(live.feeSpread == _config.fees.feeSpread, "the fee spread on chain is not the configured one");
            require(
                live.feeRecipient == _config.fees.feeRecipient,
                "the fee recipient on chain is not the configured one"
            );
            _print("VERIFIED: loanFeeTerms");
        }
    }

    /// @notice The section's calls, in the order they must be submitted. A section named on its own
    /// must be ready; a sweep (`wiring`, `all`) skips one that is not, so a config without a market
    /// still prepares the transport.
    function callsFor(
        string memory _section,
        Configuration memory _config
    )
        public
        returns (Call[] memory _calls)
    {
        bool sweep = _isSweep(_section);
        bool governance = _wants(_section, "governance");
        bool implementations = _wants(_section, "implementations") && _ready(_config, "implementations", sweep);
        bool transport = _wants(_section, "transport") && _ready(_config, "transport", sweep);
        bool market = _wants(_section, "market") && _ready(_config, "market", sweep);
        bool fees = _wants(_section, "fees") && _ready(_config, "fees", sweep);

        uint256 count =
            (governance ? 1 + (_config.pausers.length > 0 ? 1 : 0) + (_config.unpausers.length > 0 ? 1 : 0) : 0) +
            (implementations ? 2 : 0) + (transport ? 1 : 0) + (market ? 1 : 0) + (fees ? 1 : 0);
        require(count > 0, "nothing to do: the named section is empty for this configuration");
        _calls = new Call[](count);
        uint256 next = 0;
        // the roles first, and the duration LAST of everything this run emits - not merely last of
        // the governance section. A run that carries wiring too would otherwise set the duration and
        // then queue its own transport, market and fees behind it, and report a configuration that
        // has not applied
        if (governance) {
            if (_config.pausers.length > 0) {
                _calls[next] = Call("addPausers", abi.encodeCall(IIPauseFacet.addPausers, (_config.pausers)));
                next++;
            }
            if (_config.unpausers.length > 0) {
                _calls[next] = Call(
                    "addUnpausers",
                    abi.encodeCall(IIPauseFacet.addUnpausers, (_config.unpausers))
                );
                next++;
            }
        }
        if (implementations) {
            _calls[next] = Call(
                "setPersonalAccountImplementation",
                abi.encodeCall(
                    IIPersonalAccountsFacet.setPersonalAccountImplementation,
                    (_config.personalAccountImplementation)
                )
            );
            next++;
            _calls[next] = Call(
                "setSubaccountImplementation",
                abi.encodeCall(
                    IISubaccountsFacet.setSubaccountImplementation,
                    (_config.subaccountType, _config.loanSubaccountImplementation)
                )
            );
            next++;
        }
        if (transport) {
            _calls[next] = Call(
                "setComposeTransport",
                abi.encodeCall(IIComposeTransportFacet.setComposeTransport, (_config.transport))
            );
            next++;
        }
        if (market) {
            _calls[next] = Call(
                "registerLoanMarket",
                abi.encodeCall(
                    IIMorphoLoanMarketsFacet.registerLoanMarket,
                    (_config.subaccountType, _config.market)
                )
            );
            next++;
        }
        if (fees) {
            _calls[next] = Call(
                "setLoanFeeTerms",
                abi.encodeCall(IIMorphoLoanMarketsFacet.setLoanFeeTerms, (_config.subaccountType, _config.fees))
            );
            next++;
        }
        if (governance) {
            _calls[next] = Call(
                "setTimelockDuration",
                abi.encodeCall(IITimelockFacet.setTimelockDuration, (_config.timelockDurationSeconds))
            );
        }
    }

    /**
     * @notice The section's calls, minus the registrations the diamond has already made.
     * @param _diamond The diamond the calls are for; its registries are what is consulted.
     * @param _section The section name.
     * @param _config The configuration.
     * @return The calls still worth submitting.
     * @dev Only the `implementations` section is filtered, and only because the no-op is its
     * NORMAL case rather than an exception: the deploy reuses an implementation whose code has not
     * changed, so a sweep after it would re-register the address the diamond already serves. That
     * costs a timelocked call, three signatures and an execution to change nothing, and on a chain
     * with a delay it also parks a matured call anyone can execute later.
     *
     * The other sections are deliberately left alone. Re-registering a market is refused on chain
     * (write-once), and a request to register a DIFFERENT one is a disagreement with the config
     * that must reach a person rather than be filtered out of the output; the transport and the
     * fee terms are legitimately re-set to the same values as part of a rotation; and the duration
     * is the deliberate last call of every run.
     *
     * A registry that cannot be read - the facet is not cut yet - filters nothing: before the cut
     * every registration is still due, which is exactly what an unfiltered list says.
     */
    function pendingCallsFor(
        address _diamond,
        string memory _section,
        Configuration memory _config
    )
        public virtual
        returns (Call[] memory)
    {
        Call[] memory calls = callsFor(_section, _config);
        // what the list HOLDS, not what the section asked for: a sweep over a record that names no
        // implementations emits no registrations, and reading a registry for calls that are not
        // there would let a failing getter stop a run with nothing to filter - which `submit`, on
        // the same inputs, completes
        bool registers = false;
        for (uint256 i = 0; i < calls.length; i++) {
            if (
                _isCall(calls[i], "setPersonalAccountImplementation") ||
                _isCall(calls[i], "setSubaccountImplementation")
            ) {
                registers = true;
                break;
            }
        }
        if (!registers) {
            return calls;
        }
        (address personalAccount, address subaccount, bool known) = _registeredImplementations(
            _diamond,
            _config.subaccountType
        );
        // an unreadable registry is stated rather than assumed away: it filters nothing, and the
        // note is what tells the operator that the absence of SKIPPED lines is ignorance rather
        // than a diamond that disagrees
        if (!known) {
            _print("NOTE: the implementation registry is not cut yet, so no registration is filtered");
            return calls;
        }
        bool[] memory keep = new bool[](calls.length);
        uint256 kept = 0;
        for (uint256 i = 0; i < calls.length; i++) {
            keep[i] = true;
            if (
                _isCall(calls[i], "setPersonalAccountImplementation") &&
                personalAccount == _config.personalAccountImplementation
            ) {
                keep[i] = false;
                _print(
                    string.concat(
                        "SKIPPED: setPersonalAccountImplementation - the diamond already registers ",
                        vm.toString(personalAccount)
                    )
                );
            }
            if (
                _isCall(calls[i], "setSubaccountImplementation") &&
                subaccount == _config.loanSubaccountImplementation
            ) {
                keep[i] = false;
                _print(
                    string.concat(
                        "SKIPPED: setSubaccountImplementation - the diamond already registers ",
                        vm.toString(subaccount)
                    )
                );
            }
            if (keep[i]) {
                kept++;
            }
        }
        Call[] memory pending = new Call[](kept);
        uint256 next = 0;
        for (uint256 i = 0; i < calls.length; i++) {
            if (keep[i]) {
                pending[next] = calls[i];
                next++;
            }
        }
        return pending;
    }

    /**
     * @dev Both registries, and whether they answered at all. Read together because they live on
     * facets the same cut installs: either both are there or neither is, and one flag for the pair
     * keeps the caller from filtering half a section on half an answer.
     */
    function _registeredImplementations(
        address _diamond,
        uint256 _subaccountType
    )
        internal view
        returns (address, address, bool)
    {
        (address personalAccount, bool personalAccountKnown) = _registeredPersonalAccount(_diamond);
        (address subaccount, bool subaccountKnown) = _registeredSubaccount(_diamond, _subaccountType);
        return (personalAccount, subaccount, personalAccountKnown && subaccountKnown);
    }

    /**
     * @dev The registered Personal Account implementation, and whether it could be read at all.
     * The getter lives on a facet the cut installs, so before the cut it reverts exactly as a
     * diamond answers any selector it does not serve. That ONE revert means "not cut yet" and
     * nothing else: the whole payload is compared, since the same error naming another selector
     * came from somewhere else in the call, and reading it as an absent facet would file a failed
     * registry read as "still to register".
     */
    function _registeredPersonalAccount(
        address _diamond
    )
        internal view
        returns (address, bool)
    {
        try IPersonalAccountsFacet(_diamond).implementation() returns (address live) {
            return (live, true);
        } catch (bytes memory reason) {
            _requireNotServed(reason, IBeacon.implementation.selector, "the Personal Account");
            return (address(0), false);
        }
    }

    /// @dev The registered implementation of a subaccount type, and whether it could be read.
    function _registeredSubaccount(
        address _diamond,
        uint256 _subaccountType
    )
        internal view
        returns (address, bool)
    {
        try ISubaccountsFacet(_diamond).implementationForType(_subaccountType) returns (address live) {
            return (live, true);
        } catch (bytes memory reason) {
            _requireNotServed(reason, ISubaccountsFacet.implementationForType.selector, "the subaccount");
        }
        return (address(0), false);
    }

    /// @dev Passes only the diamond's own answer for the selector it was asked about.
    function _requireNotServed(
        bytes memory _reason,
        bytes4 _selector,
        string memory _what
    )
        internal pure
    {
        bytes memory notServed = abi.encodeWithSelector(FunctionNotFound.selector, _selector);
        require(
            keccak256(_reason) == keccak256(notServed),
            string.concat(
                "reading ", _what, " implementation registry reverted, and not because its facet is missing"
            )
        );
    }

    /// @dev Whether a built call is the named one.
    function _isCall(
        Call memory _call,
        string memory _description
    )
        internal pure
        returns (bool)
    {
        return keccak256(bytes(_call.description)) == keccak256(bytes(_description));
    }

    /// @notice What must hold before `execute` sends anything: the signer owns the diamond, and the
    /// duration is still zero, so the calls apply instead of queueing. A diamond that already has a
    /// duration is governance's, whatever the key says, and `prepare` is the phase for it.
    function requireExecutable(
        address _diamond,
        address _signer
    )
        public view
    {
        require(
            IERC173(_diamond).owner() == _signer,
            "execute needs the diamond's current owner to sign: use prepare for a multisig owner"
        );
        require(
            ITimelockFacet(_diamond).getTimelockDurationSeconds() == 0,
            "the timelock is already set: these calls would queue - use prepare"
        );
    }

    /// @notice The configuration for `_network`. Every key is read, so a file missing one is a file
    /// that stops the run rather than a section that silently does nothing; an unknown value is
    /// written as zero and its section reported as not ready.
    /// @notice The whole configuration a run works from: the chain config, plus the two addresses
    /// that are not in it. Kept as one seam rather than assembled inside `run`, so that which record
    /// a target reads - and that a run reads one at all - is drivable from a test.
    function configurationFor(
        string memory _network,
        string memory _target
    )
        public view
        returns (Configuration memory _config)
    {
        _config = readConfiguration(_network);
        (_config.personalAccountImplementation, _config.loanSubaccountImplementation) =
            readImplementations(_network, _target);
    }

    function readConfiguration(
        string memory _network
    )
        public view
        returns (Configuration memory _config)
    {
        return parseConfiguration(vm.readFile(string.concat("deployment/chain-config/", _network, ".json")));
    }

    /// @notice The same, from the file's contents: every key read, every value checked. Separate
    /// from the read so the checks can be exercised over a configuration that was never written to
    /// the tree - which is the only way to drive a malformed one.
    function parseConfiguration(
        string memory source
    )
        public pure
        returns (Configuration memory _config)
    {
        _config.governance = vm.parseJsonAddress(source, ".governance");
        _config.timelockDurationSeconds = vm.parseJsonUint(source, ".timelockDurationSeconds");
        _config.pausers = vm.parseJsonAddressArray(source, ".pausers");
        _config.unpausers = vm.parseJsonAddressArray(source, ".unpausers");
        _config.subaccountType = vm.parseJsonUint(source, ".subaccountType");
        _config.transport = IComposeTransportFacet.Transport({
            lzEndpoint: vm.parseJsonAddress(source, ".composeTransport.lzEndpoint"),
            oft: vm.parseJsonAddress(source, ".composeTransport.oft"),
            // range-checked before the cast: a value too large would otherwise wrap to a different,
            // perfectly plausible one, and every later check would compare the chain against that
            originEid: uint32(
                _bounded(vm.parseJsonUint(source, ".composeTransport.originEid"), type(uint32).max, "originEid")
            ),
            originPeer: bytes32(uint256(uint160(vm.parseJsonAddress(source, ".composeTransport.originPeer"))))
        });
        _config.market = IMorphoLoanMarketsFacet.Market({
            morpho: vm.parseJsonAddress(source, ".loanMarket.morpho"),
            marketParams: IMorpho.MarketParams({
                loanToken: vm.parseJsonAddress(source, ".loanMarket.loanToken"),
                collateralToken: vm.parseJsonAddress(source, ".loanMarket.collateralToken"),
                oracle: vm.parseJsonAddress(source, ".loanMarket.oracle"),
                irm: vm.parseJsonAddress(source, ".loanMarket.irm"),
                lltv: vm.parseJsonUint(source, ".loanMarket.lltv")
            })
        });
        _config.fees = IMorphoLoanMarketsFacet.FeeTerms({
            feeFloor: uint64(
                _bounded(vm.parseJsonUint(source, ".loanFeeTerms.feeFloor"), type(uint64).max, "feeFloor")
            ),
            feeSpread: uint64(
                _bounded(vm.parseJsonUint(source, ".loanFeeTerms.feeSpread"), type(uint64).max, "feeSpread")
            ),
            feeRecipient: vm.parseJsonAddress(source, ".loanFeeTerms.feeRecipient")
        });
        require(_config.governance != address(0), "the chain config names no governance");
        require(_config.timelockDurationSeconds > 0, "the chain config's timelock duration is zero");
        require(_config.subaccountType != 0, "the chain config's subaccount type is zero");
        // a repeated address would make the role lists pass a length comparison they should fail:
        // two entries, one holder
        _requireNoDuplicates(_config.pausers, "pausers");
        _requireNoDuplicates(_config.unpausers, "unpausers");
    }

    /// @dev `_value` as it was written, or a stopped run: a configuration value that does not fit
    /// the field it is bound for is a typo, and truncating it would leave the chain configured with
    /// something nobody wrote and every later comparison agreeing with the truncation.
    function _bounded(
        uint256 _value,
        uint256 _max,
        string memory _field
    )
        internal pure
        returns (uint256)
    {
        require(_value <= _max, string.concat("the chain config's ", _field, " does not fit its field"));
        return _value;
    }

    function _requireNoDuplicates(
        address[] memory _addresses,
        string memory _field
    )
        internal pure
    {
        for (uint256 i = 0; i < _addresses.length; i++) {
            for (uint256 j = i + 1; j < _addresses.length; j++) {
                require(
                    _addresses[i] != _addresses[j],
                    string.concat("the chain config's ", _field, " list repeats an address")
                );
            }
        }
    }

    /// @dev Whether the section's values are filled in. A sweep prints why it skipped one; a section
    /// named on its own stops the run with the same reason, since asking for it and getting nothing
    /// is not an answer.
    function _ready(
        Configuration memory _config,
        string memory _name,
        bool _sweep
    )
        internal
        returns (bool)
    {
        bytes32 name = keccak256(bytes(_name));
        bool ready;
        string memory reason;
        if (name == keccak256("implementations")) {
            // one without the other is not the early state a sweep may pass over: something WAS
            // deployed and the record is half written. Skipping that silently would arm the
            // timelock over a deployment whose accounts resolve no implementation at all
            require(
                (_config.personalAccountImplementation == address(0)) ==
                    (_config.loanSubaccountImplementation == address(0)),
                "the deployment record names one remote implementation but not the other"
            );
            ready = _implementationsReady(_config);
            reason = "the deployment record names no remote implementations";
        } else if (name == keccak256("transport")) {
            ready = _transportReady(_config);
            reason = "the composeTransport section is not filled in";
        } else if (name == keccak256("market")) {
            ready = _marketReady(_config);
            reason = "the loanMarket section is not filled in";
        } else {
            ready = _feesReady(_config);
            reason = "the loanFeeTerms section names no recipient";
        }
        if (!ready) {
            require(_sweep, reason);
            _print(string.concat("SKIPPED: ", reason));
        }
        return ready;
    }

    /// @dev Beside the cut flow's prepared calldata, under the same per-network directory.
    function _writeCalls(
        string memory _network,
        string memory _section,
        string memory _lines
    )
        internal virtual
    {
        string[] memory mkdirCmd = new string[](3);
        mkdirCmd[0] = "mkdir";
        mkdirCmd[1] = "-p";
        mkdirCmd[2] = string.concat("deployment/output-internal/", _network);
        vm.ffi(mkdirCmd);
        string memory path = string.concat(
            "deployment/output-internal/", _network, "/configuration-", _section, ".txt"
        );
        vm.writeFile(path, _lines);
        _print(string.concat("WROTE: ", path));
    }

    /// @dev The console seam the tests capture, so they can assert what an operator reads.

    /**
     * @notice The account this run signs as.
     * @dev In a run this is the signer forge resolved from the command line - a raw key, a keystore
     * or a Ledger - so the account the script checks and the account that signs are the same one.
     * It is a seam because a test cannot name that account any other way: `vm.prank` and a
     * broadcast are mutually exclusive, so a harness overrides this instead.
     */
    function _signer()
        internal view virtual
        returns (address)
    {
        return msg.sender;
    }

    function _print(
        string memory _line
    )
        internal virtual
    {
        console2.log(_line);
    }
    /// @notice Where the throwaway deployment's record lives: the gitignored `_mock` file the deploy
    /// wrapper writes. A seam, so a test can drive the resolver over a record of its own rather than
    /// over whatever this working tree happens to hold.
    function throwawayRecordPath(
        string memory _network
    )
        public view virtual
        returns (string memory)
    {
        return string.concat("deployment/deploys/", _network, "_mock.json");
    }

    /// @dev The record the pinned target's implementations are read from, which the deploy flow
    /// writes and every other tool resolves addresses through.
    function deploymentRecordPath(
        string memory _network
    )
        public view virtual
        returns (string memory)
    {
        return string.concat("deployment/deploys/", _network, ".json");
    }

    /// @notice The two remote implementations the target's record names, zero for either it does
    /// not. A missing record is not an error here: before `deploy_remote_account_implementations`
    /// has run there is nothing to register, and the section reports itself unready rather than
    /// stopping a run that is about to configure something else.
    function readImplementations(
        string memory _network,
        string memory _target
    )
        public view virtual
        returns (address _personalAccount, address _loanSubaccount)
    {
        string memory path;
        if (keccak256(bytes(_target)) == keccak256("throwaway")) {
            path = throwawayRecordPath(_network);
        } else {
            path = deploymentRecordPath(_network);
        }
        if (!vm.exists(path)) {
            return (address(0), address(0));
        }
        return implementationsFromRecord(vm.readFile(path));
    }

    /// @notice The same, from the record's contents, so a test can drive a record that is not in
    /// the tree. Both deploy paths write these two names - the throwaway's own run and
    /// `deploy_remote_account_implementations` - so one reader serves either target.
    function implementationsFromRecord(
        string memory _record
    )
        public pure
        returns (address _personalAccount, address _loanSubaccount)
    {
        RecordedContract[] memory records = abi.decode(vm.parseJson(_record), (RecordedContract[]));
        // whether the name was SEEN, not whether it produced an address: a zero-valued entry is
        // still an entry, and counting it as unseen would let a second one through
        bool seenPersonalAccount;
        bool seenLoanSubaccount;
        for (uint256 i = 0; i < records.length; i++) {
            bytes32 name = keccak256(bytes(records[i].name));
            // refused rather than resolved: the recorder updates the FIRST entry of a name, so a
            // record holding two of one name would leave a re-deployment writing to one of them
            // and this reading the other - a stale address, registered as if it were current
            if (name == keccak256("PersonalAccountRemoteImplementation")) {
                require(
                    !seenPersonalAccount,
                    "the deployment record names PersonalAccountRemoteImplementation twice"
                );
                seenPersonalAccount = true;
                _personalAccount = records[i].contractAddress;
            } else if (name == keccak256("MorphoLoanSubaccountRemoteImplementation")) {
                require(
                    !seenLoanSubaccount,
                    "the deployment record names MorphoLoanSubaccountRemoteImplementation twice"
                );
                seenLoanSubaccount = true;
                _loanSubaccount = records[i].contractAddress;
            }
        }
    }

    /// @notice The controller a deployment record names, from the record's own contents - the
    /// throwaway wrapper writes it through `save-deployed-addresses.ts mock`. Taking the text rather
    /// than the path is what lets a test drive a record that is not in the tree.
    function controllerFromRecord(
        string memory _record
    )
        public pure
        returns (address)
    {
        RecordedContract[] memory records = abi.decode(vm.parseJson(_record), (RecordedContract[]));
        for (uint256 i = 0; i < records.length; i++) {
            if (keccak256(bytes(records[i].name)) == keccak256("MasterAccountController")) {
                return records[i].contractAddress;
            }
        }
        revert("the throwaway record holds no MasterAccountController");
    }

    /// @notice What a throwaway target must be: not the production controller, and deployed. The
    /// first would mean the historical bytes had been reproduced after all; the second, that the
    /// record describes something that no longer exists on this chain.
    function requireUsableThrowaway(
        address _diamond
    )
        public view
    {
        require(
            _diamond != PinnedControllerInitCode.MASTER_ACCOUNT_CONTROLLER,
            "the throwaway record names the pinned controller: it is not a throwaway"
        );
        require(_diamond.code.length > 0, "the throwaway record names an address with no code");
    }

    /// @dev An empty role list is legal and is a decision, not an omission: with nobody holding
    /// the role, the pause path cannot be exercised at all, and once the duration is set adding
    /// someone takes the full delay. Said out loud rather than refused.
    function _warnOnEmptyRoles(
        string memory _section,
        Configuration memory _config
    )
        internal
    {
        if (!_wants(_section, "governance")) {
            return;
        }
        if (_config.pausers.length == 0) {
            _print("NOTE: no pausers configured - nobody will be able to pause this deployment");
        }
        if (_config.unpausers.length == 0) {
            _print("NOTE: no unpausers configured - nobody will be able to unpause this deployment");
        }
    }

    /// @dev Whether `_section` covers `_name`. `wiring` is the three wiring sections and `all` is
    /// every one of them.
    function _wants(
        string memory _section,
        string memory _name
    )
        internal pure
        returns (bool)
    {
        bytes32 section = keccak256(bytes(_section));
        if (section == keccak256("all")) {
            return true;
        }
        if (section == keccak256("wiring")) {
            // named rather than "everything but governance": the implementations are not wiring,
            // and a sweep that silently carried them would register from a record nobody named
            bytes32 name = keccak256(bytes(_name));
            return name == keccak256("transport") || name == keccak256("market") || name == keccak256("fees");
        }
        return section == keccak256(bytes(_name));
    }

    function _isSweep(
        string memory _section
    )
        internal pure
        returns (bool)
    {
        bytes32 section = keccak256(bytes(_section));
        return section == keccak256("all") || section == keccak256("wiring");
    }

    /// @dev Both, or neither: one implementation without the other is half a registration, and the
    /// section exists to make the pair land together.
    function _implementationsReady(
        Configuration memory _config
    )
        internal pure
        returns (bool)
    {
        return _config.personalAccountImplementation != address(0) &&
            _config.loanSubaccountImplementation != address(0);
    }

    function _transportReady(
        Configuration memory _config
    )
        internal pure
        returns (bool)
    {
        return _config.transport.lzEndpoint != address(0) &&
            _config.transport.oft != address(0) &&
            _config.transport.originEid != 0 &&
            _config.transport.originPeer != bytes32(0);
    }

    function _marketReady(
        Configuration memory _config
    )
        internal pure
        returns (bool)
    {
        IMorpho.MarketParams memory params = _config.market.marketParams;
        // no IRM check: `registerLoanMarket` does not require one either, and Morpho markets with
        // the zero rate model are legitimate - refusing them here would call a complete config
        // incomplete
        return _config.market.morpho != address(0) &&
            params.loanToken != address(0) &&
            params.collateralToken != address(0) &&
            params.oracle != address(0) &&
            params.lltv != 0;
    }

    /// @dev The recipient alone: zero rates with a recipient are a deliberate fee-off, and the
    /// recipient is what the contract treats as the activation marker.
    function _feesReady(
        Configuration memory _config
    )
        internal pure
        returns (bool)
    {
        return _config.fees.feeRecipient != address(0);
    }
}
