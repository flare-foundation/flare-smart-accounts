// SPDX-License-Identifier: MIT
pragma solidity >=0.7.6 <0.9;

/**
 * @title IISingletonFactory
 * @notice Internal interface for Singleton Factory contract.
 */
interface IISingletonFactory {
    function deploy(
        bytes memory _initCode,
        bytes32 _salt
    )
        external
        returns (address _deployedAddress);
}