// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LibDiamond} from "../../diamond/libraries/LibDiamond.sol";
import {ContractRegistry} from "flare-periphery/src/flare/ContractRegistry.sol";
import {IIPersonalAccount} from "../interface/IIPersonalAccount.sol";
import {IMasterAccountController} from "../../userInterfaces/IMasterAccountController.sol";


library InstructionFees {

    struct State {
        /// @notice Default fee for instruction execution in underlying asset's smallest unit (drops for XRP)
        uint256 defaultInstructionFee;
        /// @notice Override for default instruction fee (1-based to distinguish from default (0))
        mapping(uint256 instructionId => uint256 fee) instructionFees;
    }

    /**
     * @notice Sets new default instruction fee.
     * @param _defaultInstructionFee New default instruction fee in underlying asset's smallest unit (drops for XRP).
     * Can only be called by the owner.
     */
    function setDefaultInstructionFee(
        uint256 _defaultInstructionFee
    )
        external
    {
        LibDiamond.enforceIsContractOwner();
        _setDefaultInstructionFee(_defaultInstructionFee);
    }

    /**
     * @notice Sets instruction-specific fees, overriding the default fee.
     * @param _instructionIds The IDs of the instructions.
     * @param _fees The fees for the instructions in underlying asset's smallest unit (drops for XRP).
     * Can only be called by the owner.
     */
    function setInstructionFees(
        uint256[] calldata _instructionIds,
        uint256[] calldata _fees
    )
        internal
    {
        LibDiamond.enforceIsContractOwner();
        State storage state = getState();
        require(_instructionIds.length == _fees.length, IMasterAccountController.LengthsMismatch());
        for (uint256 i = 0; i < _instructionIds.length; i++) {
            uint256 instructionId = _instructionIds[i];
            uint256 fee = _fees[i];
            state.instructionFees[instructionId] = fee + 1; // store 1-based to distinguish from default (0)
            emit IMasterAccountController.InstructionFeeSet(instructionId, fee);
        }
    }

    /**
     * @notice Removes instruction-specific fees, reverting to the default fee.
     * @param _instructionIds The IDs of the instructions to remove fees for.
     * Can only be called by the owner.
     */
    function removeInstructionFees(
        uint256[] calldata _instructionIds
    )
        internal
    {
        LibDiamond.enforceIsContractOwner();
        State storage state = getState();
        for (uint256 i = 0; i < _instructionIds.length; i++) {
            uint256 instructionId = _instructionIds[i];
            require(
                state.instructionFees[instructionId] != 0,
                IMasterAccountController.InstructionFeeNotSet(instructionId)
            );
            delete state.instructionFees[instructionId];
            emit IMasterAccountController.InstructionFeeRemoved(instructionId);
        }
    }


    function _setDefaultInstructionFee(uint256 _defaultInstructionFee) internal {
        State storage state = getState();
        state.defaultInstructionFee = _defaultInstructionFee;
        emit IMasterAccountController.DefaultInstructionFeeSet(_defaultInstructionFee);
    }


    /**
     * @inheritdoc IMasterAccountController
     */
    function getInstructionFee(
        uint256 _instructionId
    )
        internal view
        returns (uint256)
    {
        State storage state = getState();
        uint256 fee = state.instructionFees[_instructionId]; // 1-based to distinguish unset (0) from zero fee
        if (fee > 0) {
            return fee - 1;
        }
        return state.defaultInstructionFee;
    }


    bytes32 internal constant STATE_POSITION = keccak256("smartAccounts.InstructionFees.State");

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
