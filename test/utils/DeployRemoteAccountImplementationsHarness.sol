// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {DeployRemoteAccountImplementations} from
    "../../deployment/scripts/DeployRemoteAccountImplementations.s.sol";

/**
 * @title DeployRemoteAccountImplementationsHarness
 * @notice The remote implementations deploy with its console output captured, so a test can assert
 * what an operator reads: which implementations the run announces as deployed, and that a run
 * deploying nothing still names the network rather than finishing in silence.
 */
contract DeployRemoteAccountImplementationsHarness is DeployRemoteAccountImplementations {

    string[] public lines;

    function lineCount()
        external view
        returns (uint256)
    {
        return lines.length;
    }

    /// @notice Whether any captured line starts with `_prefix`.
    function printed(
        string calldata _prefix
    )
        external view
        returns (bool)
    {
        bytes memory prefix = bytes(_prefix);
        for (uint256 i = 0; i < lines.length; i++) {
            bytes memory line = bytes(lines[i]);
            if (line.length < prefix.length) {
                continue;
            }
            bool same = true;
            for (uint256 j = 0; j < prefix.length; j++) {
                if (line[j] != prefix[j]) {
                    same = false;
                    break;
                }
            }
            if (same) {
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
