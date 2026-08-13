// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IIEthereumLoanSettingsFacet} from "../interface/IIEthereumLoanSettingsFacet.sol";
import {IEthereumLoanSettingsFacet} from "../../userInterfaces/facets/IEthereumLoanSettingsFacet.sol";
import {EthereumLoanSettings} from "../library/EthereumLoanSettings.sol";
import {FacetBase} from "./FacetBase.sol";

/**
 * @title EthereumLoanSettingsFacet
 * @notice Facet holding the Ethereum-side loan configuration. Cut only on the Ethereum-side
 * diamond.
 */
contract EthereumLoanSettingsFacet is IIEthereumLoanSettingsFacet, FacetBase {

    /// @inheritdoc IIEthereumLoanSettingsFacet
    function setEthereumLoanSettings(
        IEthereumLoanSettingsFacet.Settings calldata _settings
    )
        external
        onlyOwnerWithTimelock
    {
        EthereumLoanSettings.setEthereumLoanSettings(_settings);
    }

    /// @inheritdoc IEthereumLoanSettingsFacet
    function getEthereumLoanSettings()
        external view
        returns (IEthereumLoanSettingsFacet.Settings memory)
    {
        return EthereumLoanSettings.getEthereumLoanSettings();
    }
}
