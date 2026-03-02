// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title Mintable ERC20 Token
/// @author Filip Koprivec
/// @notice Placeholder for the actual implementation of ERC20 interface.
contract MintableERC20 is ERC20 {

    uint8 internal _decimals;

    /// @notice constructor
    /// @param name asset name
    /// @param symbol asset symbol
    /// @param decimals_ asset decimals
    constructor(string memory name, string memory symbol, uint8 decimals_) ERC20(name, symbol) {
        _decimals = decimals_;
    }

    /// @notice Override decimals
    /// @return uint8 decimals
    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    /// @notice Call mint on ERC20
    /// @param to receiving address
    /// @param amount amount
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
