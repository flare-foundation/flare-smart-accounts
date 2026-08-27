// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {MintableERC20} from "./MintableERC20.sol";

/**
 * @title MockFalseReturningToken
 * @notice An ERC-20 whose `transfer` reports failure by returning `false` instead of
 * reverting - the convention some real tokens follow, and the one a raw call cannot see.
 */
contract MockFalseReturningToken is MintableERC20 {
    constructor() MintableERC20("FalseReturning", "FLS", 18) {}

    function transfer(address, uint256) public pure override returns (bool) {
        return false;
    }
}
