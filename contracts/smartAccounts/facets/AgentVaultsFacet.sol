// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ContractRegistry} from "flare-periphery/src/flare/ContractRegistry.sol";
import {IAssetManager} from "flare-periphery/src/flare/IAssetManager.sol";
import {AgentInfo} from "flare-periphery/src/flare/data/AgentInfo.sol";
import {IIAgentVaultsFacet} from "../interface/IIAgentVaultsFacet.sol";
import {IAgentVaultsFacet} from "../../userInterfaces/facets/IAgentVaultsFacet.sol";
import {AgentVaults} from "../library/AgentVaults.sol";
import {FacetBase} from "./FacetBase.sol";

/**
 * @title AgentVaultsFacet
 * @notice Facet for handling agent vault-related functions.
 */
contract AgentVaultsFacet is IIAgentVaultsFacet, FacetBase {

    /// @inheritdoc IIAgentVaultsFacet
    function addAgentVaults(
        uint256[] calldata _agentVaultIds,
        address[] calldata _agentVaultAddresses
    )
        external
        onlyOwnerWithTimelock
    {
        require(_agentVaultIds.length == _agentVaultAddresses.length, AgentsVaultsLengthsMismatch());
        IAssetManager assetManager = ContractRegistry.getAssetManagerFXRP();
        AgentVaults.State storage state = AgentVaults.getState();
        for (uint256 i = 0; i < _agentVaultIds.length; i++) {
            uint256 agentVaultId = _agentVaultIds[i];
            require(agentVaultId > 0, AgentVaultIdZero(i));
            require(
                state.agentVaultIdToAgentVaultAddress[agentVaultId] == address(0),
                AgentVaultIdAlreadyAdded(agentVaultId)
            );
            address agentVaultAddress = _agentVaultAddresses[i];
            require(agentVaultAddress != address(0), AgentVaultAddressZero(i));
            require(
                state.agentVaultAddressToAgentVaultId[agentVaultAddress] == 0,
                AgentVaultAddressAlreadyAdded(agentVaultAddress)
            );
            AgentInfo.Info memory agentInfo = assetManager.getAgentInfo(agentVaultAddress);
            require(agentInfo.status == AgentInfo.Status.NORMAL, AgentNotAvailable(agentVaultAddress));
            state.agentVaultIdToAgentVaultAddress[agentVaultId] = agentVaultAddress;
            state.agentVaultAddressToAgentVaultId[agentVaultAddress] = agentVaultId;
            state.agentVaultIds.push(agentVaultId);
            emit AgentVaultAdded(agentVaultId, agentVaultAddress);
        }
    }

    /// @inheritdoc IIAgentVaultsFacet
    function removeAgentVaults(
        uint256[] calldata _agentVaultIds
    )
        external
        onlyOwnerWithTimelock
    {
        AgentVaults.State storage state = AgentVaults.getState();
        for (uint256 i = 0; i < _agentVaultIds.length; i++) {
            uint256 agentVaultId = _agentVaultIds[i];
            address agentVault = state.agentVaultIdToAgentVaultAddress[agentVaultId];
            require(agentVault != address(0), InvalidAgentVault(agentVaultId));
            // remove from mappings
            delete state.agentVaultIdToAgentVaultAddress[agentVaultId];
            delete state.agentVaultAddressToAgentVaultId[agentVault];
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
            _agentVaultAddresses[i] = state.agentVaultIdToAgentVaultAddress[_agentVaultIds[i]];
        }
    }
}
