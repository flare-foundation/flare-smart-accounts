// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LoanHomeFixture} from "../utils/LoanHomeFixture.sol";
import {ILoanSubaccount} from "../../contracts/userInterfaces/ILoanSubaccount.sol";
import {ISubaccount} from "../../contracts/userInterfaces/ISubaccount.sol";
import {PAYLOAD_VERSION_1} from "../../contracts/userInterfaces/IComposeReceiverAccountBase.sol";
import {ACTION_CANCEL} from "../../contracts/userInterfaces/IMorphoLoanSubaccountRemote.sol";
import {
    IBridgingSubaccount,
    REDEEM_HOME_TTL
} from "../../contracts/userInterfaces/IBridgingSubaccount.sol";
import {IPauseFacet} from "../../contracts/userInterfaces/facets/IPauseFacet.sol";
import {ITimelockFacet} from "../../contracts/userInterfaces/facets/ITimelockFacet.sol";
import {Errors} from "@layerzerolabs/lz-evm-protocol-v2/contracts/libs/Errors.sol";
import {IComposeReceiverAccountBase} from "../../contracts/userInterfaces/IComposeReceiverAccountBase.sol";
import {MockOft} from "../../contracts/mock/MockOft.sol";

/**
 * @title LoanHomeOrderingTest
 * @notice Flare-side attack and ordering tests: the public sweep racing a redeem-home compose, queued
 * route governance across a pause, and the sender-side guards of borrow and withdraw.
 */
contract LoanHomeOrderingTest is LoanHomeFixture {
    function setUp() public {
        _setUpHomeFixture();
    }

    /// @notice A public sweep cannot redirect funds; failed compose value stays with its caller,
    /// and an expired retry forwards its entire value to the fixed parent without touching later credit.
    function testSweepBeforeComposeRetainsRetryValueAndExpiresToParent() public {
        fxrp.mint(address(account), 100e6);
        (bytes memory message, bytes32 guid) = _queueHome(1, 100e6);
        uint256 nativeBefore = address(this).balance;
        _expectHomeRedemption(100e6, 2 * EXECUTOR_FEE);
        (uint256 amount, uint256 redeemed) = account.sweepRedeem{
            value: 2 * EXECUTOR_FEE
        }();
        assertEq(amount, 100e6);
        assertEq(redeemed, 100e6);
        _assertHomeRequest(1, 100e6);
        assertEq(address(assetManager).balance, 2 * EXECUTOR_FEE);

        vm.expectRevert(IBridgingSubaccount.NothingToRedeem.selector);
        _deliverHome(message, guid, EXECUTOR_FEE);
        assertEq(address(this).balance, nativeBefore - 2 * EXECUTOR_FEE);
        assertEq(
            endpoint.composeQueue(address(oft), address(account), guid, 0),
            keccak256(message)
        );
        assertEq(parent.balance, 0);
        assertEq(address(endpoint).balance, 0);

        vm.warp(block.timestamp + REDEEM_HOME_TTL + 1);
        fxrp.mint(address(account), 20e6);
        vm.expectEmit(address(account));
        emit IBridgingSubaccount.NativeSweptToParent(parent, EXECUTOR_FEE);
        vm.expectEmit(address(account));
        emit IBridgingSubaccount.RedeemHomeSkipped(parent, guid);
        _deliverHome(message, guid, EXECUTOR_FEE);
        assertEq(parent.balance, EXECUTOR_FEE);
        assertEq(address(this).balance, nativeBefore - 3 * EXECUTOR_FEE);
        assertEq(fxrp.balanceOf(address(account)), 20e6);
        assertEq(fxrp.balanceOf(parent), 0);
        assertEq(assetManager.lastRequestId(), 1);
        assertEq(address(account).balance, 0);
        assertEq(address(endpoint).balance, 0);
        assertEq(
            endpoint.composeQueue(address(oft), address(account), guid, 0),
            bytes32(uint256(1))
        );
    }

    /// @notice Compose-first redemption uses the fixed XRPL owner, pays the exact attached fee,
    /// rejects an empty public sweep and cannot replay through the vendored compose-queue semantics.
    function testComposeBeforeSweepCannotRedeemSameCreditTwice() public {
        fxrp.mint(address(account), 100e6);
        (bytes memory message, bytes32 guid) = _queueHome(1, 100e6);
        uint256 nativeBefore = address(this).balance;
        _expectHomeRedemption(100e6, 2 * EXECUTOR_FEE);
        _deliverHome(message, guid, 2 * EXECUTOR_FEE);
        _assertHomeRequest(1, 100e6);
        assertEq(address(assetManager).balance, 2 * EXECUTOR_FEE);
        assertEq(address(this).balance, nativeBefore - 2 * EXECUTOR_FEE);
        assertEq(fxrp.balanceOf(address(account)), 0);
        assertEq(fxrp.balanceOf(parent), 0);

        vm.expectRevert(IBridgingSubaccount.NothingToRedeem.selector);
        account.sweepRedeem{value: EXECUTOR_FEE}();
        fxrp.mint(address(account), 50e6);
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.LZ_ComposeNotFound.selector,
                bytes32(uint256(1)),
                keccak256(message)
            )
        );
        _deliverHome(message, guid, EXECUTOR_FEE);
        assertEq(fxrp.balanceOf(address(account)), 50e6);
        assertEq(assetManager.lastRequestId(), 1);
        assertEq(address(this).balance, nativeBefore - 2 * EXECUTOR_FEE);
        assertEq(parent.balance, 0);
        assertEq(address(account).balance, 0);
        assertEq(address(endpoint).balance, 0);
    }

    /// @notice Accepted TTL residual: after a public sweep, the pending packet may redeem later
    /// credit before expiry, but only its own amount and only through the fixed parent's XRPL destination.
    function testPendingComposeAfterSweepCapsItsUseOfLaterCredit() public {
        // The public sweep includes 20 FXRP donated beside the queued packet's 60 FXRP credit.
        fxrp.mint(address(account), 80e6);
        (bytes memory message, bytes32 guid) = _queueHome(1, 60e6);
        uint256 nativeBefore = address(this).balance;
        _expectHomeRedemption(80e6, EXECUTOR_FEE);
        account.sweepRedeem{value: EXECUTOR_FEE}();
        _assertHomeRequest(1, 80e6);

        fxrp.mint(address(account), 100e6);
        _expectHomeRedemption(60e6, 0);
        _deliverHome(message, guid, 0);
        _assertHomeRequest(2, 60e6);
        assertEq(fxrp.balanceOf(address(account)), 40e6);
        assertEq(fxrp.balanceOf(parent), 0);
        assertEq(assetManager.lastRedeemValue(), 0);
        assertEq(address(assetManager).balance, EXECUTOR_FEE);
        assertEq(address(this).balance, nativeBefore - EXECUTOR_FEE);
        assertEq(parent.balance, 0);
        assertEq(address(account).balance, 0);
    }

    /// @notice Both dust paths conserve FXRP and native at the fixed parent, including excess
    /// compose value; neither may spend the parent's preexisting FXRP or pay the permissionless caller.
    function testDustComposeThenSweepForwardExactBalancesToParent() public {
        assetManager.setMinimumRedeemAmountUBA(100e6);
        fxrp.mint(parent, 900e6);
        fxrp.mint(address(account), 80e6);
        (bytes memory message, bytes32 guid) = _queueHome(1, 30e6);
        uint256 nativeBefore = address(this).balance;
        vm.expectEmit(address(account));
        emit IBridgingSubaccount.NativeSweptToParent(parent, 2 * EXECUTOR_FEE);
        vm.expectEmit(address(account));
        emit IBridgingSubaccount.TokenSweptToParent(
            parent,
            address(fxrp),
            30e6
        );
        _deliverHome(message, guid, 2 * EXECUTOR_FEE);
        assertEq(fxrp.balanceOf(parent), 930e6);
        assertEq(fxrp.balanceOf(address(account)), 50e6);
        assertEq(parent.balance, 2 * EXECUTOR_FEE);

        (uint256 amount, uint256 redeemed) = account.sweepRedeem{
            value: EXECUTOR_FEE
        }();
        assertEq(amount, 50e6);
        assertEq(redeemed, 0);
        assertEq(fxrp.balanceOf(parent), 980e6);
        assertEq(fxrp.balanceOf(address(account)), 0);
        assertEq(parent.balance, 3 * EXECUTOR_FEE);
        assertEq(address(this).balance, nativeBefore - 3 * EXECUTOR_FEE);
        assertEq(address(account).balance, 0);
        assertEq(address(endpoint).balance, 0);
        assertEq(address(assetManager).balance, 0);
        assertEq(assetManager.lastRequestId(), 0);
    }

    /// @notice A queued route suspension still matures during pause; anyone may execute it,
    /// and subsequent unpause does not silently restore the suspended route.
    function testQueuedSuspensionExecutesWhilePaused() public {
        _setHomeTimelock();
        bytes memory suspendCall = _queueHomeSuspension(true);
        vm.prank(owner);
        controller.pause();
        vm.warp(block.timestamp + 1 days);
        controller.executeTimelockedCall(suspendCall);
        (uint32 eid, bool suspended) = controller.getSubaccountTypeRoutePin(1);
        assertEq(eid, REMOTE_EID);
        assertTrue(suspended);
        assertTrue(controller.isPaused());

        vm.prank(owner);
        controller.unpause();
        fxrp.mint(address(account), 1e6);
        vm.deal(parent, BRIDGE_FEE);
        vm.prank(parent);
        vm.expectRevert(IBridgingSubaccount.BridgeRouteNotConfigured.selector);
        account.depositCollateral{value: BRIDGE_FEE}(1e6, "");
        assertEq(fxrp.balanceOf(address(account)), 1e6);
        assertEq(oft.lastValue(), 0);
    }

    /// @notice Accepted queue survival: a resume queued before suspension can undo it while
    /// paused; the pause itself still blocks every forward send until explicitly lifted.
    function testQueuedResumeSurvivesSuspensionAndPause() public {
        _setHomeTimelock();
        bytes memory suspendCall = _queueHomeSuspension(true);
        bytes memory resumeCall = _queueHomeSuspension(false);
        vm.prank(owner);
        controller.pause();
        vm.warp(block.timestamp + 1 days);
        controller.executeTimelockedCall(suspendCall);
        (, bool suspended) = controller.getSubaccountTypeRoutePin(1);
        assertTrue(suspended);
        controller.executeTimelockedCall(resumeCall);
        (uint32 eid, bool resumedSuspension) = controller.getSubaccountTypeRoutePin(1);
        assertEq(eid, REMOTE_EID);
        assertFalse(resumedSuspension);
        assertTrue(controller.isPaused());

        fxrp.mint(address(account), 1e6);
        vm.deal(parent, BRIDGE_FEE);
        vm.prank(parent);
        vm.expectRevert(IPauseFacet.IsPaused.selector);
        account.depositCollateral{value: BRIDGE_FEE}(1e6, "");
        vm.prank(owner);
        controller.unpause();
        vm.prank(parent);
        account.depositCollateral{value: BRIDGE_FEE}(1e6, "");
        assertEq(fxrp.balanceOf(address(account)), 0);
        assertEq(fxrp.balanceOf(address(oft)), 1e6);
        assertEq(oft.lastValue(), BRIDGE_FEE);
    }

    /// @notice Canceling the queued resume before executing suspension prevents a later caller
    /// from reopening the route after the incident; this pins the documented containment runbook.
    function testCanceledResumeCannotUndoSuspension() public {
        _setHomeTimelock();
        bytes memory suspendCall = _queueHomeSuspension(true);
        bytes memory resumeCall = _queueHomeSuspension(false);
        vm.startPrank(owner);
        controller.cancelTimelockedCall(resumeCall);
        controller.pause();
        vm.stopPrank();
        vm.warp(block.timestamp + 1 days);
        controller.executeTimelockedCall(suspendCall);
        vm.expectRevert(ITimelockFacet.TimelockInvalidSelector.selector);
        controller.executeTimelockedCall(resumeCall);
        (, bool suspended) = controller.getSubaccountTypeRoutePin(1);
        assertTrue(suspended);
        assertTrue(controller.isPaused());
    }

    /// @notice Borrow has its own parent-authority guard: neither an arbitrary caller nor the
    /// controller may send a loan instruction directly, and the rejected attempts pay no bridge fee.
    function testBorrowRejectsNonParentAndController() public {
        uint64 deadline = uint64(block.timestamp + 1 hours);
        uint256 nativeBefore = address(this).balance;
        vm.expectRevert(ISubaccount.OnlyParent.selector);
        _borrowHome(bytes32("foreign"), deadline);
        vm.deal(address(controller), BRIDGE_FEE);
        vm.prank(address(controller));
        vm.expectRevert(ISubaccount.OnlyParent.selector);
        _borrowHome(bytes32("controller"), deadline);
        assertEq(address(this).balance, nativeBefore);
        assertEq(address(controller).balance, BRIDGE_FEE);
        assertEq(oft.lastValue(), 0);
        assertEq(address(oft).balance, 0);
    }

    /// @notice A zero borrow operation ID is rejected before any bridge payment despite valid
    /// parent authority, destination, amount, deadline, route and funding.
    function testBorrowRejectsZeroIdBeforeBridgeFee() public {
        vm.deal(parent, BRIDGE_FEE);
        vm.prank(parent);
        vm.expectRevert(ILoanSubaccount.InvalidLoanInstruction.selector);
        _borrowHome(bytes32(0), uint64(block.timestamp + 1 hours));
        assertEq(parent.balance, BRIDGE_FEE);
        assertEq(oft.lastValue(), 0);
        assertEq(address(oft).balance, 0);
    }

    /// @notice A deadline one second in the past is rejected at the Flare borrow sender,
    /// leaving the full prepaid bridge fee with the parent.
    function testBorrowRejectsExpiredDeadlineBeforeBridgeFee() public {
        vm.deal(parent, BRIDGE_FEE);
        vm.prank(parent);
        vm.expectRevert(ILoanSubaccount.InvalidLoanInstruction.selector);
        _borrowHome(bytes32("expired"), uint64(block.timestamp - 1));
        assertEq(parent.balance, BRIDGE_FEE);
        assertEq(oft.lastValue(), 0);
        assertEq(address(oft).balance, 0);
    }

    /// @notice Borrow accepts an inclusive deadline and transports the exact ID and timestamp;
    /// the message-only send does not use staged FXRP or pay more than its quote.
    function testBorrowAcceptsInclusiveDeadline() public {
        fxrp.mint(address(account), 50e6);
        vm.deal(parent, BRIDGE_FEE);
        vm.prank(parent);
        _borrowHome(bytes32("boundary"), uint64(block.timestamp));
        (
            uint32 eid,
            bytes32 destination,
            uint256 amount,
            ,
            ,
            bytes memory payload,

        ) = oft.lastSendParam();
        assertEq(eid, REMOTE_EID);
        assertEq(destination, bytes32(uint256(uint160(address(account)))));
        assertEq(amount, 0);
        (, , bytes memory actionData) = abi.decode(
            payload,
            (uint8, uint8, bytes)
        );
        (bytes32 id, uint64 deadline, , , uint256 borrowed) = abi.decode(
            actionData,
            (bytes32, uint64, uint8, bytes32, uint256)
        );
        assertEq(id, bytes32("boundary"));
        assertEq(deadline, block.timestamp);
        assertEq(borrowed, 100e18);
        assertEq(fxrp.balanceOf(address(account)), 50e6);
        assertEq(oft.lastValue(), BRIDGE_FEE);
        assertEq(parent.balance, 0);
    }

    /// @notice Withdraw independently checks both ID and deadline; valid amount, positive floor
    /// and funding cannot make either malformed instruction pay a bridge fee.
    function testWithdrawRejectsZeroIdAndExpiredDeadlineBeforeBridgeFee() public {
        vm.deal(parent, BRIDGE_FEE);
        vm.startPrank(parent);
        vm.expectRevert(ILoanSubaccount.InvalidLoanInstruction.selector);
        account.withdraw{value: BRIDGE_FEE}(
            1e6,
            bytes32(0),
            uint64(block.timestamp + 1 hours),
            _homeWithdrawOptions()
        );
        vm.expectRevert(ILoanSubaccount.InvalidLoanInstruction.selector);
        account.withdraw{value: BRIDGE_FEE}(
            1e6,
            bytes32("expired"),
            uint64(block.timestamp - 1),
            _homeWithdrawOptions()
        );
        vm.stopPrank();
        assertEq(parent.balance, BRIDGE_FEE);
        assertEq(oft.lastValue(), 0);
        assertEq(address(oft).balance, 0);
    }

    /// @notice The cancellation is message-only and carries nothing but the id it burns: no
    /// FXRP leaves, no deadline travels, and the payload is exactly the one word.
    function testCancelSendsOnlyTheIdItBurns() public {
        fxrp.mint(address(account), 50e6);
        vm.deal(parent, BRIDGE_FEE);
        vm.prank(parent);
        account.cancel{value: BRIDGE_FEE}(bytes32("op-c"), "");

        (
            uint32 eid,
            bytes32 destination,
            uint256 amount,
            ,
            ,
            bytes memory payload,

        ) = oft.lastSendParam();
        assertEq(eid, REMOTE_EID);
        assertEq(destination, bytes32(uint256(uint160(address(account)))));
        assertEq(amount, 0, "no tokens ride with a cancellation");
        (uint8 version, uint8 action, bytes memory actionData) =
            abi.decode(payload, (uint8, uint8, bytes));
        assertEq(version, PAYLOAD_VERSION_1);
        assertEq(action, ACTION_CANCEL);
        assertEq(actionData, abi.encode(bytes32("op-c")), "the id is the whole instruction");
        // the staged collateral is untouched and the fee is exactly the quote
        assertEq(fxrp.balanceOf(address(account)), 50e6);
        assertEq(oft.lastValue(), BRIDGE_FEE);
        assertEq(parent.balance, 0);
    }

    /// @notice Only the parent may burn an id, and a zero id is refused before the bridge fee.
    function testCancelIsParentOnlyAndRejectsAZeroIdBeforeTheBridgeFee() public {
        vm.deal(parent, BRIDGE_FEE);
        vm.prank(parent);
        vm.expectRevert(ILoanSubaccount.InvalidLoanInstruction.selector);
        account.cancel{value: BRIDGE_FEE}(bytes32(0), "");

        address stranger = makeAddr("stranger");
        vm.deal(stranger, BRIDGE_FEE);
        vm.prank(stranger);
        vm.expectRevert(ISubaccount.OnlyParent.selector);
        account.cancel{value: BRIDGE_FEE}(bytes32("op-c"), "");

        assertEq(parent.balance, BRIDGE_FEE);
        assertEq(oft.lastValue(), 0);
        assertEq(address(oft).balance, 0);
    }

    /**
     * @dev The homebound half of the same hazard the loan chain has: the withdrawal's arrival is a
     * composed message, and the Flare side authenticates it against whatever `setFxrpOft` currently
     * names, derived live rather than stored. So rotating the adapter under a packet that is
     * already queued kills that packet here too. What differs is the recovery: on Flare the FXRP
     * the old adapter credited is redeemable by anyone through `sweepRedeem`, which reads the
     * balance and needs no compose at all, so the user's assets still reach XRPL.
     *
     * As on the loan chain, the sender check is the first of two barriers: the GUID embeds the
     * adapter, so removing the sender check leaves `WrongGuid` refusing the same packet.
     */
    function testRotatingTheAdapterKillsAQueuedRedeemHomeButNotTheRedemption() public {
        fxrp.mint(address(account), 100e6);
        (bytes memory message, bytes32 guid) = _queueHome(1, 100e6);

        MockOft rotated = new MockOft(fxrp, BRIDGE_FEE);
        rotated.setEndpoint(address(endpoint));
        rotated.setPeer(REMOTE_EID, remotePeer);
        vm.prank(owner);
        controller.setFxrpOft(address(rotated));

        // the queued packet is refused on the sender the rotation replaced
        vm.expectRevert(
            abi.encodeWithSelector(IComposeReceiverAccountBase.WrongComposeSender.selector, address(oft))
        );
        _deliverHome(message, guid, EXECUTOR_FEE);
        assertEq(fxrp.balanceOf(address(account)), 100e6, "and the credited FXRP is still sitting here");

        // the compose-free path is unaffected, so the redemption still happens
        _expectHomeRedemption(100e6, 2 * EXECUTOR_FEE);
        (uint256 amount, uint256 redeemed) = account.sweepRedeem{value: 2 * EXECUTOR_FEE}();
        assertEq(amount, 100e6);
        assertEq(redeemed, 100e6);
        _assertHomeRequest(1, 100e6);
        assertEq(fxrp.balanceOf(address(account)), 0, "the rotation cost the instruction, not the funds");
    }
}
