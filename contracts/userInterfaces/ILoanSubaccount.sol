// SPDX-License-Identifier: MIT
pragma solidity >=0.8.4 <0.9;

/**
 * @title ILoanSubaccount
 * @notice User interface for deterministic loan subaccounts.
 */
interface ILoanSubaccount {

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
     * @notice Emitted when idle FXRP is redeemed to the parent Personal Account's XRPL owner.
     * @param parentPersonalAccount The parent Personal Account address.
     * @param amount Amount of FXRP requested for redemption (the whole balance).
     * @param redeemedAmount Amount of FXRP actually redeemed, which can be less.
     * @param executor Executor used for the redemption.
     * @param valueForwarded Native value actually forwarded with the redemption (covers the
     * executor fee).
     */
    event FXrpRedeemed(
        address indexed parentPersonalAccount,
        uint256 amount,
        uint256 redeemedAmount,
        address executor,
        uint256 valueForwarded
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
     * @notice Reverts if the FXRP balance is below the FAssets minimum redemption amount.
     * Such a residual is recovered with {sweepToParent} instead.
     * @param minimumRedeemAmount The FAssets minimum redemption amount.
     */
    error BelowMinimumRedemption(
        uint256 minimumRedeemAmount
    );

    /**
     * @notice Reverts if FXRP at or above the FAssets minimum redemption amount is passed to
     * {sweepToParent}. Such a balance moves only through {sweepRedeem} or {sweepToLoan}, so
     * recovery to the parent cannot become a third direction for the loan asset.
     * @param balance The FXRP balance.
     * @param minimumRedeemAmount The FAssets minimum redemption amount.
     */
    error FXrpAboveMinimumRedemption(
        uint256 balance,
        uint256 minimumRedeemAmount
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
     * @notice Reverts if the sent value does not cover the executor fee.
     * @param executorFee The required executor fee.
     */
    error InsufficientFundsForRedeem(
        uint256 executorFee
    );

    /**
     * @notice Redeems all idle FXRP to the parent Personal Account's XRPL owner.
     * @dev Permissionless: this is the backward cleanup move, so anyone may trigger it. The
     * destination is read on-chain from the parent Personal Account and cannot be chosen by the
     * caller, and the executor comes from the controller, so the call takes no parameters at all.
     * Redeems the whole balance rather than whole lots, so nothing is left stranded; FAssets can
     * still redeem less than requested, in which case the remainder stays and can be swept again.
     * Balances below the FAssets minimum redemption amount revert and are recovered with
     * {sweepToParent} instead.
     * @return _amount Amount of FXRP requested for redemption (the whole balance).
     * @return _redeemedAmount Amount of FXRP actually redeemed.
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
     * @notice Recovers a token balance to the parent Personal Account.
     * @dev Permissionless. The destination is fixed to the parent, so the caller chooses only
     * which asset to recover, never where it goes. This is how assets with no other exit leave
     * the account — for example vault collateral or WNat paid out here by a FAssets redemption
     * default, or an FXRP residual below the FAssets minimum redemption amount. FXRP at or above
     * that minimum is rejected: the loan asset moves only through {sweepRedeem} or {sweepToLoan}.
     * Stays available while the controller is paused, since the parent is the safest possible
     * destination.
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
     * @dev Permissionless, fixed destination; see {sweepToParent}. Native can arrive here as a
     * bridge or redemption refund, or by being sent with an instruction before the subaccount
     * was deployed.
     * @return _amount The recovered amount.
     */
    function sweepNativeToParent()
        external
        returns (uint256 _amount);

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
