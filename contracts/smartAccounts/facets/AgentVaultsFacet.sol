// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LibDiamond} from "../../diamond/libraries/LibDiamond.sol";
import {ContractRegistry} from "flare-periphery/src/flare/ContractRegistry.sol";
import {IAssetManager} from "flare-periphery/src/flare/IAssetManager.sol";
import {AgentInfo} from "flare-periphery/src/flare/data/AgentInfo.sol";
import {IIAgentVaultsFacet} from "../interface/IIAgentVaultsFacet.sol";
import {IAgentVaultsFacet} from "../../userInterfaces/facets/IAgentVaultsFacet.sol";
import {AgentVaults} from "../library/AgentVaults.sol";

/**
 * @title AgentVaultsFacet
 * @notice Facet for handling agent vault-related functions.
 */
contract AgentVaultsFacet is IIAgentVaultsFacet {

    /// @inheritdoc IIAgentVaultsFacet
    function addAgentVaults(
        uint256[] calldata _agentVaultIds,
        address[] calldata _agentVaultAddresses
    )
        external
    {
        LibDiamond.enforceIsContractOwner();
        require(_agentVaultIds.length == _agentVaultAddresses.length, AgentsVaultsLengthsMismatch());
        IAssetManager assetManager = ContractRegistry.getAssetManagerFXRP();
        AgentVaults.State storage state = AgentVaults.getState();
        for (uint256 i = 0; i < _agentVaultIds.length; i++) {
            uint256 agentVaultId = _agentVaultIds[i];
            address agentVaultAddress = _agentVaultAddresses[i];
            require(state.agentVaults[agentVaultId] == address(0), AgentVaultIdAlreadyUsed(agentVaultId));
            require(agentVaultAddress != address(0), InvalidAgentVault(agentVaultId));
            AgentInfo.Info memory agentInfo = assetManager.getAgentInfo(agentVaultAddress);
            require(agentInfo.status == AgentInfo.Status.NORMAL, AgentNotAvailable(agentVaultAddress));
            state.agentVaults[agentVaultId] = agentVaultAddress;
            state.agentVaultIds.push(agentVaultId);
            emit AgentVaultAdded(agentVaultId, agentVaultAddress);
        }
    }

    /// @inheritdoc IIAgentVaultsFacet
    function removeAgentVaults(
        uint256[] calldata _agentVaultIds
    )
        external
    {
        LibDiamond.enforceIsContractOwner();
        AgentVaults.State storage state = AgentVaults.getState();
        for (uint256 i = 0; i < _agentVaultIds.length; i++) {
            uint256 agentVaultId = _agentVaultIds[i];
            address agentVault = state.agentVaults[agentVaultId];
            require(agentVault != address(0), InvalidAgentVault(agentVaultId));
            // remove from mapping
            delete state.agentVaults[agentVaultId];
            // remove from array
            for (uint256 j = 0; j < state.agentVaultIds.length; j++) {
                if (state.agentVaultIds[j] == agentVaultId) {
                    state.agentVaultIds[j] = state.agentVaultIds[state.agentVaultIds.length - 1];
                    state.agentVaultIds.pop();
                    break;
                }
            }
            emit AgentVaultRemoved(agentVaultId, agentVault);
        }
    }

    /// @inheritdoc IAgentVaultsFacet
    function getAgentVaults()
        external view
        returns (uint256[] memory _agentVaultIds, address[] memory _agentVaultAddresses)
    {
        AgentVaults.State storage state = AgentVaults.getState();
        _agentVaultIds = state.agentVaultIds;
        _agentVaultAddresses = new address[](_agentVaultIds.length);
        for (uint256 i = 0; i < _agentVaultIds.length; i++) {
            _agentVaultAddresses[i] = state.agentVaults[_agentVaultIds[i]];
        }
    }
}
