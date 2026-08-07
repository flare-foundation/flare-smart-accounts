// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Proxy} from "@openzeppelin/contracts/proxy/Proxy.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {ILoanSubaccount} from "../../userInterfaces/ILoanSubaccount.sol";
import {ILoanSubaccountsFacet} from "../../userInterfaces/facets/ILoanSubaccountsFacet.sol";

/**
 * @title LoanSubaccountProxy contract
 * @notice Per-Personal-Account loan subaccount proxy. The controller is the beacon:
 * the implementation is resolved per subaccount type through {loanImplementationForType},
 * so upgrades happen on the controller and the type is fixed at deployment.
 */
contract LoanSubaccountProxy is Proxy {

    /// @notice MasterAccountController address used to resolve the implementation.
    address private immutable controller;
    /// @notice Subaccount type, fixed at deployment.
    ILoanSubaccountsFacet.SubaccountType private immutable subaccountType;

    /**
     * @notice Deploys the proxy and initializes loan subaccount state.
     * @param _controller MasterAccountController address, used as the beacon.
     * @param _parentPersonalAccount Parent Personal Account address.
     * @param _subaccountType Subaccount type.
     */
    constructor(
        address _controller,
        address _parentPersonalAccount,
        ILoanSubaccountsFacet.SubaccountType _subaccountType
    ) {
        controller = _controller;
        subaccountType = _subaccountType;

        address impl = ILoanSubaccountsFacet(_controller).loanImplementationForType(_subaccountType);
        Address.functionDelegateCall(
            impl,
            abi.encodeCall(
                ILoanSubaccount.initialize,
                (_controller, _parentPersonalAccount, _subaccountType)
            )
        );
    }

    /// @inheritdoc Proxy
    function _implementation()
        internal view
        override
        returns (address)
    {
        return ILoanSubaccountsFacet(controller).loanImplementationForType(subaccountType);
    }
}
