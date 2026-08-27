// SPDX-License-Identifier: MIT
pragma solidity >=0.8.4 <0.9;

import {ISubaccount} from "./ISubaccount.sol";

/**
 * @title ILoanSubaccount
 * @notice User interface for deterministic loan subaccounts.
 */
interface ILoanSubaccount is ISubaccount {

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
     * @param amount Amount of FXRP pushed and requested for redemption (the whole balance).
     * @param redeemedAmount Amount of FXRP actually redeemed, which can be less; the rest
     * stays on the parent.
     */
    event FXrpRedeemed(
        address indexed parentPersonalAccount,
        uint256 amount,
        uint256 redeemedAmount
    );

    /**
     * @notice Emitted when a token balance is recovered to the parent Personal Account.
     * @param parentPersonalAccount The parent Personal Account address.
     * @param token The recovered token.
     * @param amount The recovered amount.
     */
    event TokenSweptToParent(
        address indexed parentPersonalAccount,
        address indexed token,
        uint256 amount
    );

    /**
     * @notice Emitted when the native balance is recovered to the parent Personal Account.
     * @param parentPersonalAccount The parent Personal Account address.
     * @param amount The recovered amount.
     */
    event NativeSweptToParent(
        address indexed parentPersonalAccount,
        uint256 amount
    );

    /**
     * @notice Emitted when idle FXRP is bridged onward to the loan chain.
     * @param parentPersonalAccount The parent Personal Account address.
     * @param amount Amount of FXRP bridged.
     * @param destinationEid The LayerZero endpoint id it was bridged to.
     * @param guid The LayerZero message id.
     */
    event FXrpSweptToLoan(
        address indexed parentPersonalAccount,
        uint256 amount,
        uint32 destinationEid,
        bytes32 guid
    );

    /**
     * @notice Emitted when a borrow instruction is sent to this account's loan-chain twin.
     * @param parentPersonalAccount The parent Personal Account address.
     * @param operationId The user-chosen operation id.
     * @param collateralAmount FXRP bridged with the instruction, to become collateral.
     * @param borrowAmount Loan-token amount to borrow and disburse; zero for a pure top-up.
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
     * @notice Reverts if the caller is not the parent Personal Account.
     */
    error OnlyParent();

    /**
     * @notice Reverts if there is no FXRP to redeem.
     */
    error NothingToRedeem();

    /**
     * @notice Reverts if there is no FXRP to sweep onward.
     */
    error NothingToSweep();

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
     * @notice Reverts if FXRP is passed to {sweepToParent}: the loan asset moves only on its
     * own rails ({sweepRedeem}, which pushes a balance below the FAssets minimum to the parent
     * unredeemed, and the forward moves).
     * @param token The rejected token.
     */
    error ProtectedToken(
        address token
    );

    /**
     * @notice Reverts if the native balance could not be sent to the parent Personal Account.
     */
    error NativeSweepFailed();

    /**
     * @notice Reverts on the implementation contract itself, which is never initialized: it must
     * not accept native, and its recovery methods have no parent to send to.
     */
    error NotInitialized();

    /**
     * @notice Reverts on a loan instruction whose arguments cannot execute on the loan chain:
     * a zero operation id, a deadline already passed, nothing to collateralize or borrow, a
     * zero withdrawal, or a borrow disbursement that is not a clean non-zero EVM address
     * other than this account. Checked here, before any bridge fee is paid.
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
     * @notice Bridges all idle FXRP onward to this account's address on the loan chain.
     * @dev Permissionless: this is the forward cleanup move, so anyone may trigger it. Like
     * {sweepRedeem} it takes no parameters. The destination address is this account's own address,
     * which is identical on every chain because it is CREATE2-derived from inputs that do not vary
     * by chain, and the destination chain and OFT come from the controller, so the caller cannot
     * choose where the assets go. `msg.value` must cover the LayerZero messaging fee; any excess
     * is returned to the caller. Reverts while the controller is paused: the forward sweep is the
     * incident-containment surface, while {sweepRedeem} stays available during a pause.
     * @return _amount Amount of FXRP bridged.
     */
    function sweepToLoan()
        external payable
        returns (uint256 _amount);

    /**
     * @notice The borrow instruction: bridges exactly `_collateralAmount` FXRP (zero for a
     * borrow against existing collateral) to this account's own address on the loan chain,
     * with the typed borrow payload the loan-chain twin executes on arrival — supply the
     * bridged amount as collateral and, for a non-zero `_borrowAmount`, borrow and disburse.
     * @dev Restricted to the parent Personal Account: the instruction names a loan action and
     * a user-chosen disbursement destination, so it must carry the user's XRPL signature. The
     * payload is built here, not passed in, so what the user signs is structured and
     * type-checked, and a malformed payload cannot reach the bridge. Arguments are validated
     * before any fee is paid (`InvalidLoanInstruction`); the loan chain re-validates on
     * delivery. The bridge destination is this account's own cross-chain address, exactly as
     * in {sweepToLoan}, with all of its guards: paused reverts, configured settings required,
     * live peer re-checked. `_extraOptions` must be type-3 options carrying both the
     * destination `lzReceive` gas and the `lzCompose` gas. `msg.value` must cover the
     * LayerZero fee; any excess is returned to the caller (the parent).
     * @param _collateralAmount FXRP to bridge and supply as collateral; may be zero, at most
     * the account's balance.
     * @param _borrowAmount Loan-token amount to borrow and disburse; zero for a pure top-up.
     * @param _destinationKind The disbursement destination kind (`DESTINATION_KIND_*`).
     * @param _destination The disbursement destination (a clean zero-padded EVM address for
     * `DESTINATION_KIND_EVM`); ignored for a pure top-up.
     * @param _operationId The user-chosen operation id (non-zero, unique per subaccount).
     * @param _deadline Unix time after which the loan chain skips the instruction unexecuted.
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
     * @notice The withdraw instruction: a message-only send to this account's own address on
     * the loan chain, with the typed withdraw payload — withdraw `_amount` of collateral from
     * the position to the loan-chain account itself, where only its fixed rails can move it.
     * @dev Restricted to the parent Personal Account; same validation, guards, and fee
     * handling as {borrow}. No FXRP travels with it.
     * @param _amount Collateral to withdraw on the loan chain; non-zero.
     * @param _operationId The user-chosen operation id (non-zero, unique per subaccount).
     * @param _deadline Unix time after which the loan chain skips the instruction unexecuted.
     * @param _extraOptions Caller-supplied LayerZero execution options (type-3).
     */
    function withdraw(
        uint256 _amount,
        bytes32 _operationId,
        uint64 _deadline,
        bytes calldata _extraOptions
    )
        external payable;

    /**
     * @notice Recovers a token balance to the parent Personal Account.
     * @dev Permissionless. The destination is fixed to the parent, so the caller chooses only
     * which asset to recover, never where it goes: a thin mover for anything that lands here
     * with no other exit (a mistaken token send). FXRP is rejected ({ProtectedToken}) - it
     * moves only on its own rails, and a below-minimum residual goes home through
     * {sweepRedeem}. Stays available while the controller is paused, since the parent is the
     * safest possible destination.
     * @param _token The token to recover.
     * @return _amount The recovered amount.
     */
    function sweepToParent(
        address _token
    )
        external
        returns (uint256 _amount);

    /**
     * @notice Recovers the native balance to the parent Personal Account.
     * @dev Permissionless, fixed destination; see {sweepToParent}. Native can arrive here as
     * an external refund, or by being sent with an instruction before the subaccount was
     * deployed.
     * @return _amount The recovered amount.
     */
    function sweepNativeToParent()
        external
        returns (uint256 _amount);

}
