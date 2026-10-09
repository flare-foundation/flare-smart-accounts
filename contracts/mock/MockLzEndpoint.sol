// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ILayerZeroComposer} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroComposer.sol";
import {Errors} from "@layerzerolabs/lz-evm-protocol-v2/contracts/libs/Errors.sol";

/**
 * @title MockLzEndpoint
 * @notice Minimal LayerZero EndpointV2 stand-in: the local `eid()` the accounts read when
 * recomputing the packet GUID, plus the index-zero compose queue of the real endpoint's
 * `MessagingComposer` - the same queue key, message hash, received sentinel and errors. The
 * OFT (impersonated) queues a compose with {sendCompose}; anyone delivers it with {deliver},
 * which calls the receiver's `lzCompose` with this endpoint as `msg.sender`. Tests that need
 * no queue keep impersonating this address as the `lzCompose` caller directly.
 * @dev Compose index zero only, with a reduced delivery ABI (no executor or extra data):
 * inheriting the full endpoint pushes the non-IR coverage build over the compiler's stack
 * limit.
 */
contract MockLzEndpoint {
    /// @notice The sentinel the real endpoint leaves behind a delivered compose.
    bytes32 private constant RECEIVED_MESSAGE_HASH = bytes32(uint256(1));

    uint32 public eid;
    mapping(address from => mapping(address to => mapping(bytes32 guid => mapping(uint16 index => bytes32 hash))))
        public composeQueue;

    constructor(
        uint32 _eid
    ) {
        eid = _eid;
    }

    /// @notice Queues a compose from `msg.sender` (the OFT) to `_to`, as `EndpointV2.sendCompose` does.
    function sendCompose(
        address _to,
        bytes32 _guid,
        uint16 _index,
        bytes calldata _message
    )
        external
    {
        if (composeQueue[msg.sender][_to][_guid][_index] != bytes32(0)) {
            revert Errors.LZ_ComposeExists();
        }
        composeQueue[msg.sender][_to][_guid][_index] = keccak256(_message);
    }

    /// @notice Delivers the queued index-zero compose `_guid` from `_from` to `_to`, as the
    /// executor's `EndpointV2.lzCompose` does: the hash must match, the entry becomes the
    /// received sentinel, and the value rides along.
    function deliver(
        address _from,
        address _to,
        bytes32 _guid,
        bytes calldata _message
    )
        external payable
    {
        bytes32 expectedHash = composeQueue[_from][_to][_guid][0];
        bytes32 actualHash = keccak256(_message);
        if (expectedHash != actualHash) {
            revert Errors.LZ_ComposeNotFound(expectedHash, actualHash);
        }
        composeQueue[_from][_to][_guid][0] = RECEIVED_MESSAGE_HASH;
        ILayerZeroComposer(_to).lzCompose{value: msg.value}(_from, _guid, _message, msg.sender, "");
    }
}
