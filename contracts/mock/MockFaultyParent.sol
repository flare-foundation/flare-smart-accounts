// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

// the receive behaviors of a MockFaultyParent
uint8 constant MODE_ACCEPT = 0;
uint8 constant MODE_REJECT = 1;
uint8 constant MODE_EXHAUST_GAS = 2;
uint8 constant MODE_REENTER = 3;

/**
 * @title MockFaultyParent
 * @notice A parent Personal Account stand-in whose `receive` misbehaves on demand, for the
 * value-forwarding paths a real Personal Account (it accepts native) cannot reach: it rejects
 * the value, burns the whole gas stipend, or reenters a configured target and records how that
 * attempt failed. Mode zero accepts.
 */
contract MockFaultyParent {
    uint8 public mode;
    address public target;
    bytes public data;
    bytes public callbackError;
    uint256 public calls;

    receive() external payable {
        _receiveValue();
    }

    /// @notice Sets the mode; `_target` and `_data` are the reentry call of {MODE_REENTER}.
    function configure(
        uint8 _mode,
        address _target,
        bytes calldata _data
    )
        external
    {
        mode = _mode;
        target = _target;
        data = _data;
    }

    function _receiveValue() private {
        require(mode != MODE_REJECT, "parent rejects");
        if (mode == MODE_EXHAUST_GAS) {
            // burns whatever stipend the forwarding call granted; the test bounds the outer gas
            while (gasleft() > 100) {
                calls++;
            }
            revert("gas consumed");
        }
        if (mode == MODE_REENTER) {
            calls++;
            // solhint-disable-next-line avoid-low-level-calls
            (bool success, bytes memory result) = target.call(data);
            if (!success) callbackError = result;
        }
    }
}
