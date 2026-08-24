// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IOFT} from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import {IOAppCore} from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppCore.sol";
import {IEthereumLoanSettingsFacet} from "../../userInterfaces/facets/IEthereumLoanSettingsFacet.sol";
import {IMorpho} from "../interface/IMorpho.sol";
import {ILoanBridgeSettingsFacet} from "../../userInterfaces/facets/ILoanBridgeSettingsFacet.sol";

library EthereumLoanSettings {

    /// @custom:storage-location erc7201:smartAccounts.EthereumLoanSettings.State
    struct State {
        IEthereumLoanSettingsFacet.Settings settings;
        /// @dev The route new debt opens on and debt-free deposits use; zero when the
        /// settings are cleared. Top-ups, withdrawals, and repayment work against any
        /// registered route.
        bytes32 activeRouteId;
        /// @dev Every route ever configured, permanently: positions live in the route they
        /// were opened in, so exits must outlive configuration changes.
        mapping(bytes32 routeId => IEthereumLoanSettingsFacet.Route) routes;
        bytes32[] routeIds;
        /// @dev Loan/collateral tokens of every registered route; they never leave through
        /// generic recovery.
        mapping(address token => bool) protectedTokens;
    }

    bytes32 internal constant STATE_POSITION = keccak256(
        abi.encode(uint256(keccak256("smartAccounts.EthereumLoanSettings.State")) - 1)) & ~bytes32(uint256(0xff)
    );

    function setEthereumLoanSettings(
        IEthereumLoanSettingsFacet.Settings calldata _settings
    )
        internal
    {
        State storage state = getState();
        if (
            _settings.lzEndpoint == address(0) &&
            _settings.fxrpOft == address(0) &&
            _settings.morpho == address(0) &&
            _settings.originEid == 0 &&
            _settings.originPeer == bytes32(0) &&
            _settings.marketParams.loanToken == address(0) &&
            _settings.marketParams.collateralToken == address(0) &&
            _settings.marketParams.oracle == address(0) &&
            _settings.marketParams.irm == address(0) &&
            _settings.marketParams.lltv == 0
        ) {
            // explicit clear, only for a fully zero struct: disables lzCompose (including
            // composed withdrawals), the bridge-back sweep and new borrowing until
            // reconfigured. Registered routes, repayment and configured recovery persist.
            // A partially zero struct falls through to the validation below and reverts, so
            // a malformed clear cannot wipe the settings
            delete state.settings;
            delete state.activeRouteId;
            emit IEthereumLoanSettingsFacet.EthereumLoanSettingsSet(
                address(0), address(0), 0, bytes32(0), address(0), bytes32(0)
            );
            return;
        }
        require(_settings.lzEndpoint.code.length > 0, IEthereumLoanSettingsFacet.InvalidLzEndpoint());
        require(_settings.morpho.code.length > 0, IEthereumLoanSettingsFacet.InvalidMorpho());
        require(_settings.originEid != 0, IEthereumLoanSettingsFacet.InvalidOriginEid());
        // the origin peer is the Flare-side adapter, an EVM address: it must be non-zero and
        // cleanly zero-padded
        require(
            _settings.originPeer != bytes32(0) && uint256(_settings.originPeer) >> 160 == 0,
            IEthereumLoanSettingsFacet.InvalidOriginPeer()
        );
        IMorpho.MarketParams memory marketParams = _settings.marketParams;
        require(
            marketParams.loanToken != address(0) &&
            marketParams.collateralToken != address(0) &&
            marketParams.loanToken != marketParams.collateralToken &&
            marketParams.lltv != 0,
            IEthereumLoanSettingsFacet.InvalidMarketParams()
        );
        // both tokens must be contracts: the first registration pins them permanently, and a
        // Morpho market can exist for a token address that carries no code
        require(
            marketParams.loanToken.code.length > 0 &&
            marketParams.collateralToken.code.length > 0,
            IEthereumLoanSettingsFacet.InvalidMarketParams()
        );
        // the token pair is pinned across every route: routes may vary the market (oracle,
        // interest model, LLTV) and even the Morpho contract, but never the tokens - the
        // rails and recovery guards assume one loan and one collateral token, and a role
        // change would strand collateral or let a rail consume repayment material. This
        // namespace is one per diamond, so token migration needs a per-type settings
        // namespace (future work), not merely a new registered implementation.
        if (state.routeIds.length > 0) {
            IMorpho.MarketParams storage first = state.routes[state.routeIds[0]].marketParams;
            require(
                marketParams.loanToken == first.loanToken &&
                marketParams.collateralToken == first.collateralToken,
                IEthereumLoanSettingsFacet.MismatchedRouteTokens()
            );
        }
        // the OFT must be the FXRP bridge on this chain: it must wrap the market's collateral
        // token, share its decimals (the bridge-back sweep sends with minAmountLD == amountLD),
        // and report the canonical interface and message-codec version - the compose
        // authentication in the subaccount depends on the canonical composeFrom encoding
        require(_settings.fxrpOft.code.length > 0, ILoanBridgeSettingsFacet.InvalidFxrpOft());
        require(
            IOFT(_settings.fxrpOft).token() == marketParams.collateralToken,
            ILoanBridgeSettingsFacet.InvalidFxrpOft()
        );
        require(
            IOFT(_settings.fxrpOft).sharedDecimals() ==
                IERC20Metadata(marketParams.collateralToken).decimals(),
            ILoanBridgeSettingsFacet.InvalidFxrpOft()
        );
        (bytes4 interfaceId, uint64 version) = IOFT(_settings.fxrpOft).oftVersion();
        require(
            interfaceId == type(IOFT).interfaceId && version == 1,
            ILoanBridgeSettingsFacet.InvalidFxrpOft()
        );
        // the OFT must be wired to the same endpoint that will deliver lzCompose calls;
        // otherwise a wrong (or malicious) endpoint could fabricate every callback parameter
        require(
            address(IOAppCore(_settings.fxrpOft).endpoint()) == _settings.lzEndpoint,
            IEthereumLoanSettingsFacet.InvalidLzEndpoint()
        );
        // the live peer for the origin endpoint must be exactly the pinned remote OApp
        require(
            IOAppCore(_settings.fxrpOft).peers(_settings.originEid) == _settings.originPeer,
            IEthereumLoanSettingsFacet.InvalidOriginPeer()
        );
        // the market must actually exist on the Morpho contract, or every credited compose
        // action against it would revert
        bytes32 marketId = keccak256(abi.encode(marketParams));
        (, , , , uint128 lastUpdate, ) = IMorpho(_settings.morpho).market(marketId);
        require(lastUpdate != 0, IEthereumLoanSettingsFacet.InvalidMarketParams());

        // register the route permanently and make it the active one
        bytes32 routeId = keccak256(abi.encode(_settings.morpho, marketParams));
        if (state.routes[routeId].morpho == address(0)) {
            state.routes[routeId] = IEthereumLoanSettingsFacet.Route({
                morpho: _settings.morpho,
                marketParams: marketParams
            });
            state.routeIds.push(routeId);
            state.protectedTokens[marketParams.loanToken] = true;
            state.protectedTokens[marketParams.collateralToken] = true;
            emit IEthereumLoanSettingsFacet.RouteRegistered(routeId, _settings.morpho, marketId);
        }
        state.activeRouteId = routeId;

        state.settings = _settings;
        emit IEthereumLoanSettingsFacet.EthereumLoanSettingsSet(
            _settings.lzEndpoint,
            _settings.fxrpOft,
            _settings.originEid,
            _settings.originPeer,
            _settings.morpho,
            keccak256(abi.encode(marketParams))
        );
    }

    function getEthereumLoanSettings()
        internal view
        returns (IEthereumLoanSettingsFacet.Settings memory)
    {
        return getState().settings;
    }

    function getActiveRouteId()
        internal view
        returns (bytes32)
    {
        return getState().activeRouteId;
    }

    function getRoute(
        bytes32 _routeId
    )
        internal view
        returns (IEthereumLoanSettingsFacet.Route memory)
    {
        return getState().routes[_routeId];
    }

    function getRouteIds()
        internal view
        returns (bytes32[] memory)
    {
        return getState().routeIds;
    }

    function getPinnedTokens()
        internal view
        returns (address _loanToken, address _collateralToken)
    {
        State storage state = getState();
        if (state.routeIds.length == 0) return (address(0), address(0));
        IMorpho.MarketParams storage marketParams =
            state.routes[state.routeIds[0]].marketParams;
        return (marketParams.loanToken, marketParams.collateralToken);
    }

    function isProtectedToken(
        address _token
    )
        internal view
        returns (bool)
    {
        return getState().protectedTokens[_token];
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
