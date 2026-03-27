// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IIVaultsFacet} from "../interface/IIVaultsFacet.sol";
// import is needed for @inheritdoc
// solhint-disable-next-line no-unused-import
import {IVaultsFacet} from "../../userInterfaces/facets/IVaultsFacet.sol";
import {Vaults} from "../library/Vaults.sol";
import {FacetBase} from "./FacetBase.sol";
/**
 * @title VaultsFacet
 * @notice Facet for handling vault-related functions.
 */
contract VaultsFacet is IIVaultsFacet, FacetBase {

    /// @inheritdoc IIVaultsFacet
    function addVaults(
        uint256[] calldata _vaultIds,
        address[] calldata _vaultAddresses,
        VaultType[] calldata _vaultTypes
    )
        external
        onlyOwnerWithTimelock
    {
        require(_vaultIds.length == _vaultAddresses.length, VaultsLengthsMismatch());
        require(_vaultIds.length == _vaultTypes.length, VaultsLengthsMismatch());
        Vaults.State storage state = Vaults.getState();
        for (uint256 i = 0; i < _vaultIds.length; i++) {
            uint256 vaultId = _vaultIds[i];
            require(vaultId > 0, VaultIdZero(i));
            Vaults.VaultInfo storage vaultInfo = state.vaultIdToVaultInfo[vaultId];
            require(vaultInfo.vaultAddress == address(0), VaultIdAlreadyAdded(vaultId));
            VaultType vaultType = _vaultTypes[i];
            require(
                vaultType == VaultType.Firelight || vaultType == VaultType.Upshift,
                InvalidVaultType(vaultType)
            );
            address vaultAddress = _vaultAddresses[i];
            require(vaultAddress != address(0), VaultAddressZero(i));
            require(
                state.vaultAddressToVaultId[vaultAddress] == 0,
                VaultAddressAlreadyAdded(vaultAddress)
            );
            vaultInfo.vaultAddress = vaultAddress;
            vaultInfo.vaultType = vaultType;
            state.vaultAddressToVaultId[vaultAddress] = vaultId;
            state.vaultIds.push(vaultId);
            emit VaultAdded(vaultId, vaultAddress, vaultType);
        }
    }

    /// @inheritdoc IVaultsFacet
    function getVaults()
        external view
        returns (
            uint256[] memory _vaultIds,
            address[] memory _vaultAddresses,
            VaultType[] memory _vaultTypes
        )
    {
        Vaults.State storage state = Vaults.getState();
        _vaultIds = state.vaultIds;
        _vaultAddresses = new address[](_vaultIds.length);
        _vaultTypes = new VaultType[](_vaultIds.length);
        for (uint256 i = 0; i < _vaultIds.length; i++) {
            Vaults.VaultInfo memory vaultInfo = state.vaultIdToVaultInfo[_vaultIds[i]];
            _vaultAddresses[i] = vaultInfo.vaultAddress;
            _vaultTypes[i] = vaultInfo.vaultType;
        }
    }
}
