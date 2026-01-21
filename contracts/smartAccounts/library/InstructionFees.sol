// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IInstructionFeesFacet} from "../../userInterfaces/facets/IInstructionFeesFacet.sol";

library InstructionFees {

    /// @custom:storage-location erc7201:smartAccounts.InstructionFees.State
    struct State {
        /// @notice Default fee for instruction execution in underlying asset's smallest unit (drops for XRP)
        uint256 defaultInstructionFee;
        /// @notice Override for default instruction fee (1-based to distinguish from default (0))
        mapping(uint256 instructionId => uint256 fee) instructionFees;
    }

    bytes32 internal constant STATE_POSITION = keccak256(
        abi.encode(uint256(keccak256("smartAccounts.InstructionFees.State")) - 1)) & ~bytes32(uint256(0xff)
    );

    function setDefaultInstructionFee(
        uint256 _defaultInstructionFee
    )
        internal
    {
        State storage state = getState();
        state.defaultInstructionFee = _defaultInstructionFee;
        emit IInstructionFeesFacet.DefaultInstructionFeeSet(_defaultInstructionFee);
    }

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
