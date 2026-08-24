// SPDX-License-Identifier: MIT
pragma solidity >=0.8.4 <0.9;

import {IMorpho} from "../../smartAccounts/interface/IMorpho.sol";

/**
 * @title IEthereumLoanSettingsFacet
 * @notice Governance-set configuration for the Ethereum-side loan subaccounts: the LayerZero
 * authentication surface (endpoint, FXRP OFT, pinned origin route back to Flare) and the
 * Morpho market the loan operates against. This facet is cut only on the Ethereum-side
 * diamond; the Flare-side diamond does not carry it.
 * @dev An invalid FXRP OFT (not a contract, wrapping a token other than the market's
 * collateral token, mismatched shared decimals, or a non-canonical interface/message-codec
 * version) reverts with `ILoanBridgeSettingsFacet.InvalidFxrpOft`, the same error the Flare-side
 * bridge settings use.
 */
interface IEthereumLoanSettingsFacet {

    /// @dev A lending route the account can talk to: a Morpho contract and a market on it.
    /// Routes are registered permanently - positions live in the route they were opened in,
    /// and repayment and withdrawal must stay possible against every route ever used, no
    /// matter how the active configuration changes later.
    struct Route {
        /// @notice The Morpho contract.
        address morpho;
        /// @notice The Morpho market on it.
        IMorpho.MarketParams marketParams;
    }

    struct Settings {
        /// @notice The LayerZero EndpointV2: the only allowed `lzCompose` caller.
        address lzEndpoint;
        /// @notice The FXRP OFT on this chain: the only allowed compose sender (`_from`), and
        /// the vehicle for the bridge-back sweep.
        address fxrpOft;
        /// @notice The LayerZero endpoint id of the origin chain (Flare).
        uint32 originEid;
        /// @notice The pinned peer on the origin chain (the Flare-side FXRP OFT adapter);
        /// the bridge-back sweep re-checks the live peer against it on every call.
        bytes32 originPeer;
        /// @notice The Morpho contract.
        address morpho;
        /// @notice The Morpho market: `loanToken` is RLUSD, `collateralToken` is FXRP.
        IMorpho.MarketParams marketParams;
    }

    /**
     * @notice Emitted when a route is registered (the first time its exact
     * Morpho-and-market pair is configured).
     * @param routeId The route id: `keccak256(abi.encode(morpho, marketParams))`.
     * @param morpho The Morpho contract.
     * @param marketId The Morpho market id: `keccak256(abi.encode(marketParams))`.
     */
    event RouteRegistered(
        bytes32 indexed routeId,
        address morpho,
        bytes32 marketId
    );

    /**
     * @notice Emitted when the Ethereum loan settings are set or cleared (all-zero values).
     * @param lzEndpoint The LayerZero endpoint.
     * @param fxrpOft The FXRP OFT.
     * @param originEid The origin (Flare) endpoint id.
     * @param originPeer The pinned origin peer.
     * @param morpho The Morpho contract.
     * @param marketId The Morpho market id: `keccak256(abi.encode(marketParams))`.
     */
    event EthereumLoanSettingsSet(
        address lzEndpoint,
        address fxrpOft,
        uint32 originEid,
        bytes32 originPeer,
        address morpho,
        bytes32 marketId
    );

    /**
     * @notice Reverts if the LayerZero endpoint address is invalid.
     */
    error InvalidLzEndpoint();

    /**
     * @notice Reverts if the origin endpoint id is invalid.
     */
    error InvalidOriginEid();

    /**
     * @notice Reverts if the origin peer is zero, has dirty upper bits (not a clean
     * zero-padded EVM address), or does not match the OFT's live peer for the origin endpoint.
     */
    error InvalidOriginPeer();

    /**
     * @notice Reverts if the Morpho address is invalid.
     */
    error InvalidMorpho();

    /**
     * @notice Reverts if the Morpho market parameters are invalid.
     */
    error InvalidMarketParams();

    /**
     * @notice Reverts if a new route's token pair differs from the pinned one: routes may
     * vary the market and the Morpho contract, but never the loan or collateral token.
     */
    error MismatchedRouteTokens();

    /**
     * @notice Creates the loan subaccount for an XRPL owner on this chain.
     * @dev Permissionless and idempotent, like the Flare-side `createSubaccount` — but the
     * parent Personal Account is resolved to its **computed** address instead of requiring a
     * deployment: Personal Accounts exist only on Flare, and their address is a pure function
     * of the diamond (same on every chain) and the XRPL owner, so the subaccount created here
     * is exactly the one the Flare side predicts. Because this facet is cut only on the
     * Ethereum-side diamond, the relaxed route exists only where it is needed.
     * @param _xrplOwner The XRPL owner.
     * @param _subaccountType The subaccount type.
     * @return The loan subaccount address.
     */
    function createEthereumLoanSubaccount(
        string calldata _xrplOwner,
        uint256 _subaccountType
    )
        external
        returns (address);

    /**
     * @notice Returns the Ethereum loan settings.
     * @return The settings; all-zero when not configured.
     */
    function getEthereumLoanSettings()
        external view
        returns (Settings memory);

    /**
     * @notice Returns the active route id - the only route new debt opens on and the
     * deposit target for debt-free accounts. Zero when the settings are cleared; registered
     * routes then remain available for repayment, debt synchronization, and live-debt idle
     * deposits, while composed actions (top-ups, withdrawals) resume once the transport is
     * reconfigured.
     * @return The active route id.
     */
    function getActiveRouteId()
        external view
        returns (bytes32);

    /**
     * @notice Returns a registered route.
     * @param _routeId The route id.
     * @return The route; a zero `morpho` means the id was never registered.
     */
    function getRoute(
        bytes32 _routeId
    )
        external view
        returns (Route memory);

    /**
     * @notice Returns every registered route id, in registration order. Append-only and
     * bounded by governance actions.
     * @return The route ids.
     */
    function getRouteIds()
        external view
        returns (bytes32[] memory);

    /**
     * @notice Returns the pinned token pair - the loan and collateral token every route
     * shares. Zero addresses until the first route is registered.
     * @return _loanToken The pinned loan token.
     * @return _collateralToken The pinned collateral token.
     */
    function getPinnedTokens()
        external view
        returns (address _loanToken, address _collateralToken);

    /**
     * @notice Returns whether a token is a loan or collateral token of any registered route.
     * Protected tokens never leave through generic recovery; they move only on their own
     * rails.
     * @param _token The token.
     * @return Whether the token is protected.
     */
    function isProtectedToken(
        address _token
    )
        external view
        returns (bool);
}
