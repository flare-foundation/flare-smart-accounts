// SPDX-License-Identifier: MIT
pragma solidity >=0.8.4 <0.9;

import {IMorpho} from "./IMorpho.sol";

/**
 * @title IIrm
 * @notice Minimal Morpho Blue interest rate model interface: the two rate entry points, as in
 * the canonical `morpho-org/morpho-blue` `IIrm` v1.0.0. `borrowRateView` is what the account's
 * read surface uses to bring a market's debt forward to the current block the way Morpho's own
 * accrual will; `borrowRate` is the state-changing twin Morpho calls when it accrues. Kept as our
 * own MIT code because the upstream files are GPL-2.0-or-later; conformance is pinned by
 * `test/unit/smartAccounts/MorphoConformance.t.sol`.
 */
interface IIrm {
    /**
     * @notice Returns the borrow rate per second (WAD) of `marketParams`, updating the model's
     * state; called by Morpho on accrual.
     */
    function borrowRate(
        IMorpho.MarketParams memory marketParams,
        IMorpho.Market memory market
    )
        external
        returns (uint256);

    /**
     * @notice Returns the borrow rate per second (WAD) of `marketParams` without updating the
     * model's state.
     */
    function borrowRateView(
        IMorpho.MarketParams memory marketParams,
        IMorpho.Market memory market
    )
        external view
        returns (uint256);
}
