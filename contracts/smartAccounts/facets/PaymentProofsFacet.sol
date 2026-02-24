// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IIPaymentProofsFacet} from "../interface/IIPaymentProofsFacet.sol";
import {IPaymentProofsFacet} from "../../userInterfaces/facets/IPaymentProofsFacet.sol";
import {PaymentProofs} from "../library/PaymentProofs.sol";
import {FacetBase} from "./FacetBase.sol";

/**
 * @title PaymentProofsFacet
 * @notice Facet for handling payment proofs.
 */
contract PaymentProofsFacet is IIPaymentProofsFacet, FacetBase {

    /// @inheritdoc IIPaymentProofsFacet
    function setPaymentProofValidityDuration(
        uint256 _paymentProofValidityDurationSeconds
    )
        external
        onlyOwnerWithTimelock
    {
        PaymentProofs.setPaymentProofValidityDuration(_paymentProofValidityDurationSeconds);
    }

    /// @inheritdoc IPaymentProofsFacet
    function getSourceId()
        external view
        returns (bytes32)
    {
        PaymentProofs.State storage state = PaymentProofs.getState();
        return state.sourceId;
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
