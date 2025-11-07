// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LibDiamond} from "../../diamond/libraries/LibDiamond.sol";
import {ContractRegistry} from "flare-periphery/src/flare/ContractRegistry.sol";
import {IIPersonalAccount} from "../interface/IIPersonalAccount.sol";
import {IMasterAccountController} from "../../userInterfaces/IMasterAccountController.sol";


library Executors {

    struct State {
        /// @notice The mint and redeem executor.
        address payable executor;
        /// @notice Executor fee for minting and redeeming (in wei)
        uint256 executorFee;
    }

    bytes32 internal constant STATE_POSITION = keccak256("smartAccounts.Executors.State");

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
