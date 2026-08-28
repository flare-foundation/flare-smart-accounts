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

/**
 * @title ComposeReceiverAccountBase contract
 * @notice The compose-receiver surface shared by the accounts that receive authenticated compose
 * messages - the loan-chain subaccount and Personal Account, and the Flare loan subaccount as the
 * receiver of its own bridge-back (their parent-driven and public rails live outside it): the
 * authenticated `lzCompose` entry (endpoint, OFT, origin chain, self-as-sender, GUID recomputed
 * from the pinned origin peer) and, for the signed id-carrying actions, operation-id replay
 * protection. Derived accounts define only
 * their action set (in {_dispatch}), where their transport configuration lives
 * ({_getTransport}), whether compose value is accepted ({_acceptsComposeValue}), and their
 * identity. The authentication is deliberately in one place: it is the security root of every
 * action that arrives without a local signature.
 */
abstract contract ComposeReceiverAccountBase is IComposeReceiverAccountBase, ReentrancyGuardTransient {
    using OFTComposeMsgCodec for bytes;

    address internal constant EMPTY_ADDRESS = 0x0000000000000000000000000000000000001111;

    // STORAGE PREFIX of every derived account's proxy lineage (the subaccounts on both chains
    // and the remote Personal Account alike): these two fields occupy slots 0 and 1 of
    // every proxy. Once the first proxy is deployed, never insert, remove, or reorder base fields -
    // append new base state only after the derived contracts' own fields would be a layout
    // break too, so base state is effectively frozen at these two.

    /// @dev MasterAccountController address; exposed through {controllerAddress}. Internal
    /// storage rather than a public variable so derived contracts can disambiguate the
    /// getter against interface declarations.
    address internal controller;
    // false positive (uninitialized-state): a mapping has no initializer; derived accounts with
    // signed, id-carrying actions write it, and a receiver whose actions carry no id (the Flare
    // redeem-on-arrival) leaves it empty by design
    // slither-disable-start uninitialized-state
    /// @inheritdoc IComposeReceiverAccountBase
    mapping(bytes32 operationId => bool used) public usedOperations;
    // slither-disable-end uninitialized-state

    constructor() {
        // ensure the implementation contract itself cannot be initialized/used
        controller = EMPTY_ADDRESS;
    }

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
    function controllerAddress()
        external view virtual
        returns (address)
    {
        return controller;
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

    /// @dev One-time controller assignment for the derived account's `initialize`.
    function _setController(
        address _controllerAddress
    )
        internal
    {
        require(controller == address(0), AlreadyInitialized());
        require(_controllerAddress != address(0), InvalidControllerAddress());
        controller = _controllerAddress;
    }

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
        if (usedOperations[_operationId]) {
            return SKIP_REASON_DUPLICATE;
        }
        if (block.timestamp > _deadline) {
            return SKIP_REASON_EXPIRED;
        }
        return 0;
    }

    function _checkNotPaused()
        internal view
    {
        // outward and exposure-increasing moves stop while paused; defensive moves never
        // route through this gate
        require(!IPauseFacet(controller).isPaused(), IPauseFacet.IsPaused());
    }

    /// @dev The transport this receiver authenticates against: the endpoint that may call, the
    /// OFT that must be the sender, the chain the message must come from and the peer it must
    /// have been sent by. The remote accounts read the diamond's compose transport; the Flare
    /// receiver derives it from its own bridge settings.
    function _getTransport()
        internal view virtual
        returns (IComposeTransportFacet.Transport memory _transport)
    {
        _transport = IComposeTransportFacet(controller).getComposeTransport();
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
