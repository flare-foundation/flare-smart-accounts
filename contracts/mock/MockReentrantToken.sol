// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {MintableERC20} from "./MintableERC20.sol";

/**
 * @title MockReentrantToken
 * @notice An ERC-20 whose `transfer` and `transferFrom` first call back into a configured
 * target - the shape of a malicious token trying to re-enter the account moving it. A failing
 * callback fails the transfer with the callback's own revert data bubbled up, so a test can
 * assert exactly which guard stopped the re-entry.
 */
contract MockReentrantToken is MintableERC20 {
    address public callbackTarget;
    bytes public callbackData;

    constructor() MintableERC20("Reentrant", "RNT", 18) {}

    function setCallback(address _target, bytes calldata _data) external {
        callbackTarget = _target;
        callbackData = _data;
    }

    function transfer(address _to, uint256 _amount) public override returns (bool) {
        _callback();
        return super.transfer(_to, _amount);
    }

    function transferFrom(address _from, address _to, uint256 _amount) public override returns (bool) {
        _callback();
        return super.transferFrom(_from, _to, _amount);
    }

    function _callback() private {
        if (callbackTarget == address(0)) return;
        // solhint-disable-next-line avoid-low-level-calls
        (bool ok, bytes memory returndata) = callbackTarget.call(callbackData);
        if (!ok) {
            // bubble the callback's revert data verbatim
            // solhint-disable-next-line no-inline-assembly
            assembly {
                revert(add(returndata, 32), mload(returndata))
            }
        }
    }
}
