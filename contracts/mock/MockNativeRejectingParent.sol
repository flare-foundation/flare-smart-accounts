// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/**
 * @title MockNativeRejectingParent
 * @notice A parent Personal Account stand-in that cannot receive native: it has no `receive`
 * and no `fallback`, so every plain value transfer to it reverts, while {callWithValue} still
 * lets it drive its subaccount's parent-only methods. Used to pin the refund and
 * value-forwarding failure paths (`RefundFailed`), which a real Personal Account - it accepts
 * native - cannot reach.
 */
contract MockNativeRejectingParent {

    /// @notice Calls `_target` with `_value` and `_data`, bubbling any revert data verbatim.
    function callWithValue(
        address _target,
        uint256 _value,
        bytes calldata _data
    )
        external
        returns (bytes memory)
    {
        (bool success, bytes memory returndata) = _target.call{value: _value}(_data);
        if (!success) {
            // solhint-disable-next-line no-inline-assembly
            assembly {
                revert(add(returndata, 32), mload(returndata))
            }
        }
        return returndata;
    }
}
