// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LibDiamond} from "../../diamond/libraries/LibDiamond.sol";
import {IIExecutorsFacet} from "../interface/IIExecutorsFacet.sol";
import {IExecutorsFacet} from "../../userInterfaces/facets/IExecutorsFacet.sol";
import {Executors} from "../library/Executors.sol";

/**
 * @title ExecutorsFacet
 * @notice Facet for handling executor-related functions.
 */
contract ExecutorsFacet is IIExecutorsFacet {

    /// @inheritdoc IIExecutorsFacet
    function setExecutor(
        address payable _executor
    )
        external
    {
        LibDiamond.enforceIsContractOwner();
        require(_executor != address(0), InvalidExecutor());
        Executors.State storage state = Executors.getState();
        state.executor = _executor;
        emit ExecutorSet(_executor);
    }

    /// @inheritdoc IIExecutorsFacet
    function setExecutorFee(
        uint256 _executorFee
    )
        external
    {
        LibDiamond.enforceIsContractOwner();
        require(_executorFee > 0, InvalidExecutorFee());
        Executors.State storage state = Executors.getState();
        state.executorFee = _executorFee;
        emit ExecutorFeeSet(_executorFee);
    }

    /// @inheritdoc IExecutorsFacet
    function getExecutorInfo()
        external view
        returns (address payable, uint256)
    {
        return Executors.getExecutorInfo();
    }
}
