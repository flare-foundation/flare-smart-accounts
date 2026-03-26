// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IPauseFacet} from "../../userInterfaces/facets/IPauseFacet.sol";

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

    function checkNotPaused() internal view {
        require(!getState().paused, IPauseFacet.IsPaused());
    }

    function isPauser(
        address _account
    )
        internal view
        returns (bool)
    {
        return getState().pausers.contains(_account);
    }

    function isUnpauser(
        address _account
    )
        internal view
        returns (bool)
    {
        return getState().unpausers.contains(_account);
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
