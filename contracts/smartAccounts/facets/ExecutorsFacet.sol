// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IIExecutorsFacet} from "../interface/IIExecutorsFacet.sol";
import {IExecutorsFacet} from "../../userInterfaces/facets/IExecutorsFacet.sol";
import {Executors} from "../library/Executors.sol";
import {FacetBase} from "./FacetBase.sol";

/**
 * @title ExecutorsFacet
 * @notice Facet for handling executor-related functions.
 */
contract ExecutorsFacet is IIExecutorsFacet, FacetBase {

    /// @inheritdoc IIExecutorsFacet
    function setExecutor(
        address payable _executor
    )
        external
        onlyOwner
    {
        Executors.setExecutor(_executor);
    }

    /// @inheritdoc IIExecutorsFacet
    function setExecutorFee(
        uint256 _executorFee
    )
        external
        onlyOwnerWithTimelock
    {
        Executors.setExecutorFee(_executorFee);
    }

    /// @inheritdoc IExecutorsFacet
    function getExecutorInfo()
        external view
        returns (address payable, uint256)
    {
        return Executors.getExecutorInfo();
    }
}
