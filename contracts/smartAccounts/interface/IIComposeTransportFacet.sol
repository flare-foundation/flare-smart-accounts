// SPDX-License-Identifier: MIT
pragma solidity >=0.8.4 <0.9;

import {IComposeTransportFacet} from "../../userInterfaces/facets/IComposeTransportFacet.sol";

/**
 * @title IIComposeTransportFacet
 * @notice Internal interface for the ComposeTransportFacet contract.
 */
interface IIComposeTransportFacet is IComposeTransportFacet {
    /**
     * @notice Sets the compose transport, validated against the OFT (canonical
     * interface/codec version, decimals shared with its own token, wired to the `lzCompose`
     * endpoint, live peer equal to the pinned one). Once a token is pinned - by the first loan
     * market registration - the OFT must wrap it: the adapter can rotate, the token cannot.
     * Never clears: an all-zero transport fails validation; see {clearComposeTransport}.
     * @param _transport The transport.
     * Can only be called by the owner (timelocked).
     */
    function setComposeTransport(
        IComposeTransportFacet.Transport calldata _transport
    )
        external;

    /**
     * @notice Clears the compose transport immediately: disables `lzCompose` on every compose
     * receiver of this diamond and the remote loan subaccount's bridge-back until a new
     * transport is set; markets, the token pin, repayment, defensive deposits and recovery
     * persist. The containment lever for a compromised endpoint, OFT or peer: cancel queued
     * {setComposeTransport} calls first (the clear does not), and never restore the
     * compromised tuple afterwards - rotate it (see {IComposeTransportFacet}).
     * Can only be called by the owner (immediate, not timelocked).
     */
    function clearComposeTransport()
        external;
}
