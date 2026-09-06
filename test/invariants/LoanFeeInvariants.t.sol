// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {LoanFeeHandler} from "../utils/LoanFeeHandler.sol";

/**
 * @title LoanFeeInvariantsTest
 * @notice The Flare fee's stateful invariants over `LoanFeeHandler`: deterministic (fixed seed),
 * bounded (64 runs of depth 64) sequences over the real account logic and the local dependency
 * mocks. The smoke test below pins that every handler path executes, so the campaign is not vacuous.
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

    /// A successful exit leaves collateral worth `(D + 2F) x 1.155 / LLTV` at the oracle's price.
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
}
