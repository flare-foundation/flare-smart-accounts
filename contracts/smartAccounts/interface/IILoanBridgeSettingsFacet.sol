// SPDX-License-Identifier: MIT
pragma solidity >=0.7.6 <0.9;

import {ILoanBridgeSettingsFacet} from "../../userInterfaces/facets/ILoanBridgeSettingsFacet.sol";

/**
 * @title IILoanBridgeSettingsFacet
 * @notice Internal interface for the LoanBridgeSettingsFacet contract.
 */
interface IILoanBridgeSettingsFacet is ILoanBridgeSettingsFacet {
    /**
     * @notice Sets the settings used to bridge FXRP to the loan chain.
     * @dev Validates that the OFT wraps the FXRP token, shares its decimals, and that its live
     * peer for the destination endpoint equals `_destinationPeer` exactly. Passing zero for all
     * arguments clears the settings, which disables the forward sweep until reconfigured.
     * @param _fxrpOft The FXRP OFT used to bridge FXRP.
     * @param _destinationEid The LayerZero endpoint id of the loan chain.
     * @param _destinationPeer The expected remote OApp (peer) on the loan chain.
     * Can only be called by the owner (timelocked).
     */
    function setLoanBridgeSettings(
        address _fxrpOft,
        uint32 _destinationEid,
        bytes32 _destinationPeer
    )
        external;
}
