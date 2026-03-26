// SPDX-License-Identifier: MIT
pragma solidity >=0.7.6 <0.9;

import {IPauseFacet} from "../../userInterfaces/facets/IPauseFacet.sol";

/**
 * @title IIPauseFacet
 * @notice Internal interface for the PauseFacet contract.
 */
interface IIPauseFacet is IPauseFacet {

    /**
     * @notice Add pausers. Only callable by owner.
     * @param _pausers The addresses to add as pausers.
     */
    function addPausers(address[] calldata _pausers) external;

    /**
     * @notice Remove pausers. Only callable by owner.
     * @param _pausers The addresses to remove as pausers.
     */
    function removePausers(address[] calldata _pausers) external;

    /**
     * @notice Add unpausers. Only callable by owner.
     * @param _unpausers The addresses to add as unpausers.
     */
    function addUnpausers(address[] calldata _unpausers) external;

    /**
     * @notice Remove unpausers. Only callable by owner.
     * @param _unpausers The addresses to remove as unpausers.
     */
    function removeUnpausers(address[] calldata _unpausers) external;
}
