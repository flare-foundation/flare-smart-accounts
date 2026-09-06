// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {MintableERC20} from "./MintableERC20.sol";

// the entry points a MockCallbackToken callback can fire from
uint8 constant CALLBACK_ON_TRANSFER = 1;
uint8 constant CALLBACK_ON_TRANSFER_FROM = 2;
uint8 constant CALLBACK_ON_APPROVE = 3;

/**
 * @title MockCallbackToken
 * @notice An ERC-20 with two configurable faults, both beyond what a production token does: a
 * recipient for which `transfer` and `transferFrom` return `false` instead of moving tokens,
 * and a callback fired from inside one entry point (`transfer`, `transferFrom` or `approve`)
 * when a chosen caller invokes it - the shape of a token that reenters, or mutates a
 * dependency, in the middle of a move. A failing callback is recorded, not bubbled, so the move
 * itself goes through and a test can assert exactly which guard stopped the callback.
 */
contract MockCallbackToken is MintableERC20 {
    address public falseRecipient;
    uint8 public callbackKind;
    address public callbackCaller;
    address public callbackTarget;
    bytes public callbackData;
    bytes public callbackError;
    uint256 public callbackCount;

    constructor(
        uint8 _decimals
    ) MintableERC20("Callback", "CBK", _decimals) {}

    /// @notice Transfers to `_recipient` return `false` without moving tokens.
    function setFalseRecipient(
        address _recipient
    )
        external
    {
        falseRecipient = _recipient;
    }

    /// @notice Fires `_target.call(_data)` from inside entry point `_kind` whenever `_caller` invokes it.
    function setCallback(
        uint8 _kind,
        address _caller,
        address _target,
        bytes calldata _data
    )
        external
    {
        callbackKind = _kind;
        callbackCaller = _caller;
        callbackTarget = _target;
        callbackData = _data;
    }

    function transfer(
        address _to,
        uint256 _value
    )
        public override
        returns (bool)
    {
        if (_to == falseRecipient) {
            return false;
        }
        _callback(CALLBACK_ON_TRANSFER);
        return super.transfer(_to, _value);
    }

    function transferFrom(
        address _from,
        address _to,
        uint256 _value
    )
        public override
        returns (bool)
    {
        if (_to == falseRecipient) {
            return false;
        }
        _callback(CALLBACK_ON_TRANSFER_FROM);
        return super.transferFrom(_from, _to, _value);
    }

    function approve(
        address _spender,
        uint256 _value
    )
        public override
        returns (bool)
    {
        _callback(CALLBACK_ON_APPROVE);
        return super.approve(_spender, _value);
    }

    function _callback(
        uint8 _kind
    )
        private
    {
        if (_kind != callbackKind || msg.sender != callbackCaller) {
            return;
        }
        callbackCount++;
        // solhint-disable-next-line avoid-low-level-calls
        (bool success, bytes memory result) = callbackTarget.call(callbackData);
        if (!success) {
            callbackError = result;
        }
    }
}
