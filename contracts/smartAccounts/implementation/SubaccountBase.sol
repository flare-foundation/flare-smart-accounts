// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ISubaccount} from "../../userInterfaces/ISubaccount.sol";
import {
    ISubaccountsFacet,
    SUBACCOUNT_TYPE_NONE
} from "../../userInterfaces/facets/ISubaccountsFacet.sol";
import {ControlledAccountBase} from "./ControlledAccountBase.sol";

/**
 * @title SubaccountBase
 * @notice The identity every subaccount implementation shares, on Flare and on the remote
 * chains and whatever the type does: the parent Personal Account and the type (both fixed at
 * deployment and part of the account's CREATE2 address), the frozen-proxy `initialize`, the
 * `onlyParent` gate and the type-aware beacon lookup. The frozen `SubaccountProxy` dictates this
 * surface ({ISubaccount}) for every type; implementing the interface directly is enough (the
 * generic test mock does), and this base is its one shared implementation.
 * @dev STORAGE: the parent and the type live in the `smartAccounts.SubaccountBase.State` namespace,
 * never in linear slots, so this base can grow without shifting a derived lineage; the derived
 * contract's own linear state starts right after {ControlledAccountBase}'s slot 0.
 */
abstract contract SubaccountBase is ISubaccount, ControlledAccountBase {

    /// @custom:storage-location erc7201:smartAccounts.SubaccountBase.State
    struct SubaccountState {
        address parentPersonalAccount;
        uint256 subaccountType;
    }

    bytes32 private constant SUBACCOUNT_STATE_POSITION =
        bytes32(erc7201("smartAccounts.SubaccountBase.State"));

    /// @dev The caller must be the parent Personal Account, fixed at deployment and part of
    /// this account's address.
    modifier onlyParent() {
        require(msg.sender == _getSubaccountState().parentPersonalAccount, OnlyParent());
        _;
    }

    /// @inheritdoc ISubaccount
    function initialize(
        address _controllerAddress,
        address _parentPersonalAccount,
        uint256 _subaccountType
    )
        external
    {
        _setController(_controllerAddress);
        require(_parentPersonalAccount != address(0), InvalidParentPersonalAccount());
        require(_subaccountType != SUBACCOUNT_TYPE_NONE, ISubaccountsFacet.InvalidSubaccountType());
        SubaccountState storage state = _getSubaccountState();
        state.parentPersonalAccount = _parentPersonalAccount;
        state.subaccountType = _subaccountType;
        emit SubaccountInitialized(_controllerAddress, _parentPersonalAccount, _subaccountType);
    }

    /// @inheritdoc ISubaccount
    function parentPersonalAccount()
        external view
        returns (address)
    {
        return _parentAccount();
    }

    /// @inheritdoc ISubaccount
    function subaccountType()
        external view
        returns (uint256)
    {
        return _accountType();
    }

    /// @inheritdoc ISubaccount
    function implementation()
        external view
        returns (address)
    {
        // controller is the beacon; it resolves the implementation for this subaccount type
        return ISubaccountsFacet(controllerAddress).implementationForType(_accountType());
    }

    function _parentAccount()
        internal view
        returns (address)
    {
        return _getSubaccountState().parentPersonalAccount;
    }

    function _accountType()
        internal view
        returns (uint256)
    {
        return _getSubaccountState().subaccountType;
    }

    function _getSubaccountState()
        private pure
        returns (SubaccountState storage _state)
    {
        bytes32 position = SUBACCOUNT_STATE_POSITION;
        // solhint-disable-next-line no-inline-assembly
        assembly {
            _state.slot := position
        }
    }
}
