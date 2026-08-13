// SPDX-License-Identifier: MIT
pragma solidity >=0.8.4 <0.9;

import {ILayerZeroComposer} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroComposer.sol";

/// @dev Compose payload schema version 1. The payload is
/// `abi.encode(uint8 version, uint8 action, bytes actionData)`.
uint8 constant PAYLOAD_VERSION_1 = 1;

/// @dev Borrow action: `actionData` is `abi.encode(bytes32 operationId, uint64 deadline,
/// bytes32 expectedMarketId, uint8 destinationKind, bytes32 destination,
/// uint256 borrowAmount)`. The operation id must be non-zero and globally unique per
/// subaccount across all action types; a retry of the same intent keeps its economic fields
/// and refreshes only the deadline. The authenticated bridged amount (the codec's `amountLD`, never the
/// idle balance) is supplied as collateral; if `borrowAmount` is non-zero, that amount of the
/// loan token is borrowed and sent to `destination`. A zero bridged amount with a non-zero
/// `borrowAmount` borrows against the existing position; a non-zero bridged amount with a zero
/// `borrowAmount` is a pure collateral top-up that ignores the destination fields.
uint8 constant ACTION_BORROW = 1;

/// @dev Withdraw action: `actionData` is `abi.encode(bytes32 operationId, uint64 deadline,
/// bytes32 expectedMarketId, uint256 withdrawAmount)`. Withdraws collateral from the account's
/// own position to the account itself, where it leaves only along the fixed rails (the
/// bridge-back sweep to this account's own origin-chain address). Position health is enforced
/// by Morpho.
uint8 constant ACTION_WITHDRAW = 2;

/// @dev The destination is an EVM address (cleanly zero-padded into the `bytes32`), paid by a
/// plain ERC-20 transfer — typically an exchange deposit address.
uint8 constant DESTINATION_KIND_EVM = 1;

/// @dev Reserved: an XRPL address reached over Wormhole. Not implemented yet (Wormhole specs
/// pending); payloads using it revert.
uint8 constant DESTINATION_KIND_XRPL_WORMHOLE = 2;

/// @dev Skip reason: the operation id was already executed (a retried instruction delivered
/// twice must not turn one intended action into two).
uint8 constant SKIP_REASON_DUPLICATE = 1;

/// @dev Skip reason: the deadline passed before delivery; the user's intent is stale. The
/// operation id is not consumed, so the same intent can be retried with a fresh deadline.
uint8 constant SKIP_REASON_EXPIRED = 2;

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
     * @param collateralSupplied FXRP supplied as collateral (the authenticated bridged amount).
     * @param borrowAmount Loan-token amount borrowed and disbursed; zero for a pure top-up.
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
     * @notice Emitted when an authenticated action completes without executing. The bridged
     * FXRP that arrived with the message stays on the account, recoverable along the fixed
     * rails.
     * @param parentPersonalAccount The parent Personal Account address.
     * @param operationId The payload's operation id (consumed only when executed, never when
     * skipped).
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
     * compose value, and the account has no native exit; a rejected delivery is retriable
     * through the endpoint without value.
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
     * @notice Reverts if the configured Morpho market is not the one the payload was signed
     * for. Deliberately a revert, not a skip: a mismatch is a temporary state (settings can
     * change back), and a permissionless delivery during the window must not consume the
     * packet. The delivery stays retriable until its deadline expires.
     * @param expectedMarketId The market id the payload was signed for.
     */
    error WrongMarket(
        bytes32 expectedMarketId
    );

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
     * @notice Reverts on a borrow whose EVM destination is zero or not a clean zero-padded
     * address.
     */
    error InvalidDestination();

    /**
     * @notice Reverts on a borrow action that would neither supply collateral nor borrow, or
     * a withdraw action of zero.
     */
    error NothingToDo();

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
     * @notice Returns whether an operation id has been executed.
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
