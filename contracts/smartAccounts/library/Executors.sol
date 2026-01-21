// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IExecutorsFacet} from "../../userInterfaces/facets/IExecutorsFacet.sol";

library Executors {

    /// @custom:storage-location erc7201:smartAccounts.Executors.State
    struct State {
        /// @notice The mint and redeem executor.
        address payable executor;
        /// @notice Executor fee for minting and redeeming (in wei)
        uint256 executorFee;
    }

    bytes32 internal constant STATE_POSITION = keccak256(
        abi.encode(uint256(keccak256("smartAccounts.Executors.State")) - 1)) & ~bytes32(uint256(0xff)
    );

    function setExecutor(
        address payable _executor
    )
        internal
    {
        require(_executor != address(0), IExecutorsFacet.InvalidExecutor());
        State storage state = getState();
        state.executor = _executor;
        emit IExecutorsFacet.ExecutorSet(_executor);
    }

    function setExecutorFee(
        uint256 _executorFee
    )
        internal
    {
        require(_executorFee > 0, IExecutorsFacet.InvalidExecutorFee());
        State storage state = getState();
        state.executorFee = _executorFee;
        emit IExecutorsFacet.ExecutorFeeSet(_executorFee);
    }

    function getExecutorInfo()
        internal view
        returns (address payable _executor, uint256 _executorFee)
    {
        State storage state = getState();
        _executor = state.executor;
        _executorFee = state.executorFee;
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
