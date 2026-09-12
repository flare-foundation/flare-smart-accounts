// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ConfigureRemoteController} from "../../deployment/scripts/ConfigureRemoteController.s.sol";

/**
 * @title ConfigureRemoteControllerHarness
 * @notice The remote controller's configuration script with its console output captured and its file
 * write held in memory, so a test can assert what an operator reads - the skips, the notes and the
 * prepared calldata - without the script touching the working tree.
 */
contract ConfigureRemoteControllerHarness is ConfigureRemoteController {

    string[] public lines;
    /// @dev Set, the record the resolver reads instead of the deployment's own.
    string public recordPath;
    /// @dev The same for the pinned target's record.
    string public pinnedRecordPath;
    string public written;
    string public writtenTo;

    function lineCount()
        external view
        returns (uint256)
    {
        return lines.length;
    }

    /// @notice Whether any captured line starts with `_prefix`.
    function printed(
        string memory _prefix
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

    /// @notice The record the resolver will read, pointed at a directory a test may write to.
    /// `deployment/deploys` is read-only to forge and holds the real records; the scratch file lives
    /// under `deployment/output-internal`, which the cut flow already writes to.
    function setThrowawayRecordPath(
        string memory _path
    )
        external
    {
        recordPath = _path;
    }

    function throwawayRecordPath(
        string memory _network
    )
        public view override
        returns (string memory)
    {
        return bytes(recordPath).length > 0 ? recordPath : super.throwawayRecordPath(_network);
    }

    /// @notice The pinned target's record, likewise pointed at a file a test may write.
    function setDeploymentRecordPath(
        string memory _path
    )
        external
    {
        pinnedRecordPath = _path;
    }

    function deploymentRecordPath(
        string memory _network
    )
        public view override
        returns (string memory)
    {
        return bytes(pinnedRecordPath).length > 0 ? pinnedRecordPath : super.deploymentRecordPath(_network);
    }

    /// @notice The range check, exposed: a configuration value that does not fit its field must
    /// stop the run rather than wrap into a different, plausible one.
    function bounded(
        uint256 _value,
        uint256 _max,
        string memory _field
    )
        external pure
        returns (uint256)
    {
        return _bounded(_value, _max, _field);
    }

    /// @notice The duplicate check, exposed.
    function requireNoDuplicates(
        address[] memory _addresses,
        string memory _field
    )
        external pure
    {
        _requireNoDuplicates(_addresses, _field);
    }

    function _writeCalls(
        string memory _network,
        string memory _section,
        string memory _lines
    )
        internal override
    {
        writtenTo = string.concat("deployment/output-internal/", _network, "/configuration-", _section, ".txt");
        written = _lines;
        _print(string.concat("WROTE: ", writtenTo));
    }

    function _print(
        string memory _line
    )
        internal override
    {
        lines.push(_line);
    }
}
