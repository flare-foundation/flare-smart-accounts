// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {UUPSUpgradeable} from "@openzeppelin-contracts/proxy/utils/UUPSUpgradeable.sol";
import {ERC1967Utils} from "@openzeppelin-contracts/proxy/ERC1967/ERC1967Utils.sol";
import {IPersonalAccount} from "../../userInterfaces/IPersonalAccount.sol";

/// @title PersonalAccountBase contract
/// @notice Minimal, upgradeable-only PersonalAccount seed used solely to stabilize CREATE2 init code.
/// Proxies are deployed pointing to this seed, then initialized and immediately upgraded to the real implementation.
contract PersonalAccountBase is UUPSUpgradeable, IPersonalAccount {
    address private constant EMPTY_ADDRESS = 0x0000000000000000000000000000000000001111;

    /// @notice MasterAccountController contract address
    address public controllerAddress;
    /// @notice XRPL address
    string public xrplOwner;

    modifier onlyController() {
        require(msg.sender == controllerAddress, OnlyController());
        _;
    }

    constructor() {
        // ensure the implementation contract itself cannot be initialized/used
        controllerAddress = EMPTY_ADDRESS;
    }

    /**
     * Proxyable initialization method. Can be called only once, from the proxy constructor
     */
    function initialize(
        string memory _xrplOwner,
        address _controllerAddress
    )
        external
    {
        require(controllerAddress == address(0), AlreadyInitialized());
        require(_controllerAddress != address(0), InvalidControllerAddress());
        require(bytes(_xrplOwner).length > 0, InvalidXrplOwner());

        xrplOwner = _xrplOwner;
        controllerAddress = _controllerAddress;
    }

    /// @inheritdoc IPersonalAccount
    function implementation()
        external view
        returns (address)
    {
        return ERC1967Utils.getImplementation();
    }

    /*
     * @inheritdoc UUPSUpgradeable
     * @dev Only the controller can call upgrade functions.
     */
    function _authorizeUpgrade(address _newImplementation) internal override onlyController {}
}
