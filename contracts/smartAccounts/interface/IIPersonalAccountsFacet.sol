// SPDX-License-Identifier: MIT
pragma solidity >=0.7.6 <0.9;

import {IPersonalAccountsFacet} from "../../userInterfaces/facets/IPersonalAccountsFacet.sol";

/**
 * @title IIPersonalAccountsFacet
 * @notice Internal interface for the PersonalAccountsFacet contract.
 */
interface IIPersonalAccountsFacet is IPersonalAccountsFacet {
    /**
     * @notice Sets new PersonalAccount implementation address.
     * @param _implementation New PersonalAccount implementation address.
     * Can only be called by the owner.
     */
    function setPersonalAccountImplementation(
        address _implementation
    )
        external;
}