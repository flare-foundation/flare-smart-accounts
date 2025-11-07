// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LibDiamond} from "../../diamond/libraries/LibDiamond.sol";
import {ContractRegistry} from "flare-periphery/src/flare/ContractRegistry.sol";
import {IIPersonalAccount} from "../interface/IIPersonalAccount.sol";
import {IMasterAccountController} from "../../userInterfaces/IMasterAccountController.sol";
import {IAssetManager} from "flare-periphery/src/flare/IAssetManager.sol";
import {AgentInfo} from "flare-periphery/src/flare/data/AvailableAgentInfo.sol";


library AgentVaults {

    struct State {
        /// @notice Mapping from agent vault ID to agent vault address
        mapping(uint256 agentVaultId => address agentVaultAddress) agentVaults;
        uint256[] agentVaultIds;
    }

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
        internal
    {
        LibDiamond.enforceIsContractOwner();
        require(
            _agentVaultIds.length == _agentVaultAddresses.length,
            IMasterAccountController.LengthsMismatch()
        );
        IAssetManager assetManager = ContractRegistry.getAssetManagerFXRP();
        State storage state = getState();
        for (uint256 i = 0; i < _agentVaultIds.length; i++) {
            uint256 agentVaultId = _agentVaultIds[i];
            address agentVaultAddress = _agentVaultAddresses[i];
            require(
                state.agentVaults[agentVaultId] == address(0),
                IMasterAccountController.AgentVaultIdAlreadyUsed(agentVaultId)
            );
            require(
                agentVaultAddress != address(0),
                IMasterAccountController.InvalidAgentVault(agentVaultId)
            );
            AgentInfo.Info memory agentInfo = assetManager.getAgentInfo(agentVaultAddress);
            require(
                agentInfo.status == AgentInfo.Status.NORMAL,
                IMasterAccountController.AgentNotAvailable(agentVaultAddress)
            );
            state.agentVaults[agentVaultId] = agentVaultAddress;
            state.agentVaultIds.push(agentVaultId);
            emit IMasterAccountController.AgentVaultAdded(agentVaultId, agentVaultAddress);
        }
    }

    /**
     * @notice Removes existing agent vault addresses by their IDs.
     * @param _agentVaultIds The IDs of the agent vaults to remove.
     * Can only be called by the owner.
     */
    function removeAgentVaults(
        uint256[] calldata _agentVaultIds
    )
        internal
    {
        LibDiamond.enforceIsContractOwner();
        State storage state = getState();
        for (uint256 i = 0; i < _agentVaultIds.length; i++) {
            uint256 agentVaultId = _agentVaultIds[i];
            address agentVault = state.agentVaults[agentVaultId];
            require(agentVault != address(0), IMasterAccountController.InvalidAgentVault(agentVaultId));
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
            emit IMasterAccountController.AgentVaultRemoved(agentVaultId, agentVault);
        }
    }

    /**
     * @inheritdoc IMasterAccountController
     */
    function getAgentVaults()
        internal view
        returns (uint256[] memory _agentVaultIds, address[] memory _agentVaultAddresses)
    {
        State storage state = getState();
        _agentVaultIds = state.agentVaultIds;
        _agentVaultAddresses = new address[](_agentVaultIds.length);
        for (uint256 i = 0; i < _agentVaultIds.length; i++) {
            _agentVaultAddresses[i] = state.agentVaults[_agentVaultIds[i]];
        }
    }

    function getAgentVaultAddress(bytes32 _paymentReference) internal view returns (address _agentVault) {
        // bytes 12-13: agent vault address id
        uint256 agentVaultId = (uint256(_paymentReference) >> 144) & ((uint256(1) << 16) - 1);
        State storage state = getState();
        _agentVault = state.agentVaults[agentVaultId];
        require(_agentVault != address(0), IMasterAccountController.InvalidAgentVault(agentVaultId));
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
