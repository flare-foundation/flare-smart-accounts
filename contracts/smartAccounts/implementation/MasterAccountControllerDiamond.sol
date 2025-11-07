// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Diamond, DiamondArgs} from "../../diamond/implementation/Diamond.sol";
import {IDiamondCut} from "../../diamond/interfaces/IDiamondCut.sol";

/**
 * MasterAccountControllerDiamond is the Diamond implementation for MasterAccountController contract.
 */
contract MasterAccountControllerDiamond is Diamond {

    constructor(
        IDiamondCut.FacetCut[] memory _diamondCut,
        DiamondArgs memory _args
    )
        Diamond(_diamondCut, _args)
    { }
}
