// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IILoanMarketsFacet} from "../interface/IILoanMarketsFacet.sol";
import {ILoanMarketsFacet} from "../../userInterfaces/facets/ILoanMarketsFacet.sol";
import {LoanMarkets} from "../library/LoanMarkets.sol";
import {FacetBase} from "./FacetBase.sol";

/**
 * @title LoanMarketsFacet
 * @notice Facet holding the loan configuration of the remote loan subaccounts: the write-once
 * Morpho market per subaccount type and the per-type borrow switch. Cut only on the
 * loan-chain diamond (Ethereum, at launch), never on the Flare side.
 */
contract LoanMarketsFacet is IILoanMarketsFacet, FacetBase {

    /// @inheritdoc IILoanMarketsFacet
    function registerLoanMarket(
        uint256 _subaccountType,
        ILoanMarketsFacet.Market calldata _market
    )
        external
        onlyOwnerWithTimelock
    {
        LoanMarkets.registerLoanMarket(_subaccountType, _market);
    }

    /// @inheritdoc IILoanMarketsFacet
    function disableLoanBorrowing(
        uint256 _subaccountType
    )
        external
        onlyOwnerWithTimelock
    {
        LoanMarkets.disableLoanBorrowing(_subaccountType);
    }

    /// @inheritdoc IILoanMarketsFacet
    function enableLoanBorrowing(
        uint256 _subaccountType
    )
        external
        onlyOwnerWithTimelock
    {
        LoanMarkets.enableLoanBorrowing(_subaccountType);
    }

    /// @inheritdoc ILoanMarketsFacet
    function getLoanMarket(
        uint256 _subaccountType
    )
        external view
        returns (ILoanMarketsFacet.Market memory)
    {
        return LoanMarkets.getLoanMarket(_subaccountType);
    }

    /// @inheritdoc ILoanMarketsFacet
    function isLoanBorrowingDisabled(
        uint256 _subaccountType
    )
        external view
        returns (bool)
    {
        return LoanMarkets.isLoanBorrowingDisabled(_subaccountType);
    }
}
