// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IERC173} from "../../contracts/diamond/interfaces/IERC173.sol";

/**
 * @title PinnedControllerStub
 * @notice The two answers a deployment script asks of a diamond before it sends anything - who owns
 * it, and what its timelock duration is - plus the transfer itself. Etched at the pinned
 * controller's address, it is what lets the scripts' own entry points be driven, rather than only
 * the checks behind them: both resolve that address and stop at it.
 *
 * The duration it reports is zero, which is what a freshly bootstrapped controller reports before
 * its configuration sets one.
 */
contract PinnedControllerStub is IERC173 {

    address private ownerAddress;

    /// @notice Sets the owner outright, which a real diamond only does through its constructor.
    function setOwner(
        address _owner
    )
        external
    {
        ownerAddress = _owner;
    }

    /// @inheritdoc IERC173
    function transferOwnership(
        address _newOwner
    )
        external override
    {
        ownerAddress = _newOwner;
    }

    /// @inheritdoc IERC173
    function owner()
        external view override
        returns (address)
    {
        return ownerAddress;
    }

    /// @notice A fresh controller's duration: nothing queues until the configuration sets one.
    function getTimelockDurationSeconds()
        external pure
        returns (uint256)
    {
        return 0;
    }
}
