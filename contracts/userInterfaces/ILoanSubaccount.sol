// SPDX-License-Identifier: MIT
pragma solidity >=0.8.4 <0.9;

import {IComposeReceiverAccountBase} from "./IComposeReceiverAccountBase.sol";
import {ISubaccount} from "./ISubaccount.sol";

/// @dev Redeem-home action: the compose the loan-chain bridge-back attaches to the FXRP it
/// returns - the parent-signed `sweepToOrigin`, or the withdraw action's return leg.
/// `actionData` is `abi.encode(uint64 deadline)`, stamped by the sender as its block time plus
/// `REDEEM_HOME_TTL` - the compose itself expresses no choice (fixed destination, capped
/// amount). On arrival, `min(balance, amountLD)` - at most the packet's authenticated
/// amount - goes through the sweep-redeem logic (to the parent, which redeems it; below the
/// FAssets minimum pushed unredeemed), with the compose value as the executor fee; the rest of
/// the balance is left for the public rail. FXRP is fungible: the cap bounds the amount one
/// compose can move, it does not tie the compose to the units its packet credited. Past its
/// deadline the packet skips terminally (the balance is left untouched for the public rail,
/// any compose value goes to the parent), so a packet cannot outlive its delivery window as a
/// standing instruction over later funds. The public `sweepRedeem` fee requirement does not
/// apply here: the packet already cost its sender the LayerZero fee.
uint8 constant ACTION_REDEEM_HOME = 1;

/// @dev Lifetime of a redeem-home packet, from the send on the loan chain to its delivery on
/// Flare: the intended operational delivery window (verification, executor delivery and
/// ordinary retries - normally minutes). A packet delivered later skips and its FXRP falls back
/// to the public rail; an extended LayerZero outage is what that rail is for. Tune from
/// observed delivery latency once deployment data exists.
uint64 constant REDEEM_HOME_TTL = 1 hours;

/**
 * @title ILoanSubaccount
 * @notice User interface for deterministic loan subaccounts on Flare. Besides its parent-driven
 * instructions and its one permissionless rail (`sweepRedeem`), the account is the compose
 * receiver of its own loan-chain twin's bridge-back (see {IComposeReceiverAccountBase}): FXRP
 * coming home is redeemed on arrival.
 */
interface ILoanSubaccount is IComposeReceiverAccountBase, ISubaccount {

    /// @notice The two LayerZero option blobs a withdraw instruction carries - one per leg of
    /// the atomic withdrawal. The operator quotes the return leg first, puts that fee (plus
    /// headroom; the excess lands on the parent) into `destinationOptions` as compose value,
    /// then quotes and sends the first message.
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
        /// with less cannot consume the packet and burn the prepaid value.
        uint256 minComposeValue;
        /// @notice The signed cap on the loan fee this withdrawal may settle, in FXRP
        /// deducted from the withdrawn collateral at the market oracle's price. Binds only
        /// when the withdrawal would leave the fee under-secured (the secured-claim rule;
        /// most mid-loan withdrawals collect nothing). The cap is the user's price
        /// protection: a worse price parks the delivery retriably (reissue with a higher
        /// cap on the same operation id), and a dead oracle is escaped by settling through
        /// the subaccount's repay first. Quote the converted fee plus headroom; zero when
        /// no collection is expected.
        uint256 maxFeeFxrp;
    }

    /**
     * @notice Emitted when a loan subaccount is initialized.
     * @param controllerAddress The controller address.
     * @param parentPersonalAccount The parent Personal Account address.
     * @param subaccountType The subaccount type.
     */
    event LoanSubaccountInitialized(
        address indexed controllerAddress,
        address indexed parentPersonalAccount,
        uint256 indexed subaccountType
    );

    /**
     * @notice Emitted when idle FXRP is pushed to the parent Personal Account and redeemed by
     * it to its XRPL owner.
     * @param parentPersonalAccount The parent Personal Account address (the redeemer).
     * @param amount Amount of FXRP pushed and requested for redemption (the whole balance from
     * the public rail; at most the packet's authenticated amount from the redeem-home compose).
     * @param redeemedAmount Amount of FXRP actually redeemed, which can be less; the rest
     * stays on the parent.
     */
    event FXrpRedeemed(
        address indexed parentPersonalAccount,
        uint256 amount,
        uint256 redeemedAmount
    );

    /**
     * @notice Emitted when a redeem-home compose arrives past its deadline and skips: nothing
     * is redeemed, the packet's credit stays for the public rail, its value went to the parent.
     * @param parentPersonalAccount The parent Personal Account address.
     * @param guid The LayerZero message id of the skipped packet.
     */
    event RedeemHomeSkipped(
        address indexed parentPersonalAccount,
        bytes32 guid
    );

    /**
     * @notice Emitted when a {sweepRedeem} or redeem-home compose pushes a below-minimum FXRP
     * balance to the parent Personal Account unredeemed (in place of {FXrpRedeemed}).
     * @param parentPersonalAccount The parent Personal Account address.
     * @param token The FXRP token.
     * @param amount The pushed amount.
     */
    event TokenSweptToParent(
        address indexed parentPersonalAccount,
        address indexed token,
        uint256 amount
    );

    /**
     * @notice Emitted when native is sent to the parent Personal Account: the value of a
     * {sweepRedeem} or redeem-home compose that pushed a below-minimum balance without
     * redeeming, or of a redeem-home compose that arrived past its deadline.
     * @param parentPersonalAccount The parent Personal Account address.
     * @param amount The amount sent.
     */
    event NativeSweptToParent(
        address indexed parentPersonalAccount,
        uint256 amount
    );


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
     * @param operationId The user-chosen operation id.
     * @param amount FXRP bridged with the instruction, to become collateral.
     * @param destinationEid The loan chain's LayerZero endpoint id.
     * @param guid The LayerZero message id.
     */
    event CollateralDepositInstructionSent(
        address indexed parentPersonalAccount,
        bytes32 operationId,
        uint256 amount,
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
     * @notice Reverts if the parent Personal Account address is invalid.
     */
    error InvalidParentPersonalAccount();

    /**
     * @notice Reverts if the caller is not the parent Personal Account.
     */
    error OnlyParent();

    /**
     * @notice Reverts if there is no FXRP to redeem.
     */
    error NothingToRedeem();


    /**
     * @notice Reverts if the loan bridge settings have not been configured on the controller.
     */
    error LoanBridgeNotConfigured();

    /**
     * @notice Reverts if the OFT's live peer for the destination chain no longer matches the
     * peer pinned in the controller's bridge settings.
     */
    error WrongDestinationPeer();

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
     * @notice Reverts if the value sent with {sweepRedeem} does not cover the controller's
     * executor fee: the configured fee is the price of the permissionless backward rail.
     * @param executorFee The required executor fee.
     */
    error InsufficientFundsForRedeem(
        uint256 executorFee
    );


    /**
     * @notice Reverts if native could not be sent to the parent Personal Account.
     */
    error NativeSweepFailed();


    /**
     * @notice Reverts on a loan instruction whose arguments cannot execute on the loan chain:
     * a zero operation id, a deadline already passed, a zero borrow, deposit or withdrawal
     * amount, a borrow disbursement that is not a clean non-zero EVM address other than
     * this account, or a withdraw with a zero delivery-value floor. Checked here, before any
     * bridge fee is paid.
     */
    error InvalidLoanInstruction();

    /**
     * @notice Reverts if the requested bridge amount exceeds the account's FXRP balance.
     * @param amount The requested amount.
     * @param balance The account's FXRP balance.
     */
    error AmountExceedsBalance(
        uint256 amount,
        uint256 balance
    );

    /**
     * @notice Pushes all idle FXRP to the parent Personal Account and has it redeemed to the
     * parent's XRPL owner in the same call.
     * @dev Permissionless: this is the backward cleanup move, so anyone may trigger it. It takes
     * no parameters: the destination is the parent (fixed at deployment, part of this account's
     * address), which redeems through {IPersonalAccount-redeemFromSubaccount} - pulling exactly
     * the pushed amount and redeeming exactly that, with the controller's executor and this
     * call's whole `msg.value` as the fee (FAssets records it in whole gwei). `msg.value` must
     * cover the controller's configured executor fee ({InsufficientFundsForRedeem}): the fee is
     * the price of the permissionless rail, so forcing the backward direction is never
     * gas-only. The parent is the recorded redeemer, so every redemption outcome (a partial
     * fill when FAssets tickets run out, a payment-default payout, a refund) lands on the
     * parent, under the user's control. The whole balance is redeemed rather than whole lots,
     * so nothing is left stranded here. A balance below the FAssets minimum redemption amount
     * is pushed to the parent unredeemed instead (FAssets would reject it): `_redeemedAmount`
     * is zero, the value goes to the parent as well ({NativeSweptToParent}), and
     * {TokenSweptToParent} is emitted in place of {FXrpRedeemed} - the rail never fails on
     * amount, and it costs the same either way.
     * @return _amount Amount of FXRP pushed to the parent (the whole balance).
     * @return _redeemedAmount Amount of FXRP actually redeemed; zero below the minimum.
     */
    function sweepRedeem()
        external payable
        returns (uint256 _amount, uint256 _redeemedAmount);


    /**
     * @notice The borrow instruction: bridges exactly `_collateralAmount` FXRP (zero for a
     * borrow against existing collateral) to this account's own address on the loan chain,
     * with the typed borrow payload the loan-chain twin executes on arrival — supply the
     * bridged amount as collateral, borrow `_borrowAmount` and disburse it. A pure collateral
     * deposit is its own instruction, {depositCollateral}.
     * @dev Restricted to the parent Personal Account: the instruction names a loan action and
     * a user-chosen disbursement destination, so it must carry the user's XRPL signature. The
     * payload is built here, not passed in, so what the user signs is structured and
     * type-checked, and a malformed payload cannot reach the bridge. Arguments are validated
     * before any fee is paid (`InvalidLoanInstruction`); the loan chain re-validates on
     * delivery. The bridge destination is this account's own cross-chain address, fixed in the
     * shared bridging core with all of its guards: paused reverts, configured settings required,
     * live peer re-checked. `_extraOptions` must be type-3 options carrying both the
     * destination `lzReceive` gas and the `lzCompose` gas. `msg.value` must cover the
     * LayerZero fee; any excess is returned to the caller (the parent).
     * @param _collateralAmount FXRP to bridge and supply as collateral; may be zero, at most
     * the account's balance.
     * @param _borrowAmount Loan-token amount to borrow and disburse; non-zero.
     * @param _destinationKind The disbursement destination kind (`DESTINATION_KIND_*`).
     * @param _destination The disbursement destination (a clean zero-padded EVM address for
     * `DESTINATION_KIND_EVM`).
     * @param _operationId The user-chosen operation id (non-zero, unique per subaccount).
     * @param _deadline Unix time after which the loan chain skips the instruction unexecuted.
     * @param _maxFeeFloor The signed fee-rate bound: the loan chain terminal-skips the borrow
     * (id unconsumed, credit idle) if the type's current fee floor exceeds this - a delayed
     * packet never executes at a worse rate than signed; a favorable decrease still executes.
     * @param _maxFeeSpread The signed bound on the fee spread, same semantics.
     * @param _extraOptions Caller-supplied LayerZero execution options (type-3).
     */
    function borrow(
        uint256 _collateralAmount,
        uint256 _borrowAmount,
        uint8 _destinationKind,
        bytes32 _destination,
        bytes32 _operationId,
        uint64 _deadline,
        uint64 _maxFeeFloor,
        uint64 _maxFeeSpread,
        bytes calldata _extraOptions
    )
        external payable;

    /**
     * @notice The deposit-collateral instruction: bridges exactly `_amount` FXRP to this
     * account's own address on the loan chain, with the typed deposit payload the loan-chain
     * twin executes on arrival — supply the bridged amount as collateral, no debt change.
     * @dev Restricted to the parent Personal Account; same validation, guards, and fee
     * handling as {borrow}. On the loan chain the deposit is the defensive move: while the
     * controller is paused it still executes when the position carries live debt.
     * @param _amount FXRP to bridge and supply as collateral; non-zero, at most the balance.
     * @param _operationId The user-chosen operation id (non-zero, unique per subaccount).
     * @param _deadline Unix time after which the loan chain skips the instruction unexecuted.
     * @param _extraOptions Caller-supplied LayerZero execution options (type-3).
     */
    function depositCollateral(
        uint256 _amount,
        bytes32 _operationId,
        uint64 _deadline,
        bytes calldata _extraOptions
    )
        external payable;

    /**
     * @notice The withdraw instruction: a message-only send to this account's own address on
     * the loan chain, with the typed withdraw payload — withdraw `_amount` of collateral from
     * the position and bridge it back here in the same execution, to be redeemed on arrival
     * (the atomic withdrawal: no idle window on the loan chain, so nothing can be redeposited
     * from under it).
     * @dev Restricted to the parent Personal Account; same validation, guards, and fee
     * handling as {borrow}. No FXRP travels with it, but `_options.destinationOptions` must
     * carry, as compose value, the native that pays the return leg's LayerZero fee (quoted
     * against `_options.returnOptions` on the loan chain; the excess lands on the parent, and
     * too little parks the delivery as retriable).
     * @param _amount Collateral to withdraw on the loan chain and bridge home; non-zero.
     * @param _operationId The user-chosen operation id (non-zero, unique per subaccount).
     * @param _deadline Unix time after which the loan chain skips the instruction unexecuted.
     * @param _options The two option blobs, the delivery-value floor and the signed FXRP fee
     * cap ({WithdrawOptions}); `minComposeValue` must be non-zero.
     */
    function withdraw(
        uint256 _amount,
        bytes32 _operationId,
        uint64 _deadline,
        WithdrawOptions calldata _options
    )
        external payable;


    /// @inheritdoc ISubaccount
    function controllerAddress()
        external view
        override(IComposeReceiverAccountBase, ISubaccount)
        returns (address);
}
