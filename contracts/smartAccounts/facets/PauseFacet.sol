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
        require(Pause.isPauser(msg.sender), NotPauser(msg.sender));
        Pause.getState().paused = true;
        emit Paused(msg.sender);
    }

    /// @inheritdoc IPauseFacet
    function unpause() external {
        require(Pause.isUnpauser(msg.sender), NotUnpauser(msg.sender));
        Pause.getState().paused = false;
        emit Unpaused(msg.sender);
    }

    /// @inheritdoc IIPauseFacet
    function addPausers(
        address[] calldata _pausers
    )
        external
        onlyOwnerWithTimelock
    {
        Pause.State storage state = Pause.getState();
        for (uint256 i = 0; i < _pausers.length; i++) {
            require(state.pausers.add(_pausers[i]), PauserAlreadyAdded(_pausers[i]));
            emit PauserAdded(_pausers[i]);
        }
    }

    /// @inheritdoc IIPauseFacet
    function removePausers(
        address[] calldata _pausers
    )
        external
        onlyOwnerWithTimelock
    {
        Pause.State storage state = Pause.getState();
        for (uint256 i = 0; i < _pausers.length; i++) {
            require(state.pausers.remove(_pausers[i]), NotPauser(_pausers[i]));
            emit PauserRemoved(_pausers[i]);
        }
    }

    /// @inheritdoc IIPauseFacet
    function addUnpausers(
        address[] calldata _unpausers
    )
        external
        onlyOwnerWithTimelock
    {
        Pause.State storage state = Pause.getState();
        for (uint256 i = 0; i < _unpausers.length; i++) {
            require(state.unpausers.add(_unpausers[i]), UnpauserAlreadyAdded(_unpausers[i]));
            emit UnpauserAdded(_unpausers[i]);
        }
    }

    /// @inheritdoc IIPauseFacet
    function removeUnpausers(
        address[] calldata _unpausers
    )
        external
        onlyOwnerWithTimelock
    {
        Pause.State storage state = Pause.getState();
        for (uint256 i = 0; i < _unpausers.length; i++) {
            require(state.unpausers.remove(_unpausers[i]), NotUnpauser(_unpausers[i]));
            emit UnpauserRemoved(_unpausers[i]);
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
        return Pause.isPauser(_account);
    }

    /// @inheritdoc IPauseFacet
    function isUnpauser(
        address _account
    )
        external view
        returns (bool)
    {
        return Pause.isUnpauser(_account);
    }

    /// @inheritdoc IPauseFacet
    function getPausers()
        external view
        returns (address[] memory)
    {
        return Pause.getState().pausers.values();
    }

    /// @inheritdoc IPauseFacet
    function getUnpausers()
        external view
        returns (address[] memory)
    {
        return Pause.getState().unpausers.values();
    }
}
