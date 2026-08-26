// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Proxy} from "@openzeppelin/contracts/proxy/Proxy.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {ISubaccount} from "../../userInterfaces/ISubaccount.sol";
import {ISubaccountsFacet} from "../../userInterfaces/facets/ISubaccountsFacet.sol";

/**
 * @title SubaccountProxy contract
 * @notice Per-Personal-Account subaccount proxy, shared by every subaccount type. The
 * controller is the beacon:
 * the implementation is resolved per subaccount type through {implementationForType},
 * so upgrades happen on the controller and the type is fixed at deployment.
 */
contract SubaccountProxy is Proxy {

    /// @notice MasterAccountController address used to resolve the implementation.
    address private immutable controller;
    /// @notice Subaccount type, fixed at deployment.
    uint256 private immutable subaccountType;

    /**
     * @notice Deploys the proxy and initializes the subaccount state.
     * @param _controller MasterAccountController address, used as the beacon.
     * @param _parentPersonalAccount Parent Personal Account address.
     * @param _subaccountType Subaccount type.
     */
    constructor(
        address _controller,
        address _parentPersonalAccount,
        uint256 _subaccountType
    ) {
        controller = _controller;
        subaccountType = _subaccountType;

        address impl = ISubaccountsFacet(_controller).implementationForType(_subaccountType);
        Address.functionDelegateCall(
            impl,
            abi.encodeCall(
                ISubaccount.initialize,
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
        return ISubaccountsFacet(controller).implementationForType(subaccountType);
    }
}
