// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IILoanMarketsFacet} from "../interface/IILoanMarketsFacet.sol";
import {ILoanMarketsFacet} from "../../userInterfaces/facets/ILoanMarketsFacet.sol";
import {LoanMarkets} from "../library/LoanMarkets.sol";
import {FacetBase} from "./FacetBase.sol";

/**
 * @title LoanMarketsFacet
 * @notice Facet holding the loan configuration of the remote loan subaccounts: the write-once
 * Morpho market per subaccount type, the per-type borrow switch, and the type's Flare fee
 * terms. Cut only on the loan-chain diamond (Ethereum, at launch), never on the Flare side.
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
    function setLoanFeeRates(
        uint256 _subaccountType,
        uint64 _feeFloor,
        uint64 _feeSpread
    )
        external
        onlyOwnerWithTimelock
    {
        LoanMarkets.setLoanFeeRates(_subaccountType, _feeFloor, _feeSpread);
    }

    /// @inheritdoc IILoanMarketsFacet
    function setLoanFeeRecipient(
        uint256 _subaccountType,
        address _feeRecipient
    )
        external
        onlyOwnerWithTimelock
    {
        LoanMarkets.setLoanFeeRecipient(_subaccountType, _feeRecipient);
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

    /// @inheritdoc ILoanMarketsFacet
    function getLoanFeeTerms(
        uint256 _subaccountType
    )
        external view
        returns (ILoanMarketsFacet.FeeTerms memory)
    {
        return LoanMarkets.getLoanFeeTerms(_subaccountType);
    }
}
