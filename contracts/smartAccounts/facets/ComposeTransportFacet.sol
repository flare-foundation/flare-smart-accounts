// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IIComposeTransportFacet} from "../interface/IIComposeTransportFacet.sol";
import {IComposeTransportFacet} from "../../userInterfaces/facets/IComposeTransportFacet.sol";
import {ComposeTransport} from "../library/ComposeTransport.sol";
import {FacetBase} from "./FacetBase.sol";

/**
 * @title ComposeTransportFacet
 * @notice Facet holding the compose transport of a remote diamond: the one record every
 * compose receiver on the diamond (the remote Personal Account, every remote subaccount type)
 * authenticates against. Set under the timelock, cleared immediately (the incident lever; see the
 * interface for the runbook). Cut only on remote diamonds (the loan chain, Ethereum, at launch),
 * never on the Flare side.
 */
contract ComposeTransportFacet is IIComposeTransportFacet, FacetBase {

    /// @inheritdoc IIComposeTransportFacet
    function setComposeTransport(
        IComposeTransportFacet.Transport calldata _transport
    )
        external
        onlyOwnerWithTimelock
    {
        ComposeTransport.setComposeTransport(_transport);
    }

    /// @inheritdoc IIComposeTransportFacet
    function clearComposeTransport()
        external
        onlyOwner
    {
        ComposeTransport.clearComposeTransport();
    }

    /// @inheritdoc IComposeTransportFacet
    function getComposeTransport()
        external view
        returns (IComposeTransportFacet.Transport memory)
    {
        return ComposeTransport.getComposeTransport();
    }
}
