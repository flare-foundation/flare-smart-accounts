// SPDX-License-Identifier: MIT
pragma solidity >=0.8.4 <0.9;

import {IComposeReceiverAccountBase} from "./IComposeReceiverAccountBase.sol";
import {ISubaccount} from "./ISubaccount.sol";

/// @dev Borrow action: `actionData` is `abi.encode(bytes32 operationId, uint64 deadline,
/// uint8 destinationKind, bytes32 destination, uint256 borrowAmount)`. The market is not a
/// payload field: the account type fixes it (write-once), so the subaccount address itself
/// commits to the pool. The authenticated bridged amount (the codec's `amountLD`, never the
/// idle balance) becomes collateral - zero borrows against the existing position - and
/// `borrowAmount` (non-zero) is borrowed and sent to `destination`. The fee terms are the
/// type's current terms at delivery (the front end warns while a change is pending in the
/// timelock and keeps deadlines short; see the spec). It is a debt increase: pause-gated and
/// subject to the per-type borrow switch, both of which revert retriably. The operation id
/// must be non-zero and globally unique per subaccount across all action types; clients
/// retrying an expired intent must reuse its id only for the same intent with a fresh
/// deadline (a convention, not contract-enforced). A pure collateral deposit is its own action
/// (`ACTION_DEPOSIT_COLLATERAL`).
uint8 constant ACTION_BORROW = 1;

/// @dev Withdraw action: `actionData` is `abi.encode(bytes32 operationId, uint64 deadline,
/// uint256 withdrawAmount, uint256 minComposeValue, bytes returnOptions)`. The atomic
/// withdrawal: withdraws collateral from the account's one position and bridges it back to the
/// account's own Flare address in the same execution, with the redeem-home compose - no idle
/// window, so the redeposit ordering race cannot touch a withdrawal. **The fee is a secured
/// claim**: the withdrawal passes while the collateral remaining after it, valued at the market
/// oracle's price, covers three times the collectible fee, and otherwise reverts retriably
/// (`OutstandingLoanFee`) - the fee is paid in loan tokens through {repay} or {payLoanFee},
/// never taken from the collateral, so no price ever moves funds here. `minComposeValue` is the delivery floor:
/// compose delivery is permissionless and LayerZero does not authenticate the delivered value,
/// so a delivery carrying less - execution and terminal skip alike - reverts
/// (`InsufficientDeliveryValue`), which is what stops a zero-value front-run from consuming
/// the packet and burning the prepaid value. `returnOptions` are the signed return-send
/// options (Flare-side gas and, optionally, the redemption's executor fee as compose value,
/// best-effort on that leg - the Flare redeem-home accepts zero value by design); the return
/// fee is paid from the compose value delivered with this action - the only action that
/// accepts value - and the excess goes to the parent. Every failure reverts and leaves the
/// delivery retriable; what recovers it differs by cause, and this is the one place it is
/// written out. A quote shortfall: retry the SAME packet with more value. Another transient
/// return-send failure: retry the same packet once its cause clears - more value cannot help,
/// since exactly the newly quoted fee is forwarded. An under-secured fee (`OutstandingLoanFee`,
/// which a dead or zero-priced oracle also produces, since it values the security at
/// nothing): pay the fee - send loan tokens to the account and let {repay} collect (with debt
/// outstanding the tokens are split pro rata between debt and fee, so covering both settles
/// it and a smaller top-up pays only its share), or pay the fee alone from the parent through
/// {payLoanFee} - after which the retried
/// delivery passes with nothing collectible, oracle-free. Bad `returnOptions` frozen into the
/// signed packet (the accepted residual - no retry can fix the blob itself): issue a corrected
/// instruction reusing the SAME operation id, whereupon the parked packet later
/// duplicate-skips. Position health is enforced by Morpho.
uint8 constant ACTION_WITHDRAW = 2;

/// @dev Deposit-collateral action: `actionData` is `abi.encode(bytes32 operationId,
/// uint64 deadline)`. Supplies exactly the authenticated bridged amount (the codec's
/// `amountLD`, which must be non-zero) as collateral on the account's one market; no debt
/// changes hands. While the controller is paused it executes only when the position carries
/// live debt (the defensive case - protecting an endangered position); a debt-free deposit is
/// new exposure and waits out the pause.
uint8 constant ACTION_DEPOSIT_COLLATERAL = 3;

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
 * @notice User interface for the loan-chain-side subaccount (Ethereum, at launch), at the same
 * CREATE2 address as its Flare counterpart. Authenticated compose payloads, sent by this same
 * account on Flare, execute the typed actions on the type's write-once Morpho market — so the
 * address itself commits to the pool. Repayment, idle-collateral deposit and the fee
 * checkpoint are permissionless fixed rails; only the parent Personal Account (the remote
 * implementation, itself compose-driven) may sweep idle FXRP home ({sweepToOrigin}) or pay the
 * fee from its own balance ({payLoanFee}). On those
 * rails every destination is fixed on-chain - the account's own position, the parent, the
 * governance-set fee recipient, or this account's own address on Flare - while the one
 * user-chosen destination is a signed borrow's disbursement. It has no native rail.
 */
interface ILoanSubaccountRemote is IComposeReceiverAccountBase, ISubaccount {

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
     * @notice Emitted when a withdraw action executes; the withdrawn collateral is bridged
     * home in the same execution ({FXrpSweptToOrigin} follows).
     * @param parentPersonalAccount The parent Personal Account address.
     * @param operationId The user-chosen operation id, now consumed.
     * @param amount Collateral withdrawn from the position and bridged.
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
     * @notice Emitted when native value is forwarded to the parent Personal Account
     * (the remote implementation): the excess of a withdraw action's return-leg fee, or the whole value of a
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
     * @notice Emitted after each fee checkpoint and re-baseline, degenerate ones included
     * (zero principal or a zero elapsed period skip the fee math but still re-baseline).
     * @param parentPersonalAccount The parent Personal Account address.
     * @param principal The canonical Morpho debt measured at the checkpoint (base units); a
     * borrow or repayment in the same call re-syncs it afterward
     * ({LoanFeePrincipalSynced}), and {getLoanFeeState} is authoritative.
     * @param feeDeltaX18 The fee accrued for the interval (base units at WAD precision); zero
     * on degenerate checkpoints.
     */
    event LoanFeeCheckpointed(
        address indexed parentPersonalAccount,
        uint256 principal,
        uint256 feeDeltaX18
    );

    /**
     * @notice Emitted when a borrow or repayment re-syncs the fee base to the canonical
     * post-action debt (the clock and terms snapshot stay).
     * @param parentPersonalAccount The parent Personal Account address.
     * @param principal The canonical Morpho debt after the action (base units) - the base
     * the next period is priced on.
     */
    event LoanFeePrincipalSynced(
        address indexed parentPersonalAccount,
        uint256 principal
    );

    /**
     * @notice Emitted when accrued fee is paid to the fee recipient in loan tokens: from the
     * account's balance in {repay} (the fee's pro-rata share of a partial payment, or, once
     * the debt is closed, as much of the collectible as the balance covers), or from the
     * parent's balance through {payLoanFee}.
     * @param feeRecipient The collector paid.
     * @param amount The amount paid (whole base units; the fee debt shrinks by exactly this).
     */
    event LoanFeeCollected(
        address indexed feeRecipient,
        uint256 amount
    );

    /**
     * @notice Emitted when a sub-unit fee remainder is forgiven - at an exit gate, or when a
     * {payLoanFee} brings the fee down to it: on a debt-free position it can never be
     * transferred (ERC-20 moves whole base units) and never grows again, so a raw-zero gate
     * would park the exits forever over less than one base unit. Never more than a sub-unit
     * remainder: a whole base unit or more stays owed.
     * @param remainderX18 The forgiven remainder (base units at WAD precision, below 1e18).
     */
    event LoanFeeRemainderForgiven(
        uint256 remainderX18
    );

    /**
     * @notice Emitted with the amount of outstanding fee covered by loan tokens retained on
     * the account instead of leaving as surplus; a later {repay} retries from it. A snapshot,
     * not a delta: repeated calls can emit the same amount, and a collection that empties the
     * balance reserves zero (the claim then lives only in the fee debt).
     * @param feeRecipient The collector the reservation is owed to.
     * @param amount The reserved amount (whole base units).
     */
    event LoanFeeReserved(
        address indexed feeRecipient,
        uint256 amount
    );

    /**
     * @notice Emitted when the initial pro-rata attempt of a partial {repay} failed to pay
     * the fee's share - held while paused, or the token refused the recipient. The share
     * stays in the repayment balance and repays debt; if that closes the debt, the remainder
     * is attempted again and whatever still cannot be paid is reserved on the account
     * ({LoanFeeReserved}). Whatever the call leaves unpaid stays owed; a later {repay} or
     * {payLoanFee} collects it.
     * @param feeRecipient The collector the share was owed to.
     * @param amount The unpaid share (whole base units).
     */
    event LoanFeeDeferred(
        address indexed feeRecipient,
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
     * @notice Reverts on a debt increase while new borrowing is disabled for this account's
     * subaccount type — the routine way a pool is sunset. Deliberately a revert, not a skip:
     * the condition is temporary-by-policy and a permissionless delivery must not consume
     * the packet.
     */
    error BorrowingDisabled();

    /**
     * @notice Reverts a debt increase before the subaccount type's fee recipient activates
     * its terms: a registered-but-unpriced type cannot take on debt. Retriable - the packet
     * is not consumed by this temporary condition.
     */
    error FeeTermsNotConfigured();

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
     * @notice Reverts a {payLoanFee} with nothing collectible: no fee is owed, or only a
     * sub-unit remainder that no transfer can move.
     */
    error NothingCollectible();

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
     * caller's refund, or the parent on the withdraw action.
     */
    error RefundFailed();

    /**
     * @notice Reverts a withdraw delivered below its signed compose-value floor, so that an
     * underfunded permissionless delivery cannot consume the packet - not even as a terminal
     * skip. Retriable.
     * @param required The signed delivery-value floor.
     */
    error InsufficientDeliveryValue(
        uint256 required
    );

    /**
     * @notice Reverts an exit - a withdraw action or {sweepToOrigin} - that would leave the
     * collectible fee under-secured: the collateral remaining after it, at the market oracle's
     * price, would be worth less than three times the fee (a dead or zero-priced oracle values
     * it at nothing). Retriable: pay the fee - loan tokens to the account and {repay}, or the
     * fee alone from the parent through {payLoanFee} - then retry.
     * @param collectible The fee currently payable.
     */
    error OutstandingLoanFee(
        uint256 collectible
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
     * deposit with no bridged amount, or a withdraw of zero.
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
     * @notice Repays the account's debt and the accrued Flare fee with its idle loan-token
     * balance: a payment short of the two is split pro rata between them, a covering one
     * closes the debt, attempts the whole collectible (reserving anything unpaid) and returns
     * the surplus to the parent.
     * @dev Permissionless and pause-exempt for the debt reduction, which only moves the
     * account's own position toward safety. It checkpoints before the repayment and re-syncs
     * the canonical debt after (see {checkpointFee}). With live debt `D` and collectible fee
     * `F`, interest accrues, then a balance `P < D + F` pays `P × F / (D + F)` (rounded down)
     * to the fee recipient first and repays Morpho with the rest - by exact borrow shares when
     * that rest covers the debt (no over-repay revert), otherwise by assets; a balance covering
     * `D + F` closes the debt by exact shares and attempts the whole collectible from the
     * remainder. Every fee payment is best-effort, held while paused,
     * never rolling back the repayment ({LoanFeeCollected}; the fee debt shrinks only by the
     * successfully requested transfer, conventional ERC-20 semantics being a
     * market-registration policy): a share that cannot be paid stays in the balance and
     * repays debt ({LoanFeeDeferred}), and once debt-free the remainder is attempted again,
     * with as much of it as the outstanding fee needs reserved here ({LoanFeeReserved}). Only
     * the unreserved balance is pushed to the parent once debt-free ({LoanSurplusRecovered};
     * best-effort, {LoanSurplusRetained} on refusal). Settling both claims through this rail
     * therefore costs the live debt plus the collectible fee, from one balance in one call; a
     * payment that covers the debt but not the fee leaves a pro-rata sliver of both, unless
     * the debt closes for less: a paid share's round-down can leave exactly the debt (possible
     * within roughly `F / D` base units of `D + F`), and a deferred share leaves the full
     * payment available, which may cover it - Morpho then consumes exactly the debt and the
     * tail handles any remainder, with fee still outstanding. The default route pays the fee
     * alongside the debt; repaying Morpho directly, on this account's behalf, pays the debt
     * alone.
     * @return _assets The assets repaid.
     */
    function repay()
        external
        returns (uint256 _assets);

    /**
     * @notice Runs a bare fee checkpoint: prices the elapsed period at the snapshotted
     * terms, adds the result to the fee debt, and re-baselines (principal to the canonical
     * live debt, clock to now, snapshot to the current terms).
     * @dev Permissionless and pause-exempt - notably the liquidated account's relief: an
     * external repayment or liquidation is invisible to the account, so the floor keeps
     * accruing on the stale principal until someone checkpoints, and only prospectively.
     * Under unchanged terms and non-decreasing debt, splitting a period typically increases
     * the total fee and never decreases it by more than one X18 unit (under 1e-18 of a base
     * unit) per checkpoint, so checkpointing cannot be used against the protocol; the
     * advertised promise is that per-checkpoint measurement. Shares-first: zero principal
     * makes no Morpho call, zero live shares settle at zero debt without touching the IRM.
     */
    function checkpointFee()
        external;

    /**
     * @notice Deposits the whole idle FXRP balance as collateral into the account's position.
     * @dev Permissionless with a fixed destination (the account's own position): the retry
     * rail for FXRP that arrived without a successful composed action. It remains available
     * while paused only to defend a position with live debt; a debt-free deposit is new
     * exposure and is pause-gated.
     * @return _amount The amount deposited.
     */
    function depositIdleFxrp()
        external
        returns (uint256 _amount);

    /**
     * @notice Pays the collectible Flare fee from the parent Personal Account's own loan-token
     * balance - the fee alone, the Morpho debt untouched - so an under-secured exit can be
     * unblocked without closing the loan.
     * @dev Restricted to the parent Personal Account (the remote implementation), so it is
     * reached only through a user-signed cross-chain user operation: the batch approves this
     * account for the amount and calls this method, and `_maxAmount` is the user's signed cap.
     * Checkpoints first, then transfers `min(_maxAmount, collectible)` from the parent
     * straight to the governance-set fee recipient (`transferFrom`; nothing lands here, so this
     * account's loan tokens keep their one meaning, repayment). Pause-gated like {repay}'s fee
     * leg: money leaving the user's accounts toward the collector waits out an incident. An
     * under-approved, underfunded or frozen parent, a frozen recipient, a frozen subaccount
     * (the token checks the spender too), or nothing collectible reverts the whole batch,
     * retriable. The batch should end by resetting the allowance
     * (`approve(0)`): the clamp can leave a remainder, and an allowance to this upgradeable
     * account is spending authority - harmless under this implementation, not something to
     * leave standing. The complement of {repay}, which pays the fee pro rata with the debt and
     * attempts the whole collectible only on a payment covering both, reserving what it cannot
     * pay ({LoanFeeCollected}; debt-free sub-unit dust is forgiven). With
     * live debt and a dead oracle this clears the fee gate, but Morpho's own health check still
     * reads that oracle, so the withdrawal waits for the debt to be closed.
     * @param _maxAmount The most this call may transfer (whole base units; the signed cap).
     * @return _paid The amount transferred to the fee recipient.
     */
    function payLoanFee(
        uint256 _maxAmount
    )
        external
        returns (uint256 _paid);

    /**
     * @notice Bridges all idle FXRP back to this account's own address on the origin chain
     * (Flare), where it is redeemed on arrival toward the user's XRPL address.
     * @dev Restricted to the parent Personal Account (the remote implementation), so it is
     * reached only through a user-signed cross-chain user operation - by policy the exit
     * direction requires the user's signature - and pause-gated on this chain, since every
     * exit rides the OFT. The parent's batch supplies `msg.value` from its own native balance
     * (fund it with a native drop in the same instruction if needed); exactly the quote is
     * spent, only this call's excess is refunded to the parent, and the account's own native
     * never subsidizes the caller. The live peer is re-checked against the pinned one, and
     * the attached compose is the Flare twin's redeem-home action, carrying only a deadline
     * (this block time plus the protocol TTL): on arrival it redeems at most this amount, and
     * past the deadline it skips. Waiting while the Flare side is paused or its route
     * unconfigured is accepted - custody is unaffected. The secured-claim exit gate applies: a
     * live fee principal checkpoints first, an under-secured collectible fee blocks the sweep
     * ({OutstandingLoanFee} - settle through {repay} or {payLoanFee} first), and a fee the position's
     * collateral still covers to the gate's threshold rides along uncollected. With zero
     * principal and nothing collectible the gate avoids Morpho and the oracle entirely and
     * forgives sub-unit dust, never blocking.
     * @param _extraOptions Caller-supplied LayerZero execution options (type-3).
     * @return _amount Amount of FXRP bridged.
     */
    function sweepToOrigin(
        bytes calldata _extraOptions
    )
        external payable
        returns (uint256 _amount);

    /**
     * @notice Returns the account's fee state, as of the last checkpoint or post-action
     * sync (stored values, not a live projection - run {checkpointFee} first for current
     * numbers).
     * @return _principal The canonical Morpho debt at the last checkpoint or sync (base
     * units).
     * @return _feeDebtX18 The accrued, uncollected fee at WAD precision (base units × 1e18);
     * the fractional part below one base unit is carried, never discarded.
     * @return _collectible The fee payable now: `_feeDebtX18 / 1e18`, whole base units.
     * @return _lastCheckpoint The last checkpoint's timestamp.
     * @return _feeFloor The snapshotted floor the next elapsed period is priced at (WAD).
     * @return _feeSpread The snapshotted spread the next elapsed period is priced at (WAD).
     */
    function getLoanFeeState()
        external view
        returns (
            uint256 _principal,
            uint256 _feeDebtX18,
            uint256 _collectible,
            uint64 _lastCheckpoint,
            uint64 _feeFloor,
            uint64 _feeSpread
        );
}
