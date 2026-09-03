// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IBeacon} from "@openzeppelin/contracts/proxy/beacon/IBeacon.sol";
import {IPersonalAccountBase} from "../../userInterfaces/IPersonalAccountBase.sol";
import {ControlledAccountBase} from "./ControlledAccountBase.sol";

/**
 * @title PersonalAccountBase
 * @notice The identity shared by every Personal Account implementation - the Flare account and
 * its compose-driven remote twin: the XRPL owner, the frozen-proxy `initialize`, and the
 * beacon lookup. What the account can do on its chain is the derived contract's.
 * @dev STORAGE: `xrplOwner` is slot 1, linear, right after {ControlledAccountBase}'s slot 0 -
 * the production Flare Personal Account's layout, which this base reproduces exactly and which
 * every Personal Account implementation on every chain therefore shares. Anything a Personal
 * Account base ever needs beyond these two fields goes into a namespace.
 */
abstract contract PersonalAccountBase is IPersonalAccountBase, ControlledAccountBase {

    /// @inheritdoc IPersonalAccountBase
    string public xrplOwner;

    /// @inheritdoc IPersonalAccountBase
    function initialize(
        address _controllerAddress,
        string calldata _xrplOwner
    )
        external
    {
        _setController(_controllerAddress);
        require(bytes(_xrplOwner).length > 0, InvalidXrplOwner());
        xrplOwner = _xrplOwner;
        emit PersonalAccountInitialized(_controllerAddress, _xrplOwner);
    }

    /// @inheritdoc IPersonalAccountBase
    function implementation()
        external view
        returns (address)
    {
        // controller is the beacon
        return IBeacon(controllerAddress).implementation();
    }
}
