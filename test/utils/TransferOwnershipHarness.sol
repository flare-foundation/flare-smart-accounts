// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {TransferOwnership} from "../../deployment/scripts/TransferOwnership.s.sol";

/**
 * @title TransferOwnershipHarness
 * @notice The ownership handover script with its console output captured, so a test can assert what
 * an operator reads before the one call that cannot be undone.
 */
contract TransferOwnershipHarness is TransferOwnership {

    string[] public lines;

    /// @notice Whether any captured line is exactly `_line`.
    function printed(
        string calldata _line
    )
        external view
        returns (bool)
    {
        for (uint256 i = 0; i < lines.length; i++) {
            if (keccak256(bytes(lines[i])) == keccak256(bytes(_line))) {
                return true;
            }
        }
        return false;
    }

    function _print(
        string memory _line
    )
        internal override
    {
        lines.push(_line);
    }
}
