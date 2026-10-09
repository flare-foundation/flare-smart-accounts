// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ExecuteDiamondCut} from "../../deployment/scripts/ExecuteDiamondCut.s.sol";

/**
 * @title ExecuteDiamondCutHarness
 * @notice Exposes the cut executor's internal guards for direct unit testing: the two name
 * guards, and the two the pinned bootstrap depends on - which diamond a cut may target, and
 * which address a pinned base facet is cut at. Driving `run()` for the pinned pair would need a
 * cut file under `deployment/cuts/`, which is read-only to tests, so the guards are exercised
 * where they are decided.
 */
contract ExecuteDiamondCutHarness is ExecuteDiamondCut {
    function requirePermittedCutTarget(address _diamond) external view {
        _requirePermittedCutTarget(_diamond);
    }

    function pinnedFacetAddress(string calldata _name) external view returns (address, bool) {
        return _pinnedFacetAddress(_name);
    }

    function validateFacetName(string calldata _name) external pure {
        _validateFacetName(_name);
    }

    function validateInitName(string calldata _name) external pure {
        _validateInitName(_name);
    }
}
