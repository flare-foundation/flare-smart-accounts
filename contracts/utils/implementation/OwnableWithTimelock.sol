// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IOwnableWithTimelock} from "../../userInterfaces/IOwnableWithTimelock.sol";

/**
 * @title OwnableWithTimelock
 * @notice Ownable extension that timelocks selected owner calls using dedicated storage slot.
 */
abstract contract OwnableWithTimelock is OwnableUpgradeable, IOwnableWithTimelock {

    /// @custom:storage-location erc7201:utils.OwnableWithTimelock.State
    struct State {
        bool executing;
        uint256 timelockDurationSeconds;
        mapping(bytes32 encodedCallHash => uint256 allowedAfterTimestamp) timelockedCalls;
    }

    uint256 internal constant MAX_TIMELOCK_DURATION_SECONDS = 7 days;

    bytes32 internal constant STATE_POSITION = keccak256(
        abi.encode(uint256(keccak256("utils.OwnableWithTimelock.State")) - 1)
    ) & ~bytes32(uint256(0xff));

    modifier onlyOwnerWithTimelock() {
        if (_timeToExecuteTimelockedCall()) {
            _beforeExecuteTimelockedCall();
            _;
        } else {
            _recordTimelockedCall(msg.data);
        }
    }

    /// @inheritdoc IOwnableWithTimelock
    function executeTimelockedCall(
        bytes calldata _encodedCall
    )
        external
        virtual
    {
        State storage state = getState();
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

    /// @inheritdoc IOwnableWithTimelock
    function cancelTimelockedCall(
        bytes calldata _encodedCall
    )
        external
        virtual
        onlyOwner
    {
        State storage state = getState();
        bytes32 encodedCallHash = keccak256(_encodedCall);
        require(state.timelockedCalls[encodedCallHash] != 0, TimelockInvalidSelector());
        emit TimelockedCallCanceled(encodedCallHash);
        delete state.timelockedCalls[encodedCallHash];
    }

    /// @inheritdoc IOwnableWithTimelock
    function setTimelockDuration(
        uint256 _timelockDurationSeconds
    )
        external
        virtual
        onlyOwnerWithTimelock
    {
        State storage state = getState();
        require(_timelockDurationSeconds <= MAX_TIMELOCK_DURATION_SECONDS, TimelockDurationTooLong());
        state.timelockDurationSeconds = _timelockDurationSeconds;
        emit TimelockDurationSet(_timelockDurationSeconds);
    }

    /// @inheritdoc IOwnableWithTimelock
    function getTimelockDurationSeconds()
        public
        view
        virtual
        returns (uint256)
    {
        State storage state = getState();
        return state.timelockDurationSeconds;
    }

    /// @inheritdoc IOwnableWithTimelock
    function getExecuteTimelockedCallTimestamp(
        bytes calldata _encodedCall
    )
        public
        view
        virtual
        returns (uint256 _allowedAfterTimestamp)
    {
        State storage state = getState();
        bytes32 encodedCallHash = keccak256(_encodedCall);
        _allowedAfterTimestamp = state.timelockedCalls[encodedCallHash];
        require(_allowedAfterTimestamp != 0, TimelockInvalidSelector());
    }

    function _beforeExecuteTimelockedCall()
        internal
        virtual
    {
        State storage state = getState();
        if (state.executing) {
            assert(msg.sender == address(this));
            state.executing = false;
        } else {
            _checkOwner();
        }
    }

    function _recordTimelockedCall(
        bytes calldata _encodedCall
    )
        internal
        virtual
    {
        State storage state = getState();
        _checkOwner();
        bytes32 encodedCallHash = keccak256(_encodedCall);
        uint256 allowedAt = block.timestamp + state.timelockDurationSeconds;
        state.timelockedCalls[encodedCallHash] = allowedAt;
        emit CallTimelocked(_encodedCall, encodedCallHash, allowedAt);
    }

    function _timeToExecuteTimelockedCall()
        internal
        view
        virtual
        returns (bool)
    {
        State storage state = getState();
        return state.executing || state.timelockDurationSeconds == 0;
    }

    function _passReturnOrRevert(
        bool _success
    )
        internal
        pure
        virtual
    {
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

    function getState()
        internal
        pure
        returns (State storage _state)
    {
        bytes32 position = STATE_POSITION;
        //solhint-disable-next-line no-inline-assembly
        assembly {
            _state.slot := position
        }
    }
}
