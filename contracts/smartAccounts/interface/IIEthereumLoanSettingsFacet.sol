// SPDX-License-Identifier: MIT
pragma solidity >=0.7.6 <0.9;

import {IEthereumLoanSettingsFacet} from "../../userInterfaces/facets/IEthereumLoanSettingsFacet.sol";

/**
 * @title IIEthereumLoanSettingsFacet
 * @notice Internal interface for the EthereumLoanSettingsFacet contract.
 */
interface IIEthereumLoanSettingsFacet is IEthereumLoanSettingsFacet {
    /**
     * @notice Sets the Ethereum loan settings.
     * @dev Validates that the OFT wraps the market's collateral token, shares its decimals,
     * reports the canonical OFT interface and message-codec version, and that its live peer
     * for the origin endpoint equals `originPeer` exactly. Passing all-zero settings clears
     * them, which disables `lzCompose` and the bridge-back sweep until reconfigured.
     * @param _settings The new settings.
     * Can only be called by the owner (timelocked).
     */
    function setEthereumLoanSettings(
        Settings calldata _settings
    )
        external;
}
