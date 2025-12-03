// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Timelock} from "../library/Timelock.sol";

/**
 * @title FacetBase
 * @notice Base contract for facets that require owner-only access controls.
 */
abstract contract FacetBase is ReentrancyGuard {

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
