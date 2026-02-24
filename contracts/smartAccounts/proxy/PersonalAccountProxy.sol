// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";

/**
 * @title PersonalAccountProxy contract
 * @dev controller address is beacon address
 */
contract PersonalAccountProxy is BeaconProxy {
    bytes4 constant private INITIALIZE_SELECTOR = bytes4(keccak256("initialize(address,string)"));

    constructor(address _controller, string memory _xrplOwner)
        BeaconProxy(
            _controller,
            abi.encodeWithSelector(INITIALIZE_SELECTOR, _controller, _xrplOwner)
        )
    {}
}