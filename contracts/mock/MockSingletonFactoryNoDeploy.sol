// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

contract MockSingletonFactoryNoDeploy {
    function deploy(bytes memory _initCode, bytes32 _salt) external payable returns (address deployed) {
        // do nothing
    }
}