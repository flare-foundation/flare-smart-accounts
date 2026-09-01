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
 * life — the market its type is bound to — so the address itself commits to the pool. Every
 * authorized action arrives as an authenticated LayerZero compose payload sent by this same
 * account on Flare, with one exception: the parent Personal Account (the mirror, itself
 * compose-driven) holds one narrow direct authority — the signed exit {sweepToOrigin}, which
 * can only send idle FXRP home to this account's own fixed Flare address. Everything else is
 * permissionless movement along fixed rails: into the account's own position, or loan-token
 * surplus to the parent. It has no native rail.
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
     * @notice Emitted by every fee checkpoint, degenerate ones included (zero principal or a
     * zero elapsed period, which skip the fee math but still re-baseline).
     * @param parentPersonalAccount The parent Personal Account address.
     * @param principal The canonical Morpho debt the account is re-baselined to (base
     * units). A borrow or repayment in the same call re-syncs it right after
     * ({LoanFeePrincipalSynced}); {getLoanFeeState} is the authoritative state.
     * @param feeDeltaX18 The fee added for the elapsed period (base units at WAD precision);
     * zero on degenerate checkpoints.
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
     * @notice Emitted when accrued fee is paid to the fee recipient at the end of {repay}.
     * @param feeRecipient The collector paid.
     * @param amount The amount paid (whole base units; the fee debt shrinks by exactly this).
     */
    event LoanFeeCollected(
        address indexed feeRecipient,
        uint256 amount
    );

    /**
     * @notice Emitted when loan tokens covering still-outstanding fee stay reserved on the
     * account instead of leaving as surplus: the fee leg held (paused) or the recipient
     * refused the transfer; a later {repay} retries from the reservation. A snapshot, not a
     * delta: repeated calls can emit the same amount, and a partial collection that empties
     * the balance reserves zero (the claim then lives only in the fee debt).
     * @param feeRecipient The collector the reservation is owed to.
     * @param amount The reserved amount (whole base units).
     */
    event LoanFeeReserved(
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
     * @notice Reverts on a debt increase while the subaccount type's fee terms are not yet
     * configured (the recipient is the activation marker, set last): a
     * registered-but-unpriced type cannot take on debt. A revert, not a skip - the condition
     * is temporary and must not consume the packet.
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
     * @notice Reverts if {sweepToOrigin} is called by anything other than the parent
     * Personal Account (the mirror): the remote exit is a user-signed action by policy -
     * every permissionless arrival has exactly one meaning (FXRP deposits, RLUSD repays),
     * and the exit direction requires the user's signature, carried by the mirror's
     * cross-chain user operation.
     */
    error OnlyParent();

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
     * @notice Repays the account's debt with its idle loan-token balance, clamped to the
     * live debt, then settles the accrued Flare fee from what remains.
     * @dev Permissionless - repayment only reduces debt on the account's own position.
     * Stays available while paused (it moves the position toward safety). The fee checkpoint
     * runs first and the canonical debt is re-read after (see {checkpointFee}). With live
     * debt, interest accrues; a balance covering the full debt closes by exact borrow shares
     * (no over-repay revert), a smaller one repays by assets. Then, in order: the fee leg
     * pays the collectible fee from the remainder - best-effort, held while paused, never
     * rolling back the repayment ({LoanFeeCollected} / {LoanFeeReserved}; the fee debt
     * shrinks only by the successfully requested transfer - conventional ERC-20 semantics
     * are a market-registration policy) - tokens covering still-outstanding fee stay
     * reserved here, and only the rest is surplus, pushed to the parent on a debt-free
     * position ({LoanSurplusRecovered}; best-effort, {LoanSurplusRetained} on refusal).
     * Closing through the rails therefore costs the live debt plus the collectible fee, from
     * one balance in one call.
     * @return _assets The assets repaid.
     */
    function repay()
        external
        returns (uint256 _assets);

    /**
     * @notice Runs a bare fee checkpoint: prices the elapsed period at the snapshotted
     * terms, adds the result to the fee debt, and re-baselines (principal to the canonical
     * live debt, clock to now, snapshot to the current terms).
     * @dev Permissionless and pause-exempt - notably the liquidated account's relief: a
     * liquidation is invisible to the account, so the floor keeps accruing on the stale
     * principal until someone checkpoints (prospectively only). Under unchanged terms and
     * non-decreasing debt, splitting a period typically increases the total fee and never
     * decreases it by more than one X18 unit (under 1e-18 of a base unit) per checkpoint,
     * so checkpointing cannot be used against the protocol; a checkpoint after an external
     * repayment or liquidation legitimately shrinks the FUTURE base - that is the
     * prospective policy, not a loss. The advertised promise is the per-checkpoint
     * measurement. Shares-first:
     * zero principal makes no Morpho call, zero live shares settle at zero debt without
     * touching the IRM.
     */
    function checkpointFee()
        external;

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
     * @dev Restricted to the parent Personal Account (the mirror), so it is reached only
     * through a user-signed cross-chain user operation: by policy, the remote exit requires
     * the user's signature, while permissionless arrivals have exactly one meaning each. The
     * mirror's batch supplies `msg.value` from its own native balance (fund it with a native
     * drop in the same instruction if needed); temporary unavailability while the Flare side
     * is paused or its route unconfigured is accepted - custody is unaffected and the call
     * works again after. The attached compose is the Flare twin's redeem-home action,
     * carrying only a deadline (this block time plus the protocol TTL): on arrival it redeems
     * at most this amount, and past the deadline it skips.
     * `_extraOptions` must carry the Flare-side `lzReceive` and `lzCompose` gas (type-3) and
     * may carry compose value, which becomes the redemption's executor fee on Flare (zero
     * allowed). `msg.value` must cover the LayerZero fee; exactly the quote is spent, only this
     * call's excess is refunded to the mirror, and the account's own native never subsidizes
     * the caller. Pause-gated on this chain (every exit rides the OFT); the live peer is
     * re-checked against the pinned one on every call.
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

    /// @inheritdoc ISubaccount
    function controllerAddress()
        external view
        override(IComposeReceiverAccountBase, ISubaccount)
        returns (address);
}
