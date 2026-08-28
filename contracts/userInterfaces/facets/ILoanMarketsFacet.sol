// SPDX-License-Identifier: MIT
pragma solidity >=0.8.4 <0.9;

import {IMorpho} from "../../smartAccounts/interface/IMorpho.sol";

/**
 * @title ILoanMarketsFacet
 * @notice Governance-set configuration of the remote loan subaccounts: one **write-once Morpho
 * market per subaccount type** — a position's market can never change under it, so exits
 * need no registry; a new pool is a new subaccount type — and a per-type borrow switch, the
 * routine way to sunset a pool. Registration requires the compose transport (the market's
 * collateral token must be the transport OFT's token) and permanently pins that token for
 * every later transport. Cut only on the loan-chain diamond (Ethereum, at launch).
 */
interface ILoanMarketsFacet {

    /// @dev The pool a subaccount type is bound to: a Morpho contract and a market on it.
    /// Write-once per type - positions live in it, so the binding must never change.
    struct Market {
        /// @notice The Morpho contract.
        address morpho;
        /// @notice The Morpho market on it. `collateralToken` must be the transport OFT's
        /// token (enforced); the loan token is RLUSD by governance policy per registration,
        /// not an on-chain check.
        IMorpho.MarketParams marketParams;
    }

    /**
     * @notice Emitted when a subaccount type's market is registered (write-once).
     * @param subaccountType The subaccount type the market is bound to.
     * @param morpho The Morpho contract.
     * @param marketId The Morpho market id: `keccak256(abi.encode(marketParams))`.
     */
    event LoanMarketRegistered(
        uint256 indexed subaccountType,
        address morpho,
        bytes32 marketId
    );

    /**
     * @notice Emitted when new debt increases are disabled for a subaccount type.
     * @param subaccountType The subaccount type.
     */
    event LoanBorrowingDisabled(
        uint256 indexed subaccountType
    );

    /**
     * @notice Emitted when new debt increases are re-enabled for a subaccount type.
     * @param subaccountType The subaccount type.
     */
    event LoanBorrowingEnabled(
        uint256 indexed subaccountType
    );

    /**
     * @notice Reverts if the Morpho address is invalid.
     */
    error InvalidMorpho();

    /**
     * @notice Reverts if the Morpho market parameters are invalid: a zero or codeless token,
     * identical tokens, a zero LLTV, a collateral token other than the transport OFT's token,
     * or a market that does not exist on the Morpho contract.
     */
    error InvalidMarketParams();

    /**
     * @notice Reverts on registering a market for a type that already has one: the binding
     * is write-once - a different market means a new subaccount type.
     * @param subaccountType The already-bound subaccount type.
     */
    error MarketAlreadyRegistered(
        uint256 subaccountType
    );

    /**
     * @notice Reverts when an operation needs a type's market and none is registered.
     * @param subaccountType The subaccount type without a market.
     */
    error MarketNotRegistered(
        uint256 subaccountType
    );

    /**
     * @notice Returns the market a subaccount type is bound to.
     * @param _subaccountType The subaccount type.
     * @return The market; a zero `morpho` means no market is registered for the type.
     */
    function getLoanMarket(
        uint256 _subaccountType
    )
        external view
        returns (Market memory);

    /**
     * @notice Returns whether new debt increases are disabled for a subaccount type.
     * Repayment, collateral deposits, withdrawals, and recovery are never affected.
     * @param _subaccountType The subaccount type.
     * @return Whether borrowing is disabled.
     */
    function isLoanBorrowingDisabled(
        uint256 _subaccountType
    )
        external view
        returns (bool);
}
