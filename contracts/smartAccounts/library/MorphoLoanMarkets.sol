// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IOFT} from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import {IMorphoLoanMarketsFacet, MAX_FEE_RATE} from "../../userInterfaces/facets/IMorphoLoanMarketsFacet.sol";
import {IComposeTransportFacet} from "../../userInterfaces/facets/IComposeTransportFacet.sol";
import {SUBACCOUNT_TYPE_NONE, ISubaccountsFacet} from "../../userInterfaces/facets/ISubaccountsFacet.sol";
import {IMorpho} from "../interface/IMorpho.sol";
import {MorphoMath} from "./MorphoMath.sol";
import {ComposeTransport} from "./ComposeTransport.sol";

library MorphoLoanMarkets {

    /// @custom:storage-location erc7201:smartAccounts.MorphoLoanMarkets.State
    struct State {
        /// @dev Write-once market binding for each subaccount type: positions live in it, so
        /// the binding must never change under them.
        mapping(uint256 subaccountType => IMorphoLoanMarketsFacet.Market) markets;
        /// @dev Per-type switch for new debt increases - the routine way to sunset a pool.
        mapping(uint256 subaccountType => bool) borrowingDisabled;
        /// @dev Mutable per-type fee terms; a non-zero recipient marks activation. Kept out of
        /// the write-once `markets` mapping because the terms may change while the binding
        /// never does.
        mapping(uint256 subaccountType => IMorphoLoanMarketsFacet.FeeTerms) feeTerms;
    }

    bytes32 internal constant STATE_POSITION = keccak256(
        abi.encode(uint256(keccak256("smartAccounts.MorphoLoanMarkets.State")) - 1)) & ~bytes32(uint256(0xff)
    );

    function registerLoanMarket(
        uint256 _subaccountType,
        IMorphoLoanMarketsFacet.Market calldata _market
    )
        internal
    {
        State storage state = getState();
        require(_subaccountType != SUBACCOUNT_TYPE_NONE, ISubaccountsFacet.InvalidSubaccountType());
        // write-once: a position's market can never change under it, so a different market
        // is a different subaccount type
        require(
            state.markets[_subaccountType].morpho == address(0),
            IMorphoLoanMarketsFacet.MarketAlreadyRegistered(_subaccountType)
        );
        // the collateral must match the configured transport token, so the transport is
        // configured first
        address oft = ComposeTransport.getComposeTransport().oft;
        require(oft != address(0), IComposeTransportFacet.ComposeTransportNotConfigured());
        require(_market.morpho.code.length > 0, IMorphoLoanMarketsFacet.InvalidMorpho());
        IMorpho.MarketParams memory marketParams = _market.marketParams;
        require(
            marketParams.loanToken != address(0) &&
            marketParams.collateralToken != address(0) &&
            marketParams.loanToken != marketParams.collateralToken &&
            marketParams.lltv != 0,
            IMorphoLoanMarketsFacet.InvalidMarketParams()
        );
        // both tokens and the oracle must be contracts: the binding is permanent, a Morpho
        // market can exist for addresses that carry no code (createMarket checks none of
        // them), and a codeless oracle would escape the exit gate's try/catch - the call
        // succeeds with empty return data and decoding it reverts outside the catch, a raw
        // revert instead of the gate's refusal. Code presence at registration only; the
        // oracle's later behavior is the gate's business
        require(
            marketParams.loanToken.code.length > 0 &&
            marketParams.collateralToken.code.length > 0 &&
            marketParams.oracle.code.length > 0,
            IMorphoLoanMarketsFacet.InvalidMarketParams()
        );
        require(
            IOFT(oft).token() == marketParams.collateralToken,
            IMorphoLoanMarketsFacet.InvalidMarketParams()
        );
        // the market must actually exist on the Morpho contract, or every credited compose
        // action against it would revert
        bytes32 marketId = MorphoMath.marketId(marketParams);
        (, , , , uint128 lastUpdate, ) = IMorpho(_market.morpho).market(marketId);
        require(lastUpdate != 0, IMorphoLoanMarketsFacet.InvalidMarketParams());

        // the first registration pins the collateral token for every later transport and,
        // transitively, every later market
        ComposeTransport.pinToken(marketParams.collateralToken);
        state.markets[_subaccountType] = _market;
        emit IMorphoLoanMarketsFacet.LoanMarketRegistered(_subaccountType, _market.morpho, marketId);
        // fee terms are configured separately: borrowing stays blocked until
        // setLoanFeeTerms activates the type
    }

    function setLoanFeeTerms(
        uint256 _subaccountType,
        IMorphoLoanMarketsFacet.FeeTerms calldata _terms
    )
        internal
    {
        _requireRegistered(_subaccountType);
        // the cap bounds the accrual arithmetic for every rate an account can ever snapshot
        require(
            _terms.feeFloor <= MAX_FEE_RATE && _terms.feeSpread <= MAX_FEE_RATE,
            IMorphoLoanMarketsFacet.InvalidFeeTerms()
        );
        // never zero: the first set is the terms' activation - it opens borrowing for the
        // type - and the marker can never return to unconfigured afterwards
        require(_terms.feeRecipient != address(0), IMorphoLoanMarketsFacet.InvalidFeeRecipient());
        getState().feeTerms[_subaccountType] = _terms;
        emit IMorphoLoanMarketsFacet.LoanFeeTermsSet(
            _subaccountType, _terms.feeFloor, _terms.feeSpread, _terms.feeRecipient
        );
    }

    function disableLoanBorrowing(
        uint256 _subaccountType
    )
        internal
    {
        _setBorrowingDisabled(_subaccountType, true);
        emit IMorphoLoanMarketsFacet.LoanBorrowingDisabled(_subaccountType);
    }

    function enableLoanBorrowing(
        uint256 _subaccountType
    )
        internal
    {
        _setBorrowingDisabled(_subaccountType, false);
        emit IMorphoLoanMarketsFacet.LoanBorrowingEnabled(_subaccountType);
    }

    function getLoanMarket(
        uint256 _subaccountType
    )
        internal view
        returns (IMorphoLoanMarketsFacet.Market memory)
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
        returns (IMorphoLoanMarketsFacet.FeeTerms memory)
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
            IMorphoLoanMarketsFacet.MarketNotRegistered(_subaccountType)
        );
    }
}
