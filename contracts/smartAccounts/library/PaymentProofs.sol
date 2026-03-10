// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ContractRegistry} from "flare-periphery/src/flare/ContractRegistry.sol";
import {IPayment} from "flare-periphery/src/flare/IPayment.sol";
import {IXRPPayment} from "../../userInterfaces/IXRPPayment.sol";
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
        _verifyProofData(
            _proof.data.sourceId,
            _proof.data.responseBody.status,
            _proof.data.responseBody.blockTimestamp,
            _proof.data.responseBody.sourceAddressHash,
            _proof.data.responseBody.receivingAddressHash,
            _xrplAddress
        );
        require(
            ContractRegistry.getFdcVerification().verifyPayment(_proof),
            IPaymentProofsFacet.InvalidTransactionProof()
        );
    }

    function verifyPayment(
        IXRPPayment.Proof calldata _proof,
        string calldata _xrplAddress
    )
        internal view
    {
        _verifyProofData(
            _proof.data.sourceId,
            _proof.data.responseBody.status,
            _proof.data.responseBody.blockTimestamp,
            _proof.data.responseBody.sourceAddressHash,
            _proof.data.responseBody.receivingAddressHash,
            _xrplAddress
        );
        // TODO: FDC verification for IXRPPayment.Proof - pending flare-periphery support
        // require(
        //     ContractRegistry.getFdcVerification().verifyXRPPayment(_proof),
        //     IPaymentProofsFacet.InvalidTransactionProof()
        // );
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

    function _verifyProofData(
        bytes32 _sourceId,
        uint8 _status,
        uint64 _blockTimestamp,
        bytes32 _sourceAddressHash,
        bytes32 _receivingAddressHash,
        string memory _xrplAddress
    )
        private view
    {
        State storage state = getState();
        require(
            _sourceId == state.sourceId,
            IPaymentProofsFacet.InvalidSourceId()
        );
        require(
            _status == 0,
            IPaymentProofsFacet.InvalidTransactionStatus()
        );
        require(
            block.timestamp <= state.paymentProofValidityDurationSeconds + _blockTimestamp,
            IPaymentProofsFacet.PaymentProofExpired()
        );
        require(
            _sourceAddressHash == keccak256(bytes(_xrplAddress)),
            IPaymentProofsFacet.MismatchingSourceAndXrplAddr()
        );
        XrplProviderWallets.State storage xrplProviderWalletsState = XrplProviderWallets.getState();
        require(
            xrplProviderWalletsState.xrplProviderWalletHashes[_receivingAddressHash] != 0,
            IPaymentProofsFacet.InvalidReceivingAddressHash()
        );
    }
}
