// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IAgentVaultsFacet} from "../../userInterfaces/facets/IAgentVaultsFacet.sol";
import {PaymentReferenceParser} from "./PaymentReferenceParser.sol";

library AgentVaults {

    /// @custom:storage-location erc7201:smartAccounts.AgentVaults.State
    struct State {
        /// @notice Mapping from agent vault ID to agent vault address
        mapping(uint256 agentVaultId => address agentVaultAddress) agentVaultIdToAgentVaultAddress;
        /// @notice Mapping from agent vault address to agent vault ID
        mapping(address agentVaultAddress => uint256 agentVaultId) agentVaultAddressToAgentVaultId;
        /// @notice Array of agent vault IDs
        uint256[] agentVaultIds;
    }

    bytes32 internal constant STATE_POSITION = keccak256(
        abi.encode(uint256(keccak256("smartAccounts.AgentVaults.State")) - 1)) & ~bytes32(uint256(0xff)
    );

    function getAgentVaultAddress(bytes32 _paymentReference) internal view returns (address _agentVault) {
        uint256 agentVaultId = PaymentReferenceParser.getAgentVaultId(_paymentReference);
        State storage state = getState();
        _agentVault = state.agentVaultIdToAgentVaultAddress[agentVaultId];
        require(_agentVault != address(0), IAgentVaultsFacet.InvalidAgentVault(agentVaultId));
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
