// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {BeaconProxy} from "@openzeppelin-contracts/proxy/beacon/BeaconProxy.sol";

/// @title PersonalAccountProxy contract
/// controller address is beacon address
contract PersonalAccountProxy is BeaconProxy {
    bytes4 constant private INITIALIZE_SELECTOR = bytes4(keccak256("initialize(string,address)"));

    constructor(address _beacon, string memory _xrplOwner, address _controller)
        BeaconProxy(
            _beacon,
            abi.encodeWithSelector(INITIALIZE_SELECTOR, _xrplOwner, _controller)
        )
    {}
}