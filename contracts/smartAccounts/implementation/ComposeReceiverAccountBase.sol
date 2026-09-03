// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {OFTComposeMsgCodec} from "@layerzerolabs/oft-evm/contracts/libs/OFTComposeMsgCodec.sol";
import {GUID} from "@layerzerolabs/lz-evm-protocol-v2/contracts/libs/GUID.sol";
import {IMessagingChannel} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/IMessagingChannel.sol";
// import is needed for @inheritdoc
// solhint-disable-next-line no-unused-import
import {ILayerZeroComposer} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroComposer.sol";
import {
    IComposeReceiverAccountBase,
    PAYLOAD_VERSION_1,
    SKIP_REASON_DUPLICATE,
    SKIP_REASON_EXPIRED
} from "../../userInterfaces/IComposeReceiverAccountBase.sol";
import {IComposeTransportFacet} from "../../userInterfaces/facets/IComposeTransportFacet.sol";
import {IPauseFacet} from "../../userInterfaces/facets/IPauseFacet.sol";
import {ControlledAccountBase} from "./ControlledAccountBase.sol";

/**
 * @title ComposeReceiverAccountBase contract
 * @notice Shared authenticated `lzCompose` ingress and operation-id replay protection for the
 * accounts that receive compose messages from their own twin on the other chain. Derived
 * accounts define their action set ({_dispatch}), their transport source ({_getTransport}),
 * whether compose value is accepted ({_acceptsComposeValue}) and their identity; their
 * parent-driven and public rails stay outside this base. The authentication is deliberately in
 * one place: it is the security root of every action that arrives without a local signature.
 * @dev STORAGE: the consumed operation ids live in the
 * `smartAccounts.ComposeReceiverAccountBase.State` namespace (see the storage rule on
 * {ControlledAccountBase}), so this base can grow without shifting any lineage that
 * inherits it.
 */
abstract contract ComposeReceiverAccountBase is
    IComposeReceiverAccountBase, ControlledAccountBase, ReentrancyGuardTransient
{
    using OFTComposeMsgCodec for bytes;

    /// @custom:storage-location erc7201:smartAccounts.ComposeReceiverAccountBase.State
    struct ComposeReceiverState {
        mapping(bytes32 operationId => bool used) usedOperations;
    }

    bytes32 private constant COMPOSE_RECEIVER_STATE_POSITION =
        bytes32(erc7201("smartAccounts.ComposeReceiverAccountBase.State"));

    /// @inheritdoc ILayerZeroComposer
    /// @dev The authenticated entry point; {_authenticate} holds the full checklist. The
    /// executor and extra data are untrusted and ignored. A failing message reverts and stays
    /// retriable at the endpoint; any tokens it bridged are already on this account.
    function lzCompose(
        address _from,
        bytes32 _guid,
        bytes calldata _message,
        address /* _executor */,
        bytes calldata /* _extraData */
    )
        external payable
        nonReentrant
    {
        IComposeTransportFacet.Transport memory transport = _getTransport();
        _authenticate(transport, _from, _guid, _message);

        (uint8 version, uint8 action, bytes memory actionData) =
            abi.decode(_message.composeMsg(), (uint8, uint8, bytes));
        require(version == PAYLOAD_VERSION_1, UnsupportedPayloadVersion(version));
        // most actions never expect compose value; rejecting it keeps a mistaken delivery
        // retriable through the endpoint without value. An action that spends or forwards the
        // value in the same call (the Flare redeem-on-arrival, the loan-chain atomic withdraw)
        // opts in - per action, so no other branch of the same receiver can silently keep
        // native
        require(msg.value == 0 || _acceptsComposeValue(action), NonZeroComposeValue());
        _dispatch(action, actionData, _guid, _message.amountLD());
    }

    /// @inheritdoc IComposeReceiverAccountBase
    function usedOperations(
        bytes32 _operationId
    )
        external view
        returns (bool)
    {
        return _getComposeReceiverState().usedOperations[_operationId];
    }

    /// @dev The account's action set: executes `_action` or reverts `UnsupportedAction`.
    /// Runs after full authentication; `_amountLD` is the authenticated bridged amount.
    function _dispatch(
        uint8 _action,
        bytes memory _actionData,
        bytes32 _guid,
        uint256 _amountLD
    )
        internal virtual;

    /// @dev The full authentication checklist: the caller must be the endpoint, the sender
    /// the configured OFT, the source chain the origin, the source-chain sender this
    /// account itself, and the delivered GUID must recompute from the pinned origin peer
    /// (the compose wrapper alone does not commit to the source OApp, so this last check is
    /// what defeats a temporarily swapped OFT peer).
    function _authenticate(
        IComposeTransportFacet.Transport memory _transport,
        address _from,
        bytes32 _guid,
        bytes calldata _message
    )
        internal view
    {
        require(msg.sender == _transport.lzEndpoint, OnlyEndpoint());
        require(_from == _transport.oft, WrongComposeSender(_from));
        uint32 srcEid = _message.srcEid();
        require(srcEid == _transport.originEid, WrongSourceEid(srcEid));
        // the canonical OFT codec records the source-chain caller of `send`; only this
        // account itself sends composed messages here, so any other sender must not execute
        bytes32 composeFrom = _message.composeFrom();
        require(
            composeFrom == bytes32(uint256(uint160(address(this)))),
            WrongComposeFrom(composeFrom)
        );
        // bind the message to the pinned origin peer: the endpoint computed the GUID from the
        // true packet header, so it cannot match unless the sender was exactly the pinned peer
        bytes32 expectedGuid = GUID.generate(
            _message.nonce(),
            srcEid,
            address(uint160(uint256(_transport.originPeer))),
            IMessagingChannel(_transport.lzEndpoint).eid(),
            bytes32(uint256(uint160(_transport.oft)))
        );
        require(_guid == expectedGuid, WrongGuid(_guid));
    }

    /// @dev The soft terminal gates shared by all actions: returns a skip reason for a
    /// duplicate (already-consumed) id or a stale deadline, zero to proceed. The derived
    /// account emits its own skip event. Expiry leaves the id unconsumed for a retry with a
    /// fresh deadline.
    function _terminalSkipReason(
        bytes32 _operationId,
        uint64 _deadline
    )
        internal view
        returns (uint8 _reason)
    {
        if (_getComposeReceiverState().usedOperations[_operationId]) {
            return SKIP_REASON_DUPLICATE;
        }
        if (block.timestamp > _deadline) {
            return SKIP_REASON_EXPIRED;
        }
        return 0;
    }

    /// @dev Consumes an operation id: the signed action it carried has executed.
    function _markOperationUsed(
        bytes32 _operationId
    )
        internal
    {
        _getComposeReceiverState().usedOperations[_operationId] = true;
    }

    function _getComposeReceiverState()
        private pure
        returns (ComposeReceiverState storage _state)
    {
        bytes32 position = COMPOSE_RECEIVER_STATE_POSITION;
        // solhint-disable-next-line no-inline-assembly
        assembly {
            _state.slot := position
        }
    }

    function _checkNotPaused()
        internal view
    {
        // outward and exposure-increasing moves stop while paused; defensive moves never
        // route through this gate
        require(!IPauseFacet(controllerAddress).isPaused(), IPauseFacet.IsPaused());
    }

    /// @dev The transport this receiver authenticates against: the endpoint that may call, the
    /// OFT that must be the sender, the chain the message must come from and the peer it must
    /// have been sent by. The remote accounts read the diamond's compose transport; the Flare
    /// receiver derives it from its own bridge settings.
    function _getTransport()
        internal view virtual
        returns (IComposeTransportFacet.Transport memory _transport)
    {
        _transport = IComposeTransportFacet(controllerAddress).getComposeTransport();
        require(
            _transport.lzEndpoint != address(0),
            IComposeTransportFacet.ComposeTransportNotConfigured()
        );
    }

    /// @dev Whether `lzCompose` may carry native value for `_action`. False by default; a
    /// receiver overrides it for exactly the actions that spend the value within the same
    /// delivery.
    function _acceptsComposeValue(
        uint8 /* _action */
    )
        internal pure virtual
        returns (bool)
    {
        return false;
    }
}
