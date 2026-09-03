// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IControlledAccount} from "../../userInterfaces/IControlledAccount.sol";

/**
 * @title ControlledAccountBase
 * @notice The root of every account implementation: the controller, set once. Nothing else lives
 * here, so that the one linear storage field every lineage shares is exactly the one the
 * deployed Flare Personal Account already has.
 * @dev STORAGE RULE for the account bases: `controllerAddress` is slot 0, linear, in every
 * lineage - frozen by the production Flare Personal Account (slot 0 `controllerAddress`, slot 1
 * `xrplOwner`), which every base must reproduce. Every other base keeps its state in an ERC-7201
 * namespace, so bases can gain fields without shifting a derived lineage; derived contracts
 * append their own linear state after the linear base fields of their lineage.
 */
abstract contract ControlledAccountBase is IControlledAccount {

    /// @dev Written into slot 0 by the constructor, so the implementation contract itself can
    /// never pass an initializer's "not yet initialized" check.
    address internal constant EMPTY_ADDRESS = 0x0000000000000000000000000000000000001111;

    /// @inheritdoc IControlledAccount
    address public controllerAddress;

    constructor() {
        // ensure the implementation contract itself cannot be initialized/used
        controllerAddress = EMPTY_ADDRESS;
    }

    /// @dev One-time controller assignment for the derived account's `initialize`.
    function _setController(
        address _controllerAddress
    )
        internal
    {
        require(controllerAddress == address(0), AlreadyInitialized());
        require(_controllerAddress != address(0), InvalidControllerAddress());
        controllerAddress = _controllerAddress;
    }
}
