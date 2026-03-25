// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IIPauseFacet} from "../interface/IIPauseFacet.sol";
// import is needed for @inheritdoc
// solhint-disable-next-line no-unused-import
import {IPauseFacet} from "../../userInterfaces/facets/IPauseFacet.sol";
import {Pause} from "../library/Pause.sol";
import {FacetBase} from "./FacetBase.sol";

/**
 * @title PauseFacet
 * @notice Facet for pausing and unpausing the contract.
 */
contract PauseFacet is IIPauseFacet, FacetBase {
    using EnumerableSet for EnumerableSet.AddressSet;

    /// @inheritdoc IPauseFacet
    function pause() external {
        Pause.checkPauser(msg.sender);
        Pause.pause();
        emit Paused(msg.sender);
    }

    /// @inheritdoc IPauseFacet
    function unpause() external {
        Pause.checkUnpauser(msg.sender);
        Pause.unpause();
        emit Unpaused(msg.sender);
    }

    /// @inheritdoc IIPauseFacet
    function addPausers(
        address[] calldata _pausers
    )
        external
        onlyOwnerWithTimelock
    {
        for (uint256 i = 0; i < _pausers.length; i++) {
            Pause.addPauser(_pausers[i]);
        }
    }

    /// @inheritdoc IIPauseFacet
    function removePausers(
        address[] calldata _pausers
    )
        external
        onlyOwnerWithTimelock
    {
        for (uint256 i = 0; i < _pausers.length; i++) {
            Pause.removePauser(_pausers[i]);
        }
    }

    /// @inheritdoc IIPauseFacet
    function addUnpausers(
        address[] calldata _unpausers
    )
        external
        onlyOwnerWithTimelock
    {
        for (uint256 i = 0; i < _unpausers.length; i++) {
            Pause.addUnpauser(_unpausers[i]);
        }
    }

    /// @inheritdoc IIPauseFacet
    function removeUnpausers(
        address[] calldata _unpausers
    )
        external
        onlyOwnerWithTimelock
    {
        for (uint256 i = 0; i < _unpausers.length; i++) {
            Pause.removeUnpauser(_unpausers[i]);
        }
    }

    /// @inheritdoc IPauseFacet
    function isPaused()
        external view
        returns (bool)
    {
        return Pause.getState().paused;
    }

    /// @inheritdoc IPauseFacet
    function isPauser(
        address _account
    )
        external view
        returns (bool)
    {
        return Pause.getState().pausers.contains(_account);
    }

    /// @inheritdoc IPauseFacet
    function isUnpauser(
        address _account
    )
        external view
        returns (bool)
    {
        return Pause.getState().unpausers.contains(_account);
    }

    /// @inheritdoc IPauseFacet
    function getPausers()
        external view
        returns (address[] memory)
    {
        return Pause.getPausers();
    }

    /// @inheritdoc IPauseFacet
    function getUnpausers()
        external view
        returns (address[] memory)
    {
        return Pause.getUnpausers();
    }
}
