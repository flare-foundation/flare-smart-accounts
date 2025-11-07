// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LibDiamond} from "../../diamond/libraries/LibDiamond.sol";
import {IIPaymentProofsFacet} from "../interface/IIPaymentProofsFacet.sol";
import {IPaymentProofsFacet} from "../../userInterfaces/facets/IPaymentProofsFacet.sol";
import {PaymentProofs} from "../library/PaymentProofs.sol";

/**
 * @title PaymentProofsFacet
 * @notice Facet for handling payment proofs.
 */
contract PaymentProofsFacet is IIPaymentProofsFacet {

    /// @inheritdoc IIPaymentProofsFacet
    function setPaymentProofValidityDuration(
        uint256 _paymentProofValidityDurationSeconds
    )
        external
    {
        LibDiamond.enforceIsContractOwner();
        PaymentProofs.setPaymentProofValidityDuration(_paymentProofValidityDurationSeconds);
    }

    /// @inheritdoc IPaymentProofsFacet
    function getPaymentProofValidityDurationSeconds()
        external view
        returns (uint256)
    {
        PaymentProofs.State storage state = PaymentProofs.getState();
        return state.paymentProofValidityDurationSeconds;
    }
}
