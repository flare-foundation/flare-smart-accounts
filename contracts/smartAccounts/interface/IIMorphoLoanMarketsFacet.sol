// SPDX-License-Identifier: MIT
pragma solidity >=0.8.4 <0.9;

import {IMorphoLoanMarketsFacet} from "../../userInterfaces/facets/IMorphoLoanMarketsFacet.sol";

/**
 * @title IIMorphoLoanMarketsFacet
 * @notice Internal interface for the MorphoLoanMarketsFacet contract.
 */
interface IIMorphoLoanMarketsFacet is IMorphoLoanMarketsFacet {
    /**
     * @notice Registers the market a subaccount type is bound to, write-once: a different
     * market means a new subaccount type. Requires the compose transport (the collateral token
     * must be the OFT's token), both tokens and the oracle carrying code, and an existing
     * market on the Morpho contract. The first
     * registration permanently pins the collateral token for every later transport.
     * Registration does not configure the type's fee terms: borrowing reverts until
     * {setLoanFeeTerms} activates them, so a registered-but-unpriced type cannot take on
     * debt.
     * @param _subaccountType The subaccount type to bind.
     * @param _market The Morpho contract and market.
     * Can only be called by the owner (timelocked).
     */
    function registerLoanMarket(
        uint256 _subaccountType,
        IMorphoLoanMarketsFacet.Market calldata _market
    )
        external;

    /**
     * @notice Sets a subaccount type's fee terms as one unit: both rates (each at most
     * `MAX_FEE_RATE`) and the non-zero recipient. The first call activates borrowing for the
     * type; later calls change the rates or rotate the collector, always restating all three
     * fields. Accounts adopt new rates prospectively at their next checkpoint — never
     * retroactively, since each snapshots the terms it accrues under — so follow the
     * settle-before-and-after runbook for live accounts. Explicit zero rates are a deliberate
     * "fee off".
     * @param _subaccountType The subaccount type (its market must be registered).
     * @param _terms The fee floor, the fee spread and the collector.
     * Can only be called by the owner (timelocked).
     */
    function setLoanFeeTerms(
        uint256 _subaccountType,
        IMorphoLoanMarketsFacet.FeeTerms calldata _terms
    )
        external;

    /**
     * @notice Disables new debt increases for a subaccount type — the routine way to sunset
     * a pool. Repayment, collateral deposits, withdrawals, and recovery are never affected.
     * @param _subaccountType The subaccount type.
     * Can only be called by the owner (timelocked).
     */
    function disableLoanBorrowing(
        uint256 _subaccountType
    )
        external;

    /**
     * @notice Re-enables new debt increases for a subaccount type.
     * @param _subaccountType The subaccount type.
     * Can only be called by the owner (timelocked).
     */
    function enableLoanBorrowing(
        uint256 _subaccountType
    )
        external;
}
