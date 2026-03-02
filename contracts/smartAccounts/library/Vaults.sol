// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IVaultsFacet} from "../../userInterfaces/facets/IVaultsFacet.sol";
import {IInstructionsFacet} from "../../userInterfaces/facets/IInstructionsFacet.sol";
import {PaymentReferenceParser} from "./PaymentReferenceParser.sol";

library Vaults {

    /// @notice Struct containing vault information
    struct VaultInfo {
        /// @notice Vault address
        address vaultAddress;
        /// @notice Vault type (1 = Firelight, 2 = Upshift, ...)
        uint8 vaultType;
    }

    /// @custom:storage-location erc7201:smartAccounts.Vaults.State
    struct State {
        /// @notice Mapping from vault ID to vault information
        mapping(uint256 vaultId => VaultInfo vaultInfo) vaultIdToVaultInfo;
        /// @notice Mapping from vault address to vault ID
        mapping(address vaultAddress => uint256 vaultId) vaultAddressToVaultId;
        /// @notice Array of vault IDs
        uint256[] vaultIds;
    }

    bytes32 internal constant STATE_POSITION = keccak256(
        abi.encode(uint256(keccak256("smartAccounts.Vaults.State")) - 1)) & ~bytes32(uint256(0xff)
    );

    function getVaultAddress(bytes32 _paymentReference) internal view returns (address _vault) {
        uint256 vaultId = PaymentReferenceParser.getVaultId(_paymentReference);
        State storage state = getState();
        VaultInfo memory vaultInfo = state.vaultIdToVaultInfo[vaultId];
        _vault = vaultInfo.vaultAddress;
        uint256 instructionType = PaymentReferenceParser.getInstructionType(_paymentReference);
        require(_vault != address(0), IVaultsFacet.InvalidVaultId(vaultId));
        require(
            instructionType == vaultInfo.vaultType,
            IInstructionsFacet.InvalidInstructionType(instructionType)
        );
    }

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
