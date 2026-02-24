// SPDX-License-Identifier: MIT
pragma solidity >=0.7.6 <0.9;

import {IXrplProviderWalletsFacet} from "../../userInterfaces/facets/IXrplProviderWalletsFacet.sol";

/**
 * @title IIXrplProviderWalletsFacet
 * @notice Internal interface for the XrplProviderWalletsFacet contract.
 */
interface IIXrplProviderWalletsFacet is IXrplProviderWalletsFacet {

    /**
     * @notice Adds new XRPL provider wallet addresses.
     * @param _xrplProviderWallets The XRPL provider wallet addresses to add.
     * Can only be called by the owner.
     */
    function addXrplProviderWallets(
        string[] calldata _xrplProviderWallets
    )
        external;

    /**
     * @notice Removes existing XRPL provider wallet addresses.
     * @param _xrplProviderWallets The XRPL provider wallet addresses to remove.
     * Can only be called by the owner.
     */
    function removeXrplProviderWallets(
        string[] calldata _xrplProviderWallets
    )
        external;
}