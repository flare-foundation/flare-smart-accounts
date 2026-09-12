// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import {Script, console2} from "forge-std/Script.sol";
import {IERC173} from "../../contracts/diamond/interfaces/IERC173.sol";
import {DeployNetworks} from "../lib/DeployNetworks.sol";
import {PinnedControllerInitCode} from "../lib/PinnedControllerInitCode.sol";

/**
 * @title TransferOwnership
 * @notice The pinned remote controller's ownership handover, with the preflight a raw `cast send`
 * does not have. `transferOwnership` is the one call of a deployment that cannot be undone: it is a
 * single step with no acceptance from the new owner, it is not timelocked, and a wrong address ends
 * governance of that diamond permanently. Everything here exists to refuse before that happens.
 *
 * It serves one case, the deployer-owned handover at the end of a rehearsal
 * ([`RUNBOOK.md`](../RUNBOOK.md) Part B): the bootstrap's historical owner signs its one transfer
 * from a wallet, which no wrapper can drive, and a throwaway controller is never handed on. So there
 * is no target argument - the pinned controller is the only diamond this touches.
 *
 * The caller names the owner they believe holds it. That argument is the guard: pointed at the wrong
 * network, or at a diamond somebody else has already taken, the run stops instead of sending. The
 * signing key must be that owner too, so a transfer that could only revert is refused locally rather
 * than paid for.
 *
 * Two phases, for the same reason the configuration script has them: forge collects a script's
 * transactions and broadcasts them after it returns, so a read-back inside the run that sends sees
 * simulated state. The wrapper follows a broadcast with a separate `verify` run, which is the one
 * that reads the chain.
 */
// solhint-disable no-console
contract TransferOwnership is Script {

    function run(
        string calldata _expectedNetwork,
        string calldata _phase,
        address _expectedCurrentOwner,
        address _newOwner
    )
        external
    {
        require(DeployNetworks.isLoanChain(block.chainid), "the pinned controller lives on a loan chain");
        string memory network = DeployNetworks.networkName(block.chainid);
        DeployNetworks.requireExpectedNetwork(network, _expectedNetwork);
        address diamond = PinnedControllerInitCode.MASTER_ACCOUNT_CONTROLLER;
        require(diamond.code.length > 0, "no controller at the pinned address: run the bootstrap first");

        _print(string.concat("NETWORK: ", network));
        _print(string.concat("DIAMOND: ", vm.toString(diamond)));

        bytes32 phase = keccak256(bytes(_phase));
        if (phase == keccak256("execute")) {
            uint256 signerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
            requireTransferable(diamond, _expectedCurrentOwner, _newOwner, vm.addr(signerPrivateKey));
            _print(string.concat("FROM: ", vm.toString(_expectedCurrentOwner)));
            _print(string.concat("TO: ", vm.toString(_newOwner)));
            vm.startBroadcast(signerPrivateKey);
            IERC173(diamond).transferOwnership(_newOwner);
            vm.stopBroadcast();
        } else if (phase == keccak256("verify")) {
            requireOwner(diamond, _newOwner);
        } else {
            revert("unknown phase: execute or verify");
        }
    }

    /// @notice Everything that must hold before the one irreversible call is sent. The current owner
    /// is compared against the one the caller named rather than merely read, because reading it and
    /// proceeding would hand away whatever diamond the run happened to find.
    function requireTransferable(
        address _diamond,
        address _expectedCurrentOwner,
        address _newOwner,
        address _signer
    )
        public
    {
        address current = IERC173(_diamond).owner();
        require(
            current == _expectedCurrentOwner,
            "the diamond's owner is not the one named: check the network and the address"
        );
        require(_newOwner != address(0), "the new owner is the zero address: that would end governance");
        require(_newOwner != _diamond, "the new owner is the diamond itself: that would end governance");
        require(_newOwner != current, "the new owner already owns the diamond: nothing to transfer");
        // the transfer would revert on chain anyway; refusing here costs no gas and says why
        require(_signer == current, "the signing key is not the diamond's owner");
        if (_newOwner.code.length == 0) {
            // legitimate - a deployer or a hardware wallet is an ordinary account - but a handover
            // meant for a multisig and typed one character wrong looks exactly like this
            _print("NOTE: the new owner has no code, so it is an ordinary account rather than a contract");
        }
    }

    /// @notice What the chain says once the transfer has been mined, which is the only proof of it.
    function requireOwner(
        address _diamond,
        address _expectedOwner
    )
        public
    {
        address current = IERC173(_diamond).owner();
        require(current == _expectedOwner, "the owner on chain is not the one the transfer named");
        _print(string.concat("VERIFIED: owner ", vm.toString(current)));
    }

    function _print(
        string memory _line
    )
        internal virtual
    {
        console2.log(_line);
    }
}
