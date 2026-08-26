// SPDX-License-Identifier: MIT
pragma solidity >=0.8.4 <0.9;

import {ILayerZeroComposer} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroComposer.sol";
import {ISubaccount} from "./ISubaccount.sol";

/// @dev Compose payload schema version 1. The payload is
/// `abi.encode(uint8 version, uint8 action, bytes actionData)`.
uint8 constant PAYLOAD_VERSION_1 = 1;

/// @dev Borrow action: `actionData` is `abi.encode(bytes32 operationId, uint64 deadline,
/// uint8 destinationKind, bytes32 destination, uint256 borrowAmount)`. The market is not a
/// payload field: the account operates on exactly one market — the one its subaccount type
/// is bound to (write-once) — so the subaccount address itself commits to the pool.
/// The operation id must be non-zero and globally unique per subaccount across all action
/// types; clients retrying an expired intent must reuse its id only for the same intent
/// with a fresh deadline (a convention, not contract-enforced). The authenticated bridged
/// amount (the codec's `amountLD`, never the idle balance) is supplied as collateral; if
/// `borrowAmount` is non-zero, that amount of the loan token is borrowed and sent to
/// `destination`. A zero bridged amount borrows against the existing position; a pure
/// top-up (`borrowAmount == 0`) ignores the destination fields, and while the controller is
/// paused executes only when the position carries live debt (the defensive case).
uint8 constant ACTION_BORROW = 1;

/// @dev Withdraw action: `actionData` is `abi.encode(bytes32 operationId, uint64 deadline,
/// uint256 withdrawAmount)`. Withdraws collateral from the account's one position to the
/// account itself; the idle FXRP leaves only along the fixed rails, and which rail runs
/// first is permissionless (redeposit or bridge-back - the accepted ordering race, see
/// `depositIdleFxrp`). Position health is enforced by Morpho.
uint8 constant ACTION_WITHDRAW = 2;

/// @dev Set-recovery action: `actionData` is `abi.encode(bytes32 operationId, uint64 deadline,
/// uint64 epoch, bytes32 destination)`. Stores the recovery destination for the permissionless
/// recovery rails; the destination follows the same rules as `DESTINATION_KIND_EVM` (clean
/// zero-padded, non-zero, neither this account nor the parent Personal Account). The epoch
/// must be strictly greater than the stored one: LayerZero deliveries are unordered, and an
/// older authenticated update must not overwrite a newer destination (a stale epoch skips).
uint8 constant ACTION_SET_RECOVERY = 3;

/// @dev The destination is an EVM address (cleanly zero-padded into the `bytes32`), paid by a
/// plain ERC-20 transfer — typically an exchange deposit address. It may not be zero, the
/// subaccount itself, or the parent Personal Account (the two addresses in scope when a
/// payload is composed, never valid disbursement targets).
uint8 constant DESTINATION_KIND_EVM = 1;

/// @dev Reserved: an XRPL address reached over Wormhole. Not implemented yet (Wormhole specs
/// pending); payloads using it revert.
uint8 constant DESTINATION_KIND_XRPL_WORMHOLE = 2;

/// @dev Skip reason: the operation id was already consumed (a retried instruction delivered
/// twice must not turn one intended action into two).
uint8 constant SKIP_REASON_DUPLICATE = 1;

/// @dev Skip reason: the deadline passed before delivery; the user's intent is stale. The
/// operation id is not consumed, so the same intent can be retried with a fresh deadline.
uint8 constant SKIP_REASON_EXPIRED = 2;

/// @dev Skip reason: a set-recovery action carried an epoch not greater than the stored one -
/// an older update delivered late must not overwrite a newer destination.
uint8 constant SKIP_REASON_STALE_EPOCH = 3;

/**
 * @title ILoanChainSubaccount
 * @notice User interface for the loan-chain-side subaccount: the implementation registered
 * for a loan subaccount type on the loan-chain diamond (Ethereum, at launch), living at the
 * same CREATE2 address
 * as its Flare counterpart. The account operates on exactly one Morpho market for its whole
 * life — the market its type is bound to — so the address itself commits to the pool. It has
 * no parent-driven methods — the parent Personal Account exists only on Flare — so every
 * authorized action arrives as an authenticated LayerZero compose payload sent by this same
 * account on Flare, and everything else is permissionless movement along fixed rails.
 */
interface ILoanChainSubaccount is ILayerZeroComposer, ISubaccount {

    /**
     * @notice Emitted when a loan subaccount is initialized.
     * @param controllerAddress The controller address.
     * @param parentPersonalAccount The parent Personal Account address (a Flare-side address;
     * it has no code on this chain).
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
     * @param collateralSupplied FXRP supplied as collateral (the authenticated bridged amount).
     * @param borrowAmount Loan-token amount borrowed and disbursed; zero for a pure top-up.
     * @param destinationKind The destination kind (see the `DESTINATION_KIND_*` constants);
     * ignored for a pure top-up.
     * @param destination The disbursement destination; ignored for a pure top-up.
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
     * @notice Emitted when the recovery destination is set by an authenticated action.
     * @param parentPersonalAccount The parent Personal Account address.
     * @param destination The new recovery destination.
     * @param epoch The new recovery epoch.
     * @param guid The LayerZero message id the action arrived with.
     */
    event RecoveryDestinationSet(
        address indexed parentPersonalAccount,
        address destination,
        uint64 epoch,
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
     * @notice Emitted when a token balance is recovered to the recovery destination.
     * @param parentPersonalAccount The parent Personal Account address.
     * @param token The recovered token.
     * @param amount The recovered amount.
     * @param destination The recovery destination paid.
     */
    event TokenRecovered(
        address indexed parentPersonalAccount,
        address indexed token,
        uint256 amount,
        address destination
    );

    /**
     * @notice Emitted when the native balance is recovered to the recovery destination.
     * @param parentPersonalAccount The parent Personal Account address.
     * @param amount The recovered amount.
     * @param destination The recovery destination paid.
     */
    event NativeRecovered(
        address indexed parentPersonalAccount,
        uint256 amount,
        address destination
    );

    /**
     * @notice Emitted when an authenticated action completes without executing. The bridged
     * FXRP that arrived with the message stays on the account, recoverable along the fixed
     * rails.
     * @param parentPersonalAccount The parent Personal Account address.
     * @param operationId The payload's operation id. A duplicate was already consumed; an
     * expired skip leaves it unconsumed (the intent can retry under it); a stale-epoch skip
     * consumes it, since staleness cannot be cured without changing an economic field.
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
     * @notice Reverts if the contract is already initialized.
     */
    error AlreadyInitialized();

    /**
     * @notice Reverts if the controller address is invalid.
     */
    error InvalidControllerAddress();

    /**
     * @notice Reverts if the parent Personal Account address is invalid.
     */
    error InvalidParentPersonalAccount();

    /**
     * @notice Reverts if `lzCompose` is called by anything other than the LayerZero endpoint.
     */
    error OnlyEndpoint();

    /**
     * @notice Reverts if native value is attached to `lzCompose`. The loan flow never sends
     * compose value, and rejecting it keeps a mistaken delivery retriable without value.
     */
    error NonZeroComposeValue();

    /**
     * @notice Reverts if the compose sender (`_from`) is not the configured FXRP OFT.
     * @param from The compose sender.
     */
    error WrongComposeSender(
        address from
    );

    /**
     * @notice Reverts if the composed message did not originate on the configured origin chain.
     * @param srcEid The source endpoint id of the message.
     */
    error WrongSourceEid(
        uint32 srcEid
    );

    /**
     * @notice Reverts if the source-chain sender of the composed transfer is not this account
     * itself (its own address on the origin chain).
     * @param composeFrom The source-chain sender.
     */
    error WrongComposeFrom(
        bytes32 composeFrom
    );

    /**
     * @notice Reverts if the delivered GUID does not equal the one recomputed from the pinned
     * origin peer: the compose wrapper alone does not commit to the source OApp, so this
     * check is what binds the message to the pinned peer.
     * @param guid The delivered GUID.
     */
    error WrongGuid(
        bytes32 guid
    );

    /**
     * @notice Reverts on a payload whose operation id is zero.
     */
    error InvalidOperationId();

    /**
     * @notice Reverts on a debt increase while new borrowing is disabled for this account's
     * subaccount type — the routine way a pool is sunset. Deliberately a revert, not a skip:
     * the condition is temporary-by-policy and a permissionless delivery must not consume
     * the packet.
     */
    error BorrowingDisabled();

    /**
     * @notice Reverts on the implementation contract itself, which is never initialized: it
     * holds no parent and must not accept native.
     */
    error NotInitialized();

    /**
     * @notice Reverts if there are no idle loan tokens to repay, or the position has no debt.
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
     * @notice Reverts if there is nothing to recover.
     */
    error NothingToRecover();

    /**
     * @notice Reverts if a recovery rail is used before an authenticated set-recovery action
     * stored a destination.
     */
    error RecoveryDestinationNotSet();

    /**
     * @notice Reverts if generic recovery is attempted on the market's loan or collateral
     * token; those move only on their own rails.
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
     * @notice Reverts if the native balance could not be sent to the recovery destination.
     */
    error NativeRecoveryFailed();

    /**
     * @notice Reverts on a payload with an unsupported schema version.
     * @param version The unsupported version.
     */
    error UnsupportedPayloadVersion(
        uint8 version
    );

    /**
     * @notice Reverts on a payload with an unsupported action.
     * @param action The unsupported action.
     */
    error UnsupportedAction(
        uint8 action
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
     * @notice Reverts on a borrow disbursement or recovery destination that is not a clean
     * zero-padded EVM address, or is zero, this account, or the parent Personal Account.
     */
    error InvalidDestination();

    /**
     * @notice Reverts on an action carrying no amount: a borrow that would neither supply
     * collateral nor borrow, or a withdraw of zero.
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
     * {recoverLoanToken}.
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
     * (Flare), where the backward cleanup continues (`sweepRedeem` toward the user's XRPL
     * address).
     * @dev Permissionless with a fixed destination. `msg.value` must cover the LayerZero
     * fee; exactly the quote is spent, only this call's excess is refunded, and the
     * account's own native never subsidizes a caller. Pause-gated (every exit rides the
     * OFT); the live peer is re-checked against the pinned one on every call.
     * @return _amount Amount of FXRP bridged.
     */
    function sweepToOrigin()
        external payable
        returns (uint256 _amount);

    /**
     * @notice Recovers a token balance to the stored recovery destination.
     * @dev Permissionless with a fixed destination (the authenticated recovery destination;
     * reverts until one is set). The market's loan and collateral tokens are protected and
     * rejected: they move only on their own rails. Reverts while paused.
     * @param _token The token to recover.
     * @return _amount The recovered amount.
     */
    function recoverToken(
        address _token
    )
        external
        returns (uint256 _amount);

    /**
     * @notice Recovers the loan-token surplus to the stored recovery destination, once the
     * position carries no debt.
     * @dev Permissionless with a fixed destination. While any debt exists the balance is
     * repayment material and this reverts; the debt is read live from Morpho. Reverts while
     * paused.
     * @return _amount The recovered amount.
     */
    function recoverLoanToken()
        external
        returns (uint256 _amount);

    /**
     * @notice Recovers the native balance to the stored recovery destination.
     * @dev Permissionless with a fixed destination (native arrives as bridge refunds).
     * Reverts while paused.
     * @return _amount The recovered amount.
     */
    function recoverNative()
        external
        returns (uint256 _amount);

    /**
     * @notice Returns whether an operation id has been consumed. An id is consumed on
     * execution and on a stale-epoch skip; an expired skip leaves it unconsumed, and a
     * duplicate skip means it was already consumed.
     * @param _operationId The operation id.
     * @return Whether the operation id is consumed.
     */
    function usedOperations(
        bytes32 _operationId
    )
        external view
        returns (bool);

    /**
     * @notice Returns the recovery destination set by an authenticated set-recovery action,
     * or zero when none was ever set.
     * @return The recovery destination.
     */
    function recoveryDestination()
        external view
        returns (address);

    /**
     * @notice Returns the recovery epoch: set-recovery actions must carry a strictly greater
     * one.
     * @return The recovery epoch.
     */
    function recoveryEpoch()
        external view
        returns (uint64);
}
