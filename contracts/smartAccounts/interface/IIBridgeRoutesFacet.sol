// SPDX-License-Identifier: MIT
pragma solidity >=0.7.6 <0.9;

import {IBridgeRoutesFacet} from "../../userInterfaces/facets/IBridgeRoutesFacet.sol";

/**
 * @title IIBridgeRoutesFacet
 * @notice Internal interface for the BridgeRoutesFacet contract.
 */
interface IIBridgeRoutesFacet is IBridgeRoutesFacet {
    /**
     * @notice Sets the FXRP OFT adapter every route sends through.
     * @dev Validates that the OFT wraps the FXRP token, shares its decimals and reports the
     * canonical interface/codec version, and re-validates every registered route's pinned peer
     * against the new adapter's live peers, so a rotation cannot leave a route pointing at a
     * peer the new adapter does not have. Zero clears the adapter, which blocks every outbound
     * send and fails the subaccounts' bridge-back compose authentication closed until
     * reconfigured; the routes and type assignments stay recorded.
     * @param _fxrpOft The FXRP OFT adapter, or zero to clear.
     * Can only be called by the owner (timelocked).
     */
    function setFxrpOft(
        address _fxrpOft
    )
        external;

    /**
     * @notice Sets or clears the route to a remote chain: the peer pinned for its endpoint id.
     * @dev Requires a configured adapter whose live peer for `_destinationEid` equals
     * `_destinationPeer` exactly - existence alone would accept a wrong route. A zero peer
     * clears the route: every subaccount type pointed at it and every cross-chain user
     * operation naming it fail closed until the route is set again; the type assignments stay
     * recorded.
     * @param _destinationEid The LayerZero endpoint id of the remote chain.
     * @param _destinationPeer The pinned peer on that chain (a clean zero-padded EVM address),
     * or zero to clear the route.
     * Can only be called by the owner (timelocked).
     */
    function setBridgeRoute(
        uint32 _destinationEid,
        bytes32 _destinationPeer
    )
        external;

    /**
     * @notice Pins a subaccount type to the remote chain it lives on, write-once.
     * @dev Only for the types that bridge (a Flare-local type, such as a vault subaccount, is
     * never pinned). The route must exist (`UnknownBridgeRoute`); the reserved type zero and a
     * zero endpoint id are refused (`ISubaccountsFacet.InvalidSubaccountType`,
     * `InvalidDestinationEid`). Re-pinning the same route is a no-op, so a retried timelocked
     * call is harmless; a different one reverts (`SubaccountTypeRoutePinned`) - a type's signed
     * instructions carry no destination, so its chain must not move under them. Use
     * {setSubaccountTypeRouteSuspended} to stop a pinned type.
     * @param _subaccountType The subaccount type (non-zero).
     * @param _destinationEid The endpoint id of a registered route (non-zero).
     * Can only be called by the owner (timelocked).
     */
    function setSubaccountTypeRoute(
        uint256 _subaccountType,
        uint32 _destinationEid
    )
        external;

    /**
     * @notice Suspends or resumes a pinned subaccount type's forward moves.
     * @dev Per-type containment that keeps the chain pin: while suspended the type reads as
     * unroutable, so its forward moves and its bridge-back authentication fail closed exactly
     * as an unconfigured route does, and the positions' chain is still recorded. The type must
     * be pinned first (`UnknownBridgeRoute(0)`).
     * @param _subaccountType The subaccount type.
     * @param _suspended Whether to suspend the type.
     * Can only be called by the owner (timelocked).
     */
    function setSubaccountTypeRouteSuspended(
        uint256 _subaccountType,
        bool _suspended
    )
        external;
}
