// SPDX-License-Identifier: MIT
pragma solidity >=0.8.4 <0.9;

/**
 * @title IBridgeRoutesFacet
 * @notice Interface for the BridgeRoutesFacet contract: the Flare-side, governance-set routing
 * for everything that bridges FXRP or sends a compose message from an account here to that same
 * account's address on a remote chain — the subaccounts of every type and the Personal Account's
 * cross-chain user operations. Three records: the one FXRP OFT adapter on Flare, one pinned peer
 * per remote chain (a route), and the remote chain each subaccount type lives on. The Flare
 * counterpart of the remote diamonds' {IComposeTransportFacet}: a transport says how composes
 * arrive on a remote, a route says where sends go from here. Cut only on the Flare diamond.
 * @dev Routes are governance-set rather than supplied by the caller, so that no caller can choose
 * where assets are bridged: a subaccount's destination is the route of its type, and a Personal
 * Account's cross-chain user operation names a destination endpoint that must be a registered
 * route. Every send also re-checks the OFT's live peer for the destination against the pinned one,
 * so a peer mutation on the adapter after configuration fails the sends closed instead of routing
 * to an unknown remote OApp.
 */
interface IBridgeRoutesFacet {

    /**
     * @notice Emitted when the FXRP OFT adapter is set or cleared.
     * @param fxrpOft The FXRP OFT adapter; zero when cleared.
     */
    event FxrpOftSet(
        address fxrpOft
    );

    /**
     * @notice Emitted when a route is set or cleared.
     * @param destinationEid The LayerZero endpoint id of the remote chain.
     * @param destinationPeer The pinned peer on that chain; zero when the route is cleared.
     */
    event BridgeRouteSet(
        uint32 destinationEid,
        bytes32 destinationPeer
    );

    /**
     * @notice Emitted when a subaccount type is pointed at a route or its assignment is cleared.
     * Only the types that bridge have a route; a Flare-local type (a vault subaccount, say)
     * never gets one.
     * @param subaccountType The subaccount type.
     * @param destinationEid The route's endpoint id; zero when the assignment is cleared.
     */
    event SubaccountTypeRouteSet(
        uint256 subaccountType,
        uint32 destinationEid
    );

    /**
     * @notice Reverts if the FXRP OFT address is invalid: not a contract, not wrapping FXRP, not
     * sharing its decimals, or reporting a non-canonical interface/message-codec version.
     */
    error InvalidFxrpOft();

    /**
     * @notice Reverts if a route is set while no FXRP OFT adapter is configured.
     */
    error FxrpOftNotConfigured();

    /**
     * @notice Reverts if the destination endpoint id is zero.
     */
    error InvalidDestinationEid();

    /**
     * @notice Reverts if the destination peer has dirty upper bits (not a clean zero-padded EVM
     * address), or does not match the OFT's live peer for the destination endpoint.
     */
    error InvalidDestinationPeer();

    /**
     * @notice Reverts if a subaccount type is pointed at an endpoint id that has no route.
     * @param destinationEid The unregistered endpoint id.
     */
    error UnknownBridgeRoute(
        uint32 destinationEid
    );

    /**
     * @notice Returns the FXRP OFT adapter every route sends through.
     * @return The adapter; zero when not configured.
     */
    function getFxrpOft()
        external view
        returns (address);

    /**
     * @notice Returns the pinned peer of a route.
     * @param _destinationEid The LayerZero endpoint id of the remote chain.
     * @return The pinned peer on that chain; zero when no route exists for the endpoint.
     */
    function getBridgeRoute(
        uint32 _destinationEid
    )
        external view
        returns (bytes32);

    /**
     * @notice Returns every registered route.
     * @return _destinationEids The endpoint ids, in registration order.
     * @return _destinationPeers The pinned peers, aligned with `_destinationEids`.
     */
    function getBridgeRoutes()
        external view
        returns (uint32[] memory _destinationEids, bytes32[] memory _destinationPeers);

    /**
     * @notice Returns the route a subaccount type bridges over, if it bridges at all.
     * @dev The tuple a subaccount needs to send and to authenticate its own bridge-back: the
     * adapter, the endpoint id its type is pointed at, and that route's pinned peer. Any zero
     * member means the type is not routable (no adapter, a type pointed nowhere, or a cleared
     * route).
     * @param _subaccountType The subaccount type.
     * @return _fxrpOft The FXRP OFT adapter.
     * @return _destinationEid The endpoint id of the type's remote chain.
     * @return _destinationPeer The pinned peer there.
     */
    function getSubaccountTypeRoute(
        uint256 _subaccountType
    )
        external view
        returns (address _fxrpOft, uint32 _destinationEid, bytes32 _destinationPeer);
}
