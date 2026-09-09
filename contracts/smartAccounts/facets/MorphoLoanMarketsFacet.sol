// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IIMorphoLoanMarketsFacet} from "../interface/IIMorphoLoanMarketsFacet.sol";
import {IMorphoLoanMarketsFacet} from "../../userInterfaces/facets/IMorphoLoanMarketsFacet.sol";
import {MorphoLoanMarkets} from "../library/MorphoLoanMarkets.sol";
import {FacetBase} from "./FacetBase.sol";

/**
 * @title MorphoLoanMarketsFacet
 * @notice Facet holding the loan configuration of the remote loan subaccounts: the write-once
 * Morpho market per subaccount type, the per-type borrow switch, and the type's Flare fee
 * terms. Cut only on the loan-chain diamond (Ethereum, at launch), never on the Flare side.
 */
contract MorphoLoanMarketsFacet is IIMorphoLoanMarketsFacet, FacetBase {

    /// @inheritdoc IIMorphoLoanMarketsFacet
    function registerLoanMarket(
        uint256 _subaccountType,
        IMorphoLoanMarketsFacet.Market calldata _market
    )
        external
        onlyOwnerWithTimelock
    {
        MorphoLoanMarkets.registerLoanMarket(_subaccountType, _market);
    }

    /// @inheritdoc IIMorphoLoanMarketsFacet
    function setLoanFeeTerms(
        uint256 _subaccountType,
        IMorphoLoanMarketsFacet.FeeTerms calldata _terms
    )
        external
        onlyOwnerWithTimelock
    {
        MorphoLoanMarkets.setLoanFeeTerms(_subaccountType, _terms);
    }

    /// @inheritdoc IIMorphoLoanMarketsFacet
    function disableLoanBorrowing(
        uint256 _subaccountType
    )
        external
        onlyOwnerWithTimelock
    {
        MorphoLoanMarkets.disableLoanBorrowing(_subaccountType);
    }

    /// @inheritdoc IIMorphoLoanMarketsFacet
    function enableLoanBorrowing(
        uint256 _subaccountType
    )
        external
        onlyOwnerWithTimelock
    {
        MorphoLoanMarkets.enableLoanBorrowing(_subaccountType);
    }

    /// @inheritdoc IMorphoLoanMarketsFacet
    function getLoanMarket(
        uint256 _subaccountType
    )
        external view
        returns (IMorphoLoanMarketsFacet.Market memory)
    {
        return MorphoLoanMarkets.getLoanMarket(_subaccountType);
    }

    /// @inheritdoc IMorphoLoanMarketsFacet
    function isLoanBorrowingDisabled(
        uint256 _subaccountType
    )
        external view
        returns (bool)
    {
        return MorphoLoanMarkets.isLoanBorrowingDisabled(_subaccountType);
    }

    /// @inheritdoc IMorphoLoanMarketsFacet
    function getLoanFeeTerms(
        uint256 _subaccountType
    )
        external view
        returns (IMorphoLoanMarketsFacet.FeeTerms memory)
    {
        return MorphoLoanMarkets.getLoanFeeTerms(_subaccountType);
    }
}
