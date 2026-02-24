// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IDiamondCut} from "../../diamond/interfaces/IDiamondCut.sol";
import {LibDiamond} from "../../diamond/libraries/LibDiamond.sol";
import {FacetBase} from "./FacetBase.sol";

/**
 * @title DiamondCutFacet
 * @notice Facet for adding/replacing/removing functions in a diamond.
 */
contract DiamondCutFacet is IDiamondCut, FacetBase {
    /**
     * @notice Add/replace/remove any number of functions and optionally execute
     *         a function with delegatecall
     * @param _diamondCut Contains the facet addresses and function selectors
     * @param _init The address of the contract or facet to execute _calldata
     * @param _calldata A function call, including function selector and arguments
     *                  _calldata is executed with delegatecall on _init
     */
    function diamondCut(
        FacetCut[] calldata _diamondCut,
        address _init,
        bytes calldata _calldata
    )
        external
        onlyOwnerWithTimelock
    {
        LibDiamond.diamondCut(_diamondCut, _init, _calldata);
    }
}
