// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {UUPSUpgradeable} from "@openzeppelin-contracts/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin-contracts-upgradeable/access/OwnableUpgradeable.sol";

/// @title MasterAccountControllerBase contract
/// @notice Minimal, upgradeable-only MasterAccountController seed used solely to stabilize CREATE2 init code.
/// Proxy is deployed pointing to this seed, then immediately upgraded to the real implementation and initialized.
contract MasterAccountControllerBase is UUPSUpgradeable, OwnableUpgradeable {

    error AlreadyInitialized();

    constructor() {
        // ensure the implementation contract itself cannot be initialized/used
        _disableInitializers();
    }

    /// @notice One-time initializer for setting the initial owner via proxy constructor call.
    /// Can be called only once when owner is unset.
    function seedInitOwner(address _initialOwner) external initializer {
        require(owner() == address(0), AlreadyInitialized()); // todo reduntant?
        __Ownable_init(_initialOwner);
    }

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address) internal virtual override onlyOwner {}
}