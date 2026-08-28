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
