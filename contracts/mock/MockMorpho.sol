// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IMorpho} from "../smartAccounts/interface/IMorpho.sol";
import {MintableERC20} from "./MintableERC20.sol";

/**
 * @title MockMorpho
 * @notice Behavioral Morpho mock with per-market positions and totals, virtual-share
 * conversions, queued interest and over-repay reverts (as real Morpho's share-math underflow
 * does), so the repay clamp is exercised against real share math instead of stubbed values.
 * Position health and liquidation eligibility are intentionally not modeled.
 */
contract MockMorpho is IMorpho {
    using SafeERC20 for IERC20;

    struct MarketState {
        uint128 totalBorrowAssets;
        uint128 totalBorrowShares;
        uint128 lastUpdate;
    }

    struct PositionState {
        uint128 borrowShares;
        uint128 collateral;
    }

    uint256 private constant VIRTUAL_SHARES = 1e6;
    uint256 private constant VIRTUAL_ASSETS = 1;

    /// @notice Interest waiting to be applied on the next `accrueInterest` call, per market.
    mapping(bytes32 marketId => uint256 assets) public pendingInterest;

    bool public accrueInterestReverts;
    mapping(bytes32 marketId => MarketState) private _markets;
    mapping(bytes32 marketId => mapping(address account => PositionState)) private _positions;

    /// @notice Creates a market, as real Morpho's permissionless `createMarket` does; the
    /// settings validation requires a non-zero `lastUpdate`.
    function createMarket(MarketParams calldata marketParams) external {
        _markets[_id(marketParams)].lastUpdate = uint128(block.timestamp);
    }

    /// @notice Queues interest on a market's debt, applied on the next `accrueInterest`.
    function addPendingInterest(bytes32 marketId, uint256 assets) external {
        pendingInterest[marketId] += assets;
    }

    /// @notice Makes `accrueInterest` revert, standing in for a broken or hostile IRM.
    function setAccrueInterestReverts(bool _reverts) external {
        accrueInterestReverts = _reverts;
    }

    /// @notice Simulates a full external liquidation: the CALLER repays the account's whole
    /// debt and receives the seized collateral - entirely outside the account. Health and
    /// the liquidation incentive are not modeled; the money flow is.
    function simulateLiquidation(MarketParams calldata marketParams, address account) external {
        bytes32 id = _id(marketParams);
        _simulateLiquidation(marketParams, account, _positions[id][account].borrowShares);
    }

    /// @notice Simulates a partial external liquidation of `shares` borrow shares: the caller
    /// repays them and seizes proportional collateral; the position keeps its remaining debt.
    function simulatePartialLiquidation(
        MarketParams calldata marketParams,
        address account,
        uint128 shares
    )
        external
    {
        _simulateLiquidation(marketParams, account, shares);
    }

    /// @inheritdoc IMorpho
    function accrueInterest(MarketParams calldata marketParams) external {
        bytes32 id = _id(marketParams);
        require(_markets[id].lastUpdate != 0, "market not created");
        _accrue(id);
    }

    /// @inheritdoc IMorpho
    function supplyCollateral(
        MarketParams calldata marketParams,
        uint256 assets,
        address onBehalf,
        bytes calldata /* data */
    )
        external
    {
        bytes32 id = _id(marketParams);
        require(_markets[id].lastUpdate != 0, "market not created");
        IERC20(marketParams.collateralToken).safeTransferFrom(msg.sender, address(this), assets);
        _positions[id][onBehalf].collateral += uint128(assets);
    }

    /// @inheritdoc IMorpho
    /// @dev Canonical Morpho accrues interest and oracle-checks position health here when
    /// borrow shares are live; the mock models neither (tests exercise account flows, and
    /// the live-debt/dead-oracle blocking premise belongs to the integration harness).
    function withdrawCollateral(
        MarketParams calldata marketParams,
        uint256 assets,
        address onBehalf,
        address receiver
    )
        external
    {
        bytes32 id = _id(marketParams);
        require(msg.sender == onBehalf, "unauthorized");
        require(assets <= _positions[id][onBehalf].collateral, "withdraw exceeds collateral");
        _positions[id][onBehalf].collateral -= uint128(assets);
        IERC20(marketParams.collateralToken).safeTransfer(receiver, assets);
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
        require(shares == 0, "borrow by shares not modeled");
        require(msg.sender == onBehalf, "unauthorized");
        bytes32 id = _id(marketParams);
        MarketState storage m = _markets[id];
        require(m.lastUpdate != 0, "market not created");
        // canonical Morpho accrues before converting, so the exchange rate is never stale
        _accrue(id);

        uint256 sharesUp = _toSharesUp(assets, m.totalBorrowAssets, m.totalBorrowShares);
        m.totalBorrowAssets += uint128(assets);
        m.totalBorrowShares += uint128(sharesUp);
        _positions[id][onBehalf].borrowShares += uint128(sharesUp);
        // stands in for market liquidity leaving the pool
        MintableERC20(marketParams.loanToken).mint(receiver, assets);
        return (assets, sharesUp);
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
        require((assets == 0) != (shares == 0), "exactly one of assets/shares");
        bytes32 id = _id(marketParams);
        MarketState storage m = _markets[id];
        require(m.lastUpdate != 0, "market not created");
        // canonical Morpho accrues before converting, so the exchange rate is never stale
        _accrue(id);

        if (shares == 0) {
            shares = _toSharesDown(assets, m.totalBorrowAssets, m.totalBorrowShares);
        } else {
            assets = _toAssetsUp(shares, m.totalBorrowAssets, m.totalBorrowShares);
        }
        // real Morpho underflows here when repaying more shares than the position owes
        require(
            shares <= _positions[id][onBehalf].borrowShares,
            "repay exceeds debt"
        );
        _positions[id][onBehalf].borrowShares -= uint128(shares);
        m.totalBorrowShares -= uint128(shares);
        m.totalBorrowAssets = assets >= m.totalBorrowAssets
            ? 0
            : m.totalBorrowAssets - uint128(assets);
        IERC20(marketParams.loanToken).safeTransferFrom(msg.sender, address(this), assets);
        MintableERC20(marketParams.loanToken).burn(address(this), assets);
        return (assets, shares);
    }

    /// @inheritdoc IMorpho
    function position(
        bytes32 id,
        address user
    )
        external view
        returns (uint256, uint128, uint128)
    {
        PositionState storage p = _positions[id][user];
        return (0, p.borrowShares, p.collateral);
    }

    /// @inheritdoc IMorpho
    function market(
        bytes32 id
    )
        external view
        returns (uint128, uint128, uint128, uint128, uint128, uint128)
    {
        MarketState storage m = _markets[id];
        return (0, 0, m.totalBorrowAssets, m.totalBorrowShares, m.lastUpdate, 0);
    }

    /// @dev Canonical accounting: interest accrues first, a debt-free position cannot be
    /// liquidated, and totals shrink by the assets the repaid shares represent. The money
    /// flow is real Morpho's too: repaid loan tokens are pulled from the caller (and burned,
    /// like `repay`), seized collateral goes to the caller - past the borrower entirely.
    function _simulateLiquidation(
        MarketParams calldata marketParams,
        address account,
        uint128 shares
    )
        private
    {
        bytes32 marketId = _id(marketParams);
        PositionState storage p = _positions[marketId][account];
        MarketState storage m = _markets[marketId];
        require(shares > 0 && shares <= p.borrowShares, "no debt to liquidate");
        _accrue(marketId);
        uint256 assets = _toAssetsUp(shares, m.totalBorrowAssets, m.totalBorrowShares);
        uint128 seized = shares == p.borrowShares
            ? p.collateral
            : uint128(Math.mulDiv(p.collateral, shares, p.borrowShares));
        p.borrowShares -= shares;
        m.totalBorrowShares -= shares;
        m.totalBorrowAssets = assets >= m.totalBorrowAssets
            ? 0
            : m.totalBorrowAssets - uint128(assets);
        p.collateral -= seized;
        IERC20(marketParams.loanToken).safeTransferFrom(msg.sender, address(this), assets);
        MintableERC20(marketParams.loanToken).burn(address(this), assets);
        IERC20(marketParams.collateralToken).safeTransfer(msg.sender, seized);
    }

    /// @dev The one accrual routine, shared by `accrueInterest`, `borrow`, `repay` and the
    /// liquidation, as in canonical Morpho - so the broken-IRM switch breaks them all.
    function _accrue(bytes32 id) private {
        require(!accrueInterestReverts, "IRM reverted");
        MarketState storage m = _markets[id];
        m.totalBorrowAssets += SafeCast.toUint128(pendingInterest[id]);
        pendingInterest[id] = 0;
        m.lastUpdate = uint128(block.timestamp);
    }

    function _id(MarketParams calldata marketParams) private pure returns (bytes32) {
        return keccak256(abi.encode(marketParams));
    }

    function _toSharesUp(
        uint256 _assets,
        uint256 _totalAssets,
        uint256 _totalShares
    )
        private pure
        returns (uint256)
    {
        return Math.mulDiv(
            _assets, _totalShares + VIRTUAL_SHARES, _totalAssets + VIRTUAL_ASSETS,
            Math.Rounding.Ceil
        );
    }

    function _toSharesDown(
        uint256 _assets,
        uint256 _totalAssets,
        uint256 _totalShares
    )
        private pure
        returns (uint256)
    {
        return Math.mulDiv(_assets, _totalShares + VIRTUAL_SHARES, _totalAssets + VIRTUAL_ASSETS);
    }

    function _toAssetsUp(
        uint256 _shares,
        uint256 _totalAssets,
        uint256 _totalShares
    )
        private pure
        returns (uint256)
    {
        return Math.mulDiv(
            _shares, _totalAssets + VIRTUAL_ASSETS, _totalShares + VIRTUAL_SHARES,
            Math.Rounding.Ceil
        );
    }
}
