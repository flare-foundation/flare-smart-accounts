// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title LoanMath
 * @notice The Flare fee's and the cover gate's arithmetic, in one place: the loan-chain
 * subaccount's actions compute with these functions and its read surface quotes with the same
 * ones, so a quote and the refusal it predicts cannot drift apart. Pure - every input is a plain
 * number the caller has already read.
 */
library LoanMath {
    /// @dev WAD fixed point: the fee rates' and the headroom's precision.
    uint256 internal constant WAD = 1e18;
    /// @dev The fee's year: annual WAD rates accrue over a fixed 365-day year.
    uint256 internal constant YEAR = 365 days;
    /// @dev The cover gate's headroom over Morpho's liquidation line (WAD): the collateral left
    /// after an action must be worth `EXIT_HEADROOM / LLTV` of the covered claim, where Morpho
    /// itself lets a position run down to `1 / LLTV` (its withdraw, borrow and liquidation tests
    /// are one and the same). At the launch market's 77% LLTV this is exactly 1.5x.
    uint256 internal constant EXIT_HEADROOM = 1.155e18;
    /// @dev The fee's weight in the covered claim, `debt + FEE_WEIGHT * collectible`: the junior
    /// claim behind the debt counts twice, so a debt-free exit needs 3x the collectible.
    /// Deliberately not liquidation-proof (the accepted junior-claim risk).
    uint256 internal constant FEE_WEIGHT = 2;

    /// @dev The cover gate's required cover, in loan tokens: `(debt + FEE_WEIGHT * collectible)
    /// * EXIT_HEADROOM / lltv`, rounded up; zero when nothing is owed.
    function requiredCover(
        uint256 _debt,
        uint256 _collectible,
        uint256 _lltv
    )
        internal pure
        returns (uint256)
    {
        uint256 claim = _debt + FEE_WEIGHT * _collectible;
        if (claim == 0) {
            return 0;
        }
        return Math.mulDiv(claim, EXIT_HEADROOM, _lltv, Math.Rounding.Ceil);
    }

    /// @dev The fee one elapsed period adds, at WAD precision (base units x 1e18):
    /// `max(P * floor * T / YEAR, I * WAD + P * spread * T / YEAR) - I * WAD` over the principal
    /// `P` at the period's start (base units), the WAD annual rates, the period's length `T` in
    /// seconds of the 365-day year, and the market interest `I = max(0, debtReached - P)` the
    /// period produced in base units, from the debt the principal reached - a debt that fell
    /// counts as zero interest, so the delta never underflows. Each rate term is one `mulDiv`
    /// rounded down, the interest exact. Zero for a zero principal or a zero period.
    function feeDeltaX18(
        uint256 _principal,
        uint256 _debtReached,
        uint256 _elapsed,
        uint256 _floor,
        uint256 _spread
    )
        internal pure
        returns (uint256)
    {
        if (_principal == 0 || _elapsed == 0) {
            return 0;
        }
        uint256 interestX18 = (_debtReached > _principal ? _debtReached - _principal : 0) * WAD;
        uint256 owedX18 = Math.max(
            Math.mulDiv(_principal * _floor, _elapsed, YEAR),
            interestX18 + Math.mulDiv(_principal * _spread, _elapsed, YEAR)
        );
        return owedX18 - interestX18;
    }

    /// @dev The fee's share of a payment short of debt plus fee, `payment * collectible / (debt +
    /// collectible)` rounded down; the remainder goes to the debt.
    function feeShare(
        uint256 _payment,
        uint256 _debt,
        uint256 _collectible
    )
        internal pure
        returns (uint256)
    {
        return Math.mulDiv(_payment, _collectible, _debt + _collectible);
    }
}
