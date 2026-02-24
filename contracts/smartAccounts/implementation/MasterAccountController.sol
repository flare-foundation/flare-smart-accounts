// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Diamond, DiamondArgs} from "../../diamond/implementation/Diamond.sol";
import {IDiamondCut} from "../../diamond/interfaces/IDiamondCut.sol";

/**
 * @title MasterAccountController contract
 * @notice The contract controlling personal accounts (XRPL master controller)
 */
contract MasterAccountController is Diamond {

    constructor(
        IDiamondCut.FacetCut[] memory _diamondCut,
        DiamondArgs memory _args
    )
        Diamond(_diamondCut, _args)
    { }
}
