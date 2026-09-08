// SPDX-License-Identifier: MIT
pragma solidity >=0.8.4 <0.9;

import {IBridgingSubaccount} from "./IBridgingSubaccount.sol";

/**
 * @title ILoanSubaccount
 * @notice User interface for deterministic loan subaccounts on Flare: the parent-driven loan
 * instructions, typed payload encoders over the shared forward move. The permissionless rail
 * (`sweepRedeem`) and the redeem-home compose of the loan-chain twin's bridge-back are the
 * bridging surface every such type shares, declared on {IBridgingSubaccount}.
 */
interface ILoanSubaccount is IBridgingSubaccount {

    /// @notice The signed LayerZero options and delivery floor of the two-leg withdrawal. The
    /// operator quotes the return leg first, puts that fee (plus headroom; the excess lands on
    /// the parent) into `destinationOptions` as compose value, then quotes and sends the first
    /// message.
    struct WithdrawOptions {
        /// @notice Flare -> loan chain: the withdraw compose's gas and, as compose value, the
        /// native that pays the return leg's LayerZero fee.
        bytes destinationOptions;
        /// @notice Loan chain -> Flare: the redeem-home compose's gas and, optionally, the
        /// redemption's executor fee as compose value. Signed end-to-end and frozen into the
        /// instruction - a bad value parks the withdrawal until a fresh instruction (reuse the
        /// same operation id, so the parked packet terminal-skips as a duplicate).
        bytes returnOptions;
        /// @notice The delivery-value floor (non-zero): compose delivery is permissionless and
        /// LayerZero does not authenticate the delivered value, so the loan chain refuses any
        /// delivery of this withdraw - execution and terminal skip alike - carrying less than
        /// this. Set it to the compose value bought in `destinationOptions`, so a front-run
        /// with less cannot consume the packet and burn the prepaid value - and never above
        /// it: the floor is checked before the expiry skip, so a packet whose bought value is
        /// below its own floor reverts on every delivery, even after its deadline, and never
        /// finalizes (no funds at risk - the value was never delivered, and a reissue on the
        /// same operation id executes normally - but the orphan stays queued at the endpoint).
        uint256 minComposeValue;
    }

    /**
     * @notice Emitted when a borrow instruction is sent to this account's loan-chain twin.
     * @param parentPersonalAccount The parent Personal Account address.
     * @param operationId The user-chosen operation id.
     * @param collateralAmount FXRP bridged with the instruction, to become collateral.
     * @param borrowAmount Loan-token amount to borrow and disburse (non-zero).
     * @param destinationKind The disbursement destination kind.
     * @param destination The disbursement destination.
     * @param destinationEid The loan chain's LayerZero endpoint id.
     * @param guid The LayerZero message id.
     */
    event BorrowInstructionSent(
        address indexed parentPersonalAccount,
        bytes32 operationId,
        uint256 collateralAmount,
        uint256 borrowAmount,
        uint8 destinationKind,
        bytes32 destination,
        uint32 destinationEid,
        bytes32 guid
    );

    /**
     * @notice Emitted when a deposit-collateral instruction is sent to this account's
     * loan-chain twin.
     * @param parentPersonalAccount The parent Personal Account address.
     * @param amount FXRP bridged with the instruction, to become collateral.
     * @param destinationEid The loan chain's LayerZero endpoint id.
     * @param guid The LayerZero message id.
     */
    event CollateralDepositInstructionSent(
        address indexed parentPersonalAccount,
        uint256 amount,
        uint32 destinationEid,
        bytes32 guid
    );

    /**
     * @notice Emitted when a cancellation is sent to this account's loan-chain twin. Sending it
     * is not cancellation: the two packets race, and the loan chain's {LoanActionCancelled} is
     * what says the id was actually consumed.
     * @param parentPersonalAccount The parent Personal Account address.
     * @param operationId The operation id the cancellation names.
     * @param destinationEid The LayerZero endpoint id of the loan chain.
     * @param guid The LayerZero message id of the cancellation.
     */
    event LoanCancelInstructionSent(
        address indexed parentPersonalAccount,
        bytes32 operationId,
        uint32 destinationEid,
        bytes32 guid
    );

    /**
     * @notice Emitted when a withdraw instruction is sent to this account's loan-chain twin.
     * @param parentPersonalAccount The parent Personal Account address.
     * @param operationId The user-chosen operation id.
     * @param amount Collateral to withdraw on the loan chain.
     * @param destinationEid The loan chain's LayerZero endpoint id.
     * @param guid The LayerZero message id.
     */
    event WithdrawInstructionSent(
        address indexed parentPersonalAccount,
        bytes32 operationId,
        uint256 amount,
        uint32 destinationEid,
        bytes32 guid
    );

    /**
     * @notice Reverts on a loan instruction whose arguments cannot execute on the loan chain:
     * a zero operation id or a deadline already passed (borrow and withdraw), a zero borrow,
     * deposit or withdrawal amount, a borrow disbursement that is not a clean non-zero EVM address other than
     * this account, or a withdraw with a zero delivery-value floor. Checked here, before any
     * bridge fee is paid.
     */
    error InvalidLoanInstruction();

    /**
     * @notice The borrow instruction: bridges `_collateralAmount` FXRP (zero for a borrow
     * against existing collateral) with the typed payload that supplies it as collateral,
     * borrows `_borrowAmount` on the loan-chain twin's market and disburses it. A pure
     * collateral deposit is its own instruction, {depositCollateral}.
     * @dev Restricted to the parent Personal Account: the instruction names a loan action and
     * a user-chosen disbursement destination, so it must carry the user's XRPL signature. The
     * payload is built here, not passed in, so a malformed payload cannot reach the bridge; the
     * envelope and the EVM destination are validated before quoting
     * ({InvalidLoanInstruction}) and the loan chain re-validates on delivery. It sends to this
     * account's own cross-chain address through the configured pinned peer, sharing the
     * bridging core's guards: paused reverts, a configured route that is not suspended required,
     * live peer re-checked. `_extraOptions` must be type-3 options carrying both the destination
     * `lzReceive` gas and the `lzCompose` gas. `msg.value` must cover the LayerZero fee; the
     * excess is refunded to the parent. On the loan chain the borrow is also refused, retriably,
     * when the post-borrow position would fall under the cover gate
     * (`InsufficientRemainingCollateral`) - the same rule that gates {withdraw}: the collateral
     * must be worth `1.155 / LLTV` of the debt plus twice the collectible Flare fee.
     * @param _collateralAmount FXRP to bridge and supply as collateral; may be zero, at most
     * the account's balance.
     * @param _borrowAmount Loan-token amount to borrow and disburse; non-zero.
     * @param _destinationKind The disbursement destination kind (`DESTINATION_KIND_*`).
     * @param _destination The disbursement destination (a clean zero-padded EVM address for
     * `DESTINATION_KIND_EVM`).
     * @param _operationId The user-chosen operation id (non-zero, unique per subaccount).
     * @param _deadline Unix time after which the loan chain skips the instruction unexecuted.
     * Keep it short (under an hour): the loan is priced at the type's fee terms current at
     * delivery, so the front end warns while a terms change is pending in the timelock, and a
     * short deadline is what bounds how far past that warning a delayed packet can execute.
     * @param _extraOptions Caller-supplied LayerZero execution options (type-3).
     */
    function borrow(
        uint256 _collateralAmount,
        uint256 _borrowAmount,
        uint8 _destinationKind,
        bytes32 _destination,
        bytes32 _operationId,
        uint64 _deadline,
        bytes calldata _extraOptions
    )
        external payable;

    /**
     * @notice The deposit-collateral instruction: bridges exactly `_amount` FXRP to this
     * account's own address on the loan chain, with the typed deposit payload the loan-chain
     * twin executes on arrival — supply the bridged amount as collateral, no debt change.
     * @dev Restricted to the parent Personal Account; same guards and fee handling as
     * {borrow}. It carries no operation id and no deadline: a deposit only adds the user's own
     * collateral, which the loan chain's permissionless rail can do with the same tokens
     * anyway, so neither replay protection nor expiry buys anything (the loan-chain action is
     * id-less, like the Flare redeem-home). On the loan chain the deposit is the defensive
     * move: while the controller is paused it still executes when the position carries live
     * debt.
     * @param _amount FXRP to bridge and supply as collateral; non-zero, at most the balance.
     * @param _extraOptions Caller-supplied LayerZero execution options (type-3).
     */
    function depositCollateral(
        uint256 _amount,
        bytes calldata _extraOptions
    )
        external payable;

    /**
     * @notice The withdraw instruction: a typed, message-only send that atomically withdraws
     * `_amount` of collateral on the loan chain and bridges it home for redemption — no idle
     * window there, so nothing can be redeposited from under it.
     * @dev Restricted to the parent Personal Account; same validation, guards, and fee
     * handling as {borrow}. No FXRP travels with it, but `_options.destinationOptions` must
     * carry, as compose value, the native that prepays the return leg's LayerZero fee (quoted
     * against `_options.returnOptions` on the loan chain; the excess lands on the parent, and
     * too little parks the delivery as retriable). See {WithdrawOptions} for the signed
     * delivery-value floor. A withdrawal that would leave the position under the loan chain's
     * exit gate reverts there (`InsufficientRemainingCollateral`, retriable) until debt and
     * fee are repaid in loan tokens through the subaccount's `repay`, or a smaller amount is
     * signed.
     * @param _amount Collateral to withdraw on the loan chain and bridge home; non-zero.
     * @param _operationId The user-chosen operation id (non-zero, unique per subaccount).
     * @param _deadline Unix time after which the loan chain skips the instruction unexecuted.
     * @param _options The two option blobs and the delivery-value floor ({WithdrawOptions});
     * `minComposeValue` must be non-zero.
     */
    function withdraw(
        uint256 _amount,
        bytes32 _operationId,
        uint64 _deadline,
        WithdrawOptions calldata _options
    )
        external payable;

    /**
     * @notice The cancel instruction: a message-only send that consumes `_operationId` on the
     * loan chain, so a borrow or withdraw packet carrying that id can never execute.
     * @dev Restricted to the parent Personal Account. The motivating case is a borrow parked by
     * a failed health check after a price drop, which any collateral landing - the user's own
     * deposit or the permissionless rail - would otherwise make executable again. Sending this
     * is not cancellation: the two packets race, an original that lands first executes
     * normally and the cancellation then finalizes silently - so a client resolves a sent
     * cancellation by whichever arrives, the loan chain's
     * {ILoanSubaccountRemote.LoanActionCancelled} or the original action's own execution event,
     * either of which ends the instruction's live state; and an id a cancellation was signed
     * for is retired for good. It carries no deadline (a late
     * cancellation is unnecessary or still correct). On the loan chain it is not pause-gated;
     * here it travels the ordinary instruction path, which a Flare pause closes like every
     * other instruction (the controller's instruction facets and the bridge send both check
     * it), so a parked packet cannot be revoked from a paused Flare. In that state the loan
     * chain's own pause suspends the borrow but cancels nothing, so the order is: pause the loan
     * chain, restore Flare when safe, submit and confirm the cancellation while the loan chain
     * stays paused, then resume - unpausing it earlier makes the latent packet executable again.
     * Burning an unissued id is allowed and makes a re-send harmless.
     * @param _operationId The operation id to consume; must be non-zero.
     * @param _extraOptions LayerZero options for the cancel message (gas only - it moves no
     * tokens and needs no compose value).
     */
    function cancel(
        bytes32 _operationId,
        bytes calldata _extraOptions
    )
        external payable;

}
