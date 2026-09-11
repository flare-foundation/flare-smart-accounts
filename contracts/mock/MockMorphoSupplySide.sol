// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IMorpho} from "../smartAccounts/interface/IMorpho.sol";
import {MorphoMath} from "../smartAccounts/library/MorphoMath.sol";

/**
 * @title MockMorphoSupplySide
 * @notice Morpho's lender side with its totals under the test's control: what a supply is worth in
 * shares, what accrual adds, and the share price - which on a real market takes decades of interest
 * to lift above one base unit, and decides how far a landed supply can fall short of what went in.
 * {MockMorpho} models the borrower side, reporting no supply shares at all and a fixed supply
 * total, so the market script's funding phase is driven here instead. Share conversions come from
 * {MorphoMath}, the same code the accounts run.
 */
contract MockMorphoSupplySide {
    using SafeERC20 for IERC20;

    struct MarketState {
        uint128 totalSupplyAssets;
        uint128 totalSupplyShares;
        uint128 lastUpdate;
    }

    /// @notice Interest waiting to be applied on the next `accrueInterest` call, per market.
    mapping(bytes32 marketId => uint256 assets) public pendingInterest;

    mapping(bytes32 marketId => MarketState) private _markets;
    mapping(bytes32 marketId => mapping(address account => uint256 shares)) private _supplyShares;
    bool private _creditNothing;
    uint256 private _uncreditedShares;

    /// @notice Sets a market's supply totals, and with them its share price.
    function setMarket(
        bytes32 _id,
        uint128 _totalSupplyAssets,
        uint128 _totalSupplyShares
    )
        external
    {
        _markets[_id] = MarketState(_totalSupplyAssets, _totalSupplyShares, uint128(block.timestamp));
    }

    /// @notice Puts `_shares` of the market's supply in `_account`'s name.
    function setSupplyShares(
        bytes32 _id,
        address _account,
        uint256 _shares
    )
        external
    {
        _supplyShares[_id][_account] = _shares;
    }

    function addPendingInterest(
        bytes32 _id,
        uint256 _assets
    )
        external
    {
        pendingInterest[_id] += _assets;
    }

    /// @notice Makes `supply` take the tokens and credit no shares: a supply that did not land.
    function setCreditNothing(
        bool _nothing
    )
        external
    {
        _creditNothing = _nothing;
    }

    /// @notice Makes `supply` withhold `_shares` of what it credits: a supply that landed short by
    /// a chosen multiple of the share rounding, which is the line the funding phase draws.
    function setUncreditedShares(
        uint256 _shares
    )
        external
    {
        _uncreditedShares = _shares;
    }

    function accrueInterest(
        IMorpho.MarketParams calldata _marketParams
    )
        external
    {
        bytes32 id = MorphoMath.marketId(_marketParams);
        MarketState storage state = _markets[id];
        state.totalSupplyAssets += uint128(pendingInterest[id]);
        pendingInterest[id] = 0;
        state.lastUpdate = uint128(block.timestamp);
    }

    function supply(
        IMorpho.MarketParams calldata _marketParams,
        uint256 _assets,
        uint256,
        address _onBehalf,
        bytes calldata
    )
        external
        returns (uint256, uint256)
    {
        bytes32 id = MorphoMath.marketId(_marketParams);
        MarketState storage state = _markets[id];
        IERC20(_marketParams.loanToken).safeTransferFrom(msg.sender, address(this), _assets);
        if (_creditNothing) {
            return (_assets, 0);
        }
        uint256 shares =
            MorphoMath.toSharesDown(_assets, state.totalSupplyAssets, state.totalSupplyShares) - _uncreditedShares;
        state.totalSupplyAssets += uint128(_assets);
        state.totalSupplyShares += uint128(shares);
        _supplyShares[id][_onBehalf] += shares;
        return (_assets, shares);
    }

    function position(
        bytes32 _id,
        address _user
    )
        external view
        returns (uint256, uint128, uint128)
    {
        return (_supplyShares[_id][_user], 0, 0);
    }

    function market(
        bytes32 _id
    )
        external view
        returns (uint128, uint128, uint128, uint128, uint128, uint128)
    {
        MarketState storage state = _markets[_id];
        return (state.totalSupplyAssets, state.totalSupplyShares, 0, 0, state.lastUpdate, 0);
    }
}
