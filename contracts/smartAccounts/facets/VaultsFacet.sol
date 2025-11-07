// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LibDiamond} from "../../diamond/libraries/LibDiamond.sol";
import {IIVaultsFacet} from "../interface/IIVaultsFacet.sol";
// import is needed for @inheritdoc
// solhint-disable-next-line no-unused-import
import {IVaultsFacet} from "../../userInterfaces/facets/IVaultsFacet.sol";
import {Vaults} from "../library/Vaults.sol";

/**
 * @title VaultsFacet
 * @notice Facet for handling vault-related functions.
 */
contract VaultsFacet is IIVaultsFacet {

    /// @inheritdoc IIVaultsFacet
    function addVaults(
        uint256[] calldata _vaultIds,
        address[] calldata _vaultAddresses,
        uint8[] calldata _vaultTypes
    )
        external
    {
        LibDiamond.enforceIsContractOwner();
        require(_vaultIds.length == _vaultAddresses.length, VaultsLengthsMismatch());
        require(_vaultIds.length == _vaultTypes.length, VaultsLengthsMismatch());
        Vaults.State storage state = Vaults.getState();
        for (uint256 i = 0; i < _vaultIds.length; i++) {
            uint256 vaultId = _vaultIds[i];
            address vaultAddress = _vaultAddresses[i];
            uint8 vaultType = _vaultTypes[i];
            Vaults.VaultInfo storage vaultInfo = state.vaults[vaultId];
            require(vaultInfo.vaultAddress == address(0), VaultIdAlreadyUsed(vaultId));
            require(vaultAddress != address(0), InvalidVaultId(vaultId));
            require(vaultType == 1 || vaultType == 2, InvalidVaultType(vaultType));
            vaultInfo.vaultAddress = vaultAddress;
            vaultInfo.vaultType = vaultType;
            state.vaultIds.push(vaultId);
            emit VaultAdded(vaultId, vaultAddress, vaultType);
        }
    }

    /// @inheritdoc IVaultsFacet
    function getVaults()
        external view
        returns (uint256[] memory _vaultIds, address[] memory _vaultAddresses, uint8[] memory _vaultTypes)
    {
        Vaults.State storage state = Vaults.getState();
        _vaultIds = state.vaultIds;
        _vaultAddresses = new address[](_vaultIds.length);
        _vaultTypes = new uint8[](_vaultIds.length);
        for (uint256 i = 0; i < _vaultIds.length; i++) {
            Vaults.VaultInfo memory vaultInfo = state.vaults[_vaultIds[i]];
            _vaultAddresses[i] = vaultInfo.vaultAddress;
            _vaultTypes[i] = vaultInfo.vaultType;
        }
    }
}
