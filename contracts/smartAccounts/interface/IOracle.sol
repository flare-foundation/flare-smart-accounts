// SPDX-License-Identifier: MIT
pragma solidity >=0.8.4 <0.9;

/**
 * @title IOracle
 * @notice Minimal interface of a Morpho Blue market oracle: the price of one collateral-token
 * asset quoted in loan-token assets, scaled by 1e36 (token decimals are baked into the scale,
 * so `loanAmount = mulDiv(collateralAmount, price, 1e36)` - no second decimals adjustment).
 * The interface carries no freshness or timestamp field; trusting it is part of trusting the
 * write-once market it belongs to, exactly as the market's own liquidations already do.
 */
interface IOracle {
    /**
     * @notice Returns the price of one collateral asset in loan-token assets, 1e36-scaled.
     */
    function price() external view returns (uint256);
}
