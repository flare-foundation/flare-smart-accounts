// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Proxy} from "@openzeppelin/contracts/proxy/Proxy.sol";

/**
 * @notice A minimal proxy that delegates all calls to an implementation without calling initialize.
 * Useful for testing initialize() revert conditions on a fresh (zeroed) storage.
 */
contract UninitializedProxy is Proxy {
    address private immutable _impl;

    constructor(address impl) {
        _impl = impl;
    }

    function _implementation() internal view override returns (address) {
        return _impl;
    }
}
