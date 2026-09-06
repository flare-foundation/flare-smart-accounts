// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {LoanRemoteFixture} from "../utils/LoanRemoteFixture.sol";
import {ILoanSubaccountRemote} from "../../contracts/userInterfaces/ILoanSubaccountRemote.sol";
import {MorphoMath} from "../../contracts/smartAccounts/library/MorphoMath.sol";

/**
 * @title LoanFeeFuzzTest
 * @notice Property tests over the Flare fee arithmetic of `LoanSubaccountRemote`, each stated as
 * the spec's formula computed here independently of the account: the pro-rata split of an
 * underfunded repayment, the covering repayment, the accrual over three periods with a terms
 * change in between (priced at the snapshotted terms, never compounding) and the exit gate. The
 * health check is on; every position stays within the fixture's 10,000 FXRP of collateral at
 * 2 RLUSD.
 * @dev The assertions sit in small helpers because `forge coverage` compiles without via-ir.
 */
contract LoanFeeFuzzTest is LoanRemoteFixture {
    struct Terms {
        uint64 floor;
        uint64 spread;
    }

    struct Period {
        uint256 elapsed;
        uint256 interest;
    }

    /// @dev Below the market's 77% of the fixture's 20,000 RLUSD of collateral value.
    uint256 private constant MAX_DEBT = 10_000e18;
    /// @dev The exit gate's constants, as the spec states them: the cover is
    /// `(D + FEE_WEIGHT * F) * EXIT_HEADROOM / LLTV`, rounded up.
    uint256 private constant EXIT_HEADROOM = 1.155e18;
    uint256 private constant FEE_WEIGHT = 2;

    function setUp() public {
        _setUpRemoteFixture();
    }

    /// A payment short of debt plus fee pays floor(P * F / (D + F)) to the fee and the rest to the
    /// debt; with one borrower and no interest the share math is exact, so the debt, the fee state
    /// and every loan-token balance are pinned to the unit. The round-down can leave exactly the
    /// debt, which then closes by shares.
    function testFuzzUnderfundedRepaySplitsProRata(
        uint256 _debtSeed,
        uint64 _feeFloor,
        uint32 _elapsed,
        uint256 _payment
    )
        public
    {
        (uint256 debt, uint256 fee, uint256 feeX18) = _accrueFloorOnly(_debtSeed, _feeFloor, _elapsed);
        vm.assume(debt + fee > 1);
        uint256 payment = bound(_payment, 1, debt + fee - 1);
        uint256 feeShare = Math.mulDiv(payment, fee, debt + fee);
        uint256 debtPaid = Math.min(payment - feeShare, debt);
        uint256 parentBefore = loanToken.balanceOf(parent);

        loanToken.mint(address(account), payment);
        assertEq(account.repay(), debtPaid);

        _assertFeeState(debt - debtPaid, feeX18 - feeShare * WAD, fee - feeShare);
        assertEq(_debt(), debt - debtPaid);
        assertEq(loanToken.balanceOf(collector), feeShare);
        assertEq(loanToken.balanceOf(address(account)), 0);
        assertEq(loanToken.balanceOf(parent), parentBefore);
    }

    /// A payment of at least debt plus fee closes the debt by shares, pays the whole collectible
    /// and pushes the surplus to the parent; only the sub-unit carry stays owed.
    function testFuzzCoveringRepayPaysTheFeeAndPushesTheSurplus(
        uint256 _debtSeed,
        uint64 _feeFloor,
        uint32 _elapsed,
        uint256 _surplus
    )
        public
    {
        (uint256 debt, uint256 fee, uint256 feeX18) = _accrueFloorOnly(_debtSeed, _feeFloor, _elapsed);
        uint256 surplus = bound(_surplus, 0, 1_000_000e18);
        uint256 parentBefore = loanToken.balanceOf(parent);

        loanToken.mint(address(account), debt + fee + surplus);
        assertEq(account.repay(), debt);

        _assertFeeState(0, feeX18 - fee * WAD, 0);
        assertLt(feeX18 - fee * WAD, WAD);
        assertEq(_shares(), 0);
        assertEq(loanToken.balanceOf(collector), fee);
        assertEq(loanToken.balanceOf(parent), parentBefore + surplus);
        assertEq(loanToken.balanceOf(address(account)), 0);
    }

    /// Each checkpoint accrues Morpho itself, charges max(floor * D * t, interest + spread * D * t)
    /// - interest on the period's principal at the terms snapshotted when the period began, and
    /// re-baselines the principal to the live debt. Three periods, with a terms change after the
    /// first: the second period is still priced at the old terms and the third at the new; every
    /// period charges on the live debt alone, so the fee never compounds.
    function testFuzzAccrualFollowsTheFormulaWithoutCompounding(
        uint256 _debtSeed,
        uint64 _feeFloor,
        uint64 _feeSpread,
        uint64 _nextFeeFloor,
        uint64 _nextFeeSpread,
        uint32 _elapsed,
        uint256 _interest
    )
        public
    {
        uint256 debt = bound(_debtSeed, 1, MAX_DEBT);
        Terms memory first = Terms(uint64(bound(_feeFloor, 0, WAD)), uint64(bound(_feeSpread, 0, WAD)));
        Terms memory next = Terms(uint64(bound(_nextFeeFloor, 0, WAD)), uint64(bound(_nextFeeSpread, 0, WAD)));
        _setTerms(1, first.floor, first.spread);
        _open(debt);

        uint256 principal = debt;
        principal = _accrueAndCheckpoint(principal, _period(_elapsed, _interest, debt, 1), first, first);
        // a mid-loan terms change prices nothing already elapsed: it applies from the next checkpoint on
        _setTerms(1, next.floor, next.spread);
        principal = _accrueAndCheckpoint(principal, _period(_elapsed, _interest, debt, 2), first, next);
        _accrueAndCheckpoint(principal, _period(_elapsed, _interest, debt, 3), next, next);
    }

    /// A withdraw passes the exit gate iff the collateral it would leave, at the oracle's price
    /// (rounded down), is worth at least `(D + 2F) x 1.155 / LLTV` (rounded up) for the live debt D
    /// and the collectible F; a refusal is `InsufficientRemainingCollateral(required, remaining)`,
    /// changes nothing and leaves the id unused. The gate implies Morpho's health check, so a covered
    /// withdrawal executes. Prices span 1e30 to 1e50 with a four-digit mantissa, so below 1e36 the
    /// valuation is inexact and the rounding direction is exercised.
    function testFuzzExitGateTracksTheRemainingCollateralValue(
        uint256 _debtSeed,
        uint256 _amount,
        uint16 _priceMantissa,
        uint8 _priceExponent
    )
        public
    {
        _open(bound(_debtSeed, 1e18, MAX_DEBT));
        vm.warp(block.timestamp + YEAR);
        account.checkpointFee();
        uint256 collateral = _collateral();
        uint256 amount = bound(_amount, 1, collateral);
        oracle.setPrice(bound(_priceMantissa, 1_000, 9_999) * 10 ** bound(_priceExponent, 27, 46));
        (uint256 required, uint256 remaining) = _gateTerms(collateral, amount);

        (bool success, bytes memory data) = _tryWithdraw(amount);

        if (remaining < required) {
            _assertRefused(success, data, required, remaining, collateral);
        } else {
            _assertExecuted(success, collateral, amount);
        }
    }

    /// Opens a position of `_debtSeed` under a floor-only fee and lets it accrue for `_elapsed`, so
    /// the fee is exactly floor * D * t / YEAR in WAD and no interest disturbs the share math.
    function _accrueFloorOnly(
        uint256 _debtSeed,
        uint64 _feeFloor,
        uint32 _elapsed
    )
        private
        returns (uint256 _openedDebt, uint256 _fee, uint256 _feeX18)
    {
        _openedDebt = bound(_debtSeed, 1, MAX_DEBT);
        uint64 feeFloor = uint64(bound(_feeFloor, 1, WAD));
        uint256 elapsed = bound(_elapsed, 1, 2 * YEAR);
        _setTerms(1, feeFloor, 0);
        _open(_openedDebt);
        vm.warp(block.timestamp + elapsed);
        account.checkpointFee();
        (, _feeX18, _fee, , , ) = account.getLoanFeeState();
        assertEq(_feeX18, Math.mulDiv(_openedDebt * feeFloor, elapsed, YEAR));
    }

    /// One accrual period: queues `_period.interest` on Morpho without accruing it, warps
    /// `_period.elapsed`, then checkpoints and asserts that the account accrued Morpho itself, charged the spec's
    /// delta on `_principal` at `_priced` (the terms snapshotted when the period began) and now
    /// snapshots `_next`.
    function _accrueAndCheckpoint(
        uint256 _principal,
        Period memory _period,
        Terms memory _priced,
        Terms memory _next
    )
        private
        returns (uint256 _liveDebt)
    {
        bytes32 marketId = MorphoMath.marketId(params);
        morpho.addPendingInterest(marketId, _period.interest);
        vm.warp(block.timestamp + _period.elapsed);
        // the live debt the account must find once it accrues Morpho: the state plus the queued interest
        _liveDebt = _liveDebtAfterAccrual(marketId);
        (, uint256 feeBefore, , , , ) = account.getLoanFeeState();
        uint256 expected = _expectedDelta(_principal, _liveDebt, _period.elapsed, _priced);

        account.checkpointFee();

        assertEq(morpho.pendingInterest(marketId), 0);
        assertEq(_debt(), _liveDebt);
        _assertFeeState(_liveDebt, feeBefore + expected, (feeBefore + expected) / WAD);
        (, , , uint64 checkpoint, uint64 floor, uint64 spread) = account.getLoanFeeState();
        assertEq(checkpoint, block.timestamp);
        assertEq(floor, _next.floor);
        assertEq(spread, _next.spread);
    }

    /// Queues and delivers a withdraw of `_amount` under id "exit", returning the delivery's outcome.
    function _tryWithdraw(
        uint256 _amount
    )
        private
        returns (bool _success, bytes memory _data)
    {
        (bytes memory message, bytes32 guid) =
            _queue(address(account), 2, 0, _withdraw(bytes32("exit"), _amount, RETURN_VALUE));
        // solhint-disable-next-line avoid-low-level-calls
        (_success, _data) = address(endpoint).call{value: RETURN_VALUE}(
            abi.encodeCall(endpoint.deliver, (address(oft), address(account), guid, message))
        );
    }

    /// The gate's two sides from the spec's formula: the cover for the checkpointed live debt and
    /// collectible, and the value the withdrawal would leave at the oracle's price.
    function _gateTerms(
        uint256 _collateralBefore,
        uint256 _amount
    )
        private view
        returns (uint256 _required, uint256 _remaining)
    {
        (uint256 debt, , uint256 collectible, , , ) = account.getLoanFeeState();
        assertEq(debt, _debt());
        assertGt(collectible, 0);
        _required = Math.mulDiv(debt + FEE_WEIGHT * collectible, EXIT_HEADROOM, params.lltv, Math.Rounding.Ceil);
        _remaining = _collateralBefore > _amount
            ? Math.mulDiv(_collateralBefore - _amount, oracle.price(), 1e36)
            : 0;
    }

    /// The account's debt as Morpho will report it after accruing the queued interest.
    function _liveDebtAfterAccrual(
        bytes32 _marketId
    )
        private view
        returns (uint256)
    {
        (, uint128 shares, ) = morpho.position(_marketId, address(account));
        (, , uint128 totalBorrowAssets, uint128 totalBorrowShares, , ) = morpho.market(_marketId);
        return MorphoMath.toAssetsUp(
            shares, totalBorrowAssets + morpho.pendingInterest(_marketId), totalBorrowShares
        );
    }

    function _assertRefused(
        bool _success,
        bytes memory _data,
        uint256 _required,
        uint256 _remaining,
        uint256 _collateralBefore
    )
        private view
    {
        assertFalse(_success);
        assertEq(
            _data,
            abi.encodeWithSelector(
                ILoanSubaccountRemote.InsufficientRemainingCollateral.selector, _required, _remaining
            )
        );
        assertEq(_collateral(), _collateralBefore);
        assertFalse(account.usedOperations(bytes32("exit")));
    }

    function _assertExecuted(
        bool _success,
        uint256 _collateralBefore,
        uint256 _amount
    )
        private view
    {
        assertTrue(_success);
        assertEq(_collateral(), _collateralBefore - _amount);
        assertEq(fxrp.balanceOf(address(oft)), _amount);
        assertTrue(account.usedOperations(bytes32("exit")));
    }

    function _assertFeeState(
        uint256 _principal,
        uint256 _feeX18,
        uint256 _collectible
    )
        private view
    {
        (uint256 principal, uint256 feeX18, uint256 collectible, , , ) = account.getLoanFeeState();
        assertEq(principal, _principal);
        assertEq(feeX18, _feeX18);
        assertEq(collectible, _collectible);
    }

    /// The `_index`-th period's length and queued interest, derived from the fuzzed seeds.
    function _period(
        uint32 _elapsedSeed,
        uint256 _interestSeed,
        uint256 _debt,
        uint256 _index
    )
        private pure
        returns (Period memory)
    {
        return Period(
            bound(uint256(_elapsedSeed) / _index, 1, 2 * YEAR), bound(_interestSeed / _index, 0, _debt / 10)
        );
    }

    /// The spec's per-period charge: max(floor * D * t, interest + spread * D * t) - interest, in WAD.
    function _expectedDelta(
        uint256 _principal,
        uint256 _liveDebt,
        uint256 _elapsed,
        Terms memory _terms
    )
        private pure
        returns (uint256)
    {
        uint256 interestX18 = (_liveDebt > _principal ? _liveDebt - _principal : 0) * WAD;
        return Math.max(
            Math.mulDiv(_principal * _terms.floor, _elapsed, YEAR),
            interestX18 + Math.mulDiv(_principal * _terms.spread, _elapsed, YEAR)
        ) - interestX18;
    }
}
