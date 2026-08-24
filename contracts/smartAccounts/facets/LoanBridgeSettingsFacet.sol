// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IILoanBridgeSettingsFacet} from "../interface/IILoanBridgeSettingsFacet.sol";
// import is needed for @inheritdoc
// solhint-disable-next-line no-unused-import
import {ILoanBridgeSettingsFacet} from "../../userInterfaces/facets/ILoanBridgeSettingsFacet.sol";
import {LoanBridgeSettings} from "../library/LoanBridgeSettings.sol";
import {FacetBase} from "./FacetBase.sol";

/**
 * @title LoanBridgeSettingsFacet
 * @notice Loan-specific governance configuration: the FXRP bridge to the loan chain. The
 * generic subaccount registry and creation route live on {SubaccountsFacet}.
 */
contract LoanBridgeSettingsFacet is IILoanBridgeSettingsFacet, FacetBase {

    /// @inheritdoc IILoanBridgeSettingsFacet
    function setLoanBridgeSettings(
        address _fxrpOft,
        uint32 _destinationEid,
        bytes32 _destinationPeer
    )
        external
        onlyOwnerWithTimelock
    {
        LoanBridgeSettings.setLoanBridgeSettings(_fxrpOft, _destinationEid, _destinationPeer);
    }

    /// @inheritdoc ILoanBridgeSettingsFacet
    function getLoanBridgeSettings()
        external view
        returns (address _fxrpOft, uint32 _destinationEid, bytes32 _destinationPeer)
    {
        return LoanBridgeSettings.getLoanBridgeSettings();
    }
}
