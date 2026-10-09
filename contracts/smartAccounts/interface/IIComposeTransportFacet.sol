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
     * @notice Immediately clears the compose transport: disables `lzCompose` on every compose
     * receiver of this diamond and the remote loan subaccount's bridge-back, while markets,
     * the token pin, repayment and defensive deposits keep working.
     * @dev Owner-only and not timelocked - the containment lever for a compromised endpoint,
     * OFT or peer. It cancels neither queued {setComposeTransport} calls nor compose packets
     * already queued at the endpoint; follow the incident runbook in
     * {IComposeTransportFacet}.
     * Can only be called by the owner (immediate, not timelocked).
     */
    function clearComposeTransport()
        external;
}
