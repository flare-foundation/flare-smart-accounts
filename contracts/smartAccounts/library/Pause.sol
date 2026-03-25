// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IPauseFacet} from "../../userInterfaces/facets/IPauseFacet.sol";
import {IIPauseFacet} from "../interface/IIPauseFacet.sol";

library Pause {
    using EnumerableSet for EnumerableSet.AddressSet;

    /// @custom:storage-location erc7201:smartAccounts.Pause.State
    struct State {
        bool paused;
        EnumerableSet.AddressSet pausers;
        EnumerableSet.AddressSet unpausers;
    }

    bytes32 internal constant STATE_POSITION = keccak256(
        abi.encode(uint256(keccak256("smartAccounts.Pause.State")) - 1)) & ~bytes32(uint256(0xff)
    );

    function pause() internal {
        State storage state = getState();
        state.paused = true;
    }

    function unpause() internal {
        State storage state = getState();
        state.paused = false;
    }

    function addPauser(
        address _account
    )
        internal
    {
        State storage state = getState();
        state.pausers.add(_account);
        emit IIPauseFacet.PauserAdded(_account);
    }

    function removePauser(
        address _account
    )
        internal
    {
        State storage state = getState();
        state.pausers.remove(_account);
        emit IIPauseFacet.PauserRemoved(_account);
    }

    function addUnpauser(
        address _account
    )
        internal
    {
        State storage state = getState();
        state.unpausers.add(_account);
        emit IIPauseFacet.UnpauserAdded(_account);
    }

    function removeUnpauser(
        address _account
    )
        internal
    {
        State storage state = getState();
        state.unpausers.remove(_account);
        emit IIPauseFacet.UnpauserRemoved(_account);
    }

    function checkNotPaused() internal view {
        require(!getState().paused, IPauseFacet.IsPaused());
    }

    function checkPauser(
        address _account
    )
        internal view
    {
        require(getState().pausers.contains(_account), IPauseFacet.NotPauser(_account));
    }

    function checkUnpauser(
        address _account
    )
        internal view
    {
        require(getState().unpausers.contains(_account), IPauseFacet.NotUnpauser(_account));
    }

    function getPausers()
        internal view
        returns (address[] memory)
    {
        return getState().pausers.values();
    }

    function getUnpausers()
        internal view
        returns (address[] memory)
    {
        return getState().unpausers.values();
    }

    function getState()
        internal pure
        returns (State storage _state)
    {
        bytes32 position = STATE_POSITION;
        // solhint-disable-next-line no-inline-assembly
        assembly {
            _state.slot := position
        }
    }
}
