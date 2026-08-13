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
 * version) reverts with `ILoanSubaccountsFacet.InvalidFxrpOft`, the same error the Flare-side
 * bridge settings use.
 */
interface IEthereumLoanSettingsFacet {

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
     * @notice Reverts if the origin peer is zero or does not match the OFT's live peer for the
     * origin endpoint.
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
     * @notice Returns the Ethereum loan settings.
     * @return The settings; all-zero when not configured.
     */
    function getEthereumLoanSettings()
        external view
        returns (Settings memory);
}
