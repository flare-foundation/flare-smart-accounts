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

    bytes32 internal constant STATE_POSITION = keccak256("smartAccounts.InstructionFees.State");

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
