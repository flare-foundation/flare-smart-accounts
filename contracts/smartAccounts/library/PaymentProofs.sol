// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ContractRegistry} from "flare-periphery/src/flare/ContractRegistry.sol";
import {IPayment} from "flare-periphery/src/flare/IPayment.sol";
import {XrplProviderWallets} from "./XrplProviderWallets.sol";
import {IPaymentProofsFacet} from "../../userInterfaces/facets/IPaymentProofsFacet.sol";

library PaymentProofs {

    /// @custom:storage-location erc7201:smartAccounts.PaymentProofs.State
    struct State {
        /// @notice Source ID used for payment verification
        bytes32 sourceId;
        /// @notice Duration (in seconds) for which the payment proof is valid
        uint256 paymentProofValidityDurationSeconds;
    }

    bytes32 internal constant STATE_POSITION = keccak256(
        abi.encode(uint256(keccak256("smartAccounts.PaymentProofs.State")) - 1)) & ~bytes32(uint256(0xff)
    );

    function setSourceId(
        bytes32 _sourceId
    )
        internal
    {
        State storage state = PaymentProofs.getState();
        state.sourceId = _sourceId;
    }

    function setPaymentProofValidityDuration(
        uint256 _paymentProofValidityDurationSeconds
    )
        internal
    {
        require(_paymentProofValidityDurationSeconds > 0, IPaymentProofsFacet.InvalidPaymentProofValidityDuration());
        PaymentProofs.State storage state = PaymentProofs.getState();
        state.paymentProofValidityDurationSeconds = _paymentProofValidityDurationSeconds;
        emit IPaymentProofsFacet.PaymentProofValidityDurationSecondsSet(_paymentProofValidityDurationSeconds);
    }

    /**
     * @notice Verifies the provided payment proof against the expected XRPL address.
     * @param _proof The payment proof to verify.
     * @param _xrplAddress The expected XRPL address associated with the payment.
     */
    function verifyPayment(
        IPayment.Proof calldata _proof,
        string memory _xrplAddress
    )
        internal view
    {
        State storage state = getState();
        require(
            _proof.data.sourceId == state.sourceId,
            IPaymentProofsFacet.InvalidSourceId()
        );
        require(
            _proof.data.responseBody.status == 0,
            IPaymentProofsFacet.InvalidTransactionStatus()
        );
        require(
            block.timestamp <= state.paymentProofValidityDurationSeconds + _proof.data.responseBody.blockTimestamp,
            IPaymentProofsFacet.PaymentProofExpired()
        );
        require(
            _proof.data.responseBody.sourceAddressHash == keccak256(bytes(_xrplAddress)),
            IPaymentProofsFacet.MismatchingSourceAndXrplAddr()
        );
        XrplProviderWallets.State storage xrplProviderWalletsState = XrplProviderWallets.getState();
        require(
            xrplProviderWalletsState.xrplProviderWalletHashes[_proof.data.responseBody.receivingAddressHash] != 0,
            IPaymentProofsFacet.InvalidReceivingAddressHash()
        );
        require(
            ContractRegistry.getFdcVerification().verifyPayment(_proof),
            IPaymentProofsFacet.InvalidTransactionProof()
        );
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
