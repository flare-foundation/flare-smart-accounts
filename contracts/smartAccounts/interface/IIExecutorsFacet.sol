// SPDX-License-Identifier: MIT
pragma solidity >=0.7.6 <0.9;

import {IExecutorsFacet} from "../../userInterfaces/facets/IExecutorsFacet.sol";

/**
 * @title IIExecutorsFacet
 * @notice Internal interface for the ExecutorsFacet contract.
 */
interface IIExecutorsFacet is IExecutorsFacet {
    /**
     * @notice Sets new executor address.
     * @param _executor New executor address.
     * Can only be called by the owner.
     */
    function setExecutor(
        address payable _executor
    )
        external;

    /**
     * @notice Sets new executor fee.
     * @param _executorFee New executor fee in wei.
     * Can only be called by the owner.
     */
    function setExecutorFee(
        uint256 _executorFee
    )
        external;
}