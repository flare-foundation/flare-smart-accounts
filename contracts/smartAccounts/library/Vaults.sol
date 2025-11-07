// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IVaultsFacet} from "../../userInterfaces/facets/IVaultsFacet.sol";
import {IInstructionsFacet} from "../../userInterfaces/facets/IInstructionsFacet.sol";

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

    function getVaultAddress(bytes32 _paymentReference) internal view returns (address _vault) {
        // bytes 14-15: vault address id
        uint256 vaultId = (uint256(_paymentReference) >> 128) & ((uint256(1) << 16) - 1);
        State storage state = getState();
        VaultInfo memory vaultInfo = state.vaults[vaultId];
        _vault = vaultInfo.vaultAddress;
        uint256 instructionType = uint256(_paymentReference) >> 252;
        require(_vault != address(0), IVaultsFacet.InvalidVaultId(vaultId));
        require(
            instructionType == vaultInfo.vaultType,
            IInstructionsFacet.InvalidInstructionType(instructionType)
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
