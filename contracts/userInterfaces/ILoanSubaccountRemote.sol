// SPDX-License-Identifier: MIT
pragma solidity >=0.8.4 <0.9;

import {IComposeReceiverAccountBase} from "./IComposeReceiverAccountBase.sol";
import {ISubaccount} from "./ISubaccount.sol";

/// @dev Borrow action: `actionData` is `abi.encode(bytes32 operationId, uint64 deadline,
/// uint8 destinationKind, bytes32 destination, uint256 borrowAmount)`. The market is not a
/// payload field: the account operates on exactly one market — the one its subaccount type
/// is bound to (write-once) — so the subaccount address itself commits to the pool.
/// The operation id must be non-zero and globally unique per subaccount across all action
/// types; clients retrying an expired intent must reuse its id only for the same intent
/// with a fresh deadline (a convention, not contract-enforced). The authenticated bridged
/// amount (the codec's `amountLD`, never the idle balance) is supplied as collateral, and
/// `borrowAmount` (non-zero) of the loan token is borrowed and sent to `destination`. A zero
/// bridged amount borrows against the existing position. A debt increase: pause-gated and
/// subject to the per-type borrow switch. A pure collateral deposit is its own action
/// (`ACTION_DEPOSIT_COLLATERAL`).
uint8 constant ACTION_BORROW = 1;

/// @dev Withdraw action: `actionData` is `abi.encode(bytes32 operationId, uint64 deadline,
/// uint256 withdrawAmount)`. Withdraws collateral from the account's one position to the
/// account itself; the idle FXRP leaves only along the fixed rails, and which rail runs
/// first is permissionless (redeposit or bridge-back - the accepted ordering race, see
/// `depositIdleFxrp`). Position health is enforced by Morpho.
uint8 constant ACTION_WITHDRAW = 2;

/// @dev Deposit-collateral action: `actionData` is `abi.encode(bytes32 operationId,
/// uint64 deadline)`. Supplies exactly the authenticated bridged amount (the codec's
/// `amountLD`, which must be non-zero) as collateral on the account's one market; no debt
/// changes hands. While the controller is paused it executes only when the position carries
/// live debt (the defensive case - protecting an endangered position); a debt-free deposit is
/// new exposure and waits out the pause.
uint8 constant ACTION_DEPOSIT_COLLATERAL = 3;

/// @dev Sweep-deposit action: the compose the permissionless Flare `sweepToLoan` attaches.
/// `actionData` is empty - nobody signed this, so it can express no choice: exactly the
/// authenticated bridged amount (the codec's `amountLD`, non-zero) is supplied as collateral
/// on the account's one market, no debt changes hands, and there is no operation id to
/// consume: replay safety is the endpoint's - EndpointV2 executes a compose at most once per
/// `(from, to, guid, index)` and a failed one stays retriable - and the action is additive,
/// each packet supplying only its own credited amount. Same pause rule as the signed deposit:
/// while paused only when the position carries live debt.
/// If it fails, the credit sits idle for `depositIdleFxrp`, the fallback rail.
uint8 constant ACTION_DEPOSIT_SWEEP = 4;

/// @dev The destination is an EVM address (cleanly zero-padded into the `bytes32`), paid by a
/// plain ERC-20 transfer — typically an exchange deposit address, or the user's own
/// loan-chain Personal Account (the parent, a functional compose-driven account). It may not
/// be zero or the subaccount itself (the proceeds could only repay the new debt).
uint8 constant DESTINATION_KIND_EVM = 1;

/// @dev Reserved: an XRPL address reached over Wormhole. Not implemented yet (Wormhole specs
/// pending); payloads using it revert.
uint8 constant DESTINATION_KIND_XRPL_WORMHOLE = 2;

/**
 * @title ILoanSubaccountRemote
 * @notice User interface for the loan-chain-side subaccount: the implementation registered
 * for a loan subaccount type on the loan-chain diamond (Ethereum, at launch), living at the
 * same CREATE2 address
 * as its Flare counterpart. The account operates on exactly one Morpho market for its whole
 * life — the market its type is bound to — so the address itself commits to the pool. It has
 * no parent-driven methods — the parent Personal Account has no local key or
 * controller-driven action on this chain; instructions exist only on Flare — so every
 * authorized action arrives as an authenticated LayerZero compose payload sent by this same
 * account on Flare, and everything else is permissionless movement along fixed rails: into
 * the account's own position, home over the bridge, or to the parent Personal Account (the
 * user's own compose-driven account on this chain). It has no native rail.
 */
interface ILoanSubaccountRemote is IComposeReceiverAccountBase, ISubaccount {

    /**
     * @notice Emitted when a loan subaccount is initialized.
     * @param controllerAddress The controller address.
     * @param parentPersonalAccount The parent Personal Account address (the same address on
     * every chain; codeless here until its compose-driven mirror is created).
     * @param subaccountType The subaccount type.
     */
    event LoanSubaccountInitialized(
        address indexed controllerAddress,
        address indexed parentPersonalAccount,
        uint256 indexed subaccountType
    );

    /**
     * @notice Emitted when a borrow action executes.
     * @param parentPersonalAccount The parent Personal Account address.
     * @param operationId The user-chosen operation id, now consumed.
     * @param collateralSupplied FXRP supplied as collateral (the authenticated bridged amount;
     * zero for a borrow against the existing position).
     * @param borrowAmount Loan-token amount borrowed and disbursed (non-zero).
     * @param destinationKind The destination kind (see the `DESTINATION_KIND_*` constants).
     * @param destination The disbursement destination.
     * @param guid The LayerZero message id the action arrived with.
     */
    event LoanOpened(
        address indexed parentPersonalAccount,
        bytes32 operationId,
        uint256 collateralSupplied,
        uint256 borrowAmount,
        uint8 destinationKind,
        bytes32 destination,
        bytes32 guid
    );

    /**
     * @notice Emitted when a deposit-collateral action executes.
     * @param parentPersonalAccount The parent Personal Account address.
     * @param operationId The user-chosen operation id, now consumed.
     * @param amount FXRP supplied as collateral (the authenticated bridged amount).
     * @param guid The LayerZero message id the action arrived with.
     */
    event CollateralDeposited(
        address indexed parentPersonalAccount,
        bytes32 operationId,
        uint256 amount,
        bytes32 guid
    );

    /**
     * @notice Emitted when a sweep-deposit action executes: FXRP swept forward from Flare was
     * supplied as collateral on arrival.
     * @param parentPersonalAccount The parent Personal Account address.
     * @param amount FXRP supplied as collateral (the authenticated bridged amount).
     * @param guid The LayerZero message id the action arrived with.
     */
    event SweptFxrpDeposited(
        address indexed parentPersonalAccount,
        uint256 amount,
        bytes32 guid
    );

    /**
     * @notice Emitted when a withdraw action executes.
     * @param parentPersonalAccount The parent Personal Account address.
     * @param operationId The user-chosen operation id, now consumed.
     * @param amount Collateral withdrawn to this account.
     * @param guid The LayerZero message id the action arrived with.
     */
    event CollateralWithdrawn(
        address indexed parentPersonalAccount,
        bytes32 operationId,
        uint256 amount,
        bytes32 guid
    );

    /**
     * @notice Emitted when idle loan tokens are repaid into the account's position.
     * @param parentPersonalAccount The parent Personal Account address.
     * @param assets The assets repaid (clamped to the live debt).
     */
    event LoanRepaid(
        address indexed parentPersonalAccount,
        uint256 assets
    );

    /**
     * @notice Emitted when idle FXRP is deposited as collateral into the account's position.
     * @param parentPersonalAccount The parent Personal Account address.
     * @param amount The amount deposited.
     */
    event IdleFxrpDeposited(
        address indexed parentPersonalAccount,
        uint256 amount
    );

    /**
     * @notice Emitted when idle FXRP is bridged back to this account's address on the origin
     * chain.
     * @param parentPersonalAccount The parent Personal Account address.
     * @param amount The amount bridged.
     * @param originEid The origin chain's LayerZero endpoint id.
     * @param guid The LayerZero message id of the bridge-back send.
     */
    event FXrpSweptToOrigin(
        address indexed parentPersonalAccount,
        uint256 amount,
        uint32 originEid,
        bytes32 guid
    );

    /**
     * @notice Emitted when a token balance is recovered to the parent Personal Account (the
     * user's own loan-chain account, the fixed recovery destination).
     * @param parentPersonalAccount The parent Personal Account address paid.
     * @param token The recovered token.
     * @param amount The recovered amount.
     */
    event TokenRecovered(
        address indexed parentPersonalAccount,
        address indexed token,
        uint256 amount
    );

    /**
     * @notice Emitted when an authenticated action completes without executing. The bridged
     * FXRP that arrived with the message stays on the account, recoverable along the fixed
     * rails.
     * @param parentPersonalAccount The parent Personal Account address.
     * @param operationId The payload's operation id. A duplicate was already consumed; an
     * expired skip leaves it unconsumed (the intent can retry under it).
     * @param reason The skip reason (see the `SKIP_REASON_*` constants).
     * @param guid The LayerZero message id the action arrived with.
     */
    event LoanActionSkipped(
        address indexed parentPersonalAccount,
        bytes32 operationId,
        uint8 reason,
        bytes32 guid
    );

    /**
     * @notice Reverts if the parent Personal Account address is invalid.
     */
    error InvalidParentPersonalAccount();

    /**
     * @notice Reverts on a debt increase while new borrowing is disabled for this account's
     * subaccount type — the routine way a pool is sunset. Deliberately a revert, not a skip:
     * the condition is temporary-by-policy and a permissionless delivery must not consume
     * the packet.
     */
    error BorrowingDisabled();

    /**
     * @notice Reverts if there are no idle loan tokens to repay, or the position has no debt.
     */
    error NothingToRepay();

    /**
     * @notice Reverts if there is no idle FXRP to deposit.
     */
    error NothingToDeposit();

    /**
     * @notice Reverts if there is nothing to recover.
     */
    error NothingToRecover();

    /**
     * @notice Reverts if there is no FXRP to sweep back to the origin chain.
     */
    error NothingToSweep();

    /**
     * @notice Reverts if the OFT's live peer for the origin chain no longer matches the pinned
     * one; the sweep fails closed instead of bridging toward an unknown remote OApp.
     */
    error WrongOriginPeer();

    /**
     * @notice Reverts if the sent value does not cover the LayerZero messaging fee.
     * @param required The required fee.
     */
    error InsufficientFundsForSweep(
        uint256 required
    );

    /**
     * @notice Reverts if the caller's excess native refund could not be returned.
     */
    error RefundFailed();

    /**
     * @notice Reverts if recovery is attempted on the market's collateral token; it moves only
     * on its own rails (`depositIdleFxrp`, `sweepToOrigin`).
     * @param token The offending token.
     */
    error ProtectedToken(
        address token
    );

    /**
     * @notice Reverts if a loan-token recovery is attempted while the position carries debt:
     * the balance is repayment material, not surplus.
     */
    error OutstandingDebt();

    /**
     * @notice Reverts on a borrow with an unsupported destination kind (the Wormhole-to-XRPL
     * kind is reserved but not implemented).
     * @param destinationKind The unsupported destination kind.
     */
    error UnsupportedDestinationKind(
        uint8 destinationKind
    );

    /**
     * @notice Reverts on a borrow disbursement destination that is not a clean zero-padded
     * EVM address, or is zero or this account.
     */
    error InvalidDestination();

    /**
     * @notice Reverts on an action carrying no amount: a borrow with a zero borrow amount, a
     * deposit (signed or swept) with no bridged amount, or a withdraw of zero.
     */
    error ZeroAmount();

    /**
     * @notice Reverts if the account's FXRP balance does not cover the authenticated bridged
     * amount — the credited tokens were moved (e.g. swept back to the origin chain) before the
     * composed action executed.
     * @param required The authenticated bridged amount.
     * @param available The account's FXRP balance.
     */
    error InsufficientComposeBalance(
        uint256 required,
        uint256 available
    );

    /**
     * @notice Repays the account's debt with its idle loan-token balance, clamped to the
     * live debt.
     * @dev Permissionless - repayment only reduces debt on the account's own position.
     * Stays available while paused (it moves the position toward safety). Interest accrues
     * first; a balance covering the full debt closes by exact borrow shares (no over-repay
     * revert), a smaller one repays by assets. Surplus stays on the account for
     * {recoverToken}.
     * @return _assets The assets repaid.
     */
    function repay()
        external
        returns (uint256 _assets);

    /**
     * @notice Deposits the whole idle FXRP balance as collateral into the account's position.
     * @dev Permissionless with a fixed destination (the account's own position): the retry
     * rail for FXRP that arrived without a successful composed action. Defending an indebted
     * position survives a pause, like repayment; the debt-free case is new exposure and
     * reverts while paused. The direction race versus {sweepToOrigin} is accepted but
     * asymmetric: redepositing costs only gas, while re-completing a withdrawal costs a new
     * signed operation and bridge fee; an executor can narrow (not close) the race by
     * bundling compose delivery with the sweep.
     * @return _amount The amount deposited.
     */
    function depositIdleFxrp()
        external
        returns (uint256 _amount);

    /**
     * @notice Bridges all idle FXRP back to this account's own address on the origin chain
     * (Flare), where it is redeemed on arrival toward the user's XRPL address.
     * @dev Permissionless with a fixed destination. The attached compose is the Flare twin's
     * redeem-home action, carrying only a deadline (this block time plus the protocol TTL):
     * nobody signed it, so it can express no choice; on arrival it redeems at most this amount,
     * and past the deadline it skips.
     * `_extraOptions` must carry the Flare-side `lzReceive` and `lzCompose` gas (type-3) and
     * may carry compose value, which becomes the redemption's executor fee on Flare (zero
     * allowed). `msg.value` must cover the LayerZero fee; exactly the quote is spent, only this
     * call's excess is refunded, and the account's own native never subsidizes a caller.
     * Pause-gated (every exit rides the OFT); the live peer is re-checked against the pinned one
     * on every call.
     * @param _extraOptions Caller-supplied LayerZero execution options (type-3).
     * @return _amount Amount of FXRP bridged.
     */
    function sweepToOrigin(
        bytes calldata _extraOptions
    )
        external payable
        returns (uint256 _amount);

    /**
     * @notice Recovers a token balance to the parent Personal Account — the user's own
     * compose-driven account on this chain, from which a signed user operation moves it anywhere.
     * @dev Permissionless with a fixed destination. The market's collateral token is rejected
     * (it moves only on its own rails); the market's loan token is recoverable only while the
     * position carries no debt (read live from Morpho — until then the balance is repayment
     * material); any other token moves freely. Not pause-gated: subaccount to its own parent
     * is inward consolidation, and the parent's signed user operations are what the pause stops.
     * @param _token The token to recover.
     * @return _amount The recovered amount.
     */
    function recoverToken(
        address _token
    )
        external
        returns (uint256 _amount);

    /// @inheritdoc ISubaccount
    function controllerAddress()
        external view
        override(IComposeReceiverAccountBase, ISubaccount)
        returns (address);
}
