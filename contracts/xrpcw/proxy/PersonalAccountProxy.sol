// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "@openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../implementation/PersonalAccount.sol";

contract PersonalAccountProxy is ERC1967Proxy {
    constructor(
        address _implementationAddress,
        string memory _xrplOwner,
        address _controllerAddress
    )
        ERC1967Proxy(_implementationAddress,
            abi.encodeCall(
                PersonalAccount.initialize,
                (
                    _xrplOwner,
                    _controllerAddress
                )
            )
        )
    { }
}