// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MasterAccountControllerBase} from "../implementation/MasterAccountControllerBase.sol";

/**
 * @title MasterAccountControllerProxy contract
 */
contract MasterAccountControllerProxy is ERC1967Proxy {
    constructor(
        address _baseSeedImplementation,
        address _initialOwner
    )
        ERC1967Proxy(
            _baseSeedImplementation,
            abi.encodeWithSelector(MasterAccountControllerBase.initializeOwner.selector, _initialOwner)
        )
    {}
}
