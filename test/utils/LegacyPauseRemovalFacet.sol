// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {FacetBase} from "../../contracts/smartAccounts/facets/FacetBase.sol";
import {Pause} from "../../contracts/smartAccounts/library/Pause.sol";
import {IPauseFacet} from "../../contracts/userInterfaces/facets/IPauseFacet.sol";

/// @notice Reproduces only origin/main's timelocked removeUnpausers body and its shared storage.
/// The migration test installs this single historical selector, not a historical full deployment.
contract LegacyPauseRemovalFacet is FacetBase {
    using EnumerableSet for EnumerableSet.AddressSet;

    function removeUnpausers(
        address[] calldata _unpausers
    )
        external
        onlyOwnerWithTimelock
    {
        Pause.State storage state = Pause.getState();
        for (uint256 i = 0; i < _unpausers.length; i++) {
            require(
                state.unpausers.remove(_unpausers[i]),
                IPauseFacet.NotUnpauser(_unpausers[i])
            );
            emit IPauseFacet.UnpauserRemoved(_unpausers[i]);
        }
    }
}
