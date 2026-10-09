// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IMorpho} from "../smartAccounts/interface/IMorpho.sol";
import {IIrm} from "../smartAccounts/interface/IIrm.sol";

/**
 * @title MockIrm
 * @notice A Morpho interest rate model with one settable per-second WAD rate, returned by both
 * rate functions, so a test can make `MockMorpho` accrue real compounded interest and check that
 * the account's projections reproduce it; with a revert switch standing in for a dead model.
 */
// solhint-disable gas-calldata-parameters
contract MockIrm is IIrm {
    uint256 public rate;
    bool public reverts;

    function setRate(
        uint256 _rate
    )
        external
    {
        rate = _rate;
    }

    function setReverts(
        bool _reverts
    )
        external
    {
        reverts = _reverts;
    }

    /// @inheritdoc IIrm
    function borrowRate(
        IMorpho.MarketParams memory,
        IMorpho.Market memory
    )
        external view
        returns (uint256)
    {
        require(!reverts, "IRM reverted");
        return rate;
    }

    /// @inheritdoc IIrm
    function borrowRateView(
        IMorpho.MarketParams memory,
        IMorpho.Market memory
    )
        external view
        returns (uint256)
    {
        require(!reverts, "IRM reverted");
        return rate;
    }
}
