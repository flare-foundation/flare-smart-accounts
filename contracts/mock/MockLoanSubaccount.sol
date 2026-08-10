// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LoanSubaccount} from "../smartAccounts/implementation/LoanSubaccount.sol";

/**
 * @title MockLoanSubaccount
 * @notice Loan subaccount implementation with a parent-restricted method, used to exercise the
 * XRPL instruction -> Personal Account -> loan subaccount dispatch path before the real restricted
 * methods exist. New state is appended after the base contract's slots.
 */
contract MockLoanSubaccount is LoanSubaccount {

    /// @notice Number of times {ping} was called.
    uint256 public pingCount;
    /// @notice Caller of the last {ping}.
    address public lastPingCaller;
    /// @notice Value received by the last {ping}.
    uint256 public lastPingValue;

    event Pinged(address caller, uint256 value);

    function ping()
        external payable
        onlyParent
    {
        pingCount += 1;
        lastPingCaller = msg.sender;
        lastPingValue = msg.value;
        emit Pinged(msg.sender, msg.value);
    }
}
