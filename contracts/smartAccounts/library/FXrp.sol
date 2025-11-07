// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LibDiamond} from "../../diamond/libraries/LibDiamond.sol";
import {ContractRegistry} from "flare-periphery/src/flare/ContractRegistry.sol";
import {IIPersonalAccount} from "../interface/IIPersonalAccount.sol";
import {IMasterAccountController} from "../../userInterfaces/IMasterAccountController.sol";


library FXrp {

    struct State {
        /// @notice The mint and redeem executor.
        address payable executor;
        /// @notice Executor fee for minting and redeeming (in wei)
        uint256 executorFee;
    }

    function reserveCollateral(
        IIPersonalAccount _personalAccount,
        address _agentVault,
        uint256 _lots,
        bytes32 _transactionId,
        bytes32 _paymentReference,
        string calldata _xrplAddress
    )
        internal
        returns (uint256 _collateralReservationId)
    {
        State storage state = getState();
        _collateralReservationId = _personalAccount.reserveCollateral{value: msg.value}(
            _agentVault,
            _lots,
            state.executor,
            state.executorFee
        );

        // emit event
        emit IMasterAccountController.CollateralReserved(
            address(_personalAccount),
            _transactionId,
            _paymentReference,
            _xrplAddress,
            _collateralReservationId,
            _agentVault,
            _lots,
            state.executor,
            state.executorFee
        );
    }

    function transfer(
        IIPersonalAccount _personalAccount,
        address _recipient,
        uint256 _amount
    )
        internal
    {
        _personalAccount.transferFXrp(_recipient, _amount);
        emit IMasterAccountController.FXrpTransferred(
            address(_personalAccount),
            _recipient,
            _amount
        );
    }

    function redeem(
        IIPersonalAccount _personalAccount,
        uint256 _lots
    )
        internal
    {
        State storage state = getState();
        address payable executor = state.executor;
        uint256 executorFee = state.executorFee;
        uint256 amount = _personalAccount.redeemFXrp{value: msg.value}(_lots, executor, executorFee);
        emit IMasterAccountController.FXrpRedeemed(
            address(_personalAccount),
            _lots,
            amount,
            executor,
            executorFee
        );
    }

    /**
     * @notice Sets new executor address.
     * @param _newExecutor New executor address.
     * Can only be called by the owner.
     */
    function setExecutor(
        address payable _newExecutor
    )
        external
    {
        LibDiamond.enforceIsContractOwner();
        _setExecutor(_newExecutor);
    }

    /**
     * @notice Sets new executor fee.
     * @param _newExecutorFee New executor fee in wei.
     * Can only be called by the owner.
     */
    function setExecutorFee(
        uint256 _newExecutorFee
    )
        external
    {
        LibDiamond.enforceIsContractOwner();
        _setExecutorFee(_newExecutorFee);
    }

    function _setExecutor(address payable _executor) internal {
        require(_executor != address(0), IMasterAccountController.InvalidExecutor());
        State storage state = getState();
        state.executor = _executor;
        emit IMasterAccountController.ExecutorSet(_executor);
    }

    function _setExecutorFee(uint256 _executorFee) internal {
        require(_executorFee > 0, IMasterAccountController.InvalidExecutorFee());
        State storage state = getState();
        state.executorFee = _executorFee;
        emit IMasterAccountController.ExecutorFeeSet(_executorFee);
    }

    /**
     * @inheritdoc IMasterAccountController
     */
    function getExecutorInfo()
        external view
        returns (address payable _executor, uint256 _executorFee)
    {
        State storage state = getState();
        _executor = state.executor;
        _executorFee = state.executorFee;
    }

    bytes32 internal constant STATE_POSITION = keccak256("smartAccounts.Vaults.State");

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
