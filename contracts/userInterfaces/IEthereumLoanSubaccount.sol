// SPDX-License-Identifier: MIT
pragma solidity >=0.8.4 <0.9;

import {ILayerZeroComposer} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroComposer.sol";

/// @dev Compose payload schema version 1. The payload is
/// `abi.encode(uint8 version, uint8 action, bytes actionData)`.
uint8 constant PAYLOAD_VERSION_1 = 1;

/// @dev Borrow action: `actionData` is `abi.encode(bytes32 operationId, uint64 deadline,
/// bytes32 routeId, uint8 destinationKind, bytes32 destination, uint256 borrowAmount)`. For
/// a debt increase (`borrowAmount > 0`) the route id
/// (`keccak256(abi.encode(morpho, marketParams))`) must be the **active** route; a pure
/// collateral top-up (`borrowAmount == 0`) works against any registered route, and while the
/// controller is paused only against the route carrying live debt (the defensive case).
/// The operation id must be non-zero and globally unique per subaccount across all action
/// types; clients retrying an expired intent must reuse its id only for the same intent
/// with a fresh deadline (a convention, not contract-enforced). The authenticated bridged
/// amount (the codec's `amountLD`, never the idle balance) is supplied as collateral; if
/// `borrowAmount` is non-zero, that amount of the loan token is borrowed and sent to
/// `destination`. A zero bridged amount borrows against the existing position; a pure
/// top-up ignores the destination fields.
uint8 constant ACTION_BORROW = 1;

/// @dev Withdraw action: `actionData` is `abi.encode(bytes32 operationId, uint64 deadline,
/// bytes32 routeId, uint256 withdrawAmount)`. The route may be **any registered route** -
/// positions must stay withdrawable however the active configuration changes. Withdraws
/// collateral from the account's own position to the account itself; the idle FXRP leaves
/// only along the fixed rails, and which rail runs first is permissionless (redeposit or
/// bridge-back - the accepted ordering race, see `depositIdleFxrp`). Position health is
/// enforced by Morpho.
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
 * @title IEthereumLoanSubaccount
 * @notice User interface for the Ethereum-side loan subaccount: the implementation registered
 * for the loan subaccount type on the Ethereum-side diamond, living at the same CREATE2 address
 * as its Flare counterpart. It has no parent-driven methods — the parent Personal Account
 * exists only on Flare — so every authorized action arrives as an authenticated LayerZero
 * compose payload sent by this same account on Flare, and everything else is permissionless
 * movement along fixed rails.
 */
interface IEthereumLoanSubaccount is ILayerZeroComposer {

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
     * @param routeId The route the action ran on: the active route when debt was opened,
     * any registered route for a pure collateral top-up.
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
        bytes32 routeId,
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
     * @param routeId The route withdrawn from (any registered route).
     * @param amount Collateral withdrawn to this account.
     * @param guid The LayerZero message id the action arrived with.
     */
    event CollateralWithdrawn(
        address indexed parentPersonalAccount,
        bytes32 operationId,
        bytes32 routeId,
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
     * @notice Emitted when idle loan tokens are repaid into a route's position.
     * @param parentPersonalAccount The parent Personal Account address.
     * @param routeId The route repaid.
     * @param assets The assets repaid (clamped to the live debt).
     */
    event LoanRepaid(
        address indexed parentPersonalAccount,
        bytes32 routeId,
        uint256 assets
    );

    /**
     * @notice Emitted when idle FXRP is deposited as collateral.
     * @param parentPersonalAccount The parent Personal Account address.
     * @param routeId The route deposited into: the live-debt route when one exists,
     * otherwise the active route.
     * @param amount The amount deposited.
     */
    event IdleFxrpDeposited(
        address indexed parentPersonalAccount,
        bytes32 routeId,
        uint256 amount
    );

    /**
     * @notice Emitted when idle FXRP is bridged back to this account's address on the origin
     * chain (Flare).
     * @param parentPersonalAccount The parent Personal Account address.
     * @param amount Amount of FXRP bridged.
     * @param originEid The LayerZero endpoint id it was bridged to.
     * @param guid The LayerZero message id.
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
     * @param destination The recovery destination it went to.
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
     * @param destination The recovery destination it went to.
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
     * @param guid The LayerZero message id.
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
     * @notice Reverts if the Ethereum loan settings have not been configured on the controller.
     */
    error EthereumLoanSettingsNotConfigured();

    /**
     * @notice Reverts if `lzCompose` is called by anything other than the LayerZero endpoint.
     */
    error OnlyEndpoint();

    /**
     * @notice Reverts if native value is attached to `lzCompose`. The loan flow never sends
     * compose value; a rejected delivery is retriable through the endpoint without value.
     */
    error NonZeroComposeValue();

    /**
     * @notice Reverts if the compose sender (`_from`) is not the configured FXRP OFT.
     * @param from The actual compose sender.
     */
    error WrongComposeSender(
        address from
    );

    /**
     * @notice Reverts if the composed message did not originate on the configured origin chain.
     * @param srcEid The actual source endpoint id.
     */
    error WrongSourceEid(
        uint32 srcEid
    );

    /**
     * @notice Reverts if the source-chain sender of the composed transfer is not this account
     * itself. The account has the same address on the origin chain, and only it sends composed
     * FXRP here; any other FXRP holder composing to this address is rejected (the attached
     * tokens simply stay on the account as a donation).
     * @param composeFrom The actual source-chain sender.
     */
    error WrongComposeFrom(
        bytes32 composeFrom
    );

    /**
     * @notice Reverts if the delivered GUID does not equal the one recomputed from the pinned
     * origin peer. The compose wrapper alone does not commit to the source OApp, so without
     * this check a temporarily swapped peer on the OFT could forge `composeFrom`; the GUID is
     * computed by the endpoint from the true packet header and binds the message to the pinned
     * peer.
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
     * @notice Reverts if a borrow names a route other than the active one. Deliberately a
     * revert, not a skip: the active route can change back, and a permissionless delivery
     * during a temporary window must not consume the packet.
     * @param routeId The route id the payload was signed for.
     */
    error RouteNotActive(
        bytes32 routeId
    );

    /**
     * @notice Reverts if a route id was never registered.
     * @param routeId The unknown route id.
     */
    error RouteNotRegistered(
        bytes32 routeId
    );

    /**
     * @notice Reverts on the implementation contract itself, which is never initialized: it
     * must not accept native.
     */
    error NotInitialized();

    /**
     * @notice Reverts if there are no idle loan tokens to repay, or the route has no debt.
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
     * @notice Reverts if generic recovery is attempted on a loan or collateral token of a
     * registered route (those move only on their own rails), or {recoverLoanToken} is called
     * with anything but the pinned loan token.
     * @param token The offending token.
     */
    error ProtectedToken(
        address token
    );

    /**
     * @notice Reverts if a loan-token recovery is attempted while a route carries debt, or a
     * borrow targets one route while another carries debt (one debt route at a time).
     * @param routeId The route with outstanding debt.
     */
    error OutstandingDebt(
        bytes32 routeId
    );

    /**
     * @notice Reverts if the OFT's live peer for the origin chain no longer matches the pinned
     * one.
     */
    error WrongOriginPeer();

    /**
     * @notice Reverts if the sent value does not cover the LayerZero messaging fee.
     * @param messagingFee The required messaging fee.
     */
    error InsufficientFundsForSweep(
        uint256 messagingFee
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
     * @notice Reverts on a borrow with an unsupported destination kind (including the reserved
     * Wormhole kind, until it is implemented).
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
     * @notice Initializes the loan subaccount.
     * @param _controllerAddress MasterAccountController address.
     * @param _parentPersonalAccount Parent Personal Account address.
     * @param _subaccountType The subaccount type.
     */
    function initialize(
        address _controllerAddress,
        address _parentPersonalAccount,
        uint256 _subaccountType
    )
        external;

    /**
     * @notice Repays a route's debt with the account's idle loan-token balance, clamped to
     * the live debt.
     * @dev Permissionless - repayment only reduces debt on the account's own position.
     * Works against **any registered route** and stays available while paused (it moves the
     * position toward safety). Interest accrues first; a balance covering the full debt
     * closes by exact borrow shares (no over-repay revert), a smaller one repays by assets.
     * Surplus stays on the account for {recoverLoanToken}.
     * @param _routeId The registered route to repay.
     * @return _assets The assets repaid.
     */
    function repay(
        bytes32 _routeId
    )
        external
        returns (uint256 _assets);

    /**
     * @notice Deposits the whole idle FXRP balance as collateral: into the route carrying
     * live debt when one exists, otherwise into the active route.
     * @dev Permissionless with a fixed destination (the account's own position): the retry
     * rail for FXRP that arrived without a successful composed action. The live-debt route
     * wins over the active one (a failed top-up credit must not be diverted from the
     * position that may need it) and that defensive case survives a pause; the debt-free
     * case is new exposure and reverts while paused. The direction race versus
     * {sweepToOrigin} is accepted but asymmetric: redepositing costs only gas, while
     * re-completing a withdrawal costs a new signed operation and bridge fee; an executor
     * can narrow (not close) the race by bundling compose delivery with the sweep.
     * @return _amount The amount deposited.
     */
    function depositIdleFxrp()
        external
        returns (uint256 _amount);

    /**
     * @notice Synchronizes the debt-route pointer against the live Morpho position and
     * returns the result: the pointed route while it still carries debt, or zero after
     * clearing a pointer left stale by an external repayment or liquidation. Callable by
     * anyone; performs no other state change.
     * @return _routeId The route carrying live debt after synchronization, or zero.
     */
    function syncDebtRoute()
        external
        returns (bytes32 _routeId);

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
     * reverts until one is set). Loan and collateral tokens of registered routes are
     * protected and rejected: they move only on their own rails. Reverts while paused.
     * @param _token The token to recover.
     * @return _amount The recovered amount.
     */
    function recoverToken(
        address _token
    )
        external
        returns (uint256 _amount);

    /**
     * @notice Recovers a loan-token surplus (e.g. RLUSD left after a clamped repayment) to
     * the stored recovery destination.
     * @dev Permissionless with a fixed destination. Only possible when **every** registered
     * route lending this token has zero outstanding borrow shares - before that, the balance
     * is repayment material, not surplus. Collateral tokens (FXRP) never leave through
     * recovery. Reverts while paused.
     * @param _token The loan token to recover.
     * @return _amount The recovered amount.
     */
    function recoverLoanToken(
        address _token
    )
        external
        returns (uint256 _amount);

    /**
     * @notice Recovers the native balance to the stored recovery destination.
     * @dev Permissionless with a fixed destination. Native can arrive as a bridge refund or
     * be force-sent. Reverts while paused.
     * @return _amount The recovered amount.
     */
    function recoverNative()
        external
        returns (uint256 _amount);

    /**
     * @notice Returns the stored recovery destination; zero until an authenticated
     * set-recovery action stores one.
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

    /**
     * @notice Returns the route currently carrying the account's debt, or zero. One route may
     * carry debt at a time; permissionless repayment callers can read this to know which
     * route to repay. Cleared lazily against the live position, so it stays one observation
     * behind an external repayment or liquidation until {syncDebtRoute} or a successful
     * debt-gated operation synchronizes it.
     * @return The debt route id.
     */
    function debtRouteId()
        external view
        returns (bytes32);

    /**
     * @notice Returns whether this account ever borrowed on a route.
     * @param _routeId The route id.
     * @return Whether the account borrowed on it.
     */
    function isBorrowedRoute(
        bytes32 _routeId
    )
        external view
        returns (bool);

    /**
     * @notice Returns every route this account ever borrowed on, append-only. Informational
     * only: the debt checks behind borrowing and loan-token recovery read the scalar
     * {debtRouteId} pointer, not this history.
     * @return The route ids.
     */
    function getBorrowedRoutes()
        external view
        returns (bytes32[] memory);

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
     * @notice Returns the controller address associated with this subaccount.
     * @return The controller address.
     */
    function controllerAddress()
        external view
        returns (address);

    /**
     * @notice Returns the parent Personal Account address for this subaccount.
     * @return The parent Personal Account address.
     */
    function parentPersonalAccount()
        external view
        returns (address);

    /**
     * @notice Returns the subaccount type.
     * @return The subaccount type.
     */
    function subaccountType()
        external view
        returns (uint256);

    /**
     * @notice Returns the implementation address of the subaccount.
     * @return The implementation address.
     */
    function implementation()
        external view
        returns (address);
}
