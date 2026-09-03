// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IMorpho} from "../interface/IMorpho.sol";

/**
 * @title MorphoMath
 * @notice Our own MIT implementation of the two pieces of Morpho Blue arithmetic the accounts
 * depend on: the market id (`keccak256(abi.encode(marketParams))`, Morpho's `MarketParamsLib.id`)
 * and the share/asset conversions with Morpho's virtual offsets (`SharesMathLib`: one virtual
 * asset, 1e6 virtual shares, rounding as named). Written here rather than imported because the
 * upstream libraries are GPL-2.0-or-later; equality with `morpho-blue` v1.0.0 (commit 55d2d99)
 * is pinned by `test/MorphoConformance.t.sol` on fixed vectors. The full-precision `mulDiv`
 * agrees with Morpho's checked multiplication everywhere Morpho itself does not revert.
 */
library MorphoMath {
    uint256 internal constant VIRTUAL_SHARES = 1e6;
    uint256 internal constant VIRTUAL_ASSETS = 1;

    /// @dev Morpho's market id for `_marketParams`.
    function marketId(IMorpho.MarketParams memory _marketParams) internal pure returns (bytes32) {
        return keccak256(abi.encode(_marketParams));
    }

    /// @dev Shares for `_assets`, rounded up.
    function toSharesUp(
        uint256 _assets,
        uint256 _totalAssets,
        uint256 _totalShares
    )
        internal pure
        returns (uint256)
    {
        return Math.mulDiv(
            _assets, _totalShares + VIRTUAL_SHARES, _totalAssets + VIRTUAL_ASSETS, Math.Rounding.Ceil
        );
    }

    /// @dev Shares for `_assets`, rounded down.
    function toSharesDown(
        uint256 _assets,
        uint256 _totalAssets,
        uint256 _totalShares
    )
        internal pure
        returns (uint256)
    {
        return Math.mulDiv(_assets, _totalShares + VIRTUAL_SHARES, _totalAssets + VIRTUAL_ASSETS);
    }

    /// @dev Assets for `_shares`, rounded up - what closing a borrow position costs.
    function toAssetsUp(
        uint256 _shares,
        uint256 _totalAssets,
        uint256 _totalShares
    )
        internal pure
        returns (uint256)
    {
        return Math.mulDiv(
            _shares, _totalAssets + VIRTUAL_ASSETS, _totalShares + VIRTUAL_SHARES, Math.Rounding.Ceil
        );
    }
}
