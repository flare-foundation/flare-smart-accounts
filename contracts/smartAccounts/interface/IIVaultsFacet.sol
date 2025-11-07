// SPDX-License-Identifier: MIT
pragma solidity >=0.7.6 <0.9;

import {IVaultsFacet} from "../../userInterfaces/facets/IVaultsFacet.sol";

/**
 * @title IIVaultsFacet
 * @notice Internal interface for the VaultsFacet contract.
 */
interface IIVaultsFacet is IVaultsFacet {

    /**
     * @notice Adds new vault addresses with the given IDs.
     * @param _vaultIds The IDs of the vaults.
     * @param _vaultAddresses The addresses of the vaults.
     * Can only be called by the owner.
     */
    function addVaults(
        uint256[] calldata _vaultIds,
        address[] calldata _vaultAddresses,
        uint8[] calldata _vaultTypes
    )
        external;
}