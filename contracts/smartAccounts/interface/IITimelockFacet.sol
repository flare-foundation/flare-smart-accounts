// SPDX-License-Identifier: MIT
pragma solidity >=0.7.6 <0.9;

import {ITimelockFacet} from "../../userInterfaces/facets/ITimelockFacet.sol";

/**
 * @title IITimelockFacet
 * @notice Internal interface for the TimelockFacet contract.
 */
interface IITimelockFacet is ITimelockFacet {

    /**
     * Cancel a timelocked call before it has been executed.
     * @dev Only owner can call this method.
     * @param _encodedCall ABI encoded call data (signature and parameters).
     */
    function cancelTimelockedCall(
        bytes calldata _encodedCall
    )
        external;

    /**
     * @notice Set the timelock duration in seconds.
     * @dev Only owner can call this method.
     * @param _timelockDurationSeconds The new timelock duration in seconds.
     */
    function setTimelockDuration(
        uint256 _timelockDurationSeconds
    )
        external;
}