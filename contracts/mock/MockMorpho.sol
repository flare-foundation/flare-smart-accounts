// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IMorpho} from "../smartAccounts/interface/IMorpho.sol";
import {MintableERC20} from "./MintableERC20.sol";

/**
 * @title MockMorpho
 * @notice Behavioral Morpho mock: collateral is actually pulled and held, borrows mint the
 * loan token to the receiver and record debt, and repays pull and burn the loan token against
 * the recorded debt (over-repaying reverts, as real Morpho does), so tests exercise real
 * balance and position invariants instead of stubbed return values.
 */
contract MockMorpho is IMorpho {
    using SafeERC20 for IERC20;

    struct Position {
        uint256 collateral;
        uint256 debt;
    }

    /// @notice Positions by account, standing in for real Morpho's per-market positions.
    mapping(address account => Position) public positions;

    /// @inheritdoc IMorpho
    function supplyCollateral(
        MarketParams calldata marketParams,
        uint256 assets,
        address onBehalf,
        bytes calldata /* data */
    )
        external
    {
        IERC20(marketParams.collateralToken).safeTransferFrom(msg.sender, address(this), assets);
        positions[onBehalf].collateral += assets;
    }

    /// @inheritdoc IMorpho
    function borrow(
        MarketParams calldata marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        address receiver
    )
        external
        returns (uint256, uint256)
    {
        require(shares == 0, "shares not modeled");
        require(msg.sender == onBehalf, "unauthorized");
        positions[onBehalf].debt += assets;
        // stands in for market liquidity leaving the pool
        MintableERC20(marketParams.loanToken).mint(receiver, assets);
        return (assets, 0);
    }

    /// @inheritdoc IMorpho
    /// @dev Position health is not modeled; tests exercise flows, not liquidation math.
    function withdrawCollateral(
        MarketParams calldata marketParams,
        uint256 assets,
        address onBehalf,
        address receiver
    )
        external
    {
        require(msg.sender == onBehalf, "unauthorized");
        require(assets <= positions[onBehalf].collateral, "withdraw exceeds collateral");
        positions[onBehalf].collateral -= assets;
        IERC20(marketParams.collateralToken).safeTransfer(receiver, assets);
    }

    /// @inheritdoc IMorpho
    function repay(
        MarketParams calldata marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        bytes calldata /* data */
    )
        external
        returns (uint256, uint256)
    {
        require(shares == 0, "shares not modeled");
        // real Morpho reverts when repaying more than the outstanding debt
        require(assets <= positions[onBehalf].debt, "repay exceeds debt");
        positions[onBehalf].debt -= assets;
        IERC20(marketParams.loanToken).safeTransferFrom(msg.sender, address(this), assets);
        MintableERC20(marketParams.loanToken).burn(address(this), assets);
        return (assets, 0);
    }
}
