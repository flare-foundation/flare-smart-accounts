// SPDX-License-Identifier: MIT
pragma solidity >=0.7.6 <0.9;

import {IInstructionFeesFacet} from "../../userInterfaces/facets/IInstructionFeesFacet.sol";

/**
 * @title IIInstructionFeesFacet
 * @notice Internal interface for the InstructionFeesFacet contract.
 */
interface IIInstructionFeesFacet is IInstructionFeesFacet {

    /**
     * @notice Sets new default instruction fee.
     * @param _defaultInstructionFee New default instruction fee in underlying asset's smallest unit (drops for XRP).
     * Can only be called by the owner.
     */
    function setDefaultInstructionFee(
        uint256 _defaultInstructionFee
    )
        external;

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
        external;

    /**
     * @notice Removes instruction-specific fees, reverting to the default fee.
     * @param _instructionIds The IDs of the instructions to remove fees for.
     * Can only be called by the owner.
     */
    function removeInstructionFees(
        uint256[] calldata _instructionIds
    )
        external;
}