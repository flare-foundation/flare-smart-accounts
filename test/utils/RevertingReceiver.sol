// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

contract RevertingReceiver {
    receive() external payable {
        revert("ERR");
    }
}
