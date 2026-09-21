// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {LoanFeeHandler} from "../utils/LoanFeeHandler.sol";

/**
 * @title LoanFeeInvariantsTest
 * @notice The Flare fee's stateful invariants over `LoanFeeHandler`: deterministic (fixed seed),
 * bounded (64 runs of depth 64) sequences over the real account logic and the local dependency
 * mocks. The smoke test proves handler reachability, not which outcomes a random run reaches.
 * Targeted fuzz sequences require fee-bearing exits, elapsed-terms checkpoints, frozen-recipient
 * reservations and retries, external debt changes and dust cleanup across randomized inputs.
 * Each sequence checks successful-action counts and the invariants at its intermediate states;
 * rare outcomes are not required from every ordinary invariant run.
 */
/// forge-config: default.invariant.runs = 64
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
/// forge-config: default.fuzz.seed = '0x6c6f616e666565'
contract LoanFeeInvariantsTest is Test {
    LoanFeeHandler private handler;

    function setUp() public {
        handler = new LoanFeeHandler();
        bytes4[] memory selectors = new bytes4[](11);
        selectors[0] = handler.advanceTime.selector;
        selectors[1] = handler.borrow.selector;
        selectors[2] = handler.checkpointFee.selector;
        selectors[3] = handler.repay.selector;
        selectors[4] = handler.externalRepay.selector;
        selectors[5] = handler.liquidate.selector;
        selectors[6] = handler.withdraw.selector;
        selectors[7] = handler.changeTerms.selector;
        selectors[8] = handler.setPaused.selector;
        selectors[9] = handler.setRecipientFrozen.selector;
        selectors[10] = handler.deposit.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    /// The stored collectible always floors the accumulator, including deferred reserves.
    // solhint-disable-next-line func-name-mixedcase
    function invariant_CollectibleFloorsAccumulator() public view {
        (, uint256 fee, uint256 collectible) = handler.feeState();
        assertEq(collectible, fee / 1e18);
    }

    /// Fee deltas reconcile to exact transfers and debt-free dust; elapsed periods keep old terms.
    // solhint-disable-next-line func-name-mixedcase
    function invariant_FeeAccountingAndTerms() public view {
        (
            bool accounting,
            bool zeroPrincipal,
            bool transfers,
            ,
            ,
            ,
            ,
            bool dust,
            bool terms
        ) = handler.checks();
        assertTrue(accounting, "fee reconciliation");
        assertTrue(zeroPrincipal, "zero-principal accrual");
        assertTrue(transfers, "fee transfer mismatch");
        assertTrue(dust, "dust forgiven with debt or whole units");
        assertTrue(terms, "elapsed terms repriced");
        assertTrue(
            handler.baselineCorrect(),
            "incorrect principal, clock or terms snapshot"
        );
        assertTrue(handler.reservationsCorrect(), "fee reservation mismatch");
    }

    /// All loan tokens remain in tracked destinations, accounting explicitly for mock mint and burn.
    // solhint-disable-next-line func-name-mixedcase
    function invariant_LoanTokenConservation() public view {
        (, , , bool conservation, , , , , ) = handler.checks();
        assertTrue(conservation);
        (uint256 supply, uint256 tracked) = handler.tokenTotals();
        assertEq(supply, tracked);
        assertEq(
            handler.initialSupply() + handler.minted(),
            supply + handler.burned()
        );
    }

    /// Repayment can push surplus only debt-free; live debt consumes the whole available payment.
    // solhint-disable-next-line func-name-mixedcase
    function invariant_RepaymentDestinations() public view {
        (, , , , bool surplus, bool remainder, , , ) = handler.checks();
        assertTrue(surplus, "surplus while indebted");
        assertTrue(remainder, "live debt with idle repayment balance");
    }

    /// A successful withdraw or borrow leaves collateral worth `(D + 2F) x 1.155 / LLTV` at the
    /// oracle's price.
    // solhint-disable-next-line func-name-mixedcase
    function invariant_ExitSecurity() public view {
        (, , , , , , bool secured, , ) = handler.checks();
        assertTrue(secured);
    }

    /// Successful deposits move the entire idle collateral balance into the account's position.
    // solhint-disable-next-line func-name-mixedcase
    function invariant_DepositAccounting() public view {
        assertTrue(handler.depositsCorrect());
        assertTrue(handler.operationsCorrect());
    }

    /// Pins non-vacuous execution of each handler path independently of random sequence selection.
    // solhint-disable-next-line ordering
    function testHandlerActionSmokeSequence() public {
        handler.changeTerms(1, 0);
        handler.checkpointFee();
        handler.advanceTime(1, 0);
        handler.repay(1, 0);
        handler.checkpointFee();
        handler.withdraw(1);
        assertGt(handler.zeroPrincipalCheckpoints(), 0);
        assertGt(handler.dustForfeitures(), 0);

        handler.changeTerms(0.1e18, 0.02e18);
        handler.checkpointFee();
        handler.borrow(100e18, 100e6);
        handler.advanceTime(15 days, 10e18);
        handler.changeTerms(0.2e18, 0.03e18);
        handler.withdraw(1e6);
        handler.setRecipientFrozen(true);
        handler.setPaused(true);
        handler.deposit(10e6);
        handler.repay(1, 0);
        (, , uint256 reservedCollectible) = handler.feeState();
        assertGt(reservedCollectible, 0);
        assertGt(handler.feeReservations(), 0);
        handler.setPaused(false);
        handler.setRecipientFrozen(false);
        handler.repay(1, 1);
        (, , uint256 retriedCollectible) = handler.feeState();
        assertEq(retriedCollectible, 0);
        handler.borrow(100e18, 100e6);
        handler.externalRepay(1e18, false);
        handler.liquidate(1e18, false);
        handler.repay(1e18, 0);
        handler.checkpointFee();
        assertGt(handler.successfulBorrows(), 0);
        assertGt(handler.successfulRepays(), 0);
        assertGt(handler.successfulWithdrawals(), 0);
        assertGt(handler.checkpoints(), 0);
        assertGt(handler.externalRepayments(), 0);
        assertGt(handler.liquidations(), 0);
        assertGt(handler.termsChanges(), 0);
        assertGt(handler.zeroPrincipalCheckpoints(), 0);
        assertGt(handler.feeTransfers(), 0);
        assertGt(handler.surplusPushes(), 0);
        assertGt(handler.successfulDeposits(), 0);
        assertGt(handler.successfulFeeBearingWithdrawals(), 0);
        assertGt(handler.elapsedTermsChangeCheckpoints(), 0);
        assertTrue(handler.depositsCorrect());
        invariant_CollectibleFloorsAccumulator();
        invariant_FeeAccountingAndTerms();
        invariant_LoanTokenConservation();
        invariant_RepaymentDestinations();
        invariant_ExitSecurity();
        invariant_DepositAccounting();
    }

    /// A healthy sequence must actually borrow and withdraw, including an elapsed period priced
    /// with the old snapshot. Caught reverts or handler no-ops must not count as coverage.
    function testFuzzFeeBearingWithdrawalAcrossTermsChange(
        uint96 _borrow,
        uint64 _floor,
        uint32 _elapsed,
        uint64 _withdraw
    )
        public
    {
        handler.borrow(uint96(bound(_borrow, 1e18, 500e18)), 1e6);
        assertEq(handler.successfulBorrows(), 1, "healthy borrow did not execute");
        _assertAllInvariants();

        uint64 floor = uint64(bound(_floor, 0.03e18, 0.1e18));
        uint32 elapsed = uint32(bound(_elapsed, 1 hours, 30 days));
        handler.changeTerms(floor, 0);
        handler.checkpointFee();
        assertEq(handler.checkpoints(), 1);
        (uint256 principal, uint256 feeBefore, ) = handler.feeState();
        handler.advanceTime(elapsed, 0);
        handler.changeTerms(floor + uint64(0.1e18), 0);
        assertEq(handler.termsChanges(), 2);
        _assertAllInvariants();

        // At most 100 FXRP leaves a position worth over 19,000 RLUSD, comfortably covering
        // the bounded debt and fee; a refused withdrawal is a regression, not a valid sample.
        handler.withdraw(uint64(bound(_withdraw, 1, 100e6)));
        assertEq(handler.successfulWithdrawals(), 1, "healthy withdrawal did not execute");
        assertEq(handler.successfulFeeBearingWithdrawals(), 1);
        assertEq(handler.elapsedTermsChangeCheckpoints(), 1);
        (, uint256 feeAfter, uint256 collectible) = handler.feeState();
        assertEq(feeAfter, feeBefore + principal * floor * elapsed / 365 days);
        assertGt(collectible, 0);
        _assertAllInvariants();

        handler.repay(1e18, 1);
        assertEq(handler.successfulRepays(), 1);
        assertGt(handler.feeTransfers(), 0);
        _assertAllInvariants();
    }

    /// A partial repayment defers the frozen collector's share; closing reserves it, and a
    /// later repayment pays it while still paused. Random amounts must reach all three stages.
    function testFuzzFrozenFeeReservationAndRetryWhilePaused(
        uint32 _elapsed,
        uint96 _partial,
        uint96 _surplus,
        uint64 _collateral
    )
        public
    {
        handler.advanceTime(uint32(bound(_elapsed, 1 hours, 30 days)), 0);
        handler.setRecipientFrozen(true);
        handler.setPaused(true);
        assertEq(handler.freezes(), 1);
        assertEq(handler.pauses(), 1);
        handler.deposit(uint64(bound(_collateral, 1, 1_000e6)));
        assertEq(handler.successfulDeposits(), 1, "paused defensive deposit did not execute");
        _assertAllInvariants();

        handler.repay(uint96(bound(_partial, 1e18, 100e18)), 1);
        assertEq(handler.successfulRepays(), 1);
        (uint256 principal, , uint256 collectible) = handler.feeState();
        assertGt(principal, 0);
        assertGt(collectible, 0);
        assertEq(handler.feeTransfers(), 0);
        assertEq(handler.feeReservations(), 0);
        _assertAllInvariants();

        handler.repay(uint96(bound(_surplus, 1, 100e18)), 0);
        assertEq(handler.successfulRepays(), 2);
        assertEq(handler.feeReservations(), 1);
        assertEq(handler.surplusPushes(), 1);
        (principal, , collectible) = handler.feeState();
        assertEq(principal, 0);
        assertGt(collectible, 0);
        _assertAllInvariants();

        handler.advanceTime(uint32(bound(_elapsed, 1, 30 days)), 0);
        handler.checkpointFee();
        assertEq(handler.zeroPrincipalCheckpoints(), 1);
        (, , uint256 stillReserved) = handler.feeState();
        assertEq(stillReserved, collectible);
        _assertAllInvariants();

        handler.setRecipientFrozen(false);
        assertEq(handler.freezes(), 2);
        handler.repay(1, 1);
        assertEq(handler.successfulRepays(), 3);
        assertEq(handler.feeTransfers(), 1);
        assertEq(handler.surplusPushes(), 2);
        (, , collectible) = handler.feeState();
        assertEq(collectible, 0);
        _assertAllInvariants();
    }

    /// Partial external debt changes leave the principal stale until checkpointed. A tiny
    /// positive fee then survives closing as dust and is forgiven only by the debt-free exit.
    function testFuzzExternalDebtChangesThenDustCleanup(
        uint96 _externalShares,
        uint96 _liquidationShares,
        uint32 _elapsed,
        bool _liquidationFirst
    )
        public
    {
        handler.changeTerms(1, 0);
        handler.checkpointFee();
        assertEq(handler.termsChanges(), 1);
        assertEq(handler.checkpoints(), 1);
        (uint256 principal, , ) = handler.feeState();
        uint32 elapsed = uint32(bound(_elapsed, 1, 1 hours));
        handler.advanceTime(elapsed, 0);

        // Each retires at most about 100 RLUSD of the initial 5,000 RLUSD debt, so neither
        // operation can exhaust the next one's shares or collateral precondition.
        uint96 externalShares = uint96(bound(_externalShares, 1e24, 1e26));
        uint96 liquidationShares = uint96(bound(_liquidationShares, 1e24, 1e26));
        if (_liquidationFirst) {
            handler.liquidate(liquidationShares, false);
            assertEq(handler.liquidations(), 1);
            _assertAllInvariants();
            handler.externalRepay(externalShares, false);
        } else {
            handler.externalRepay(externalShares, false);
            assertEq(handler.externalRepayments(), 1);
            _assertAllInvariants();
            handler.liquidate(liquidationShares, false);
        }
        assertEq(handler.externalRepayments(), 1);
        assertEq(handler.liquidations(), 1);
        (uint256 stalePrincipal, , ) = handler.feeState();
        assertEq(stalePrincipal, principal);
        _assertAllInvariants();

        handler.checkpointFee();
        assertEq(handler.checkpoints(), 2);
        (uint256 syncedPrincipal, uint256 dust, uint256 collectible) = handler.feeState();
        assertLt(syncedPrincipal, principal);
        assertGt(syncedPrincipal, 0);
        assertEq(dust, principal * elapsed / 365 days);
        assertGt(dust, 0);
        assertLt(dust, 1e18);
        assertEq(collectible, 0);
        _assertAllInvariants();

        handler.repay(1, 0);
        assertEq(handler.successfulRepays(), 1);
        (syncedPrincipal, dust, collectible) = handler.feeState();
        assertEq(syncedPrincipal, 0);
        assertGt(dust, 0);
        assertEq(collectible, 0);
        assertEq(handler.dustForfeitures(), 0);
        _assertAllInvariants();

        handler.withdraw(1);
        assertEq(handler.successfulWithdrawals(), 1);
        assertEq(handler.dustForfeitures(), 1);
        (, dust, ) = handler.feeState();
        assertEq(dust, 0);
        _assertAllInvariants();

        uint256 zeroPrincipalBefore = handler.zeroPrincipalCheckpoints();
        handler.advanceTime(elapsed, 0);
        handler.checkpointFee();
        assertEq(handler.checkpoints(), 3);
        assertEq(handler.zeroPrincipalCheckpoints(), zeroPrincipalBefore + 1);
        (, dust, ) = handler.feeState();
        assertEq(dust, 0);
        _assertAllInvariants();
    }

    function _assertAllInvariants()
        private view
    {
        invariant_CollectibleFloorsAccumulator();
        invariant_FeeAccountingAndTerms();
        invariant_LoanTokenConservation();
        invariant_RepaymentDestinations();
        invariant_ExitSecurity();
        invariant_DepositAccounting();
    }
}
