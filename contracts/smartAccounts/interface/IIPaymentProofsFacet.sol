// SPDX-License-Identifier: MIT
pragma solidity >=0.7.6 <0.9;

import {IPaymentProofsFacet} from "../../userInterfaces/facets/IPaymentProofsFacet.sol";

/**
 * @title IIPaymentProofsFacet
 * @notice Internal interface for the PaymentProofsFacet contract.
 */
interface IIPaymentProofsFacet is IPaymentProofsFacet {
    /**
     * @notice Sets the payment proof validity duration.
     * @param _paymentProofValidityDurationSeconds Duration in seconds.
     * Can only be called by the owner.
     */
    function setPaymentProofValidityDuration(
        uint256 _paymentProofValidityDurationSeconds
    )
        external;
}