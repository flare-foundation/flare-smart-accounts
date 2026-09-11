// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {
    DeployRemoteControllerThrowaway
} from "../../deployment/scripts/DeployRemoteControllerThrowaway.s.sol";

/**
 * @title DeployRemoteControllerThrowawayHarness
 * @notice The throwaway deployment with its recorder lines captured instead of printed. Those lines
 * are the deployment record's only source, so a test that wants to know what a run would record has
 * to read them rather than the chain.
 */
contract DeployRemoteControllerThrowawayHarness is DeployRemoteControllerThrowaway {

    string[] public recorded;

    function recordedCount()
        external view
        returns (uint256)
    {
        return recorded.length;
    }

    function clearRecorded()
        external
    {
        delete recorded;
    }

    /// @dev The production line, captured rather than printed: what a test reads is exactly what an
    /// operator's run would emit and the recorder would parse.
    function _logDeployed(
        string memory _name,
        string memory _contractName,
        address _address
    )
        internal override
    {
        recorded.push(deployedLine(_name, _contractName, _address));
    }
}
