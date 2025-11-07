// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IAgentVaultsFacet} from "../../userInterfaces/facets/IAgentVaultsFacet.sol";

library AgentVaults {

    struct State {
        /// @notice Mapping from agent vault ID to agent vault address
        mapping(uint256 agentVaultId => address agentVaultAddress) agentVaults;
        uint256[] agentVaultIds;
    }

    function getAgentVaultAddress(bytes32 _paymentReference) internal view returns (address _agentVault) {
        // bytes 12-13: agent vault address id
        uint256 agentVaultId = (uint256(_paymentReference) >> 144) & ((uint256(1) << 16) - 1);
        State storage state = getState();
        _agentVault = state.agentVaults[agentVaultId];
        require(_agentVault != address(0), IAgentVaultsFacet.InvalidAgentVault(agentVaultId));
    }

    bytes32 internal constant STATE_POSITION = keccak256("smartAccounts.AgentVaults.State");

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
