// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ERC1967Proxy} from "@openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @title PersonalAccountProxy
/// @notice ERC1967Proxy that does not pass initialization data
/// Initialization is performed immediately after CREATE2 deployment by the
/// controller to keep the init code chain-agnostic.
contract PersonalAccountProxy is ERC1967Proxy {
    constructor(address _implementationAddress)
        ERC1967Proxy(_implementationAddress, bytes("") /* no init data */)
    {}
}
