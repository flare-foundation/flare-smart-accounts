// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {MessagingComposer} from "@layerzerolabs/lz-evm-protocol-v2/contracts/MessagingComposer.sol";

/**
 * @title CanonicalComposeEndpoint
 * @notice Canonical LayerZero `MessagingComposer`, verbatim from the pinned protocol package,
 * plus the one getter the accounts read from their endpoint. The compose queue's rules are
 * therefore the real ones rather than a mock's reading of them: a GUID may be queued once per
 * index, a message must hash to its entry to execute, a delivered entry is replaced by a
 * sentinel instead of cleared, and a delivery that reverts takes the endpoint's own bookkeeping
 * back with it.
 *
 * Only the composer, because the rest of `EndpointV2` does not compile against this repository's
 * dependencies: `MessageLibManager` inherits OpenZeppelin's `Ownable`, which requires a
 * constructor argument from v5 onwards while LayerZero v3 still calls it as v4's no-argument
 * base. Nothing on the compose path needs any of it - no messaging library, no DVN, no executor.
 */
contract CanonicalComposeEndpoint is MessagingComposer {
    /// @notice This chain's endpoint id, which is what a receiver rebuilds a GUID from.
    uint32 public immutable eid;

    constructor(
        uint32 _eid
    ) {
        eid = _eid;
    }
}
