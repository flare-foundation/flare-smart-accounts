// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {MintableERC20} from "./MintableERC20.sol";

/// @title Freezable ERC20 Token
/// @notice Models a regulated stablecoin (RLUSD) that can freeze addresses: any transfer
/// from or to a frozen address reverts. Used to pin that a refused surplus push never rolls
/// back a repayment.
contract MockFreezableToken is MintableERC20 {

    mapping(address account => bool) public frozen;

    error FrozenAccount(address account);

    constructor(
        string memory name,
        string memory symbol,
        uint8 decimals_
    ) MintableERC20(name, symbol, decimals_) {}

    function setFrozen(address _account, bool _frozen) external {
        frozen[_account] = _frozen;
    }

    function _update(address _from, address _to, uint256 _value) internal override {
        require(!frozen[_from], FrozenAccount(_from));
        require(!frozen[_to], FrozenAccount(_to));
        super._update(_from, _to, _value);
    }
}
