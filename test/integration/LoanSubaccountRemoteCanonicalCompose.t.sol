// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LoanRemoteFixture} from "../utils/LoanRemoteFixture.sol";
import {ILoanSubaccountRemote, ACTION_CANCEL} from "../../contracts/userInterfaces/ILoanSubaccountRemote.sol";
import {PAYLOAD_VERSION_1} from "../../contracts/userInterfaces/IComposeReceiverAccountBase.sol";
import {IComposeReceiverAccountBase} from "../../contracts/userInterfaces/IComposeReceiverAccountBase.sol";
import {IComposeTransportFacet} from "../../contracts/userInterfaces/facets/IComposeTransportFacet.sol";
import {IIComposeTransportFacet} from "../../contracts/smartAccounts/interface/IIComposeTransportFacet.sol";
import {CanonicalComposeEndpoint} from "../../contracts/mock/CanonicalComposeEndpoint.sol";
import {Errors} from "@layerzerolabs/lz-evm-protocol-v2/contracts/libs/Errors.sol";

/**
 * @title LoanSubaccountRemoteCanonicalComposeTest
 * @notice The loan account against canonical LayerZero's own compose queue, not the fixture's
 * mock. `MessagingComposer` is what decides whether a packet may execute, whether a failed one
 * survives to be retried, and whether a delivered one can run twice - and every one of those is
 * a property the accounts rely on rather than implement. A mock that agrees with our reading of
 * the codec proves only that we are consistent with ourselves.
 *
 * The endpoint is deployed here rather than forked: `sendCompose` and `lzCompose` touch no
 * messaging library, no DVN and no executor, so the real contract needs nothing but its own
 * constructor to give real semantics. Everything else is the mocked fixture - the OFT, the
 * market, the oracle and the rate model - because the queue's rules are the subject here; the
 * fork suite is where the market is real.
 */
contract LoanSubaccountRemoteCanonicalComposeTest is LoanRemoteFixture {
    /// @dev Provisional compose-gas budgets: the measured cost with headroom - see the gas test.
    uint256 private constant BUDGET_DEPOSIT = 350_000;
    uint256 private constant BUDGET_BORROW = 650_000;
    uint256 private constant BUDGET_WITHDRAW = 1_200_000;

    CanonicalComposeEndpoint internal canonical;

    function setUp() public {
        _setUpRemoteFixture();
        // the account derives the expected GUID from the endpoint's own eid, so the canonical
        // endpoint has to be this chain's
        canonical = new CanonicalComposeEndpoint(DESTINATION_EID);
        oft.setEndpoint(address(canonical));
        vm.prank(owner);
        IIComposeTransportFacet(address(controller)).setComposeTransport(
            IComposeTransportFacet.Transport(address(canonical), address(oft), ORIGIN_EID, originPeer)
        );
    }

    function testTheCanonicalQueueDeliversEveryForwardActionAtIndexZero() public {
        fxrp.mint(address(account), 10_000e6);
        (bytes memory deposit, bytes32 depositGuid) = _queueCanonical(1, 10_000e6, _deposit());
        _executeCanonical(deposit, depositGuid, 0);
        assertEq(_collateral(), 10_000e6, "the deposit supplied through the real queue");

        (bytes memory borrow, bytes32 borrowGuid) = _queueCanonical(2, 0, _borrow(bytes32("b1"), 1_000e18));
        _executeCanonical(borrow, borrowGuid, 0);
        assertEq(loanToken.balanceOf(parent), 1_000e18, "the borrow paid out through the real queue");

        (bytes memory withdraw, bytes32 withdrawGuid) = _queueCanonical(3, 0, _withdraw(bytes32("w1"), 1e6, 0));
        _executeCanonical(withdraw, withdrawGuid, RETURN_VALUE);
        assertEq(_collateral(), 10_000e6 - 1e6, "and the withdrawal took its collateral out");

        (bytes memory cancel, bytes32 cancelGuid) = _queueCanonical(4, 0, _cancelPayload(bytes32("c1")));
        _executeCanonical(cancel, cancelGuid, 0);
        assertTrue(
            ILoanSubaccountRemote(address(account)).usedOperations(bytes32("c1")),
            "and the cancel consumed the id it names"
        );
    }

    function testAFailedComposeKeepsItsQueueEntryAndThatSameEntryLandsLater() public {
        fxrp.mint(address(account), 10_000e6);
        (bytes memory deposit, bytes32 depositGuid) = _queueCanonical(1, 10_000e6, _deposit());
        _executeCanonical(deposit, depositGuid, 0);

        // one unit past what the cover gate allows on this collateral, so our own gate refuses
        // it: the cover is the stricter line, and asking for the exact overshoot keeps Morpho's
        // health check out of the picture rather than leaving which one fired ambiguous
        uint256 overCover = ILoanSubaccountRemote(address(account)).getLoanLimits(0).maxBorrowByCover + 1;
        ILoanSubaccountRemote.BorrowPreview memory refused =
            ILoanSubaccountRemote(address(account)).previewBorrow(overCover, 0);
        (bytes memory borrow, bytes32 borrowGuid) = _queueCanonical(2, 0, _borrow(bytes32("b1"), overCover));
        vm.expectRevert(
            abi.encodeWithSelector(
                ILoanSubaccountRemote.InsufficientRemainingCollateral.selector,
                refused.requiredCover,
                refused.collateralValue
            )
        );
        _executeCanonical(borrow, borrowGuid, 0);
        assertEq(
            canonical.composeQueue(address(oft), address(account), borrowGuid, 0),
            keccak256(borrow),
            "a failed compose is still queued, unchanged"
        );
        assertEq(loanToken.balanceOf(parent), 0, "and nothing was paid out");

        // a rescue deposit makes the position able to carry it, and then the ORIGINAL entry
        // executes - same guid, same operation id, same amount. That is what a retry is; queueing
        // a smaller borrow under a fresh id would prove nothing about this entry
        fxrp.mint(address(account), 10_000e6);
        (bytes memory rescue, bytes32 rescueGuid) = _queueCanonical(3, 10_000e6, _deposit());
        _executeCanonical(rescue, rescueGuid, 0);
        _executeCanonical(borrow, borrowGuid, 0);
        assertEq(loanToken.balanceOf(parent), overCover, "the original packet paid out, unchanged");
    }

    function testADeliveredComposeCannotBeExecutedTwice() public {
        fxrp.mint(address(account), 10_000e6);
        (bytes memory deposit, bytes32 depositGuid) = _queueCanonical(1, 10_000e6, _deposit());
        _executeCanonical(deposit, depositGuid, 0);

        // the endpoint replaces the hash with its received sentinel, so the second attempt is
        // refused by the endpoint itself - before the account's own operation-id replay guard
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.LZ_ComposeNotFound.selector, bytes32(uint256(1)), keccak256(deposit)
            )
        );
        _executeCanonical(deposit, depositGuid, 0);
        assertEq(_collateral(), 10_000e6, "and the credit was supplied once");
    }

    function testTheSameGuidCannotBeQueuedTwice() public {
        (bytes memory message, bytes32 guid) = _queueCanonical(1, 0, _borrow(bytes32("b1"), 1_000e18));
        vm.prank(address(oft));
        vm.expectRevert(Errors.LZ_ComposeExists.selector);
        canonical.sendCompose(address(account), guid, 0, message);
    }

    function testATamperedMessageCannotExecuteAgainstAQueuedGuid() public {
        (bytes memory message, bytes32 guid) = _queueCanonical(1, 0, _borrow(bytes32("b1"), 1_000e18));
        bytes memory tampered = _packetMessage(1, 0, _borrow(bytes32("b1"), 2_000e18));
        vm.expectRevert(
            abi.encodeWithSelector(Errors.LZ_ComposeNotFound.selector, keccak256(message), keccak256(tampered))
        );
        _executeCanonical(tampered, guid, 0);
    }

    function testAnEntryAtAnotherIndexDoesNotSatisfyIndexZero() public {
        (bytes memory message, bytes32 guid) = _packet(address(account), 1, 0, _borrow(bytes32("b1"), 1_000e18));
        vm.prank(address(oft));
        canonical.sendCompose(address(account), guid, 1, message);
        vm.expectRevert(
            abi.encodeWithSelector(Errors.LZ_ComposeNotFound.selector, bytes32(0), keccak256(message))
        );
        _executeCanonical(message, guid, 0);
    }

    function testValueIsRefusedByEveryActionThatDoesNotSpendIt() public {
        // the withdrawal is the one action that spends its delivery value; the underfunded
        // withdrawal above is where that side is pinned. These three must refuse it, so that a
        // mistaken delivery stays retriable without value instead of stranding native here
        fxrp.mint(address(account), 10_000e6);
        vm.deal(address(this), 1 ether);

        (bytes memory deposit, bytes32 depositGuid) = _queueCanonical(1, 10_000e6, _deposit());
        vm.expectRevert(IComposeReceiverAccountBase.NonZeroComposeValue.selector);
        _executeCanonical(deposit, depositGuid, 1);
        // and the refusal leaves it retriable without value
        _executeCanonical(deposit, depositGuid, 0);
        assertEq(_collateral(), 10_000e6);

        (bytes memory borrow, bytes32 borrowGuid) = _queueCanonical(2, 0, _borrow(bytes32("b1"), 1_000e18));
        vm.expectRevert(IComposeReceiverAccountBase.NonZeroComposeValue.selector);
        _executeCanonical(borrow, borrowGuid, 1);

        (bytes memory cancel, bytes32 cancelGuid) = _queueCanonical(3, 0, _cancelPayload(bytes32("c1")));
        vm.expectRevert(IComposeReceiverAccountBase.NonZeroComposeValue.selector);
        _executeCanonical(cancel, cancelGuid, 1);
    }

    function testAnUnderfundedWithdrawalStaysQueuedAndTheFundedRetryLands() public {
        fxrp.mint(address(account), 10_000e6);
        (bytes memory deposit, bytes32 depositGuid) = _queueCanonical(1, 10_000e6, _deposit());
        _executeCanonical(deposit, depositGuid, 0);

        // the executor delivers without enough for the return leg: the account cannot pay the
        // OFT's quote, so the whole delivery reverts and the endpoint's entry survives it
        (bytes memory withdraw, bytes32 withdrawGuid) = _queueCanonical(2, 0, _withdraw(bytes32("w1"), 1e6, 0));
        vm.expectRevert(
            abi.encodeWithSelector(ILoanSubaccountRemote.InsufficientFundsForBridgeHome.selector, RETURN_VALUE)
        );
        _executeCanonical(withdraw, withdrawGuid, RETURN_VALUE - 1);
        assertEq(
            canonical.composeQueue(address(oft), address(account), withdrawGuid, 0),
            keccak256(withdraw),
            "an underfunded withdrawal is still queued"
        );
        assertEq(_collateral(), 10_000e6, "and took nothing out");

        // the same entry, funded correctly, goes through - the withdrawal is the one action that
        // spends its delivery value rather than refusing it
        _executeCanonical(withdraw, withdrawGuid, RETURN_VALUE);
        assertEq(_collateral(), 10_000e6 - 1e6, "the funded retry landed from the same entry");
    }

    /**
     * @dev The compose-gas half of the option budgets (item 9). Measured through the canonical
     * endpoint, so the endpoint's own dispatch overhead is inside the figure, which is what a
     * type-3 `lzCompose` option has to pay for.
     *
     * Measured 2026-09-09: deposit 171,487 first use and 137,313 on an accrued position; borrow
     * 324,813 and 299,253; withdraw 582,093 and 341,573. First use costs more in every case -
     * cold storage outweighs the extra work an accrued period brings. The budgets carry roughly
     * 2x over the peak of each pair.
     *
     * These are mock benchmarks, not production floors, and they can err in both directions. The
     * market, the oracle and the rate model here are mocks and cost less than the real adaptive
     * IRM and a Chainlink read; `MockOft.send` on the withdrawal's bridge leg, on the other hand,
     * stores its whole send parameters, which a real OFT need not do. Receive gas and the native
     * drop are not measured at all - both belong to the OFT and the remote Personal Account. So
     * the budgets below are provisional, and the testnet rehearsal is what replaces them.
     */
    function testComposeGasStaysInsideTheOptionBudgets() public {
        // a real rate, so the fee period and the market accrual are doing work rather than
        // short-circuiting on zero
        irm.setRate(1585489599);

        fxrp.mint(address(account), 10_000e6);
        assertLt(_composeGas(1, 10_000e6, _deposit(), 0), BUDGET_DEPOSIT, "deposit, first use");
        assertEq(_collateral(), 10_000e6, "the first-use deposit supplied");
        assertLt(_composeGas(2, 0, _borrow(bytes32("b1"), 1_000e18), 0), BUDGET_BORROW, "borrow, first use");
        assertLt(
            _composeGas(3, 0, _withdraw(bytes32("w1"), 1e6, 0), RETURN_VALUE), BUDGET_WITHDRAW, "withdraw, first use"
        );
        assertEq(_collateral(), 10_000e6 - 1e6, "the first-use withdrawal took its collateral out");

        // and on a position that has carried debt. Each measurement gets its own elapsed month:
        // the action before it checkpoints, so sharing one warp would leave the next with a
        // zero-length period and measure the wrong path
        fxrp.mint(address(account), 10_000e6);
        vm.warp(vm.getBlockTimestamp() + 30 days);
        assertLt(_composeGas(4, 10_000e6, _deposit(), 0), BUDGET_DEPOSIT, "deposit, accrued");
        assertEq(_collateral(), 20_000e6 - 1e6, "the accrued deposit supplied its own credit");
        vm.warp(vm.getBlockTimestamp() + 30 days);
        assertLt(_composeGas(5, 0, _borrow(bytes32("b2"), 1_000e18), 0), BUDGET_BORROW, "borrow, accrued");
        assertEq(loanToken.balanceOf(parent), 2_000e18, "the accrued borrow paid out");
        vm.warp(vm.getBlockTimestamp() + 30 days);
        assertLt(
            _composeGas(6, 0, _withdraw(bytes32("w2"), 1e6, 0), RETURN_VALUE), BUDGET_WITHDRAW, "withdraw, accrued"
        );
        assertEq(_collateral(), 20_000e6 - 2e6, "the accrued withdrawal took its collateral out");
    }

    /// @dev Queues and executes one packet, returning the gas its execution cost.
    function _composeGas(
        uint64 _nonce,
        uint256 _credit,
        bytes memory _payload,
        uint256 _value
    )
        private
        returns (uint256 _used)
    {
        (bytes memory message, bytes32 guid) = _queueCanonical(_nonce, _credit, _payload);
        uint256 before = gasleft();
        _executeCanonical(message, guid, _value);
        _used = before - gasleft();
    }

    /// @dev Queues a packet through the canonical endpoint exactly as an OFT would.
    function _queueCanonical(
        uint64 _nonce,
        uint256 _credit,
        bytes memory _payload
    )
        private
        returns (bytes memory _message, bytes32 _guid)
    {
        (_message, _guid) = _packet(address(account), _nonce, _credit, _payload);
        vm.prank(address(oft));
        canonical.sendCompose(address(account), _guid, 0, _message);
    }

    /// @dev Executes it the way an executor would, from an arbitrary caller.
    function _executeCanonical(
        bytes memory _message,
        bytes32 _guid,
        uint256 _value
    )
        private
    {
        canonical.lzCompose{value: _value}(address(oft), address(account), _guid, 0, _message, "");
    }

    function _packetMessage(
        uint64 _nonce,
        uint256 _credit,
        bytes memory _payload
    )
        private view
        returns (bytes memory _message)
    {
        (_message, ) = _packet(address(account), _nonce, _credit, _payload);
    }

    /// @dev A cancel instruction is its operation id and nothing else.
    function _cancelPayload(
        bytes32 _operationId
    )
        private pure
        returns (bytes memory)
    {
        return abi.encode(PAYLOAD_VERSION_1, ACTION_CANCEL, abi.encode(_operationId));
    }
}
