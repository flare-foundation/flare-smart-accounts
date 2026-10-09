// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ISubaccount} from "../userInterfaces/ISubaccount.sol";
// import is needed for @inheritdoc
// solhint-disable-next-line no-unused-import
import {IControlledAccount} from "../userInterfaces/IControlledAccount.sol";
import {ISubaccountsFacet} from "../userInterfaces/facets/ISubaccountsFacet.sol";

/**
 * @title MockGenericSubaccount
 * @notice A deliberately non-loan subaccount implementation carrying only the generic
 * {ISubaccount} surface: proves that a future subaccount type needs nothing from the loan
 * contracts — one registered implementation of this interface is enough for the frozen proxy
 * to deploy and initialize it.
 */
contract MockGenericSubaccount is ISubaccount {

    address private constant EMPTY_ADDRESS = 0x0000000000000000000000000000000000001111;

    /// @inheritdoc IControlledAccount
    address public controllerAddress;
    /// @inheritdoc ISubaccount
    address public parentPersonalAccount;
    /// @inheritdoc ISubaccount
    uint256 public subaccountType;

    constructor() {
        // ensure the implementation contract itself cannot be initialized/used
        controllerAddress = EMPTY_ADDRESS;
    }

    /// @inheritdoc ISubaccount
    function initialize(
        address _controllerAddress,
        address _parentPersonalAccount,
        uint256 _subaccountType
    )
        external
    {
        require(controllerAddress == address(0), AlreadyInitialized());
        controllerAddress = _controllerAddress;
        parentPersonalAccount = _parentPersonalAccount;
        subaccountType = _subaccountType;
    }

    /// @inheritdoc ISubaccount
    function implementation()
        external view
        returns (address)
    {
        return ISubaccountsFacet(controllerAddress).implementationForType(subaccountType);
    }
}
