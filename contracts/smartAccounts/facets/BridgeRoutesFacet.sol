// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IIBridgeRoutesFacet} from "../interface/IIBridgeRoutesFacet.sol";
// import is needed for @inheritdoc
// solhint-disable-next-line no-unused-import
import {IBridgeRoutesFacet} from "../../userInterfaces/facets/IBridgeRoutesFacet.sol";
import {BridgeRoutes} from "../library/BridgeRoutes.sol";
import {FacetBase} from "./FacetBase.sol";

/**
 * @title BridgeRoutesFacet
 * @notice The Flare-side routing configuration: the FXRP OFT adapter, one pinned peer per remote
 * chain, and the remote chain each subaccount type lives on. Type-generic - every subaccount type
 * and the Personal Account's cross-chain user operations resolve their destination here; the
 * type-generic registry and creation route live on {SubaccountsFacet}, loan-specific
 * configuration on the remote diamonds. Cut only on the Flare diamond.
 */
contract BridgeRoutesFacet is IIBridgeRoutesFacet, FacetBase {

    /// @inheritdoc IIBridgeRoutesFacet
    function setFxrpOft(
        address _fxrpOft
    )
        external
        onlyOwnerWithTimelock
    {
        BridgeRoutes.setFxrpOft(_fxrpOft);
    }

    /// @inheritdoc IIBridgeRoutesFacet
    function setBridgeRoute(
        uint32 _destinationEid,
        bytes32 _destinationPeer
    )
        external
        onlyOwnerWithTimelock
    {
        BridgeRoutes.setBridgeRoute(_destinationEid, _destinationPeer);
    }

    /// @inheritdoc IIBridgeRoutesFacet
    function setSubaccountTypeRoute(
        uint256 _subaccountType,
        uint32 _destinationEid
    )
        external
        onlyOwnerWithTimelock
    {
        BridgeRoutes.setSubaccountTypeRoute(_subaccountType, _destinationEid);
    }

    /// @inheritdoc IBridgeRoutesFacet
    function getFxrpOft()
        external view
        returns (address)
    {
        return BridgeRoutes.getFxrpOft();
    }

    /// @inheritdoc IBridgeRoutesFacet
    function getBridgeRoute(
        uint32 _destinationEid
    )
        external view
        returns (bytes32)
    {
        return BridgeRoutes.getBridgeRoute(_destinationEid);
    }

    /// @inheritdoc IBridgeRoutesFacet
    function getBridgeRoutes()
        external view
        returns (uint32[] memory _destinationEids, bytes32[] memory _destinationPeers)
    {
        return BridgeRoutes.getBridgeRoutes();
    }

    /// @inheritdoc IBridgeRoutesFacet
    function getSubaccountTypeRoute(
        uint256 _subaccountType
    )
        external view
        returns (address _fxrpOft, uint32 _destinationEid, bytes32 _destinationPeer)
    {
        return BridgeRoutes.getSubaccountTypeRoute(_subaccountType);
    }
}
