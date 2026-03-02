// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IIInstructionFeesFacet} from "../interface/IIInstructionFeesFacet.sol";
import {IInstructionFeesFacet} from "../../userInterfaces/facets/IInstructionFeesFacet.sol";
import {InstructionFees} from "../library/InstructionFees.sol";
import {FacetBase} from "./FacetBase.sol";

/**
 * @title InstructionFeesFacet
 * @notice Facet for handling instruction fees-related functions.
 */
contract InstructionFeesFacet is IIInstructionFeesFacet, FacetBase {

    /// @inheritdoc IIInstructionFeesFacet
    function setDefaultInstructionFee(
        uint256 _defaultInstructionFee
    )
        external
        onlyOwnerWithTimelock
    {
        InstructionFees.setDefaultInstructionFee(_defaultInstructionFee);
    }

    /// @inheritdoc IIInstructionFeesFacet
    function setInstructionFees(
        uint256[] calldata _instructionIds,
        uint256[] calldata _fees
    )
        external
        onlyOwnerWithTimelock
    {
        InstructionFees.State storage state = InstructionFees.getState();
        require(_instructionIds.length == _fees.length, InstructionFeesLengthsMismatch());
        for (uint256 i = 0; i < _instructionIds.length; i++) {
            uint256 instructionId = _instructionIds[i];
            uint256 fee = _fees[i];
            state.instructionFees[instructionId] = fee + 1; // store 1-based to distinguish from default (0)
            emit InstructionFeeSet(instructionId, fee);
        }
    }

    /// @inheritdoc IIInstructionFeesFacet
    function removeInstructionFees(
        uint256[] calldata _instructionIds
    )
        external
        onlyOwnerWithTimelock
    {
        InstructionFees.State storage state = InstructionFees.getState();
        for (uint256 i = 0; i < _instructionIds.length; i++) {
            uint256 instructionId = _instructionIds[i];
            require(
                state.instructionFees[instructionId] != 0,
                InstructionFeeNotSet(instructionId)
            );
            delete state.instructionFees[instructionId];
            emit InstructionFeeRemoved(instructionId);
        }
    }

    /// @inheritdoc IInstructionFeesFacet
    function getDefaultInstructionFee()
        external view
        returns (uint256)
    {
        InstructionFees.State storage state = InstructionFees.getState();
        return state.defaultInstructionFee;
    }

    /// @inheritdoc IInstructionFeesFacet
    function getInstructionFee(
        uint256 _instructionId
    )
        external view
        returns (uint256)
    {
        return InstructionFees.getInstructionFee(_instructionId);
    }
}