// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IMorpho} from "../smartAccounts/interface/IMorpho.sol";
import {IIrm} from "../smartAccounts/interface/IIrm.sol";
import {IOracle} from "../smartAccounts/interface/IOracle.sol";
import {MorphoMath} from "../smartAccounts/library/MorphoMath.sol";
import {MintableERC20} from "./MintableERC20.sol";

/**
 * @title MockMorpho
 * @notice Behavioral Morpho mock with per-market positions and totals, virtual-share
 * conversions, interest (compounded from the market's IRM when it has code, as canonical
 * accrual does, plus test-queued amounts), a supply total that bounds borrowing as canonical
 * liquidity does, and over-repay reverts (as real Morpho's share-math underflow does), so the
 * repay clamp is exercised against real share math instead of stubbed values.
 * `borrow` and `withdrawCollateral` run the canonical health check - accrue, read the market
 * oracle, require `collateral · price / 1e36 · lltv >= debt` while borrow shares are live - so a
 * dead oracle or an under-collateralized position reverts here as it does in Morpho; the check
 * is switchable for tests that exercise the account's arithmetic under leverage a real market
 * would not allow.
 *
 * Its liquidation entries are money-flow simulations rather than Morpho's `liquidate`, and are
 * named so: they accrue first and refuse a debt-free position, but no health condition gates
 * them, no oracle or liquidation incentive converts seized collateral into repaid shares (a
 * partial seizes pro rata, a full seizes all of it), and bad debt is never realized. That is
 * enough for what the accounts actually observe - a debt that shrank without their involvement,
 * leaving `feePrincipal` stale - which is what the adversarial suite drives them for. Canonical
 * liquidation itself is judged where it can be: against real Morpho on the fork suite,
 * `test/integration/LoanSubaccountRemoteMorphoFork.t.sol`.
 *
 * Ids and share conversions come from {MorphoMath}, the same code the accounts run.
 */
contract MockMorpho is IMorpho {
    using SafeERC20 for IERC20;

    struct MarketState {
        uint128 totalSupplyAssets;
        uint128 totalBorrowAssets;
        uint128 totalBorrowShares;
        uint128 lastUpdate;
    }

    struct PositionState {
        uint128 borrowShares;
        uint128 collateral;
    }

    uint256 private constant ORACLE_PRICE_SCALE = 1e36;
    uint256 private constant WAD = 1e18;
    /// @dev The supply every market starts with: effectively unbounded liquidity unless a test
    /// lowers it with `setTotalSupplyAssets`.
    uint128 private constant DEFAULT_SUPPLY = 1e30;

    /// @notice Interest waiting to be applied on the next `accrueInterest` call, per market.
    mapping(bytes32 marketId => uint256 assets) public pendingInterest;

    bool public accrueInterestReverts;
    /// @notice Skips the canonical health check in `borrow` and `withdrawCollateral`.
    bool public healthCheckDisabled;
    mapping(bytes32 marketId => MarketState) private _markets;
    mapping(bytes32 marketId => MarketParams) private _params;
    mapping(bytes32 marketId => mapping(address account => PositionState)) private _positions;

    /// @notice Creates a market, as real Morpho's permissionless `createMarket` does; the
    /// settings validation requires a non-zero `lastUpdate`. The params are kept for the accrual's
    /// IRM call.
    function createMarket(MarketParams calldata marketParams) external {
        bytes32 id = _id(marketParams);
        _markets[id].lastUpdate = uint128(block.timestamp);
        _markets[id].totalSupplyAssets = DEFAULT_SUPPLY;
        _params[id] = marketParams;
    }

    /// @notice Sets a market's supply total: canonical Morpho lends only up to it, so a lower
    /// value stands in for a thin pool.
    function setTotalSupplyAssets(bytes32 marketId, uint128 assets) external {
        _markets[marketId].totalSupplyAssets = assets;
    }

    /// @notice Queues interest on a market's debt, applied on the next `accrueInterest`.
    function addPendingInterest(bytes32 marketId, uint256 assets) external {
        pendingInterest[marketId] += assets;
    }

    /// @notice Makes `accrueInterest` revert, standing in for a broken or hostile IRM.
    function setAccrueInterestReverts(bool _reverts) external {
        accrueInterestReverts = _reverts;
    }

    /// @notice Switches the canonical health check off (or back on) for tests that exercise
    /// the account's gate arithmetic under leverage a real market would not allow.
    function setHealthCheckDisabled(bool _disabled) external {
        healthCheckDisabled = _disabled;
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
    /// @dev As canonical Morpho: accrues, then - with live borrow shares - reads the market
    /// oracle and requires the position to stay healthy, so a dead oracle or an
    /// under-collateralized position reverts here before the account's own logic can matter.
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
        _accrue(id);
        _positions[id][onBehalf].collateral -= uint128(assets);
        if (_positions[id][onBehalf].borrowShares != 0) {
            _requireHealthy(marketParams, id, onBehalf);
        }
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

        uint256 sharesUp = MorphoMath.toSharesUp(assets, m.totalBorrowAssets, m.totalBorrowShares);
        m.totalBorrowAssets += uint128(assets);
        m.totalBorrowShares += uint128(sharesUp);
        _positions[id][onBehalf].borrowShares += uint128(sharesUp);
        _requireHealthy(marketParams, id, onBehalf);
        // canonical: the pool lends only what it holds
        require(m.totalBorrowAssets <= m.totalSupplyAssets, "insufficient liquidity");
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
            shares = MorphoMath.toSharesDown(assets, m.totalBorrowAssets, m.totalBorrowShares);
        } else {
            assets = MorphoMath.toAssetsUp(shares, m.totalBorrowAssets, m.totalBorrowShares);
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
        return (m.totalSupplyAssets, 0, m.totalBorrowAssets, m.totalBorrowShares, m.lastUpdate, 0);
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
        uint256 assets = MorphoMath.toAssetsUp(shares, m.totalBorrowAssets, m.totalBorrowShares);
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

    /// @dev The one accrual routine, shared by `accrueInterest`, `borrow`, `repay`,
    /// `withdrawCollateral` and the liquidation, as in canonical Morpho - so the broken-IRM
    /// switch breaks them all.
    function _accrue(bytes32 id) private {
        require(!accrueInterestReverts, "IRM reverted");
        MarketState storage m = _markets[id];
        uint256 interest = pendingInterest[id];
        pendingInterest[id] = 0;
        // canonical `_accrueInterest`: with an IRM, the borrow total compounds at its rate over
        // the elapsed time (third-order Taylor), and the supply total grows by the same interest
        MarketParams memory params = _params[id];
        uint256 elapsed = block.timestamp - m.lastUpdate;
        if (elapsed != 0 && params.irm.code.length != 0) {
            uint256 rate = IIrm(params.irm).borrowRate(params, _marketView(id));
            interest += MorphoMath.wMulDown(m.totalBorrowAssets, MorphoMath.wTaylorCompounded(rate, elapsed));
        }
        m.totalBorrowAssets += SafeCast.toUint128(interest);
        m.totalSupplyAssets += SafeCast.toUint128(interest);
        m.lastUpdate = uint128(block.timestamp);
    }

    /// @dev The market's totals as the canonical `Market` struct the IRM is handed.
    function _marketView(bytes32 id) private view returns (IMorpho.Market memory) {
        MarketState storage m = _markets[id];
        return IMorpho.Market(m.totalSupplyAssets, 0, m.totalBorrowAssets, m.totalBorrowShares, m.lastUpdate, 0);
    }

    /// @dev Canonical `_isHealthy`: the collateral's oracle value at the market's LLTV must
    /// cover the rounded-up debt. The oracle read is live, so a reverting oracle reverts here.
    function _requireHealthy(
        MarketParams calldata marketParams,
        bytes32 id,
        address account
    )
        private view
    {
        if (healthCheckDisabled) {
            return;
        }
        PositionState storage p = _positions[id][account];
        MarketState storage m = _markets[id];
        uint256 price = IOracle(marketParams.oracle).price();
        uint256 borrowed = MorphoMath.toAssetsUp(p.borrowShares, m.totalBorrowAssets, m.totalBorrowShares);
        uint256 maxBorrow = Math.mulDiv(
            Math.mulDiv(p.collateral, price, ORACLE_PRICE_SCALE), marketParams.lltv, WAD
        );
        require(maxBorrow >= borrowed, "insufficient collateral");
    }

    function _id(MarketParams calldata marketParams) private pure returns (bytes32) {
        return MorphoMath.marketId(marketParams);
    }
}
