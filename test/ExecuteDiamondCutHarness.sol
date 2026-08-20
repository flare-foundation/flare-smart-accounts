// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ExecuteDiamondCut} from "../deployment/scripts/ExecuteDiamondCut.s.sol";

/**
 * @title ExecuteDiamondCutHarness
 * @notice Exposes the cut executor's internal name guards for direct unit testing.
 */
contract ExecuteDiamondCutHarness is ExecuteDiamondCut {
    function validateFacetName(string calldata _name) external pure {
        _validateFacetName(_name);
    }

    function validateInitName(string calldata _name) external pure {
        _validateInitName(_name);
    }
}
