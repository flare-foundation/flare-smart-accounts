// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LoanRemoteFixture} from "../utils/LoanRemoteFixture.sol";
import {
    MockCallbackToken,
    CALLBACK_ON_TRANSFER,
    CALLBACK_ON_TRANSFER_FROM,
    CALLBACK_ON_APPROVE
} from "../../contracts/mock/MockCallbackToken.sol";
import {
    MockFaultyParent,
    MODE_REJECT,
    MODE_EXHAUST_GAS,
    MODE_REENTER
} from "../../contracts/mock/MockFaultyParent.sol";
import {MockOft} from "../../contracts/mock/MockOft.sol";
import {MorphoLoanSubaccountRemote} from "../../contracts/smartAccounts/implementation/MorphoLoanSubaccountRemote.sol";
import {SubaccountProxy} from "../../contracts/smartAccounts/proxy/SubaccountProxy.sol";
import {MockFreezableToken} from "../../contracts/mock/MockFreezableToken.sol";
import {IMorphoLoanSubaccountRemote} from "../../contracts/userInterfaces/IMorphoLoanSubaccountRemote.sol";
import {IComposeReceiverAccountBase} from "../../contracts/userInterfaces/IComposeReceiverAccountBase.sol";
import {IComposeTransportFacet} from "../../contracts/userInterfaces/facets/IComposeTransportFacet.sol";
import {IIComposeTransportFacet} from "../../contracts/smartAccounts/interface/IIComposeTransportFacet.sol";
import {IIMorphoLoanMarketsFacet} from "../../contracts/smartAccounts/interface/IIMorphoLoanMarketsFacet.sol";
import {IMorphoLoanMarketsFacet} from "../../contracts/userInterfaces/facets/IMorphoLoanMarketsFacet.sol";
import {IPauseFacet} from "../../contracts/userInterfaces/facets/IPauseFacet.sol";
import {OFTComposeMsgCodec} from "@layerzerolabs/oft-evm/contracts/libs/OFTComposeMsgCodec.sol";
import {GUID} from "@layerzerolabs/lz-evm-protocol-v2/contracts/libs/GUID.sol";
import {Errors} from "@layerzerolabs/lz-evm-protocol-v2/contracts/libs/Errors.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title LoanOriginationAttacksTest
 * @notice Loan-chain attack tests. Every test names the attack it rules out and asserts the end
 * state (debt, operation id, queue entry, balances), so a passing negative test pins the defense.
 * Positions are healthy by default; faults are injected through the callback token, the faulty
 * parent and the endpoint's real compose-queue semantics.
 */
contract LoanOriginationAttacksTest is LoanRemoteFixture {
    function setUp() public {
        _setUpRemoteFixture();
    }

    /// Rules out duplicate supply for every relative ordering of rail and deposit compose.
    function testDepositAndComposeAllOrderings() public {
        uint256 snapshot = vm.snapshotState();
        for (uint256 order = 0; order < 3; order++) {
            fxrp.mint(address(account), 100e6);
            if (order == 0) {
                account.depositIdleFxrp();
            }
            _deliver(10, 100e6, _deposit(), 0);
            if (order == 1) {
                vm.expectRevert(
                    IMorphoLoanSubaccountRemote.NothingToDeposit.selector
                );
                account.depositIdleFxrp();
            }
            if (order == 2) {
                fxrp.mint(address(account), 1e6);
                account.depositIdleFxrp();
            }
            assertEq(_collateral(), order == 2 ? 101e6 : 100e6);
            assertEq(fxrp.balanceOf(address(account)), 0);
            assertTrue(vm.revertToState(snapshot));
        }
    }

    /// A rail before credit cannot consume future credit or make the later compose double-supply.
    function testDepositBeforeCreditCannotConsumeFutureTokens() public {
        vm.expectRevert(IMorphoLoanSubaccountRemote.NothingToDeposit.selector);
        account.depositIdleFxrp();
        fxrp.mint(address(account), 100e6);
        _deliver(2, 100e6, _deposit(), 0);
        assertEq(_collateral(), 100e6);
    }

    /// Partial liquidation between deposit and borrow keeps the signed borrow subject to live health.
    function testLiquidationBetweenDepositAndBorrowRejectsUnhealthyBorrow() public {
        _open(10_000e18);
        fxrp.mint(address(account), 100e6);
        account.depositIdleFxrp();
        oracle.setPrice(1e48);
        _liquidate(_shares() / 2);
        uint256 debt = _debt();
        (bytes memory message, bytes32 guid) = _queue(
            address(account),
            2,
            100e6,
            _borrow(bytes32("late"), 1_000e18)
        );
        vm.expectRevert(bytes("insufficient collateral"));
        endpoint.deliver(address(oft), address(account), guid, message);
        assertEq(_debt(), debt);
        assertFalse(account.usedOperations(bytes32("late")));
        assertEq(
            endpoint.composeQueue(address(oft), address(account), guid, 0),
            keccak256(message)
        );
    }

    /// A partial liquidation after the rail still lets a healthy delayed borrow use only live collateral.
    function testPartialLiquidationAfterRailAllowsHealthyDelayedBorrow() public {
        _open(10_000e18);
        fxrp.mint(address(account), 100e6);
        account.depositIdleFxrp();
        _liquidate(_shares() / 2);
        uint256 collateral = _collateral();
        uint256 debt = _debt();
        uint256 parentBalance = loanToken.balanceOf(parent);

        _deliver(2, 100e6, _borrow(bytes32("healthy late"), 1_000e18), 0);

        assertEq(_collateral(), collateral);
        assertEq(_debt(), debt + 1_000e18);
        assertEq(loanToken.balanceOf(parent), parentBalance + 1_000e18);
        assertEq(fxrp.balanceOf(address(account)), 0);
        assertTrue(account.usedOperations(bytes32("healthy late")));
    }

    /// A partial liquidation after deposit compose leaves no credited token for a later rail call.
    function testPartialLiquidationAfterDepositComposeLeavesRailEmpty() public {
        _open(10_000e18);
        fxrp.mint(address(account), 100e6);
        _deliver(2, 100e6, _deposit(), 0);
        _liquidate(_shares() / 2);
        uint256 collateral = _collateral();
        uint256 debt = _debt();

        vm.expectRevert(IMorphoLoanSubaccountRemote.NothingToDeposit.selector);
        account.depositIdleFxrp();

        assertEq(_collateral(), collateral);
        assertEq(_debt(), debt);
        assertEq(fxrp.balanceOf(address(account)), 0);
    }

    /// Full liquidation can consume already-deposited credit; an empty deposit compose is harmless.
    function testFullLiquidationBetweenRailAndDepositCompose() public {
        _open(10_000e18);
        fxrp.mint(address(account), 100e6);
        account.depositIdleFxrp();
        oracle.setPrice(1e48);
        _liquidate(_shares());
        _deliver(2, 100e6, _deposit(), 0);
        assertEq(_collateral(), 0);
        assertEq(_debt(), 0);
        assertEq(fxrp.balanceOf(address(account)), 0);
    }

    /// Full liquidation after compose leaves no idle credit for a later permissionless deposit.
    function testFullLiquidationBetweenDepositComposeAndRail() public {
        _open(10_000e18);
        fxrp.mint(address(account), 100e6);
        _deliver(2, 100e6, _deposit(), 0);
        oracle.setPrice(1e48);
        _liquidate(_shares());
        vm.expectRevert(IMorphoLoanSubaccountRemote.NothingToDeposit.selector);
        account.depositIdleFxrp();
        assertEq(_collateral(), 0);
        assertEq(_debt(), 0);
        assertEq(fxrp.balanceOf(address(account)), 0);
    }

    /// If liquidation precedes credit/deposit, subsequent credit funds only the user's position.
    function testLiquidationBeforeCreditThenCompose() public {
        _open(10_000e18);
        oracle.setPrice(1e48);
        _liquidate(_shares());
        fxrp.mint(address(account), 100e6);
        _deliver(2, 100e6, _deposit(), 0);
        assertEq(_collateral(), 100e6);
        assertEq(_debt(), 0);
    }

    /// LayerZero's vendored queue semantics reject a delivered GUID replay, even with the same nonce.
    function testExecutedGuidCannotReplayThroughEndpoint() public {
        _open(1_000e18);
        (bytes memory message, bytes32 guid) = _packet(
            address(account),
            1,
            10_000e6,
            _borrow(bytes32("initial"), 1_000e18)
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.LZ_ComposeNotFound.selector,
                bytes32(uint256(1)),
                keccak256(message)
            )
        );
        endpoint.deliver(address(oft), address(account), guid, message);
        vm.prank(address(oft));
        vm.expectRevert(Errors.LZ_ComposeExists.selector);
        endpoint.sendCompose(address(account), guid, 0, message);
        assertEq(_debt(), 1_000e18);
    }

    /// A new operation ID inside an authenticated queued packet fails the queue hash before account authentication.
    function testMutatedPayloadCannotReuseQueuedNonce() public {
        fxrp.mint(address(account), 10_000e6);
        (bytes memory original, bytes32 guid) = _queue(
            address(account),
            2,
            10_000e6,
            _borrow(bytes32("signed"), 1_000e18)
        );
        (bytes memory changed, ) = _packet(
            address(account),
            2,
            10_000e6,
            _borrow(bytes32("mutated"), 2_000e18)
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.LZ_ComposeNotFound.selector,
                keccak256(original),
                keccak256(changed)
            )
        );
        endpoint.deliver(address(oft), address(account), guid, changed);
        assertEq(_debt(), 0);
        assertFalse(account.usedOperations(bytes32("mutated")));
    }

    /// Source EID off by one is rejected even for an OFT-queued packet.
    function testOffByOneSourceEidRejected() public {
        bytes memory message = OFTComposeMsgCodec.encode(
            2,
            ORIGIN_EID + 1,
            0,
            abi.encodePacked(
                bytes32(uint256(uint160(address(account)))),
                _borrow(bytes32("bad"), 1)
            )
        );
        _queueMalformedAndReject(
            message,
            abi.encodeWithSelector(
                IComposeReceiverAccountBase.WrongSourceEid.selector,
                ORIGIN_EID + 1
            )
        );
    }

    /// Source account off by one cannot authorize a borrow against this account.
    function testOffByOneComposeFromRejected() public {
        bytes32 wrongFrom = bytes32(uint256(uint160(address(account))) + 1);
        bytes memory message = OFTComposeMsgCodec.encode(
            2,
            ORIGIN_EID,
            0,
            abi.encodePacked(wrongFrom, _borrow(bytes32("bad"), 1))
        );
        _queueMalformedAndReject(
            message,
            abi.encodeWithSelector(
                IComposeReceiverAccountBase.WrongComposeFrom.selector,
                wrongFrom
            )
        );
    }

    /// Independent authentic packets with the same operation ID cannot borrow twice.
    function testNewPacketSameOperationCannotDoubleBorrow() public {
        _open(1_000e18);
        _deliver(2, 0, _borrow(bytes32("initial"), 2_000e18), 0);
        assertEq(_debt(), 1_000e18);
        assertEq(loanToken.balanceOf(parent), 1_000e18);
    }

    /// A forged-peer GUID inserted under the trusted OFT queue key still cannot authorize a borrow.
    function testTrustedQueueInjectionWithForgedPeerCannotBorrow() public {
        address attackerPeer = makeAddr("temporary attacker peer");
        uint64 nonce = 3;
        bytes memory message = OFTComposeMsgCodec.encode(
            nonce,
            ORIGIN_EID,
            0,
            abi.encodePacked(
                bytes32(uint256(uint160(address(account)))),
                _borrow(bytes32("forged"), 1e18)
            )
        );
        bytes32 forgedGuid = GUID.generate(
            nonce,
            ORIGIN_EID,
            attackerPeer,
            DESTINATION_EID,
            bytes32(uint256(uint160(address(oft))))
        );
        // Direct insertion models post-admission state; the local harness does not implement OFT receive checks.
        vm.prank(address(oft));
        endpoint.sendCompose(address(account), forgedGuid, 0, message);
        vm.expectRevert(
            abi.encodeWithSelector(
                IComposeReceiverAccountBase.WrongGuid.selector,
                forgedGuid
            )
        );
        endpoint.deliver(address(oft), address(account), forgedGuid, message);
        assertFalse(account.usedOperations(bytes32("forged")));
        assertEq(_debt(), 0);
        assertEq(
            endpoint.composeQueue(
                address(oft),
                address(account),
                forgedGuid,
                0
            ),
            keccak256(message)
        );
    }

    /// An out-of-policy token callback changing the return peer makes withdrawal fail atomically.
    function testPeerSwapDuringCollateralTransferFailsClosed() public {
        _open(1_000e18);
        MockCallbackToken(address(fxrp)).setCallback(
            CALLBACK_ON_TRANSFER,
            address(morpho),
            address(oft),
            abi.encodeCall(oft.setPeer, (ORIGIN_EID, bytes32(uint256(7))))
        );
        _withdrawMustRevert(
            IMorphoLoanSubaccountRemote.WrongOriginPeer.selector,
            RETURN_VALUE
        );
        assertEq(oft.peers(ORIGIN_EID), originPeer);
    }

    /// An out-of-policy token callback raising the quote leaves the packet and collateral retriable.
    function testQuoteIncreaseAfterFloorBeforeQuoteRollsBack() public {
        _open(1_000e18);
        MockCallbackToken(address(fxrp)).setCallback(
            CALLBACK_ON_TRANSFER,
            address(morpho),
            address(oft),
            abi.encodeCall(oft.setNativeFee, (2 * RETURN_VALUE))
        );
        _withdrawMustRevert(
            abi.encodeWithSelector(
                IMorphoLoanSubaccountRemote.InsufficientFundsForBridgeHome.selector,
                2 * RETURN_VALUE
            ),
            RETURN_VALUE
        );
    }

    /// An adapter fee rising between the quote and the send (here from the approve callback) reverts the
    /// whole withdrawal, as the endpoint's live fee check would.
    function testQuoteIncreaseBetweenQuoteAndSendRollsBack() public {
        _open(1_000e18);
        MockCallbackToken(address(fxrp)).setCallback(
            CALLBACK_ON_APPROVE,
            address(account),
            address(oft),
            abi.encodeCall(oft.setNativeFee, (2 * RETURN_VALUE))
        );
        _withdrawMustRevert(
            abi.encodeWithSelector(MockOft.NativeFeeBelowQuote.selector, 2 * RETURN_VALUE, RETURN_VALUE),
            RETURN_VALUE
        );
    }

    /// A false fee transfer cannot cancel debt repayment or erase the deferred fee claim.
    function testFalseFeeTransferDefersAndRepaysDebt() public {
        MockCallbackToken token = _useCallbackLoanToken();
        _open(1_000e18);
        vm.warp(block.timestamp + YEAR);
        account.checkpointFee();
        token.setFalseRecipient(collector);
        token.mint(address(account), 500e18);
        assertEq(account.repay(), 500e18);
        (, uint256 fee, uint256 collectible, , , ) = account.getLoanFeeState();
        assertEq(fee, 70e36);
        assertEq(collectible, 70e18);
        assertEq(token.balanceOf(collector), 0);
        assertEq(_debt(), 500e18);
    }

    /// A recipient-specific revert reserves a debt-free fee while releasing only surplus.
    function testRevertingFeeRecipientReservesExactClaim() public {
        _open(1_000e18);
        vm.warp(block.timestamp + YEAR);
        account.checkpointFee();
        MockFreezableToken(address(loanToken)).setFrozen(collector, true);
        loanToken.mint(address(account), 1_100e18);
        account.repay();
        assertEq(_debt(), 0);
        assertEq(loanToken.balanceOf(address(account)), 70e18);
        assertEq(loanToken.balanceOf(parent), 1_030e18);
        (uint256 principal, uint256 fee, uint256 collectible, , , ) = account.getLoanFeeState();
        assertEq(principal, 0);
        assertEq(fee, 70e36);
        assertEq(collectible, 70e18);
        assertEq(loanToken.balanceOf(collector), 0);
    }

    /// Reentry from the fee transfer hits the transient guard while ordinary payment succeeds.
    function testTransferReentryCannotDoubleCollectFee() public {
        _reentrantRepayment(CALLBACK_ON_TRANSFER);
    }

    /// Reentry from Morpho's transferFrom hits the same guard and cannot double-repay.
    function testTransferFromReentryCannotDoubleRepay() public {
        _reentrantRepayment(CALLBACK_ON_TRANSFER_FROM);
    }

    /// A false Morpho token pull reverts all earlier fee collection and preserves the full balance.
    function testFalseMorphoPullRollsBackPriorFeeTransfer() public {
        MockCallbackToken token = _useCallbackLoanToken();
        _open(1_000e18);
        vm.warp(block.timestamp + YEAR);
        account.checkpointFee();
        token.setFalseRecipient(address(morpho));
        token.mint(address(account), 500e18);
        vm.expectRevert(
            abi.encodeWithSelector(
                SafeERC20.SafeERC20FailedOperation.selector,
                address(token)
            )
        );
        account.repay();
        assertEq(token.balanceOf(collector), 0);
        assertEq(token.balanceOf(address(account)), 500e18);
        assertEq(_debt(), 1_000e18);
    }

    /// Exact one-unit boundaries around D and D+F pin the documented rounded pro-rata closure.
    function testProRataEveryDebtAndTotalBoundary() public {
        _roundingBoundaries(0.07e18, YEAR);
    }

    /// The same boundaries with F>D pin closure caused by the documented floor-to-fee rounding.
    function testProRataBoundariesWithFeeAboveDebt() public {
        _roundingBoundaries(1e18, 2 * YEAR);
        (, , uint256 fee, , , ) = account.getLoanFeeState();
        assertGt(fee, 100);
    }

    /// Fee dust is retained while debt remains open, even when the zero-collectible exit succeeds.
    function testDebtOpenWithdrawalCannotForgiveDust() public {
        _open(1);
        vm.warp(block.timestamp + 1);
        account.checkpointFee();
        (, uint256 beforeFee, , , , ) = account.getLoanFeeState();
        assertGt(beforeFee, 0);
        assertLt(beforeFee, WAD);
        assertEq(_debt(), 1);
        uint256 collateralBefore = _collateral();
        _deliver(
            2,
            0,
            _withdraw(bytes32("dust"), 1e6, RETURN_VALUE),
            RETURN_VALUE
        );
        (uint256 principal, uint256 afterFee, , , , ) = account.getLoanFeeState();
        assertEq(principal, 1);
        assertEq(afterFee, beforeFee);
        assertTrue(account.usedOperations(bytes32("dust")));
        assertEq(_collateral(), collateralBefore - 1e6);
        assertEq(fxrp.balanceOf(address(oft)), 1e6);
    }

    /// An unobserved full liquidation cannot bypass a fee checkpoint or the exit gate.
    function testStalePrincipalAfterLiquidationCannotBypassExit() public {
        _open(10_000e18);
        vm.warp(block.timestamp + YEAR);
        oracle.setPrice(1e48);
        _liquidate(_shares());
        fxrp.mint(address(account), 1_000e6);
        account.depositIdleFxrp();
        // debt-free, the 700 fee needs 3x its size covered: 2100 against the 999 RLUSD the
        // 999 FXRP left are worth at the new price
        _withdrawMustRevert(
            abi.encodeWithSelector(
                IMorphoLoanSubaccountRemote.InsufficientRemainingCollateral.selector,
                2100e18,
                999e18
            ),
            RETURN_VALUE
        );
        // The rejected execution rolls back its checkpoint, so stored principal remains stale.
        (uint256 principal, , , , , ) = account.getLoanFeeState();
        assertEq(principal, 10_000e18);
        assertEq(_debt(), 0);
    }

    /// An expired withdrawal below its signed value floor cannot consume its queued packet.
    function testExpiredBelowFloorCannotConsumePacket() public {
        _open(1_000e18);
        (bytes memory message, bytes32 guid) = _queue(
            address(account),
            2,
            0,
            _withdraw(bytes32("expired"), 1e6, RETURN_VALUE)
        );
        vm.warp(block.timestamp + 2 hours);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMorphoLoanSubaccountRemote.InsufficientDeliveryValue.selector,
                RETURN_VALUE
            )
        );
        endpoint.deliver(address(oft), address(account), guid, message);
        assertEq(
            endpoint.composeQueue(address(oft), address(account), guid, 0),
            keccak256(message)
        );
        assertFalse(account.usedOperations(bytes32("expired")));
    }

    /// A rejecting fixed parent cannot strand compose value or consume a failed withdrawal.
    function testRejectingParentRollsBackWithdrawal() public {
        _parentFailure(MODE_REJECT);
    }

    /// A gas-consuming parent makes delivery fail atomically under a bounded execution gas budget.
    function testGasConsumingParentRollsBackWithdrawal() public {
        _parentFailure(MODE_EXHAUST_GAS);
    }

    /// A native-refund callback cannot reenter repayment or redirect the refunded value.
    function testParentReentryCannotRedirectRefund() public {
        MockFaultyParent receiver = _useParent();
        receiver.configure(MODE_REENTER, address(account), abi.encodeCall(account.repay, ()));
        _open(1_000e18);
        _deliver(
            2,
            0,
            _withdraw(bytes32("refund"), 1e6, RETURN_VALUE),
            2 * RETURN_VALUE
        );
        assertEq(address(receiver).balance, RETURN_VALUE);
        assertEq(receiver.calls(), 1);
        assertEq(
            receiver.callbackError(),
            abi.encodeWithSelector(
                ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector
            )
        );
        assertEq(_debt(), 1_000e18);
    }

    /// Same parent, market and operation ID remain isolated between two subaccount types.
    function testTwoTypesSharingMarketAndOperationIdAreIsolated() public {
        _open(1_000e18);
        MorphoLoanSubaccountRemote first = account;
        address implementation = account.implementation();
        vm.startPrank(owner);
        controller.setSubaccountImplementation(2, implementation);
        IIMorphoLoanMarketsFacet(address(controller)).registerLoanMarket(
            2,
            IMorphoLoanMarketsFacet.Market(address(morpho), params)
        );
        vm.stopPrank();
        _setTerms(2, 0.07e18, 0.01e18);
        account = MorphoLoanSubaccountRemote(
            address(new SubaccountProxy(address(controller), parent, 2))
        );
        fxrp.mint(address(account), 10_000e6);
        _deliver(2, 10_000e6, _borrow(bytes32("initial"), 500e18), 0);
        assertTrue(first.usedOperations(bytes32("initial")));
        assertTrue(account.usedOperations(bytes32("initial")));
        assertEq(_debt(), 500e18);
        account = first;
        assertEq(_debt(), 1_000e18);
    }

    /// A pause blocks new debt but permits a debt-reducing rail without routing to its caller.
    function testPauseCannotBeBypassedByBorrowCompose() public {
        _open(1_000e18);
        vm.prank(owner);
        controller.pause();
        (bytes memory message, bytes32 guid) = _queue(
            address(account),
            2,
            0,
            _borrow(bytes32("paused"), 1)
        );
        vm.expectRevert(IPauseFacet.IsPaused.selector);
        endpoint.deliver(address(oft), address(account), guid, message);
        loanToken.mint(address(account), 500e18);
        account.repay();
        assertEq(_debt(), 500e18);
        assertEq(loanToken.balanceOf(address(this)), 0);
    }

    /// Existing accrued fees go to the currently configured recipient after an authorized rotation.
    function testRecipientRotationDoesNotErasePreviouslyAccruedFee() public {
        _open(1_000e18);
        vm.warp(block.timestamp + YEAR);
        account.checkpointFee();
        address previous = collector;
        collector = makeAddr("new collector");
        _setTerms(1, 0.07e18, 0.01e18);
        loanToken.mint(address(account), 1_070e18);
        account.repay();
        assertEq(loanToken.balanceOf(previous), 0);
        assertEq(loanToken.balanceOf(collector), 70e18);
    }

    /**
     * @dev Rotating the OFT under a packet that is already queued. The endpoint holds the compose
     * until someone executes it, so a rotation between `sendCompose` and `lzCompose` leaves a
     * packet whose sender is no longer the configured one. It must not execute - the whole point
     * of pinning the OFT is that a different one cannot deliver instructions - and the FXRP it
     * carried, already credited by the old OFT, must stay recoverable rather than strand.
     *
     * The sender check is the first of two barriers, not the only one: the GUID embeds the OFT as
     * the packet's receiver, so a rotated configuration refuses the packet twice over. Verified by
     * removing the sender check, which leaves `WrongGuid` refusing it instead.
     */
    function testRotatingTheOftKillsAQueuedPacketWithoutStrandingItsCollateral() public {
        fxrp.mint(address(account), 1_000e6);
        (bytes memory message, bytes32 guid) = _queue(address(account), 7, 1_000e6, _deposit());

        MockOft rotated = new MockOft(fxrp, RETURN_VALUE);
        rotated.setEndpoint(address(endpoint));
        rotated.setPeer(ORIGIN_EID, originPeer);
        vm.prank(owner);
        IIComposeTransportFacet(address(controller)).setComposeTransport(
            IComposeTransportFacet.Transport(address(endpoint), address(rotated), ORIGIN_EID, originPeer)
        );

        // the queued packet is refused on the first thing the rotation changed: who sent it
        vm.expectRevert(
            abi.encodeWithSelector(IComposeReceiverAccountBase.WrongComposeSender.selector, address(oft))
        );
        endpoint.deliver(address(oft), address(account), guid, message);
        assertEq(_collateral(), 0, "and nothing was supplied");

        // the collateral is not lost, only that instruction. `depositIdleFxrp` is permissionless
        // and reads the balance, so what the old OFT credited still goes in - and it needs no
        // packet at all, which is the point: inventing a second packet here would assert against
        // a credit no OFT ever delivered
        uint256 recovered = IMorphoLoanSubaccountRemote(address(account)).depositIdleFxrp();
        assertEq(recovered, 1_000e6, "the stranded credit is recoverable");
        assertEq(_collateral(), 1_000e6, "and it is supplied to the market");
    }

    function _queueMalformedAndReject(
        bytes memory _message,
        bytes memory _error
    )
        private
    {
        (, bytes32 guid) = _packet(address(account), 2, 0, _deposit());
        vm.prank(address(oft));
        endpoint.sendCompose(address(account), guid, 0, _message);
        vm.expectRevert(_error);
        endpoint.deliver(address(oft), address(account), guid, _message);
        assertEq(_debt(), 0);
    }

    function _withdrawMustRevert(
        bytes memory _error,
        uint256 _value
    )
        private
    {
        uint256 collateral = _collateral();
        (bytes memory message, bytes32 guid) = _queue(
            address(account),
            2,
            0,
            _withdraw(bytes32("failure"), 1e6, RETURN_VALUE)
        );
        vm.expectRevert(_error);
        endpoint.deliver{value: _value}(
            address(oft),
            address(account),
            guid,
            message
        );
        assertEq(_collateral(), collateral);
        assertFalse(account.usedOperations(bytes32("failure")));
        assertEq(fxrp.balanceOf(address(oft)), 0);
        assertEq(
            endpoint.composeQueue(address(oft), address(account), guid, 0),
            keccak256(message)
        );
    }

    function _withdrawMustRevert(
        bytes4 _error,
        uint256 _value
    )
        private
    {
        _withdrawMustRevert(abi.encodePacked(_error), _value);
    }

    function _useCallbackLoanToken(
    )
        private
        returns (MockCallbackToken _token)
    {
        _token = new MockCallbackToken(18);
        loanToken = _token;
        address implementation = account.implementation();
        vm.prank(owner);
        controller.setSubaccountImplementation(2, implementation);
        _configureMarket(2, loanToken);
        account = MorphoLoanSubaccountRemote(
            address(new SubaccountProxy(address(controller), parent, 2))
        );
    }

    function _reentrantRepayment(
        uint8 _kind
    )
        private
    {
        MockCallbackToken token = _useCallbackLoanToken();
        _open(1_000e18);
        vm.warp(block.timestamp + YEAR);
        token.setCallback(
            _kind,
            _kind == CALLBACK_ON_TRANSFER ? address(account) : address(morpho),
            address(account),
            abi.encodeCall(account.repay, ())
        );
        token.mint(address(account), 1_070e18);
        account.repay();
        assertGt(token.callbackCount(), 0);
        assertEq(
            token.callbackError(),
            abi.encodeWithSelector(
                ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector
            )
        );
        assertEq(_debt(), 0);
        assertEq(token.balanceOf(collector), 70e18);
    }

    function _roundingBoundaries(
        uint64 _floor,
        uint256 _elapsed
    )
        private
    {
        _setTerms(1, _floor, 0);
        _open(100);
        vm.warp(block.timestamp + _elapsed);
        account.checkpointFee();
        (, uint256 feeX18, uint256 fee, , , ) = account.getLoanFeeState();
        assertEq(feeX18, (100 * uint256(_floor) * _elapsed) / YEAR);
        uint256 snapshot = vm.snapshotState();
        uint256[6] memory payments = [
            uint256(99),
            100,
            101,
            99 + fee,
            100 + fee,
            101 + fee
        ];
        for (uint256 i = 0; i < payments.length; i++) {
            uint256 payment = payments[i];
            loanToken.mint(address(account), payment);
            uint256 feeShare =
                payment < 100 + fee ? (payment * fee) / (100 + fee) : fee;
            uint256 debtPaid = payment - feeShare;
            if (debtPaid > 100) {
                debtPaid = 100;
            }
            // With one borrower and zero interest the virtual-share ratio is exact here.
            assertEq(account.repay(), debtPaid);
            assertEq(_debt(), 100 - debtPaid);
            (, uint256 afterFee, , , , ) = account.getLoanFeeState();
            assertEq(afterFee, feeX18 - loanToken.balanceOf(collector) * WAD);
            assertEq(loanToken.balanceOf(collector), feeShare);
            if (_debt() > 0) {
                assertEq(loanToken.balanceOf(address(account)), 0);
            }
            assertTrue(vm.revertToState(snapshot));
        }
    }

    function _liquidate(
        uint128 _amount
    )
        private
    {
        uint256 debt = _debt();
        loanToken.mint(address(this), debt);
        loanToken.approve(address(morpho), debt);
        morpho.simulatePartialLiquidation(params, address(account), _amount);
    }

    function _useParent(
    )
        private
        returns (MockFaultyParent _receiver)
    {
        _receiver = new MockFaultyParent();
        parent = address(_receiver);
        account = MorphoLoanSubaccountRemote(
            address(new SubaccountProxy(address(controller), parent, 1))
        );
    }

    function _parentFailure(
        uint8 _mode
    )
        private
    {
        MockFaultyParent receiver = _useParent();
        receiver.configure(_mode, address(0), "");
        _open(1_000e18);
        (bytes memory message, bytes32 guid) = _queue(
            address(account),
            2,
            0,
            _withdraw(bytes32("parent failure"), 1e6, RETURN_VALUE)
        );
        // Bound gas so the deliberately consuming receiver cannot stall the test process.
        vm.expectRevert(IMorphoLoanSubaccountRemote.RefundFailed.selector);
        endpoint.deliver{value: 2 * RETURN_VALUE, gas: 2_000_000}(
            address(oft),
            address(account),
            guid,
            message
        );
        assertEq(_collateral(), 10_000e6);
        assertEq(address(receiver).balance, 0);
        assertFalse(account.usedOperations(bytes32("parent failure")));
    }

}
