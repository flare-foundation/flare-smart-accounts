// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {LoanRemoteFixture} from "../utils/LoanRemoteFixture.sol";
import {IMorphoLoanSubaccountRemote} from "../../contracts/userInterfaces/IMorphoLoanSubaccountRemote.sol";
import {MorphoMath} from "../../contracts/smartAccounts/library/MorphoMath.sol";

/**
 * @title LoanFeeFuzzTest
 * @notice Property tests over the Flare fee arithmetic of `MorphoLoanSubaccountRemote`, each stated as
 * the spec's formula computed here independently of the account: the pro-rata split of an
 * underfunded repayment, the covering repayment, the accrual over three periods with a terms
 * change in between (priced at the snapshotted terms, never compounding), the cover gate on
 * the withdraw and on the borrow, and the read surface against the actions it quotes. The health
 * check is on; every position opens within the fixture's 10,000 FXRP of collateral at 2 RLUSD.
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

    struct BorrowTerms {
        uint256 debtBefore;
        uint256 debtAfter;
        uint256 required;
        uint256 value;
    }

    /// @dev Below the market's 77% of the fixture's 20,000 RLUSD of collateral value.
    uint256 private constant MAX_DEBT = 10_000e18;
    /// @dev The exit gate's constants, as the spec states them: the cover is
    /// `(D + FEE_WEIGHT * F) * EXIT_HEADROOM / LLTV`, rounded up.
    uint256 private constant EXIT_HEADROOM = 1.155e18;
    uint256 private constant FEE_WEIGHT = 2;
    /// @dev A per-second rate of about 200% a year: the upper bound of the fuzzed rate model.
    uint256 private constant MAX_RATE = 2e18 / uint256(365 days);

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

    /// A second borrow passes the cover gate iff the collateral, at the oracle's price (rounded
    /// down), is worth at least `(D' + 2F) x 1.155 / LLTV` (rounded up) for the post-borrow debt D',
    /// Morpho's share rounding included: interest queued before the borrow makes the share price
    /// non-integral, and half the sizes sit within two units of the cover. Morpho's health check
    /// runs first, inside its borrow, so an unhealthy borrow fails there and a healthy but uncovered
    /// one fails at the gate with exact arguments; either refusal rolls the whole delivery back.
    function testFuzzBorrowGateTracksThePosition(
        uint256 _debtSeed,
        uint256 _moreSeed,
        uint96 _interest,
        uint16 _priceMantissa,
        uint8 _priceExponent
    )
        public
    {
        _open(bound(_debtSeed, 1e18, MAX_DEBT));
        vm.warp(block.timestamp + YEAR);
        account.checkpointFee();
        oracle.setPrice(bound(_priceMantissa, 1_000, 9_999) * 10 ** bound(_priceExponent, 27, 46));
        morpho.addPendingInterest(MorphoMath.marketId(params), bound(_interest, 0, _debt() / 10));
        uint256 more = _borrowSize(_moreSeed);
        BorrowTerms memory terms = _borrowTerms(more);

        (bool success, bytes memory data) = _tryBorrow(more);

        _assertBorrowOutcome(success, data, terms);
    }

    /// The position view is what a checkpoint in the same block stores: for any terms, rate model
    /// rate and elapsed time, `getLoanPosition().debt` and `.feeDebtX18` equal the principal and fee
    /// `checkpointFee` then records, and Morpho's own accrual agrees on the debt.
    function testFuzzPositionViewMatchesACheckpoint(
        uint256 _debtSeed,
        uint64 _feeFloor,
        uint64 _feeSpread,
        uint64 _rate,
        uint32 _elapsed
    )
        public
    {
        _setTerms(1, uint64(bound(_feeFloor, 0, WAD)), uint64(bound(_feeSpread, 0, WAD)));
        _open(bound(_debtSeed, 1e18, MAX_DEBT));
        irm.setRate(bound(_rate, 0, MAX_RATE));
        vm.warp(block.timestamp + bound(_elapsed, 0, 2 * YEAR));

        IMorphoLoanSubaccountRemote.LoanPosition memory projected = account.getLoanPosition();
        account.checkpointFee();

        (uint256 principal, uint256 feeDebtX18, uint256 collectible, , , ) = account.getLoanFeeState();
        assertEq(principal, projected.debt);
        assertEq(feeDebtX18, projected.feeDebtX18);
        assertEq(collectible, projected.feeDebtX18 / WAD);
        assertEq(_debt(), projected.debt);
    }

    /// The withdraw preview is the gate's verdict: covered iff the delivery executes, and a refusal
    /// carries exactly the preview's two numbers. When refused, the preview's minimum top-up, repaid,
    /// makes the same withdrawal pass, and one unit less leaves it refused.
    function testFuzzPreviewWithdrawAgreesWithTheGate(
        uint256 _debtSeed,
        uint256 _amount,
        uint64 _rate,
        uint32 _elapsed,
        uint16 _priceMantissa,
        uint8 _priceExponent
    )
        public
    {
        _open(bound(_debtSeed, 1e18, MAX_DEBT));
        irm.setRate(bound(_rate, 0, MAX_RATE));
        vm.warp(block.timestamp + bound(_elapsed, 1, 2 * YEAR));
        oracle.setPrice(bound(_priceMantissa, 1_000, 9_999) * 10 ** bound(_priceExponent, 27, 46));
        uint256 amount = bound(_amount, 1, _collateral());
        IMorphoLoanSubaccountRemote.WithdrawPreview memory preview = account.previewWithdraw(amount);

        (bool success, bytes memory data) = _tryWithdrawAt(2, bytes32("exit"), amount);

        if (preview.coverSatisfied) {
            assertTrue(success);
            return;
        }
        _assertRefused(success, data, preview.requiredCover, preview.remainingValue, _collateral());
        _assertMinimumTopUpIsExact(amount, preview.minimumTopUp);
    }

    /// The borrow preview is the gate's verdict for a borrow with a packet's credit: cover satisfied
    /// iff the delivery executes; a refusal is Morpho's where its line binds first, else the gate's
    /// with exactly the preview's numbers.
    function testFuzzPreviewBorrowAgreesWithTheGate(
        uint256 _debtSeed,
        uint256 _moreSeed,
        uint64 _rate,
        uint32 _elapsed,
        uint16 _priceMantissa,
        uint8 _priceExponent,
        uint64 _credit
    )
        public
    {
        _open(bound(_debtSeed, 1e18, MAX_DEBT));
        irm.setRate(bound(_rate, 0, MAX_RATE));
        vm.warp(block.timestamp + bound(_elapsed, 1, 2 * YEAR));
        oracle.setPrice(bound(_priceMantissa, 1_000, 9_999) * 10 ** bound(_priceExponent, 27, 46));
        uint256 more = bound(_moreSeed, 1, MAX_DEBT);
        uint256 credit = bound(_credit, 0, 10_000e6);
        IMorphoLoanSubaccountRemote.BorrowPreview memory preview = account.previewBorrow(more, credit);
        BorrowTerms memory terms =
            BorrowTerms(_debt(), preview.debtAfter, preview.requiredCover, preview.collateralValue);
        fxrp.mint(address(account), credit);

        (bool success, bytes memory data) = _tryBorrowWith(2, bytes32("more"), credit, more);

        assertEq(preview.coverSatisfied, preview.collateralValue >= preview.requiredCover);
        _assertBorrowOutcome(success, data, terms);
    }

    /// Both limits are exact to the unit: the largest borrow the cover allows executes with its
    /// credit while one unit more is refused, and the largest withdrawal executes while one unit more
    /// is refused - for any accrued debt, fee, price and credit.
    function testFuzzLoanLimitsAreExact(
        uint256 _debtSeed,
        uint64 _rate,
        uint32 _elapsed,
        uint16 _priceMantissa,
        uint8 _priceExponent,
        uint64 _credit
    )
        public
    {
        _open(bound(_debtSeed, 1e18, MAX_DEBT));
        irm.setRate(bound(_rate, 0, MAX_RATE));
        vm.warp(block.timestamp + bound(_elapsed, 0, 2 * YEAR));
        oracle.setPrice(bound(_priceMantissa, 1_000, 9_999) * 10 ** bound(_priceExponent, 27, 46));
        uint256 credit = bound(_credit, 0, 10_000e6);
        IMorphoLoanSubaccountRemote.LoanLimits memory limits = account.getLoanLimits(credit);

        _assertBorrowLimitIsExact(limits.maxBorrowByCover, credit);
        _assertWithdrawLimitIsExact(limits.maxWithdraw);
    }

    /// The repay preview is the repayment: for any idle balance and top-up, the fee collected, the
    /// debt repaid, the surplus pushed and the state left behind equal the preview's.
    function testFuzzPreviewRepayAgreesWithRepay(
        uint256 _debtSeed,
        uint64 _feeFloor,
        uint32 _elapsed,
        uint256 _idleSeed,
        uint256 _topUpSeed,
        uint64 _rate
    )
        public
    {
        (uint256 debt, , ) = _accrueFloorOnly(_debtSeed, _feeFloor, _elapsed);
        irm.setRate(bound(_rate, 0, MAX_RATE));
        vm.warp(block.timestamp + bound(_elapsed, 0, YEAR));
        uint256 idle = bound(_idleSeed, 0, 2 * debt);
        uint256 topUp = bound(_topUpSeed, idle == 0 ? 1 : 0, 2 * debt);
        loanToken.mint(address(account), idle);
        IMorphoLoanSubaccountRemote.RepayPreview memory preview = account.previewRepay(topUp);
        loanToken.mint(address(account), topUp);
        uint256 collectorBefore = loanToken.balanceOf(collector);
        uint256 parentBefore = loanToken.balanceOf(parent);

        uint256 repaid = account.repay();

        _assertRepayOutcome(preview, repaid, collectorBefore, parentBefore);
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
        Period memory _span,
        Terms memory _priced,
        Terms memory _next
    )
        private
        returns (uint256 _liveDebt)
    {
        bytes32 marketId = MorphoMath.marketId(params);
        morpho.addPendingInterest(marketId, _span.interest);
        vm.warp(block.timestamp + _span.elapsed);
        // the live debt the account must find once it accrues Morpho: the state plus the queued interest
        _liveDebt = _liveDebtAfterAccrual(marketId);
        (, uint256 feeBefore, , , , ) = account.getLoanFeeState();
        uint256 expected = _expectedDelta(_principal, _liveDebt, _span.elapsed, _priced);

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
        return _tryWithdrawAt(2, bytes32("exit"), _amount);
    }

    /// Delivers a withdraw of `_amount` under `_id` as packet `_nonce`, returning the raw outcome.
    function _tryWithdrawAt(
        uint64 _nonce,
        bytes32 _id,
        uint256 _amount
    )
        private
        returns (bool _success, bytes memory _data)
    {
        (bytes memory message, bytes32 guid) =
            _queue(address(account), _nonce, 0, _withdraw(_id, _amount, RETURN_VALUE));
        // solhint-disable-next-line avoid-low-level-calls
        (_success, _data) = address(endpoint).call{value: RETURN_VALUE}(
            abi.encodeCall(endpoint.deliver, (address(oft), address(account), guid, message))
        );
    }

    /// Delivers a message-only borrow of `_more` to the parent under the id "more".
    function _tryBorrow(
        uint256 _more
    )
        private
        returns (bool _success, bytes memory _data)
    {
        (bytes memory message, bytes32 guid) = _queue(address(account), 2, 0, _borrow(bytes32("more"), _more));
        // solhint-disable-next-line avoid-low-level-calls
        (_success, _data) = address(endpoint).call(
            abi.encodeCall(endpoint.deliver, (address(oft), address(account), guid, message))
        );
    }

    /// A borrow of `_maxBorrow` with `_credit` supplied executes; one unit more is refused (by the
    /// gate, or by Morpho where its line is lower still).
    function _assertBorrowLimitIsExact(
        uint256 _maxBorrow,
        uint256 _credit
    )
        private
    {
        uint256 snapshot = vm.snapshotState();
        fxrp.mint(address(account), _credit);
        (bool tooMuch, ) = _tryBorrowWith(3, bytes32("limit+1"), _credit, _maxBorrow + 1);
        assertFalse(tooMuch);
        vm.revertToState(snapshot);
        if (_maxBorrow == 0) {
            return;
        }
        snapshot = vm.snapshotState();
        fxrp.mint(address(account), _credit);
        (bool success, ) = _tryBorrowWith(3, bytes32("limit"), _credit, _maxBorrow);
        assertTrue(success);
        vm.revertToState(snapshot);
    }

    /// A withdrawal of `_maxWithdraw` executes; one unit more is refused (unless it is everything).
    function _assertWithdrawLimitIsExact(
        uint256 _maxWithdraw
    )
        private
    {
        uint256 collateral = _collateral();
        if (_maxWithdraw < collateral) {
            uint256 snapshot = vm.snapshotState();
            (bool tooMuch, ) = _tryWithdrawAt(3, bytes32("limit+1"), _maxWithdraw + 1);
            assertFalse(tooMuch);
            vm.revertToState(snapshot);
        }
        if (_maxWithdraw == 0) {
            return;
        }
        (bool success, ) = _tryWithdrawAt(3, bytes32("limit"), _maxWithdraw);
        assertTrue(success);
    }

    /// Delivers a borrow of `_amount` under `_id` as packet `_nonce`, crediting `_credit` FXRP already
    /// minted to the account.
    function _tryBorrowWith(
        uint64 _nonce,
        bytes32 _id,
        uint256 _credit,
        uint256 _amount
    )
        private
        returns (bool _success, bytes memory _data)
    {
        (bytes memory message, bytes32 guid) = _queue(address(account), _nonce, _credit, _borrow(_id, _amount));
        // solhint-disable-next-line avoid-low-level-calls
        (_success, _data) = address(endpoint).call(
            abi.encodeCall(endpoint.deliver, (address(oft), address(account), guid, message))
        );
    }

    /// After a repay of `_minimumTopUp` the withdrawal passes; after one unit less it is refused.
    function _assertMinimumTopUpIsExact(
        uint256 _amount,
        uint256 _minimumTopUp
    )
        private
    {
        if (_minimumTopUp > 1) {
            uint256 snapshot = vm.snapshotState();
            loanToken.mint(address(account), _minimumTopUp - 1);
            account.repay();
            assertFalse(account.previewWithdraw(_amount).coverSatisfied);
            (bool refused, ) = _tryWithdrawAt(3, bytes32("short"), _amount);
            assertFalse(refused);
            vm.revertToState(snapshot);
        }
        loanToken.mint(address(account), _minimumTopUp);
        account.repay();
        assertTrue(account.previewWithdraw(_amount).coverSatisfied);
        (bool success, ) = _tryWithdrawAt(4, bytes32("reopened"), _amount);
        assertTrue(success);
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

    /// Half the seeds size the borrow uniformly, the other half within two units of what the cover
    /// allows on top of the accrued debt and twice the collectible (`value x LLTV / 1.155 - D - 2F`),
    /// so the boundary and Morpho's rounding around it are hit.
    function _borrowSize(
        uint256 _seed
    )
        private view
        returns (uint256)
    {
        if (_seed % 2 == 0) {
            return bound(_seed, 1, MAX_DEBT);
        }
        (, , uint256 collectible, , , ) = account.getLoanFeeState();
        uint256 owed = _liveDebtAfterAccrual(MorphoMath.marketId(params)) + FEE_WEIGHT * collectible;
        uint256 line = Math.mulDiv(Math.mulDiv(_collateral(), oracle.price(), 1e36), params.lltv, EXIT_HEADROOM);
        if (line <= owed + 2) {
            return 1;
        }
        uint256 candidate = line - owed - 2 + (_seed % 5);
        return bound(candidate, 1, MAX_DEBT);
    }

    /// The borrow gate's terms from the spec's formula: the debt before (raw, what a refused
    /// delivery leaves), the post-borrow debt as Morpho will round it after accruing the queued
    /// interest (`toSharesUp` on the way in, `toAssetsUp` on the way out), the cover for that debt
    /// and the checkpointed collectible, and the collateral's value at the oracle's price.
    function _borrowTerms(
        uint256 _more
    )
        private view
        returns (BorrowTerms memory _terms)
    {
        bytes32 id = MorphoMath.marketId(params);
        (, uint128 shares, ) = morpho.position(id, address(account));
        (, , uint128 totalBorrowAssets, uint128 totalBorrowShares, , ) = morpho.market(id);
        uint256 assets = totalBorrowAssets + morpho.pendingInterest(id);
        uint256 sharesUp = MorphoMath.toSharesUp(_more, assets, totalBorrowShares);
        _terms.debtBefore = _debt();
        _terms.debtAfter = MorphoMath.toAssetsUp(shares + sharesUp, assets + _more, totalBorrowShares + sharesUp);
        (, , uint256 collectible, , , ) = account.getLoanFeeState();
        assertGt(collectible, 0);
        _terms.required = Math.mulDiv(
            _terms.debtAfter + FEE_WEIGHT * collectible, EXIT_HEADROOM, params.lltv, Math.Rounding.Ceil
        );
        _terms.value = Math.mulDiv(_collateral(), oracle.price(), 1e36);
    }

    /// Morpho's line first (`value x LLTV >= debt`, its own message), then the cover, then success.
    function _assertBorrowOutcome(
        bool _success,
        bytes memory _data,
        BorrowTerms memory _terms
    )
        private view
    {
        if (Math.mulDiv(_terms.value, params.lltv, WAD) < _terms.debtAfter) {
            assertFalse(_success);
            assertEq(_data, abi.encodeWithSignature("Error(string)", "insufficient collateral"));
            assertEq(_debt(), _terms.debtBefore);
            assertFalse(account.usedOperations(bytes32("more")));
        } else if (_terms.value < _terms.required) {
            assertFalse(_success);
            assertEq(
                _data,
                abi.encodeWithSelector(
                    IMorphoLoanSubaccountRemote.InsufficientRemainingCollateral.selector, _terms.required, _terms.value
                )
            );
            assertEq(_debt(), _terms.debtBefore);
            assertFalse(account.usedOperations(bytes32("more")));
        } else {
            assertTrue(_success);
            assertEq(_debt(), _terms.debtAfter);
            assertTrue(account.usedOperations(bytes32("more")));
        }
    }

    function _assertRepayOutcome(
        IMorphoLoanSubaccountRemote.RepayPreview memory _preview,
        uint256 _repaid,
        uint256 _collectorBefore,
        uint256 _parentBefore
    )
        private view
    {
        assertEq(_repaid, _preview.debtPaid);
        assertEq(loanToken.balanceOf(collector) - _collectorBefore, _preview.feePaid);
        assertEq(loanToken.balanceOf(parent) - _parentBefore, _preview.surplus);
        (uint256 principal, , uint256 collectible, , , ) = account.getLoanFeeState();
        assertEq(principal, _preview.debtAfter);
        assertEq(collectible, _preview.collectibleAfter);
        assertEq(_debt(), _preview.debtAfter);
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
                IMorphoLoanSubaccountRemote.InsufficientRemainingCollateral.selector, _required, _remaining
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
