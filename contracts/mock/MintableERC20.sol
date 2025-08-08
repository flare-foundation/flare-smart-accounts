// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title Mintable ERC20 Token
/// @author Filip Koprivec
/// @notice Placeholder for the actual implementation of ERC20 interface.
contract MintableERC20 is ERC20 {
    /// @notice constructor
    /// @param name asset name
    /// @param symbol asset symbol
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    /// @notice Call mint on ERC20
    /// @param to receiving address
    /// @param amount amount
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
