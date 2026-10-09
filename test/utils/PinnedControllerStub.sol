// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IERC173} from "../../contracts/diamond/interfaces/IERC173.sol";
import {FunctionNotFound} from "../../contracts/diamond/implementation/Diamond.sol";

/**
 * @title PinnedControllerStub
 * @notice The two answers a deployment script asks of a diamond before it sends anything - who owns
 * it, and what its timelock duration is - plus the transfer itself. Etched at the pinned
 * controller's address, it is what lets the scripts' own entry points be driven, rather than only
 * the checks behind them: both resolve that address and stop at it.
 *
 * The duration it reports is zero, which is what a freshly bootstrapped controller reports before
 * its configuration sets one. Every other selector gets the answer a diamond gives for one it does
 * not serve - `FunctionNotFound` naming that selector - so a caller that tolerates exactly that
 * revert, and nothing else, is exercised against the real shape rather than a bare failure.
 */
contract PinnedControllerStub is IERC173 {

    address private ownerAddress;

    /// @dev A diamond's own answer for a selector no facet serves. Not payable, unlike the real
    /// one: this fallback only ever reverts, so it can receive nothing, and declaring it payable
    /// would force a payable cast at every call site of a test double for no behavior at all.
    // solhint-disable-next-line payable-fallback
    fallback() external {
        revert FunctionNotFound(msg.sig);
    }

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
