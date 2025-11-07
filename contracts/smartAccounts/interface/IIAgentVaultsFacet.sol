// SPDX-License-Identifier: MIT
pragma solidity >=0.7.6 <0.9;

import {IAgentVaultsFacet} from "../../userInterfaces/facets/IAgentVaultsFacet.sol";

/**
 * @title IIAgentVaultsFacet
 * @notice Internal interface for the AgentVaultsFacet contract.
 */
interface IIAgentVaultsFacet is IAgentVaultsFacet {

    /**
     * @notice Adds new agent vault addresses with the given IDs.
     * @param _agentVaultIds The IDs of the agent vaults.
     * @param _agentVaultAddresses The addresses of the agent vaults.
     * Can only be called by the owner.
     */
    function addAgentVaults(
        uint256[] calldata _agentVaultIds,
        address[] calldata _agentVaultAddresses
    )
        external;

    /**
     * @notice Removes existing agent vault addresses by their IDs.
     * @param _agentVaultIds The IDs of the agent vaults to remove.
     * Can only be called by the owner.
     */
    function removeAgentVaults(
        uint256[] calldata _agentVaultIds
    )
        external;
}