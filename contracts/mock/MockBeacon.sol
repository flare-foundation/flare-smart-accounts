// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

contract MockBeacon {
    address public implementation;
    constructor(address _impl) {
        implementation = _impl;
    }
}