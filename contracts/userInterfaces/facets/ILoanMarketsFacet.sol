// SPDX-License-Identifier: MIT
pragma solidity >=0.8.4 <0.9;

import {IMorpho} from "../../smartAccounts/interface/IMorpho.sol";

/// @dev The maximum fee floor and fee spread: annual WAD rates (`1e18` = 100% per year), each
/// capped at 100%. The cap bounds the accrual arithmetic for every rate an account can ever
/// snapshot - a bad stored rate could not be repaired by changing the global terms, since an
/// account always prices its elapsed period at the terms it snapshotted.
uint64 constant MAX_FEE_RATE = 1e18;

/**
 * @title ILoanMarketsFacet
 * @notice Governance-set configuration of the remote loan subaccounts: one **write-once Morpho
 * market per subaccount type** — a position's market can never change under it, so exits
 * need no registry; a new pool is a new subaccount type — a per-type borrow switch, the
 * routine way to sunset a pool, and the type's Flare fee terms, configured by timelock after
 * registration: rates first, the recipient last — the recipient is the **activation marker**,
 * and borrowing reverts while it is zero, so a registered-but-unpriced type cannot take on
 * debt. Registration requires the compose transport (the market's collateral token must be
 * the transport OFT's token) and permanently pins that token for every later transport. Cut
 * only on the loan-chain diamond (Ethereum, at launch).
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

    /// @dev A subaccount type's Flare fee terms: the user's effective rate is
    /// `max(feeFloor, market interest rate + feeSpread)`, measured checkpoint-to-checkpoint
    /// by the subaccounts. Configured by timelock after registration - rates first, recipient
    /// last - and mutable the same way (accounts snapshot the terms they accrue under, so a
    /// change is never retroactive). Explicit zero rates are a deliberate "fee off".
    struct FeeTerms {
        /// @notice The minimum effective annual rate (WAD, at most {MAX_FEE_RATE}).
        uint64 feeFloor;
        /// @notice The annual spread over the market's rate (WAD, at most {MAX_FEE_RATE}).
        uint64 feeSpread;
        /// @notice The collector the fee is paid to. Zero exactly while the type's terms are
        /// unconfigured - the activation marker: borrowing reverts until it is set, and the
        /// setter never accepts zero, so it can never return to zero. Rotating it changes
        /// where the fee goes, not what anyone owes.
        address feeRecipient;
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
     * @notice Emitted on every timelocked fee-rate change, the initial configuration
     * included.
     * @param subaccountType The subaccount type.
     * @param feeFloor The minimum effective annual rate (WAD).
     * @param feeSpread The annual spread over the market's rate (WAD).
     */
    event LoanFeeRatesSet(
        uint256 indexed subaccountType,
        uint64 feeFloor,
        uint64 feeSpread
    );

    /**
     * @notice Emitted on the recipient set that activates a type's terms and on every later
     * timelocked rotation.
     * @param subaccountType The subaccount type.
     * @param feeRecipient The collector the fee is paid to.
     */
    event LoanFeeRecipientSet(
        uint256 indexed subaccountType,
        address feeRecipient
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
     * @notice Reverts on a fee floor or fee spread above {MAX_FEE_RATE}.
     */
    error InvalidFeeTerms();

    /**
     * @notice Reverts on a zero fee recipient: the terms must always name a collector, even
     * with both rates deliberately zero.
     */
    error InvalidFeeRecipient();

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

    /**
     * @notice Returns a subaccount type's Flare fee terms.
     * @param _subaccountType The subaccount type.
     * @return The fee terms; a zero `feeRecipient` means the type's terms are not yet
     * configured, and borrowing reverts until they are.
     */
    function getLoanFeeTerms(
        uint256 _subaccountType
    )
        external view
        returns (FeeTerms memory);
}
