// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Timelock} from "../library/Timelock.sol";

/**
 * @title FacetBase
 * @notice Base contract for facets that require owner-only access controls.
 */
abstract contract FacetBase {

    modifier onlyOwnerWithTimelock {
        if (Timelock.timeToExecute()) {
            Timelock.beforeExecute();
            _;
        } else {
            Timelock.recordTimelockedCall(msg.data);
        }
    }

    modifier onlyOwner {
        Timelock.checkOnlyOwner();
        _;
    }
}
