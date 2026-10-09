// SPDX-License-Identifier: MIT
pragma solidity >=0.7.6 <0.9;

import {ISubaccountsFacet} from "../../userInterfaces/facets/ISubaccountsFacet.sol";

/**
 * @title IISubaccountsFacet
 * @notice Internal interface for the SubaccountsFacet contract.
 */
interface IISubaccountsFacet is ISubaccountsFacet {
    /**
     * @notice Sets the subaccount implementation for a subaccount type.
     * @param _subaccountType The subaccount type.
     * @param _implementation New subaccount implementation address.
     * Can only be called by the owner (timelocked).
     */
    function setSubaccountImplementation(
        uint256 _subaccountType,
        address _implementation
    )
        external;
}
