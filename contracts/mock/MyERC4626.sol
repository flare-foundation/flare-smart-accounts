// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ERC4626} from "@openzeppelin-contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin-contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin-contracts/token/ERC20/ERC20.sol";

/// @title Vault
/// @author Filip Koprivec
/// @notice This is the vault that is used by MasterAccountController contract only for demo purposes.
contract MyERC4626 is ERC4626 {
    /// @notice constructor
    /// @param baseAsset base asset address - FXRP
    /// @param name_ base asset name
    /// @param symbol_ base asset symbol
    constructor(
        IERC20 baseAsset,
        string memory name_,
        string memory symbol_
    ) ERC20(name_, symbol_) ERC4626(baseAsset) {}
}
