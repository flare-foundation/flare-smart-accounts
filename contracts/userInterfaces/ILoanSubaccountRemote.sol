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
/// uint256 withdrawAmount, uint256 minComposeValue, bytes returnOptions)`. The atomic withdrawal: withdraws collateral
/// from the account's one position and bridges exactly that amount back to the account's own
/// Flare address in the same execution, with the redeem-home compose - no idle window, so the
/// redeposit ordering race cannot touch a withdrawal. The signed `returnOptions` are the
/// return send's LayerZero options (Flare-side gas and, optionally, the redemption's executor
/// fee as compose value); the return leg's fee is paid from the compose value delivered with
/// this action - the only action that accepts value - and the excess goes to the parent
/// mirror. Compose delivery is permissionless and LayerZero does not authenticate the
/// delivered value, so the signed `minComposeValue` is the delivery floor: any delivery
/// carrying less - execution and terminal skip alike - reverts (`InsufficientDeliveryValue`)
/// and stays retriable, so a zero-value front-run cannot consume the packet and burn the
/// prepaid value. Too little value for the live quote also reverts and stays retriable (fee
/// quotes drift both ways); bad `returnOptions` are frozen in the signed packet - the
/// accepted residual, fixed by a fresh instruction that reuses the same operation id, so the
/// parked packet terminal-skips as a duplicate. The redemption fee optionally bought inside
/// `returnOptions` stays best-effort on the second leg (the Flare redeem-home accepts zero
/// value by design). Position health is enforced by Morpho.
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
     * @notice Emitted when a withdraw action executes; the withdrawn collateral is bridged
     * home in the same execution ({FXrpSweptToOrigin} follows).
     * @param parentPersonalAccount The parent Personal Account address.
     * @param operationId The user-chosen operation id, now consumed.
     * @param amount Collateral withdrawn and bridged home.
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
     * @notice Emitted when FXRP is bridged back to this account's address on the origin
     * chain, to be redeemed on arrival: the sweep rail, or a withdraw action's return leg.
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
     * @notice Emitted when native value is forwarded to the parent Personal Account (the
     * mirror): the excess of a withdraw action's return-leg fee, or the whole value of a
     * terminally skipped withdraw delivery - it must not strand on an account with no
     * native rail.
     * @param parentPersonalAccount The parent Personal Account address paid.
     * @param amount The native value forwarded.
     */
    event NativeSweptToParent(
        address indexed parentPersonalAccount,
        uint256 amount
    );

    /**
     * @notice Emitted when a closed position's loan-token surplus is sent to the parent
     * Personal Account (the user's own account on this chain) at the end of {repay}.
     * @param parentPersonalAccount The parent Personal Account address paid.
     * @param amount The surplus amount.
     */
    event LoanSurplusRecovered(
        address indexed parentPersonalAccount,
        uint256 amount
    );

    /**
     * @notice Emitted when a closed position's loan-token surplus could not be sent to the
     * parent Personal Account (the token refused the transfer - RLUSD can freeze addresses)
     * and stays on the account. The repayment itself stands; a later {repay} retries the push.
     * @param parentPersonalAccount The parent Personal Account address that refused.
     * @param amount The surplus amount retained.
     */
    event LoanSurplusRetained(
        address indexed parentPersonalAccount,
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
     * @notice Reverts if there are no idle loan tokens.
     */
    error NothingToRepay();

    /**
     * @notice Reverts if there is no idle FXRP to deposit.
     */
    error NothingToDeposit();


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
     * @notice Reverts if excess native could not be pushed to its destination: the sweep
     * caller's refund, or the parent mirror on the withdraw action.
     */
    error RefundFailed();

    /**
     * @notice Reverts on a withdraw delivery carrying less compose value than the signed
     * floor: delivery is permissionless and the value unauthenticated, so anything below the
     * floor must not consume the packet - not even as a terminal skip. Retriable.
     * @param required The signed delivery-value floor.
     */
    error InsufficientDeliveryValue(
        uint256 required
    );



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
     * Stays available while paused (it moves the position toward safety). With live debt,
     * interest accrues first; a balance covering the full debt closes by exact borrow shares
     * (no over-repay revert), a smaller one repays by assets and keeps the balance as
     * repayment material. Once the position carries no debt - closed by this call, or already
     * zero (an external liquidation, tokens arriving after the close; accrual is skipped
     * then, so a reverting IRM cannot trap the balance) - the whole remaining loan-token
     * balance is the user's surplus and is pushed to the parent Personal Account in the same
     * call ({LoanSurplusRecovered}). The push is best-effort: if the token refuses the parent
     * (RLUSD can freeze addresses), the repayment stands, the surplus stays here
     * ({LoanSurplusRetained}), and any later call retries - so loan tokens rest on a
     * debt-free account only until a repay's push succeeds.
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

    /// @inheritdoc ISubaccount
    function controllerAddress()
        external view
        override(IComposeReceiverAccountBase, ISubaccount)
        returns (address);
}
