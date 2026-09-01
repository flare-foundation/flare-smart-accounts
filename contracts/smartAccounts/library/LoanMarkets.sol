// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IOFT} from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import {ILoanMarketsFacet, MAX_FEE_RATE} from "../../userInterfaces/facets/ILoanMarketsFacet.sol";
import {IComposeTransportFacet} from "../../userInterfaces/facets/IComposeTransportFacet.sol";
import {SUBACCOUNT_TYPE_NONE, ISubaccountsFacet} from "../../userInterfaces/facets/ISubaccountsFacet.sol";
import {IMorpho} from "../interface/IMorpho.sol";
import {ComposeTransport} from "./ComposeTransport.sol";

library LoanMarkets {

    /// @custom:storage-location erc7201:smartAccounts.LoanMarkets.State
    struct State {
        /// @dev The market each type is bound to, write-once: positions live in it, so the
        /// binding must never change under them.
        mapping(uint256 subaccountType => ILoanMarketsFacet.Market) markets;
        /// @dev Types with new debt increases disabled - the routine way to sunset a pool.
        mapping(uint256 subaccountType => bool) borrowingDisabled;
        /// @dev Each type's Flare fee terms - configured by timelock after registration
        /// (rates first, the recipient last as the activation marker); kept out of the
        /// write-once `markets` mapping because the terms may change while the binding
        /// never does.
        mapping(uint256 subaccountType => ILoanMarketsFacet.FeeTerms) feeTerms;
    }

    bytes32 internal constant STATE_POSITION = keccak256(
        abi.encode(uint256(keccak256("smartAccounts.LoanMarkets.State")) - 1)) & ~bytes32(uint256(0xff)
    );

    function registerLoanMarket(
        uint256 _subaccountType,
        ILoanMarketsFacet.Market calldata _market
    )
        internal
    {
        State storage state = getState();
        require(_subaccountType != SUBACCOUNT_TYPE_NONE, ISubaccountsFacet.InvalidSubaccountType());
        // write-once: a position's market can never change under it, so exits never need a
        // registry - a different market is a different subaccount type
        require(
            state.markets[_subaccountType].morpho == address(0),
            ILoanMarketsFacet.MarketAlreadyRegistered(_subaccountType)
        );
        // the compose transport pins the bridged token's identity (the OFT's own token), which
        // the market's collateral token must match - so the transport must be configured first
        address oft = ComposeTransport.getComposeTransport().oft;
        require(oft != address(0), IComposeTransportFacet.ComposeTransportNotConfigured());
        require(_market.morpho.code.length > 0, ILoanMarketsFacet.InvalidMorpho());
        IMorpho.MarketParams memory marketParams = _market.marketParams;
        require(
            marketParams.loanToken != address(0) &&
            marketParams.collateralToken != address(0) &&
            marketParams.loanToken != marketParams.collateralToken &&
            marketParams.lltv != 0,
            ILoanMarketsFacet.InvalidMarketParams()
        );
        // both tokens must be contracts: the binding is permanent, and a Morpho market can
        // exist for a token address that carries no code
        require(
            marketParams.loanToken.code.length > 0 &&
            marketParams.collateralToken.code.length > 0,
            ILoanMarketsFacet.InvalidMarketParams()
        );
        require(
            IOFT(oft).token() == marketParams.collateralToken,
            ILoanMarketsFacet.InvalidMarketParams()
        );
        // the market must actually exist on the Morpho contract, or every credited compose
        // action against it would revert
        bytes32 marketId = keccak256(abi.encode(marketParams));
        (, , , , uint128 lastUpdate, ) = IMorpho(_market.morpho).market(marketId);
        require(lastUpdate != 0, ILoanMarketsFacet.InvalidMarketParams());

        // the first registration pins the collateral token: every later transport must wrap
        // it (checked in ComposeTransport.setComposeTransport), so later markets - validated
        // against the live OFT above - transitively match it too
        ComposeTransport.pinToken(marketParams.collateralToken);
        state.markets[_subaccountType] = _market;
        emit ILoanMarketsFacet.LoanMarketRegistered(_subaccountType, _market.morpho, marketId);
        // deliberately no fee terms here: the type stays unpriced - and borrowing stays
        // blocked - until setLoanFeeRecipient activates it (rates first, recipient last)
    }

    function setLoanFeeRates(
        uint256 _subaccountType,
        uint64 _feeFloor,
        uint64 _feeSpread
    )
        internal
    {
        _requireRegistered(_subaccountType);
        // the cap bounds the accrual arithmetic for every rate an account can ever snapshot
        require(
            _feeFloor <= MAX_FEE_RATE && _feeSpread <= MAX_FEE_RATE,
            ILoanMarketsFacet.InvalidFeeTerms()
        );
        ILoanMarketsFacet.FeeTerms storage terms = getState().feeTerms[_subaccountType];
        terms.feeFloor = _feeFloor;
        terms.feeSpread = _feeSpread;
        emit ILoanMarketsFacet.LoanFeeRatesSet(_subaccountType, _feeFloor, _feeSpread);
    }

    function setLoanFeeRecipient(
        uint256 _subaccountType,
        address _feeRecipient
    )
        internal
    {
        _requireRegistered(_subaccountType);
        // never zero: the first set (from zero) is the terms' activation - it opens borrowing
        // for the type - and the marker can never return to unconfigured afterwards. Rates
        // first by two-stage queueing (see IILoanMarketsFacet): queue this only after the
        // rate call has executed
        require(_feeRecipient != address(0), ILoanMarketsFacet.InvalidFeeRecipient());
        getState().feeTerms[_subaccountType].feeRecipient = _feeRecipient;
        emit ILoanMarketsFacet.LoanFeeRecipientSet(_subaccountType, _feeRecipient);
    }

    function disableLoanBorrowing(
        uint256 _subaccountType
    )
        internal
    {
        _setBorrowingDisabled(_subaccountType, true);
        emit ILoanMarketsFacet.LoanBorrowingDisabled(_subaccountType);
    }

    function enableLoanBorrowing(
        uint256 _subaccountType
    )
        internal
    {
        _setBorrowingDisabled(_subaccountType, false);
        emit ILoanMarketsFacet.LoanBorrowingEnabled(_subaccountType);
    }

    function getLoanMarket(
        uint256 _subaccountType
    )
        internal view
        returns (ILoanMarketsFacet.Market memory)
    {
        return getState().markets[_subaccountType];
    }

    function isLoanBorrowingDisabled(
        uint256 _subaccountType
    )
        internal view
        returns (bool)
    {
        return getState().borrowingDisabled[_subaccountType];
    }

    function getLoanFeeTerms(
        uint256 _subaccountType
    )
        internal view
        returns (ILoanMarketsFacet.FeeTerms memory)
    {
        return getState().feeTerms[_subaccountType];
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

    function _setBorrowingDisabled(
        uint256 _subaccountType,
        bool _disabled
    )
        private
    {
        _requireRegistered(_subaccountType);
        getState().borrowingDisabled[_subaccountType] = _disabled;
    }

    function _requireRegistered(
        uint256 _subaccountType
    )
        private view
    {
        require(
            getState().markets[_subaccountType].morpho != address(0),
            ILoanMarketsFacet.MarketNotRegistered(_subaccountType)
        );
    }
}
