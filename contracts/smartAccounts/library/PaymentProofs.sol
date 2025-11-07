// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LibDiamond} from "../../diamond/libraries/LibDiamond.sol";
import {ContractRegistry} from "flare-periphery/src/flare/ContractRegistry.sol";
import {IIPersonalAccount} from "../interface/IIPersonalAccount.sol";
import {IPayment} from "flare-periphery/src/flare/IPayment.sol";
import {XrplProviderWallets} from "./XrplProviderWallets.sol";
import {IMasterAccountController} from "../../userInterfaces/IMasterAccountController.sol";


library PaymentProofs {

    struct State {
        /// @notice Duration (in seconds) for which the payment proof is valid
        uint256 paymentProofValidityDurationSeconds;
    }

    /**
     * @notice Sets the payment proof validity duration.
     * @param _paymentProofValidityDurationSeconds Duration in seconds.
     * Can only be called by the owner.
     */
    function setPaymentProofValidityDurationSeconds(
        uint256 _paymentProofValidityDurationSeconds
    )
        internal
    {
        LibDiamond.enforceIsContractOwner();
        require(
            _paymentProofValidityDurationSeconds > 0,
            IMasterAccountController.InvalidPaymentProofValidityDuration()
        );
        State storage state = getState();
        state.paymentProofValidityDurationSeconds = _paymentProofValidityDurationSeconds;
        emit IMasterAccountController.PaymentProofValidityDurationSecondsSet(_paymentProofValidityDurationSeconds);
    }


    function verifyPayment(
        IPayment.Proof calldata _proof,
        string memory _xrplAddress
    )
        internal view
    {
        State storage state = getState();
        require(
            _proof.data.responseBody.status == 0,
            IMasterAccountController.InvalidTransactionStatus()
        );
        require(
            block.timestamp <= state.paymentProofValidityDurationSeconds + _proof.data.responseBody.blockTimestamp,
            IMasterAccountController.PaymentProofExpired()
        );
        require(
            _proof.data.responseBody.sourceAddressHash == keccak256(bytes(_xrplAddress)),
            IMasterAccountController.MismatchingSourceAndXrplAddr()
        );
        XrplProviderWallets.State storage xrplProviderWalletsState = XrplProviderWallets.getState();
        require(
            xrplProviderWalletsState.xrplProviderWalletHashes[_proof.data.responseBody.receivingAddressHash] != 0,
            IMasterAccountController.InvalidReceivingAddressHash()
        );
        require(
            ContractRegistry.getFdcVerification().verifyPayment(_proof),
            IMasterAccountController.InvalidTransactionProof()
        );
    }


    bytes32 internal constant STATE_POSITION = keccak256("smartAccounts.PaymentProofs.State");

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
