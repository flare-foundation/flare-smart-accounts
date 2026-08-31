// SPDX-License-Identifier: MIT
pragma solidity >=0.8.4 <0.9;

/**
 * @title ILoanBridgeSettingsFacet
 * @notice Interface for the LoanBridgeSettingsFacet contract: the governance-set configuration
 * for bridging FXRP from loan subaccounts to the loan chain. Loan-specific — the generic
 * subaccount registry and creation route live on {ISubaccountsFacet}.
 */
interface ILoanBridgeSettingsFacet {

    /**
     * @notice Emitted when the loan bridge settings are set.
     * @param fxrpOft The FXRP OFT used to bridge FXRP to the loan chain.
     * @param destinationEid The LayerZero endpoint id of the loan chain.
     * @param destinationPeer The expected remote OApp (peer) on the loan chain.
     */
    event LoanBridgeSettingsSet(
        address fxrpOft,
        uint32 destinationEid,
        bytes32 destinationPeer
    );

    /**
     * @notice Reverts if the FXRP OFT address is invalid.
     */
    error InvalidFxrpOft();

    /**
     * @notice Reverts if the destination endpoint id is invalid.
     */
    error InvalidDestinationEid();

    /**
     * @notice Reverts if the destination peer is invalid, or does not match the OFT's live peer.
     */
    error InvalidDestinationPeer();

    /**
     * @notice Returns the settings used to bridge FXRP to the loan chain.
     * @dev These are governance-set rather than supplied by the caller, so that no caller can
     * choose the route the assets are bridged over.
     * @return _fxrpOft The FXRP OFT used to bridge FXRP.
     * @return _destinationEid The LayerZero endpoint id of the loan chain.
     * @return _destinationPeer The expected remote OApp (peer) on the loan chain. Pinned so a
     * peer mutation on the OFT after configuration fails the bridging instructions closed.
     */
    function getLoanBridgeSettings()
        external view
        returns (address _fxrpOft, uint32 _destinationEid, bytes32 _destinationPeer);
}
