// SPDX-License-Identifier: MIT
pragma solidity >=0.7.6 <0.9;

import {IPauseFacet} from "../../userInterfaces/facets/IPauseFacet.sol";

/**
 * @title IIPauseFacet
 * @notice Internal interface for the PauseFacet contract.
 */
interface IIPauseFacet is IPauseFacet {

    /**
     * @notice Add pausers. Only callable by the owner (timelocked).
     * @param _pausers The addresses to add as pausers.
     */
    function addPausers(address[] calldata _pausers) external;

    /**
     * @notice Remove pausers. Only callable by the owner (timelocked: the delay keeps the
     * circuit breaker alive under an owner-key compromise).
     * @param _pausers The addresses to remove as pausers.
     */
    function removePausers(address[] calldata _pausers) external;

    /**
     * @notice Add unpausers. Only callable by the owner (timelocked).
     * @param _unpausers The addresses to add as unpausers.
     */
    function addUnpausers(address[] calldata _unpausers) external;

    /**
     * @notice Remove unpausers. Only callable by the owner — immediate, unlike the other role
     * changes: it can only keep the system paused, and is the remedy against a compromised
     * unpauser.
     * @param _unpausers The addresses to remove as unpausers.
     */
    function removeUnpausers(address[] calldata _unpausers) external;
}
