// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ILoanSubaccount} from "../../userInterfaces/ILoanSubaccount.sol";
import {ILoanSubaccountsFacet} from "../../userInterfaces/facets/ILoanSubaccountsFacet.sol";

/**
 * @title LoanSubaccount contract
 * @notice Deterministic staging account for loan-related assets owned by a Personal Account.
 * @dev The controller (MasterAccountController Diamond) is the beacon: the proxy and this
 * contract resolve the implementation per subaccount type through {loanImplementationForType}.
 */
contract LoanSubaccount is ILoanSubaccount {

    address private constant EMPTY_ADDRESS = 0x0000000000000000000000000000000000001111;

    /// @notice MasterAccountController address.
    address public controllerAddress;
    /// @notice Parent Personal Account address.
    address public parentPersonalAccount;
    /// @notice Subaccount type.
    ILoanSubaccountsFacet.SubaccountType public subaccountType;

    constructor() {
        // ensure the implementation contract itself cannot be initialized/used
        controllerAddress = EMPTY_ADDRESS;
    }

    /// @inheritdoc ILoanSubaccount
    function initialize(
        address _controllerAddress,
        address _parentPersonalAccount,
        ILoanSubaccountsFacet.SubaccountType _subaccountType
    )
        external
    {
        require(controllerAddress == address(0), AlreadyInitialized());
        require(_controllerAddress != address(0), InvalidControllerAddress());
        require(_parentPersonalAccount != address(0), InvalidParentPersonalAccount());
        require(
            _subaccountType != ILoanSubaccountsFacet.SubaccountType.None,
            ILoanSubaccountsFacet.InvalidSubaccountType()
        );

        controllerAddress = _controllerAddress;
        parentPersonalAccount = _parentPersonalAccount;
        subaccountType = _subaccountType;

        emit LoanSubaccountInitialized(_controllerAddress, _parentPersonalAccount, _subaccountType);
    }

    /// @inheritdoc ILoanSubaccount
    function implementation()
        external view
        returns (address)
    {
        // controller is the beacon; it resolves the implementation for this subaccount type
        return ILoanSubaccountsFacet(controllerAddress).loanImplementationForType(subaccountType);
    }
}
