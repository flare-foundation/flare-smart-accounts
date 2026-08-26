// SPDX-License-Identifier: MIT
pragma solidity >=0.8.4 <0.9;

import {IMorpho} from "../../smartAccounts/interface/IMorpho.sol";

/**
 * @title ILoanChainSettingsFacet
 * @notice Governance-set configuration for the loan-chain-side subaccounts: one global
 * LayerZero transport (endpoint, FXRP OFT, pinned origin route back to Flare) shared by every
 * loan type, and one **write-once Morpho market per subaccount type** — a position's market
 * can never change under it, so exits need no registry; a new pool is a new subaccount type.
 * The first market registration permanently pins the collateral token: every later non-zero
 * transport must wrap it, so a transport replacement can rotate the OFT adapter but never
 * change the token under the write-once bindings. Cut only on the loan-chain diamond
 * (Ethereum, at launch).
 * @dev An invalid FXRP OFT (not a contract, mismatched shared decimals, or a non-canonical
 * interface/message-codec version) reverts with `ILoanBridgeSettingsFacet.InvalidFxrpOft`, the
 * same error the Flare-side bridge settings use.
 */
interface ILoanChainSettingsFacet {

    /// @dev The global LayerZero transport: how authenticated loan actions arrive and how the
    /// bridge-back sweep leaves. One per diamond, shared by every loan subaccount type.
    struct Transport {
        /// @notice The LayerZero EndpointV2: the only allowed `lzCompose` caller.
        address lzEndpoint;
        /// @notice The FXRP OFT on this chain: the only allowed compose sender (`_from`), the
        /// authoritative FXRP identity (`token()`), and the vehicle for the bridge-back sweep.
        address fxrpOft;
        /// @notice The LayerZero endpoint id of the origin chain (Flare).
        uint32 originEid;
        /// @notice The pinned peer on the origin chain (the Flare-side FXRP OFT adapter);
        /// the bridge-back sweep re-checks the live peer against it on every call.
        bytes32 originPeer;
    }

    /// @dev The pool a subaccount type is bound to: a Morpho contract and a market on it.
    /// Write-once per type - positions live in it, so the binding must never change.
    struct Market {
        /// @notice The Morpho contract.
        address morpho;
        /// @notice The Morpho market on it. `collateralToken` must be the transport OFT's
        /// token (enforced); the loan token is RLUSD by governance policy per registration,
        /// not an on-chain check.
        IMorpho.MarketParams marketParams;
    }

    /**
     * @notice Emitted when the loan-chain transport is set or cleared (all-zero values).
     * @param lzEndpoint The LayerZero endpoint.
     * @param fxrpOft The FXRP OFT.
     * @param originEid The origin (Flare) endpoint id.
     * @param originPeer The pinned origin peer.
     */
    event LoanChainTransportSet(
        address lzEndpoint,
        address fxrpOft,
        uint32 originEid,
        bytes32 originPeer
    );

    /**
     * @notice Emitted when a subaccount type's market is registered (write-once).
     * @param subaccountType The subaccount type the market is bound to.
     * @param morpho The Morpho contract.
     * @param marketId The Morpho market id: `keccak256(abi.encode(marketParams))`.
     */
    event LoanChainMarketRegistered(
        uint256 indexed subaccountType,
        address morpho,
        bytes32 marketId
    );

    /**
     * @notice Emitted when new debt increases are disabled for a subaccount type.
     * @param subaccountType The subaccount type.
     */
    event LoanChainBorrowingDisabled(
        uint256 indexed subaccountType
    );

    /**
     * @notice Emitted when new debt increases are re-enabled for a subaccount type.
     * @param subaccountType The subaccount type.
     */
    event LoanChainBorrowingEnabled(
        uint256 indexed subaccountType
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
     * @notice Reverts on registering a market for a type that already has one: the binding
     * is write-once - a different market means a new subaccount type.
     * @param subaccountType The already-bound subaccount type.
     */
    error MarketAlreadyRegistered(
        uint256 subaccountType
    );

    /**
     * @notice Reverts when an operation needs a type's market and none is registered.
     * @param subaccountType The subaccount type without a market.
     */
    error MarketNotRegistered(
        uint256 subaccountType
    );

    /**
     * @notice Reverts when an operation needs the loan transport and it is not configured.
     */
    error LoanChainTransportNotConfigured();

    /**
     * @notice Returns the global loan transport.
     * @return The transport; all-zero when not configured.
     */
    function getLoanChainTransport()
        external view
        returns (Transport memory);

    /**
     * @notice Returns the market a subaccount type is bound to.
     * @param _subaccountType The subaccount type.
     * @return The market; a zero `morpho` means no market is registered for the type.
     */
    function getLoanChainMarket(
        uint256 _subaccountType
    )
        external view
        returns (Market memory);

    /**
     * @notice Returns whether new debt increases are disabled for a subaccount type.
     * Repayment, collateral top-ups, withdrawals, and recovery are never affected.
     * @param _subaccountType The subaccount type.
     * @return Whether borrowing is disabled.
     */
    function isLoanChainBorrowingDisabled(
        uint256 _subaccountType
    )
        external view
        returns (bool);
}
