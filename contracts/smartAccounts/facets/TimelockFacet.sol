// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IITimelockFacet} from "../interface/IITimelockFacet.sol";
import {ITimelockFacet} from "../../userInterfaces/facets/ITimelockFacet.sol";
import {Timelock} from "../library/Timelock.sol";
import {FacetBase} from "./FacetBase.sol";

/**
 * @title TimelockFacet
 * @notice Facet for handling timelocked calls.
 */
contract TimelockFacet is IITimelockFacet, FacetBase {

    uint256 constant internal MAX_TIMELOCK_DURATION_SECONDS = 7 days;

    /// @inheritdoc ITimelockFacet
    function executeTimelockedCall(
        bytes calldata _encodedCall
    )
        external
    {
        Timelock.State storage state = Timelock.getState();
        bytes32 encodedCallHash = keccak256(_encodedCall);
        uint256 allowedAfterTimestamp = state.timelockedCalls[encodedCallHash];
        require(allowedAfterTimestamp != 0, TimelockInvalidSelector());
        require(block.timestamp >= allowedAfterTimestamp, TimelockNotAllowedYet());
        delete state.timelockedCalls[encodedCallHash];
        state.executing = true;
        //solhint-disable-next-line avoid-low-level-calls
        (bool success,) = address(this).call(_encodedCall);
        state.executing = false;
        emit TimelockedCallExecuted(encodedCallHash);
        _passReturnOrRevert(success);
    }

    /// @inheritdoc IITimelockFacet
    function cancelTimelockedCall(
        bytes calldata _encodedCall
    )
        external
        onlyOwner
    {
        Timelock.State storage state = Timelock.getState();
        bytes32 encodedCallHash = keccak256(_encodedCall);
        require(state.timelockedCalls[encodedCallHash] != 0, TimelockInvalidSelector());
        emit TimelockedCallCanceled(encodedCallHash);
        delete state.timelockedCalls[encodedCallHash];
    }

    /// @inheritdoc IITimelockFacet
    function setTimelockDuration(
        uint256 _timelockDurationSeconds
    )
        external
        onlyOwnerWithTimelock
    {
        require(_timelockDurationSeconds <= MAX_TIMELOCK_DURATION_SECONDS, TimelockDurationTooLong());
        Timelock.State storage state = Timelock.getState();
        state.timelockDurationSeconds = _timelockDurationSeconds;
        emit TimelockDurationSet(_timelockDurationSeconds);
    }

    /// @inheritdoc ITimelockFacet
    function getTimelockDurationSeconds()
        external view
        returns (uint256)
    {
        Timelock.State storage state = Timelock.getState();
        return state.timelockDurationSeconds;
    }

    /// @inheritdoc ITimelockFacet
    function getExecuteTimelockedCallTimestamp(
        bytes calldata _encodedCall
    )
        external view
        returns (uint256 _allowedAfterTimestamp)
    {
        Timelock.State storage state = Timelock.getState();
        bytes32 encodedCallHash = keccak256(_encodedCall);
        _allowedAfterTimestamp = state.timelockedCalls[encodedCallHash];
        require(_allowedAfterTimestamp != 0, TimelockInvalidSelector());
    }

    function _passReturnOrRevert(bool _success) internal pure {
        // pass exact return or revert data - needs to be done in assembly
        //solhint-disable-next-line no-inline-assembly
        assembly {
            let size := returndatasize()
            let ptr := mload(0x40)
            mstore(0x40, add(ptr, size))
            returndatacopy(ptr, 0, size)
            if _success {
                return(ptr, size)
            }
            revert(ptr, size)
        }
    }
}
