// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {LoanMath} from "../../../contracts/smartAccounts/library/LoanMath.sol";

/**
 * @title LoanMathTest
 * @notice Pins the shared fee and cover arithmetic to the spec's worked numbers, computed here by
 * hand: the cover at the launch market and at a 50% market, its rounding, the zero claim; the
 * fee delta in the floor regime, the spread regime and the external-repayment clamp, plus the
 * zero arms the actions never reach (a zero principal or a zero period yields zero); the
 * pro-rata fee share's round-down.
 */
contract LoanMathTest is Test {
    uint256 private constant WAD = 1e18;

    function testRequiredCoverAtTheLaunchMarket() public pure {
        // 1.5 x (D + 2F) at 77%: the spec's D = 1000, F = 70 example, the debt-free 3F, the
        // fresh loan's 1.5 D, and nothing owed
        assertEq(LoanMath.requiredCover(1000e18, 70e18, 0.77e18), 1710e18);
        assertEq(LoanMath.requiredCover(0, 70e18, 0.77e18), 210e18);
        assertEq(LoanMath.requiredCover(1000e18, 0, 0.77e18), 1500e18);
        assertEq(LoanMath.requiredCover(0, 0, 0.77e18), 0);
    }

    function testRequiredCoverFollowsTheMarketLltvAndRoundsUp() public pure {
        // 1.155 / 0.5 = 2.31 on a 50% market; an odd claim's half unit rounds up
        assertEq(LoanMath.requiredCover(100e18, 0, 0.5e18), 231e18);
        assertEq(LoanMath.requiredCover(1, 0, 0.77e18), 2);
        assertEq(LoanMath.requiredCover(2, 0, 0.77e18), 3);
    }

    function testFeeDeltaInTheFloorAndSpreadRegimes() public pure {
        // a year on 1000 at floor 7% / spread 1%: 60 of interest keeps the floor binding (70 - 60
        // = 10 of fee); 100 of interest flips to the spread (10 of fee again, by a different
        // road); no interest charges the whole floor
        assertEq(LoanMath.feeDeltaX18(1000e18, 1060e18, 365 days, 0.07e18, 0.01e18), 10e18 * WAD);
        assertEq(LoanMath.feeDeltaX18(1000e18, 1100e18, 365 days, 0.07e18, 0.01e18), 10e18 * WAD);
        assertEq(LoanMath.feeDeltaX18(1000e18, 1000e18, 365 days, 0.07e18, 0.01e18), 70e18 * WAD);
        // half a year at the same terms halves the floor
        assertEq(LoanMath.feeDeltaX18(1000e18, 1000e18, 365 days / 2, 0.07e18, 0.01e18), 35e18 * WAD);
    }

    function testFeeDeltaClampsExternalRepaymentToZeroInterest() public pure {
        // the live debt fell below the principal (a repayment outside the rails): zero interest,
        // the floor on the old base, no underflow
        assertEq(LoanMath.feeDeltaX18(1000e18, 10e18, 365 days, 0.07e18, 0.01e18), 70e18 * WAD);
        assertEq(LoanMath.feeDeltaX18(1000e18, 0, 365 days, 0.07e18, 0.01e18), 70e18 * WAD);
    }

    function testFeeDeltaIsZeroForAZeroPrincipalOrPeriod() public pure {
        assertEq(LoanMath.feeDeltaX18(0, 1000e18, 365 days, 0.07e18, 0.01e18), 0);
        assertEq(LoanMath.feeDeltaX18(1000e18, 1060e18, 0, 0.07e18, 0.01e18), 0);
    }

    function testFeeShareRoundsDown() public pure {
        // the spec's small-number example: 26 against D = 100, F = 7 pays 1 of fee (26 x 7 / 107
        // = 1.70), 27 still 1; a payment split 10:7 exactly
        assertEq(LoanMath.feeShare(26, 100, 7), 1);
        assertEq(LoanMath.feeShare(27, 100, 7), 1);
        assertEq(LoanMath.feeShare(17e18, 10e18, 7e18), 7e18);
        assertEq(LoanMath.feeShare(0, 100, 7), 0);
    }
}
