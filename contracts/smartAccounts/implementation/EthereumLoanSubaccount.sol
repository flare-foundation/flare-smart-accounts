// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IEthereumLoanSubaccount} from "../../userInterfaces/IEthereumLoanSubaccount.sol";
import {
    ILoanSubaccountsFacet,
    SUBACCOUNT_TYPE_NONE
} from "../../userInterfaces/facets/ILoanSubaccountsFacet.sol";

/**
 * @title EthereumLoanSubaccount contract
 * @notice The Ethereum-side loan subaccount implementation: same frozen proxy, same CREATE2
 * address as the Flare-side account, different implementation behind the controller-as-beacon
 * (registered per chain with {ILoanSubaccountsFacet-loanImplementationForType}). This step
 * carries only initialization and resolution; the authenticated LayerZero compose entry point
 * and the permissionless repay/cleanup rails are added in later steps.
 */
contract EthereumLoanSubaccount is IEthereumLoanSubaccount {

    address private constant EMPTY_ADDRESS = 0x0000000000000000000000000000000000001111;

    /// @notice MasterAccountController address.
    address public controllerAddress;
    /// @notice Parent Personal Account address (a Flare-side address; no code on this chain).
    address public parentPersonalAccount;
    /// @notice Subaccount type.
    uint256 public subaccountType;

    constructor() {
        // ensure the implementation contract itself cannot be initialized/used
        controllerAddress = EMPTY_ADDRESS;
    }

    // note: no `receive()` yet - it is added together with the native exit in the
    // asset-moving steps, so the account can never hold native it cannot release

    /// @inheritdoc IEthereumLoanSubaccount
    function initialize(
        address _controllerAddress,
        address _parentPersonalAccount,
        uint256 _subaccountType
    )
        external
    {
        require(controllerAddress == address(0), AlreadyInitialized());
        require(_controllerAddress != address(0), InvalidControllerAddress());
        require(_parentPersonalAccount != address(0), InvalidParentPersonalAccount());
        require(_subaccountType != SUBACCOUNT_TYPE_NONE, ILoanSubaccountsFacet.InvalidSubaccountType());

        controllerAddress = _controllerAddress;
        parentPersonalAccount = _parentPersonalAccount;
        subaccountType = _subaccountType;

        emit LoanSubaccountInitialized(_controllerAddress, _parentPersonalAccount, _subaccountType);
    }

    /// @inheritdoc IEthereumLoanSubaccount
    function implementation()
        external view
        returns (address)
    {
        // controller is the beacon; it resolves the implementation for this subaccount type
        return ILoanSubaccountsFacet(controllerAddress).loanImplementationForType(subaccountType);
    }
}
