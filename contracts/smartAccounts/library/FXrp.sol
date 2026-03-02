// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ContractRegistry} from "flare-periphery/src/flare/ContractRegistry.sol";
import {IIPersonalAccount} from "../interface/IIPersonalAccount.sol";
import {Executors} from "./Executors.sol";
import {IInstructionsFacet} from "../../userInterfaces/facets/IInstructionsFacet.sol";

library FXrp {

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
        (address payable executor, uint256 executorFee) = Executors.getExecutorInfo();
        _collateralReservationId = _personalAccount.reserveCollateral{value: msg.value}(
            _agentVault,
            _lots,
            executor,
            executorFee
        );

        // emit event
        emit IInstructionsFacet.CollateralReserved(
            address(_personalAccount),
            _transactionId,
            _paymentReference,
            _xrplAddress,
            _collateralReservationId,
            _agentVault,
            _lots,
            executor,
            executorFee
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
        emit IInstructionsFacet.FXrpTransferred(
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
        (address payable executor, uint256 executorFee) = Executors.getExecutorInfo();
        uint256 amount = _personalAccount.redeemFXrp{value: msg.value}(_lots, executor, executorFee);
        emit IInstructionsFacet.FXrpRedeemed(
            address(_personalAccount),
            _lots,
            amount,
            executor,
            executorFee
        );
    }

    function lotsToAmount(uint256 _lots) internal view returns (uint256) {
        uint256 lotSize = ContractRegistry.getAssetManagerFXRP().lotSize();
        return _lots * lotSize;
    }
}
