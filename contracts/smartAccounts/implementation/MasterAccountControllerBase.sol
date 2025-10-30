// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";

/**
 * @title MasterAccountControllerBase contract
 * @notice Minimal, upgradeable-only MasterAccountController seed used solely to stabilize CREATE2 init code.
 * Proxy is deployed pointing to this seed, then immediately upgraded to the real implementation and initialized.
 */
contract MasterAccountControllerBase is UUPSUpgradeable, OwnableUpgradeable {

    constructor() {
        // ensure the implementation contract itself cannot be initialized/used
        _disableInitializers();
    }

    /// @notice One-time initializer for setting the initial owner via proxy constructor call.
    function initializeOwner(address _initialOwner) external initializer {
        __Ownable_init(_initialOwner);
    }

    /**
     * @return Current implementation address.
     */
    // expose current controller implementation address under a distinct name to avoid
    // collision with IBeacon.implementation()
    function controllerImplementation() external view returns (address) {
        return ERC1967Utils.getImplementation();
    }

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address) internal virtual override onlyOwner {}
}