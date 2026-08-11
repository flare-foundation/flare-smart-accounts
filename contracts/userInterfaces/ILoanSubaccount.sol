// SPDX-License-Identifier: MIT
pragma solidity >=0.8.4 <0.9;

import {ILoanSubaccountsFacet} from "./facets/ILoanSubaccountsFacet.sol";

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
        ILoanSubaccountsFacet.SubaccountType indexed subaccountType
    );

    /**
     * @notice Emitted when idle FXRP is redeemed to the parent Personal Account's XRPL owner.
     * @param parentPersonalAccount The parent Personal Account address.
     * @param amount Amount of FXRP requested for redemption (the whole balance).
     * @param redeemedAmount Amount of FXRP actually redeemed, which can be less.
     * @param executor Executor used for the redemption.
     * @param executorFee Executor fee paid with the redemption.
     */
    event FXrpRedeemed(
        address indexed parentPersonalAccount,
        uint256 amount,
        uint256 redeemedAmount,
        address executor,
        uint256 executorFee
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
     * @return _amount Amount of FXRP requested for redemption (the whole balance).
     * @return _redeemedAmount Amount of FXRP actually redeemed.
     */
    function sweepRedeem()
        external payable
        returns (uint256 _amount, uint256 _redeemedAmount);

    /**
     * @notice Initializes the loan subaccount.
     * @param _controllerAddress MasterAccountController address.
     * @param _parentPersonalAccount Parent Personal Account address.
     * @param _subaccountType The subaccount type.
     */
    function initialize(
        address _controllerAddress,
        address _parentPersonalAccount,
        ILoanSubaccountsFacet.SubaccountType _subaccountType
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
        returns (ILoanSubaccountsFacet.SubaccountType);

    /**
     * @notice Returns the implementation address of the subaccount.
     * @return The implementation address.
     */
    function implementation()
        external view
        returns (address);
}
