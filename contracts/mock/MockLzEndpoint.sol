// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/**
 * @title MockLzEndpoint
 * @notice Minimal LayerZero EndpointV2 stand-in: only the local `eid()` the subaccount reads
 * when recomputing the packet GUID. Tests impersonate this address as the `lzCompose` caller.
 */
contract MockLzEndpoint {
    uint32 public eid;

    constructor(uint32 _eid) {
        eid = _eid;
    }
}
