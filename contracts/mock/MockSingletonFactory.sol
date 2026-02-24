// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

contract MockSingletonFactory {
    function deploy(bytes memory _initCode, bytes32 _salt) external payable returns (address deployed) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            deployed := create2(0, add(_initCode, 0x20), mload(_initCode), _salt)
        }
    }
}