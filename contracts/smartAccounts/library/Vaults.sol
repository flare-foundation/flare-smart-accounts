// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LibDiamond} from "../../diamond/libraries/LibDiamond.sol";
import {ContractRegistry} from "flare-periphery/src/flare/ContractRegistry.sol";
import {IIPersonalAccount} from "../interface/IIPersonalAccount.sol";
import {IMasterAccountController} from "../../userInterfaces/IMasterAccountController.sol";


library Vaults {

    struct State {
        /// @notice Mapping from vault ID to vault information
        mapping(uint256 vaultId => VaultInfo vaultInfo) vaults;
        uint256[] vaultIds;
    }

    /// @notice Struct containing vault information
    struct VaultInfo {
        /// @notice Vault address
        address vaultAddress;
        /// @notice Vault type (1 = Firelight, 2 = Upshift, ...)
        uint8 vaultType;
    }

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
        external
    {
        LibDiamond.enforceIsContractOwner();
        require(_vaultIds.length == _vaultAddresses.length, IMasterAccountController.LengthsMismatch());
        require(_vaultIds.length == _vaultTypes.length, IMasterAccountController.LengthsMismatch());
        State storage state = getState();
        for (uint256 i = 0; i < _vaultIds.length; i++) {
            uint256 vaultId = _vaultIds[i];
            address vaultAddress = _vaultAddresses[i];
            uint8 vaultType = _vaultTypes[i];
            VaultInfo storage vaultInfo = state.vaults[vaultId];
            require(vaultInfo.vaultAddress == address(0), IMasterAccountController.VaultIdAlreadyUsed(vaultId));
            require(vaultAddress != address(0), IMasterAccountController.InvalidVaultId(vaultId));
            require(vaultType == 1 || vaultType == 2, IMasterAccountController.InvalidVaultType(vaultType));
            vaultInfo.vaultAddress = vaultAddress;
            vaultInfo.vaultType = vaultType;
            state.vaultIds.push(vaultId);
            emit IMasterAccountController.VaultAdded(vaultId, vaultAddress, vaultType);
        }
    }

    /**
     * @inheritdoc IMasterAccountController
     */
    function getVaults()
        external view
        returns (uint256[] memory _vaultIds, address[] memory _vaultAddresses, uint8[] memory _vaultTypes)
    {
        State storage state = getState();
        _vaultIds = state.vaultIds;
        _vaultAddresses = new address[](_vaultIds.length);
        _vaultTypes = new uint8[](_vaultIds.length);
        for (uint256 i = 0; i < _vaultIds.length; i++) {
            VaultInfo memory vaultInfo = state.vaults[_vaultIds[i]];
            _vaultAddresses[i] = vaultInfo.vaultAddress;
            _vaultTypes[i] = vaultInfo.vaultType;
        }
    }

    function getVaultAddress(bytes32 _paymentReference) internal view returns (address _vault) {
        // bytes 14-15: vault address id
        uint256 vaultId = (uint256(_paymentReference) >> 128) & ((uint256(1) << 16) - 1);
        State storage state = getState();
        VaultInfo memory vaultInfo = state.vaults[vaultId];
        _vault = vaultInfo.vaultAddress;
        uint256 instructionType = uint256(_paymentReference) >> 252;
        require(_vault != address(0), IMasterAccountController.InvalidVaultId(vaultId));
        require(
            instructionType == vaultInfo.vaultType,
            IMasterAccountController.InvalidInstructionType(instructionType)
        );
    }

    bytes32 internal constant STATE_POSITION = keccak256("smartAccounts.Vaults.State");

    function getState()
        internal pure
        returns (State storage _state)
    {
        bytes32 position = STATE_POSITION;
        // solhint-disable-next-line no-inline-assembly
        assembly {
            _state.slot := position
        }
    }
}
