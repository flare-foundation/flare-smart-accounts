// SPDX-License-Identifier: MIT
pragma solidity >=0.7.6 <0.9;

import {IPauseFacet} from "../../userInterfaces/facets/IPauseFacet.sol";

/**
 * @title IIPauseFacet
 * @notice Internal interface for the PauseFacet contract.
 */
interface IIPauseFacet is IPauseFacet {

    /**
     * @notice Emitted when a pauser is added.
     * @param account The pauser address.
     */
    event PauserAdded(address indexed account);

    /**
     * @notice Emitted when a pauser is removed.
     * @param account The pauser address.
     */
    event PauserRemoved(address indexed account);

    /**
     * @notice Emitted when an unpauser is added.
     * @param account The unpauser address.
     */
    event UnpauserAdded(address indexed account);

    /**
     * @notice Emitted when an unpauser is removed.
     * @param account The unpauser address.
     */
    event UnpauserRemoved(address indexed account);

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
