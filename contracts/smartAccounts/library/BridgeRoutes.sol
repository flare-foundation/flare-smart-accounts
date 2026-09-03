// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ContractRegistry} from "flare-periphery/src/flare/ContractRegistry.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IOFT} from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import {IOAppCore} from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppCore.sol";
import {IBridgeRoutesFacet} from "../../userInterfaces/facets/IBridgeRoutesFacet.sol";
import {ISubaccountsFacet} from "../../userInterfaces/facets/ISubaccountsFacet.sol";

library BridgeRoutes {
    using EnumerableSet for EnumerableSet.UintSet;

    /// @custom:storage-location erc7201:smartAccounts.BridgeRoutes.State
    struct State {
        /// @notice The one FXRP OFT adapter on Flare; every route sends through it.
        address fxrpOft;
        /// @notice The pinned peer per remote chain, keyed by its LayerZero endpoint id. Pinned so
        /// that a later peer mutation on the adapter fails the sends closed instead of routing to
        /// an unknown OApp.
        mapping(uint32 destinationEid => bytes32 destinationPeer) routes;
        /// @notice The registered endpoint ids, so an adapter rotation can re-validate every route.
        EnumerableSet.UintSet destinationEids;
        /// @notice The remote chain each bridging subaccount type lives on; a Flare-local type
        /// (a vault subaccount, say) has no entry.
        mapping(uint256 subaccountType => uint32 destinationEid) typeRoutes;
    }

    bytes32 internal constant STATE_POSITION = keccak256(
        abi.encode(uint256(keccak256("smartAccounts.BridgeRoutes.State")) - 1)) & ~bytes32(uint256(0xff)
    );

    function setFxrpOft(
        address _fxrpOft
    )
        internal
    {
        State storage state = getState();
        if (_fxrpOft == address(0)) {
            // explicit clear: blocks every outbound send and fails the bridge-back compose
            // authentication closed until reconfigured; routes and type assignments stay
            delete state.fxrpOft;
            emit IBridgeRoutesFacet.FxrpOftSet(address(0));
            return;
        }
        require(_fxrpOft.code.length > 0, IBridgeRoutesFacet.InvalidFxrpOft());
        // the adapter must wrap FXRP with equal shared decimals (the token-bearing signed
        // instructions send with minAmountLD == amountLD, so dust would make them revert)
        address fxrp = address(ContractRegistry.getAssetManagerFXRP().fAsset());
        require(IOFT(_fxrpOft).token() == fxrp, IBridgeRoutesFacet.InvalidFxrpOft());
        require(
            IOFT(_fxrpOft).sharedDecimals() == IERC20Metadata(fxrp).decimals(),
            IBridgeRoutesFacet.InvalidFxrpOft()
        );
        // compose authentication depends on the canonical OFT codec v1 (composeFrom = source
        // caller); adapter version stability is a deployment assumption (it is not a proxy)
        (bytes4 interfaceId, uint64 version) = IOFT(_fxrpOft).oftVersion();
        require(
            interfaceId == type(IOFT).interfaceId && version == 1,
            IBridgeRoutesFacet.InvalidFxrpOft()
        );
        // a rotation must carry every registered route: the new adapter's live peer for each
        // route's endpoint must be exactly the pinned one, or the route would fail closed in
        // the field instead of at this timelocked call
        uint256 count = state.destinationEids.length();
        for (uint256 i = 0; i < count; i++) {
            uint32 destinationEid = uint32(state.destinationEids.at(i));
            require(
                IOAppCore(_fxrpOft).peers(destinationEid) == state.routes[destinationEid],
                IBridgeRoutesFacet.InvalidDestinationPeer()
            );
        }
        state.fxrpOft = _fxrpOft;
        emit IBridgeRoutesFacet.FxrpOftSet(_fxrpOft);
    }

    function setBridgeRoute(
        uint32 _destinationEid,
        bytes32 _destinationPeer
    )
        internal
    {
        State storage state = getState();
        require(_destinationEid != 0, IBridgeRoutesFacet.InvalidDestinationEid());
        if (_destinationPeer == bytes32(0)) {
            // explicit clear: the types pointed at this route and the cross-chain user
            // operations naming it fail closed until the route is set again
            delete state.routes[_destinationEid];
            // slither-disable-next-line unused-return
            state.destinationEids.remove(_destinationEid);
            emit IBridgeRoutesFacet.BridgeRouteSet(_destinationEid, bytes32(0));
            return;
        }
        address fxrpOft = state.fxrpOft;
        require(fxrpOft != address(0), IBridgeRoutesFacet.FxrpOftNotConfigured());
        // require a clean EVM peer: the destination recomputes the GUID from the local
        // address form, so dirty upper bits would route correctly yet fail every delivery
        require(
            uint256(_destinationPeer) >> 160 == 0,
            IBridgeRoutesFacet.InvalidDestinationPeer()
        );
        // the adapter's live peer must be exactly the pinned one - existence alone would
        // accept a wrong route
        require(
            IOAppCore(fxrpOft).peers(_destinationEid) == _destinationPeer,
            IBridgeRoutesFacet.InvalidDestinationPeer()
        );
        state.routes[_destinationEid] = _destinationPeer;
        // slither-disable-next-line unused-return
        state.destinationEids.add(_destinationEid);
        emit IBridgeRoutesFacet.BridgeRouteSet(_destinationEid, _destinationPeer);
    }

    function setSubaccountTypeRoute(
        uint256 _subaccountType,
        uint32 _destinationEid
    )
        internal
    {
        State storage state = getState();
        require(_subaccountType != 0, ISubaccountsFacet.InvalidSubaccountType());
        if (_destinationEid != 0) {
            require(
                state.routes[_destinationEid] != bytes32(0),
                IBridgeRoutesFacet.UnknownBridgeRoute(_destinationEid)
            );
        }
        state.typeRoutes[_subaccountType] = _destinationEid;
        emit IBridgeRoutesFacet.SubaccountTypeRouteSet(_subaccountType, _destinationEid);
    }

    function getFxrpOft()
        internal view
        returns (address)
    {
        return getState().fxrpOft;
    }

    function getBridgeRoute(
        uint32 _destinationEid
    )
        internal view
        returns (bytes32)
    {
        return getState().routes[_destinationEid];
    }

    function getBridgeRoutes()
        internal view
        returns (uint32[] memory _destinationEids, bytes32[] memory _destinationPeers)
    {
        State storage state = getState();
        uint256 count = state.destinationEids.length();
        _destinationEids = new uint32[](count);
        _destinationPeers = new bytes32[](count);
        for (uint256 i = 0; i < count; i++) {
            uint32 destinationEid = uint32(state.destinationEids.at(i));
            _destinationEids[i] = destinationEid;
            _destinationPeers[i] = state.routes[destinationEid];
        }
    }

    function getSubaccountTypeRoute(
        uint256 _subaccountType
    )
        internal view
        returns (address _fxrpOft, uint32 _destinationEid, bytes32 _destinationPeer)
    {
        State storage state = getState();
        _fxrpOft = state.fxrpOft;
        _destinationEid = state.typeRoutes[_subaccountType];
        _destinationPeer = state.routes[_destinationEid];
    }

    function getState()
        internal pure
        returns (State storage _state)
    {
        bytes32 position = STATE_POSITION;
        // solhint-disable-next-line no-inline-assembly
        assembly {
            _state.slot := position
        }
    }
}
