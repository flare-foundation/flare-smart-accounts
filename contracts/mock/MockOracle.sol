// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IOracle} from "../smartAccounts/interface/IOracle.sol";

/**
 * @title MockOracle
 * @notice Settable Morpho-convention market oracle (1e36-scaled collateral price in loan
 * tokens), with a revert switch standing in for a dead or bricked oracle.
 */
contract MockOracle is IOracle {
    uint256 public storedPrice;
    bool public priceReverts;

    constructor(uint256 _price) {
        storedPrice = _price;
    }

    function setPrice(uint256 _price) external {
        storedPrice = _price;
    }

    function setPriceReverts(bool _reverts) external {
        priceReverts = _reverts;
    }

    /// @inheritdoc IOracle
    function price() external view returns (uint256) {
        require(!priceReverts, "oracle reverted");
        return storedPrice;
    }
}
