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
