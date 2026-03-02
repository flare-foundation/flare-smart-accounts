// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LibDiamond} from "../../diamond/libraries/LibDiamond.sol";
import {ITimelockFacet} from "../../userInterfaces/facets/ITimelockFacet.sol";

library Timelock {

    /// @custom:storage-location erc7201:smartAccounts.Timelock.State
    struct State {
        // execution lock
        bool executing;
        // timelock duration (in seconds)
        uint256 timelockDurationSeconds;
        // mapping of timelocked calls
        mapping(bytes32 encodedCallHash => uint256 allowedAfterTimestamp) timelockedCalls;
    }

    bytes32 internal constant STATE_POSITION = keccak256(
        abi.encode(uint256(keccak256("smartAccounts.Timelock.State")) - 1)) & ~bytes32(uint256(0xff)
    );

    function beforeExecute() internal {
        State storage state = getState();
        if (state.executing) {
            // can only be run from executeTimelockedCall()
            // make sure nothing else gets executed, even in case of reentrancy
            assert(msg.sender == address(this));
            state.executing = false;
        } else {
            // must be called with: timelock duration = 0
            // must check owner in this case
            checkOnlyOwner();
        }
    }

    function recordTimelockedCall(bytes calldata _encodedCall) internal {
        State storage state = getState();
        checkOnlyOwner();
        bytes32 encodedCallHash = keccak256(_encodedCall);
        uint256 allowedAt = block.timestamp + state.timelockDurationSeconds;
        state.timelockedCalls[encodedCallHash] = allowedAt;
        emit ITimelockFacet.CallTimelocked(_encodedCall, encodedCallHash, allowedAt);
    }

    function timeToExecute() internal view returns (bool) {
        State storage state = getState();
        return state.executing || state.timelockDurationSeconds == 0;
    }

    function checkOnlyOwner() internal view {
        LibDiamond.enforceIsContractOwner();
    }

    function getState()
        internal pure
        returns (State storage _state)
    {
        bytes32 position = STATE_POSITION;
        // solhint-disable-next-line no-inline-assembly
        assembly {
            _state.slot := position
        }
    }
}