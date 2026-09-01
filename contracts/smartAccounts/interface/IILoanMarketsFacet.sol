// SPDX-License-Identifier: MIT
pragma solidity >=0.8.4 <0.9;

import {ILoanMarketsFacet} from "../../userInterfaces/facets/ILoanMarketsFacet.sol";

/**
 * @title IILoanMarketsFacet
 * @notice Internal interface for the LoanMarketsFacet contract.
 */
interface IILoanMarketsFacet is ILoanMarketsFacet {
    /**
     * @notice Registers the market a subaccount type is bound to, write-once: a different
     * market means a new subaccount type. Requires the compose transport (the collateral token
     * must be the OFT's token) and an existing market on the Morpho contract. The first
     * registration permanently pins the collateral token for every later transport.
     * Registration does not configure the type's fee terms: borrowing reverts until
     * {setLoanFeeRecipient} activates them, so a registered-but-unpriced type cannot take on
     * debt.
     * @param _subaccountType The subaccount type to bind.
     * @param _market The Morpho contract and market.
     * Can only be called by the owner (timelocked).
     */
    function registerLoanMarket(
        uint256 _subaccountType,
        ILoanMarketsFacet.Market calldata _market
    )
        external;

    /**
     * @notice Sets a subaccount type's fee rates. Accounts adopt them prospectively at their
     * next checkpoint — never retroactively, since each snapshots the terms it accrues under —
     * so follow the settle-before-and-after runbook for live accounts.
     * @dev For the initial activation, EXECUTE this call before queueing
     * {setLoanFeeRecipient}.
     * @param _subaccountType The subaccount type (its market must be registered).
     * @param _feeFloor The minimum effective annual rate (WAD, at most `MAX_FEE_RATE`).
     * @param _feeSpread The annual spread over the market's rate (WAD, at most
     * `MAX_FEE_RATE`).
     * Can only be called by the owner (timelocked).
     */
    function setLoanFeeRates(
        uint256 _subaccountType,
        uint64 _feeFloor,
        uint64 _feeSpread
    )
        external;

    /**
     * @notice Sets a subaccount type's non-zero fee recipient. The first call (from zero)
     * activates borrowing for the type, so it comes last, after the rates; a later call only
     * rotates the collector, changing where the fee goes, not what anyone owes.
     * @dev On a live diamond, queue this only after the initial rate call has EXECUTED:
     * matured timelocked calls execute permissionlessly and in any order, while an unqueued
     * call cannot be executed early.
     * @param _subaccountType The subaccount type (its market must be registered).
     * @param _feeRecipient The collector the fee is paid to (non-zero).
     * Can only be called by the owner (timelocked).
     */
    function setLoanFeeRecipient(
        uint256 _subaccountType,
        address _feeRecipient
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
