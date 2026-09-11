// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LoanRemoteFixture} from "../utils/LoanRemoteFixture.sol";
import {IIMorphoLoanMarketsFacet} from "../../contracts/smartAccounts/interface/IIMorphoLoanMarketsFacet.sol";
import {IMorphoLoanMarketsFacet} from "../../contracts/userInterfaces/facets/IMorphoLoanMarketsFacet.sol";
import {IMorphoLoanSubaccountRemote} from "../../contracts/userInterfaces/IMorphoLoanSubaccountRemote.sol";
import {ITimelockFacet} from "../../contracts/userInterfaces/facets/ITimelockFacet.sol";

/**
 * @title LoanFeeActivationTest
 * @notice The runbook's activation step (`deployment/RUNBOOK.md` B6: `registerLoanMarket`, then the first
 * `setLoanFeeTerms`) under the production timelock. A registered but unpriced type keeps borrowing closed
 * through the queueing and through a premature execution; the execution at the ETA lands all three fee fields
 * at once; and the very packet that was refused, still inside its deadline, then opens the loan priced at the
 * activated terms. A borrow that slipped through earlier would have snapshotted zero rates.
 */
contract LoanFeeActivationTest is LoanRemoteFixture {
    /// The production timelock duration.
    uint256 private constant TIMELOCK = 1 hours;
    uint64 private constant FLOOR = 0.07e18;
    uint64 private constant SPREAD = 0.01e18;
    uint256 private constant BORROW = 1_000e18;

    function setUp() public {
        _setUpRemoteFixture();
        vm.prank(owner);
        controller.setTimelockDuration(TIMELOCK);
    }

    /// Rules out a borrow executing before the activation lands, and an activation landing piecemeal: the
    /// packet is refused, retriably, until the queued terms execute at their ETA, and then opens at them.
    function testActivationUnderTimelockOpensBorrowingOnlyAtExecution() public {
        // registered, not activated: the closed state is the missing recipient, not the borrow switch
        _assertUnpriced();
        assertFalse(controller.isLoanBorrowingDisabled(1));

        // the packet that will wait: its deadline outlives the delay, so the same packet is still
        // valid when the terms land
        fxrp.mint(address(account), 10_000e6);
        uint64 deadline = uint64(vm.getBlockTimestamp() + TIMELOCK + 1 hours);
        (bytes memory message, bytes32 guid) = _queue(
            address(account),
            1,
            10_000e6,
            _borrowUntil(bytes32("first"), BORROW, deadline)
        );
        _assertRefused(message, guid);

        // governance queues the activation; queueing applies nothing
        IMorphoLoanMarketsFacet.FeeTerms memory proposed = IMorphoLoanMarketsFacet.FeeTerms(
            FLOOR,
            SPREAD,
            collector
        );
        bytes memory activation = abi.encodeCall(
            IIMorphoLoanMarketsFacet.setLoanFeeTerms,
            (1, proposed)
        );
        vm.prank(owner);
        controller.setLoanFeeTerms(1, proposed);
        uint256 allowedAfter = controller.getExecuteTimelockedCallTimestamp(activation);
        assertEq(allowedAfter, vm.getBlockTimestamp() + TIMELOCK);
        _assertUnpriced();
        _assertRefused(message, guid);

        // a premature execution fails and applies nothing
        vm.warp(allowedAfter - 1);
        vm.expectRevert(ITimelockFacet.TimelockNotAllowedYet.selector);
        controller.executeTimelockedCall(activation);
        _assertUnpriced();
        _assertRefused(message, guid);

        // at the ETA anyone executes, and the three fields land together
        vm.warp(allowedAfter);
        vm.expectEmit(address(controller));
        emit IMorphoLoanMarketsFacet.LoanFeeTermsSet(1, FLOOR, SPREAD, collector);
        controller.executeTimelockedCall(activation);
        IMorphoLoanMarketsFacet.FeeTerms memory terms = controller.getLoanFeeTerms(1);
        assertEq(terms.feeFloor, FLOOR);
        assertEq(terms.feeSpread, SPREAD);
        assertEq(terms.feeRecipient, collector);
        assertFalse(controller.isLoanBorrowingDisabled(1));
        vm.expectRevert(ITimelockFacet.TimelockInvalidSelector.selector);
        controller.getExecuteTimelockedCallTimestamp(activation);

        // the refused packet, unchanged and inside its deadline, now opens the loan at the
        // activated terms
        endpoint.deliver(address(oft), address(account), guid, message);
        assertEq(endpoint.composeQueue(address(oft), address(account), guid, 0), bytes32(uint256(1)));
        assertEq(loanToken.balanceOf(parent), BORROW);
        assertEq(_debt(), BORROW);
        (
            uint256 principal,
            uint256 feeDebtX18,
            uint256 collectible,
            uint64 lastCheckpoint,
            uint64 feeFloor,
            uint64 feeSpread
        ) = account.getLoanFeeState();
        assertEq(principal, BORROW);
        assertEq(feeDebtX18, 0);
        assertEq(collectible, 0);
        assertEq(lastCheckpoint, allowedAfter);
        assertEq(feeFloor, FLOOR);
        assertEq(feeSpread, SPREAD);

        // and that snapshot is what prices the first period: the floor term alone, the market's
        // rate being zero
        vm.warp(allowedAfter + 30 days);
        account.checkpointFee();
        (, feeDebtX18, , , , ) = account.getLoanFeeState();
        assertEq(feeDebtX18, BORROW * FLOOR * 30 days / YEAR);
    }

    /// Leaves type 1 registered and unpriced: the activation is what this suite exercises.
    function _activateMarket(
        uint256
    )
        internal override
    {
        // the fixture's activation deliberately does not run here
    }

    /// The delivery reverts at the activation gate and the queue still holds the packet.
    function _assertRefused(
        bytes memory _message,
        bytes32 _guid
    )
        private
    {
        vm.expectRevert(IMorphoLoanSubaccountRemote.FeeTermsNotConfigured.selector);
        endpoint.deliver(address(oft), address(account), _guid, _message);
        assertEq(endpoint.composeQueue(address(oft), address(account), _guid, 0), keccak256(_message));
    }

    function _assertUnpriced(
    )
        private view
    {
        IMorphoLoanMarketsFacet.FeeTerms memory terms = controller.getLoanFeeTerms(1);
        assertEq(terms.feeFloor, 0);
        assertEq(terms.feeSpread, 0);
        assertEq(terms.feeRecipient, address(0));
    }
}
