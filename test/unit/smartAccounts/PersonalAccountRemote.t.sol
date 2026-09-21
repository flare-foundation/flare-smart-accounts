// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {IPersonalAccountBase} from "../../../contracts/userInterfaces/IPersonalAccountBase.sol";
import {IControlledAccount} from "../../../contracts/userInterfaces/IControlledAccount.sol";
import {FacetsDeploy} from "../../utils/FacetsDeploy.t.sol";
import {IDiamond} from "../../../contracts/diamond/interfaces/IDiamond.sol";
import {DiamondArgs} from "../../../contracts/diamond/implementation/Diamond.sol";
import {IISingletonFactory} from "../../../contracts/smartAccounts/interface/IISingletonFactory.sol";
import {MasterAccountController} from "../../../contracts/smartAccounts/implementation/MasterAccountController.sol";
import {IIMasterAccountController} from "../../../contracts/smartAccounts/interface/IIMasterAccountController.sol";
import {MasterAccountControllerInit} from "../../../contracts/smartAccounts/facets/MasterAccountControllerInit.sol";
import {PersonalAccount} from "../../../contracts/smartAccounts/implementation/PersonalAccount.sol";
import {
    PersonalAccountRemote
} from "../../../contracts/smartAccounts/implementation/PersonalAccountRemote.sol";
import {ComposeTransportFacet} from "../../../contracts/smartAccounts/facets/ComposeTransportFacet.sol";
import {MorphoLoanMarketsFacet} from "../../../contracts/smartAccounts/facets/MorphoLoanMarketsFacet.sol";
import {
    IPersonalAccountRemote,
    PA_ACTION_EXECUTE
} from "../../../contracts/userInterfaces/IPersonalAccountRemote.sol";
import {
    IComposeReceiverAccountBase,
    PAYLOAD_VERSION_1,
    SKIP_REASON_DUPLICATE,
    SKIP_REASON_EXPIRED
} from "../../../contracts/userInterfaces/IComposeReceiverAccountBase.sol";
import {IComposeTransportFacet} from "../../../contracts/userInterfaces/facets/IComposeTransportFacet.sol";
import {IIComposeTransportFacet} from "../../../contracts/smartAccounts/interface/IIComposeTransportFacet.sol";
import {IPauseFacet} from "../../../contracts/userInterfaces/facets/IPauseFacet.sol";
import {MintableERC20} from "../../../contracts/mock/MintableERC20.sol";
import {MockReentrantToken} from "../../../contracts/mock/MockReentrantToken.sol";
import {MockFalseReturningToken} from "../../../contracts/mock/MockFalseReturningToken.sol";
import {MockOft} from "../../../contracts/mock/MockOft.sol";
import {MockLzEndpoint} from "../../../contracts/mock/MockLzEndpoint.sol";
import {OFTComposeMsgCodec} from "@layerzerolabs/oft-evm/contracts/libs/OFTComposeMsgCodec.sol";
import {GUID} from "@layerzerolabs/lz-evm-protocol-v2/contracts/libs/GUID.sol";
import {ILayerZeroComposer} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroComposer.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

/**
 * @title PersonalAccountRemoteTest
 * @notice The remote Personal Account: the remotePa of the user's Flare Personal
 * Account on the loan chain, at the same frozen CREATE2 address. Covers the explicit creation
 * route, beacon resolution, and the authenticated compose entry with the signed execute
 * action (the loan-chain `executeUserOp`).
 */
contract PersonalAccountRemoteTest is Test, FacetsDeploy {
    address private constant SINGLETON_FACTORY = 0xce0042B868300000d44A59004Da54A005ffdcf9f;

    IIMasterAccountController private controller;
    PersonalAccountRemote private remotePaImpl;

    address private initialOwner;
    address private governance;
    address private personalAccountImplementation;

    address payable private executor;
    uint256 private executorFee;
    bytes32 private sourceId;
    uint256 private paymentProofValidityDurationSeconds;
    uint256 private defaultInstructionFee;

    MintableERC20 private fxrp;
    MockOft private fxrpOft;
    address private lzEndpoint;
    uint32 private originEid;
    bytes32 private originPeer;
    uint32 private dstEid;

    string private xrplOwner;

    // base facets are CREATE2-deployed with a fixed salt, so they are deployed once and shared
    IDiamond.FacetCut[] private baseCuts;

    function setUp() public {
        initialOwner = makeAddr("initialOwner");
        governance = makeAddr("governance");
        executor = payable(makeAddr("executor"));
        executorFee = 100;
        sourceId = bytes32("testXRP");
        paymentProofValidityDurationSeconds = 1 days;
        defaultInstructionFee = 1_000_000;
        xrplOwner = "rRemotePersonalAccountOwner";

        fxrp = new MintableERC20("F-XRPL", "fXRP", 6);
        fxrpOft = new MockOft(fxrp, 0.01 ether);
        dstEid = 30101; // Ethereum
        lzEndpoint = address(new MockLzEndpoint(dstEid));
        fxrpOft.setEndpoint(lzEndpoint);
        originEid = 30295; // Flare
        originPeer = bytes32(uint256(uint160(makeAddr("flareSideAdapter"))));

        personalAccountImplementation = address(new PersonalAccount());
        controller = _deployDiamond();

        // the remote diamond additionally carries the compose transport and the loan markets
        IDiamond.FacetCut[] memory settingsCut = new IDiamond.FacetCut[](2);
        settingsCut[0] = _buildFacetCut(
            address(new ComposeTransportFacet()),
            "ComposeTransportFacet",
            IDiamond.FacetCutAction.Add
        );
        settingsCut[1] = _buildFacetCut(
            address(new MorphoLoanMarketsFacet()),
            "MorphoLoanMarketsFacet",
            IDiamond.FacetCutAction.Add
        );
        vm.prank(governance);
        controller.diamondCut(settingsCut, address(0), "");

        // register the remote Personal Account implementation behind the PA beacon
        // (timelock is 0 in tests)
        remotePaImpl = new PersonalAccountRemote();
        vm.prank(governance);
        controller.setPersonalAccountImplementation(address(remotePaImpl));

        _configureTransport();
    }

    function testCreatePersonalAccount() public {
        // the generic creation route on the PersonalAccountsFacet: PAs are also created lazily
        // by instructions on Flare, but no instruction machinery exists here - the routes are
        // this one and createSubaccount. Permissionless and idempotent
        address predicted = controller.getPersonalAccount(xrplOwner);
        assertEq(predicted.code.length, 0);

        address caller = makeAddr("anyone");
        vm.prank(caller);
        vm.expectEmit();
        emit IPersonalAccountBase.PersonalAccountInitialized(address(controller), xrplOwner);
        address created = controller
            .createPersonalAccount(xrplOwner);
        assertEq(created, predicted);
        assertNotEq(created.code.length, 0);

        // idempotent, and now registered
        address again = controller
            .createPersonalAccount(xrplOwner);
        assertEq(again, created);
        assertEq(controller.getPersonalAccount(xrplOwner), created);
    }

    function testCreatePersonalAccountWhilePaused() public {
        // not pause-gated, as on Flare: the parent is what a sweep home redeems through and
        // what a closed position's surplus rests on, so a pause may not withhold it
        _pauseController();
        address predicted = controller.getPersonalAccount(xrplOwner);
        vm.prank(makeAddr("anyone"));
        address created = controller.createPersonalAccount(xrplOwner);
        assertEq(created, predicted);
        assertNotEq(created.code.length, 0);
    }

    function testCreatePersonalAccountRevertEmptyOwner() public {
        // the remotePa implementation rejects an empty owner in initialize, so the whole
        // CREATE2 deployment reverts - no orphan remotePa can exist for an impossible owner
        vm.expectRevert();
        controller.createPersonalAccount("");
    }

    function testRemotePaResolvesViaBeacon() public {
        PersonalAccountRemote remotePa = _createRemotePa();
        assertEq(remotePa.implementation(), address(remotePaImpl));
        assertEq(remotePa.xrplOwner(), xrplOwner);
        assertEq(remotePa.controllerAddress(), address(controller));

        // the controller-as-beacon upgrades every remotePa in one registration, exactly like
        // the Flare Personal Accounts
        PersonalAccountRemote newImpl = new PersonalAccountRemote();
        vm.prank(governance);
        controller.setPersonalAccountImplementation(address(newImpl));
        assertEq(remotePa.implementation(), address(newImpl));
    }

    function testInitializeRevertAlreadyInitialized() public {
        PersonalAccountRemote remotePa = _createRemotePa();
        vm.expectRevert(IControlledAccount.AlreadyInitialized.selector);
        remotePa.initialize(address(controller), xrplOwner);
    }

    function testImplementationInitializeRevertAlreadyInitialized() public {
        // the implementation locks itself in its constructor
        vm.expectRevert(IControlledAccount.AlreadyInitialized.selector);
        remotePaImpl.initialize(address(controller), xrplOwner);
    }

    function testAcceptsNativeExceptOnTheImplementation() public {
        // native funds value-carrying calls (a LayerZero native drop lands this way) and
        // leaves as one; the implementation contract, never initialized, rejects it since
        // nothing could ever move it out of there
        PersonalAccountRemote remotePa = _createRemotePa();
        vm.deal(address(this), 2);

        (bool success, ) = address(remotePa).call{value: 1}("");
        assertTrue(success);
        assertEq(address(remotePa).balance, 1);
        (success, ) = address(remotePaImpl).call{value: 1}("");
        assertFalse(success);
        assertEq(address(remotePaImpl).balance, 0);
    }

    //
    // the authenticated compose entry and the signed execute action
    //

    function testTransferTokenViaCompose() public {
        // the common instruction, as a wallet builds it: a one-call transfer batch
        PersonalAccountRemote remotePa = _createRemotePa();
        MintableERC20 stray = new MintableERC20("Stray", "STR", 18);
        stray.mint(address(remotePa), 42e18);
        address destination = makeAddr("userChosenDestination");

        bytes32 operationId = bytes32("op-1");
        vm.expectEmit();
        emit IPersonalAccountRemote.UserOpExecuted(operationId, 1, _guidFor(1));
        _deliver(address(remotePa), 1, _transferTokenPayload(
            operationId, address(stray), destination, 10e18
        ));

        assertEq(stray.balanceOf(destination), 10e18);
        assertEq(stray.balanceOf(address(remotePa)), 32e18);
        assertTrue(remotePa.usedOperations(operationId));
    }

    function testExecuteBatchWithNativeAndCalls() public {
        // the general case: several calls in one signed batch - a token transfer, a plain
        // native send (target = recipient, empty data) funded by native that landed with a
        // message, and an arbitrary contract call (an approval) - in order, one operation id
        PersonalAccountRemote remotePa = _createRemotePa();
        MintableERC20 stray = new MintableERC20("Stray", "STR", 18);
        stray.mint(address(remotePa), 42e18);
        vm.deal(address(remotePa), 1 ether);
        address tokenDest = makeAddr("tokenDest");
        address nativeDest = makeAddr("nativeDest");
        address spender = makeAddr("spender");

        IPersonalAccountRemote.Call[] memory calls = new IPersonalAccountRemote.Call[](3);
        calls[0] = IPersonalAccountRemote.Call({
            target: address(stray), value: 0, data: abi.encodeCall(IERC20.transfer, (tokenDest, 10e18))
        });
        calls[1] = IPersonalAccountRemote.Call({target: nativeDest, value: 0.4 ether, data: ""});
        calls[2] = IPersonalAccountRemote.Call({
            target: address(stray), value: 0, data: abi.encodeCall(IERC20.approve, (spender, 5e18))
        });
        vm.expectEmit();
        emit IPersonalAccountRemote.UserOpExecuted(bytes32("op-1"), 3, _guidFor(1));
        _deliver(address(remotePa), 1, _executePayload(bytes32("op-1"), calls));

        assertEq(stray.balanceOf(tokenDest), 10e18);
        assertEq(nativeDest.balance, 0.4 ether);
        assertEq(address(remotePa).balance, 0.6 ether);
        assertEq(stray.allowance(address(remotePa), spender), 5e18);
        assertTrue(remotePa.usedOperations(bytes32("op-1")));
    }

    function testExecuteIsAllOrNothing() public {
        // a failing call anywhere in the batch reverts the whole delivery with its index and
        // the callee's revert data; nothing before it sticks, the id stays unconsumed, and the
        // exact same packet succeeds once the cause is fixed (here: the native to send)
        PersonalAccountRemote remotePa = _createRemotePa();
        MintableERC20 stray = new MintableERC20("Stray", "STR", 18);
        stray.mint(address(remotePa), 42e18);
        address tokenDest = makeAddr("tokenDest");
        address nativeDest = makeAddr("nativeDest");

        IPersonalAccountRemote.Call[] memory calls = new IPersonalAccountRemote.Call[](2);
        calls[0] = IPersonalAccountRemote.Call({
            target: address(stray), value: 0, data: abi.encodeCall(IERC20.transfer, (tokenDest, 10e18))
        });
        calls[1] = IPersonalAccountRemote.Call({target: nativeDest, value: 1 ether, data: ""});
        bytes memory payload = _executePayload(bytes32("op-1"), calls);

        _deliverExpectRevert(
            address(remotePa), 1, payload,
            abi.encodeWithSelector(IPersonalAccountRemote.CallFailed.selector, 1, bytes(""))
        );
        assertEq(stray.balanceOf(tokenDest), 0);
        assertFalse(remotePa.usedOperations(bytes32("op-1")));

        vm.deal(address(remotePa), 1 ether);
        _deliver(address(remotePa), 1, payload);
        assertEq(stray.balanceOf(tokenDest), 10e18);
        assertEq(nativeDest.balance, 1 ether);
    }

    function testReturnDataIsNotInterpreted() public {
        // the raw-call semantics of executeUserOp, pinned: a token that reports failure by
        // returning false (no revert) and a call to a codeless target both count as successful
        // calls - the batch completes, the id is consumed, and no token moved. The wallet must
        // know the callee's success convention; nothing here can tell for it
        PersonalAccountRemote remotePa = _createRemotePa();
        MockFalseReturningToken sneaky = new MockFalseReturningToken();
        sneaky.mint(address(remotePa), 10e18);
        address destination = makeAddr("dest");

        IPersonalAccountRemote.Call[] memory calls = new IPersonalAccountRemote.Call[](2);
        calls[0] = IPersonalAccountRemote.Call({
            target: address(sneaky), value: 0, data: abi.encodeCall(IERC20.transfer, (destination, 10e18))
        });
        calls[1] = IPersonalAccountRemote.Call({
            target: makeAddr("codeless"), value: 0, data: abi.encodeCall(IERC20.transfer, (destination, 1))
        });
        vm.expectEmit();
        emit IPersonalAccountRemote.UserOpExecuted(bytes32("op-1"), 2, _guidFor(1));
        _deliver(address(remotePa), 1, _executePayload(bytes32("op-1"), calls));

        assertTrue(remotePa.usedOperations(bytes32("op-1")));
        assertEq(sneaky.balanceOf(address(remotePa)), 10e18);
        assertEq(sneaky.balanceOf(destination), 0);
    }

    function testExecuteGuards() public {
        PersonalAccountRemote remotePa = _createRemotePa();
        MintableERC20 stray = new MintableERC20("Stray", "STR", 18);
        stray.mint(address(remotePa), 42e18);

        // zero operation id
        _deliverExpectRevert(
            address(remotePa), 1,
            _transferTokenPayload(bytes32(0), address(stray), makeAddr("dest"), 1e18),
            IComposeReceiverAccountBase.InvalidOperationId.selector
        );
        // an empty batch would only consume the id
        _deliverExpectRevert(
            address(remotePa), 1,
            _executePayload(bytes32("op-1"), new IPersonalAccountRemote.Call[](0)),
            IPersonalAccountRemote.EmptyUserOp.selector
        );
    }

    function testTransferRevertWhenPausedThenRetriable() public {
        // outward moves stop while paused - even signed-looking traffic, since a transport
        // compromise is exactly what an incident looks like; the packet stays retriable
        PersonalAccountRemote remotePa = _createRemotePa();
        MintableERC20 stray = new MintableERC20("Stray", "STR", 18);
        stray.mint(address(remotePa), 42e18);
        bytes memory payload =
            _transferTokenPayload(bytes32("op-1"), address(stray), makeAddr("dest"), 1e18);

        _pauseController();
        _deliverExpectRevert(address(remotePa), 1, payload, IPauseFacet.IsPaused.selector);
        assertFalse(remotePa.usedOperations(bytes32("op-1")));

        _unpauseController();
        _deliver(address(remotePa), 1, payload);
        assertEq(stray.balanceOf(makeAddr("dest")), 1e18);
    }

    function testTerminalSkipsRunBeforeThePauseGate() public {
        // a duplicate or expired delivery finalizes even while paused, instead of reverting
        // forever on an incident: terminal gates come before the pause check
        PersonalAccountRemote remotePa = _createRemotePa();
        MintableERC20 stray = new MintableERC20("Stray", "STR", 18);
        stray.mint(address(remotePa), 42e18);
        address destination = makeAddr("dest");
        _deliver(address(remotePa), 1, _transferTokenPayload(
            bytes32("op-1"), address(stray), destination, 1e18
        ));

        _pauseController();
        vm.expectEmit();
        emit IPersonalAccountRemote.ActionSkipped(
            bytes32("op-1"), SKIP_REASON_DUPLICATE, _guidFor(2)
        );
        _deliver(address(remotePa), 2, _transferTokenPayload(
            bytes32("op-1"), address(stray), destination, 1e18
        ));

        bytes memory expired = _executePayloadAt(
            bytes32("op-2"),
            uint64(block.timestamp - 1),
            _transferCall(address(stray), destination, 1e18)
        );
        vm.expectEmit();
        emit IPersonalAccountRemote.ActionSkipped(
            bytes32("op-2"), SKIP_REASON_EXPIRED, _guidFor(3)
        );
        _deliver(address(remotePa), 3, expired);
        assertFalse(remotePa.usedOperations(bytes32("op-2")));
        assertEq(stray.balanceOf(destination), 1e18);
    }

    function testTransferFailureLeavesTheOperationRetriable() public {
        // a transfer that fails (here: balance too low) reverts the whole delivery with the
        // callee's own revert data wrapped in CallFailed, so the id is not consumed and the
        // exact same packet succeeds once the balance is there
        PersonalAccountRemote remotePa = _createRemotePa();
        MintableERC20 stray = new MintableERC20("Stray", "STR", 18);
        stray.mint(address(remotePa), 1e18);
        address destination = makeAddr("dest");
        bytes memory payload =
            _transferTokenPayload(bytes32("op-1"), address(stray), destination, 5e18);

        _deliverExpectRevert(
            address(remotePa), 1, payload,
            abi.encodeWithSelector(
                IPersonalAccountRemote.CallFailed.selector,
                0,
                abi.encodeWithSelector(
                    IERC20Errors.ERC20InsufficientBalance.selector, address(remotePa), 1e18, 5e18
                )
            )
        );
        assertFalse(remotePa.usedOperations(bytes32("op-1")));

        stray.mint(address(remotePa), 4e18);
        _deliver(address(remotePa), 1, payload);
        assertEq(stray.balanceOf(destination), 5e18);
        assertTrue(remotePa.usedOperations(bytes32("op-1")));
    }

    function testMaliciousTokenCannotReenter() public {
        // a token whose transfer calls back into the account meets the transient guard -
        // asserted by the guard's own error, so the test fails if the guard is ever removed
        // (the callback would then fail later, on OnlyEndpoint, for another reason);
        // the whole action reverts and stays retriable - nothing executes twice or is consumed
        PersonalAccountRemote remotePa = _createRemotePa();
        MockReentrantToken evil = new MockReentrantToken();
        evil.mint(address(remotePa), 10e18);
        bytes memory payload =
            _transferTokenPayload(bytes32("op-1"), address(evil), makeAddr("dest"), 1e18);

        // re-entering the compose entry (the remotePa's only public entry)
        (bytes memory message, bytes32 guid) = _composeMessage(address(remotePa), 1, payload);
        evil.setCallback(
            address(remotePa),
            abi.encodeCall(
                ILayerZeroComposer.lzCompose,
                (address(fxrpOft), guid, message, executor, "")
            )
        );
        _deliverExpectRevert(
            address(remotePa), 1, payload,
            abi.encodeWithSelector(
                IPersonalAccountRemote.CallFailed.selector,
                0,
                abi.encodePacked(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector)
            )
        );
        assertFalse(remotePa.usedOperations(bytes32("op-1")));
        assertEq(evil.balanceOf(address(remotePa)), 10e18);
    }

    function testComposeSkipDuplicateOperation() public {
        PersonalAccountRemote remotePa = _createRemotePa();
        MintableERC20 stray = new MintableERC20("Stray", "STR", 18);
        stray.mint(address(remotePa), 42e18);
        address destination = makeAddr("dest");

        _deliver(address(remotePa), 1, _transferTokenPayload(
            bytes32("op-1"), address(stray), destination, 1e18
        ));

        // the same id delivered again finalizes without a second transfer
        vm.expectEmit();
        emit IPersonalAccountRemote.ActionSkipped(
            bytes32("op-1"), SKIP_REASON_DUPLICATE, _guidFor(2)
        );
        _deliver(address(remotePa), 2, _transferTokenPayload(
            bytes32("op-1"), address(stray), destination, 1e18
        ));
        assertEq(stray.balanceOf(destination), 1e18);
    }

    function testComposeSkipExpiredWithoutConsumingTheOperation() public {
        PersonalAccountRemote remotePa = _createRemotePa();
        MintableERC20 stray = new MintableERC20("Stray", "STR", 18);
        stray.mint(address(remotePa), 42e18);

        bytes memory expired = _executePayloadAt(
            bytes32("op-1"),
            uint64(block.timestamp - 1),
            _transferCall(address(stray), makeAddr("dest"), 1e18)
        );
        vm.expectEmit();
        emit IPersonalAccountRemote.ActionSkipped(
            bytes32("op-1"), SKIP_REASON_EXPIRED, _guidFor(1)
        );
        _deliver(address(remotePa), 1, expired);
        assertFalse(remotePa.usedOperations(bytes32("op-1")));
    }

    function testComposeAuthentication() public {
        PersonalAccountRemote remotePa = _createRemotePa();
        MintableERC20 stray = new MintableERC20("Stray", "STR", 18);
        stray.mint(address(remotePa), 42e18);
        bytes memory payload =
            _transferTokenPayload(bytes32("op-1"), address(stray), makeAddr("dest"), 1e18);
        (bytes memory message, bytes32 guid) = _composeMessage(address(remotePa), 1, payload);

        // only the endpoint may deliver
        vm.prank(makeAddr("notTheEndpoint"));
        vm.expectRevert(IComposeReceiverAccountBase.OnlyEndpoint.selector);
        remotePa.lzCompose(address(fxrpOft), guid, message, executor, "");

        // compose value is rejected, keeping a mistaken delivery retriable
        vm.deal(lzEndpoint, 1 ether);
        vm.prank(lzEndpoint);
        vm.expectRevert(IComposeReceiverAccountBase.NonZeroComposeValue.selector);
        remotePa.lzCompose{value: 1}(address(fxrpOft), guid, message, executor, "");

        // the compose sender must be the configured OFT
        vm.prank(lzEndpoint);
        vm.expectRevert(
            abi.encodeWithSelector(
                IComposeReceiverAccountBase.WrongComposeSender.selector, makeAddr("otherOft")
            )
        );
        remotePa.lzCompose(makeAddr("otherOft"), guid, message, executor, "");

        // the source-chain sender must be this account itself - its own Flare twin
        bytes memory forged = OFTComposeMsgCodec.encode(
            1, originEid, 0,
            abi.encodePacked(bytes32(uint256(uint160(makeAddr("intruder")))), payload)
        );
        vm.prank(lzEndpoint);
        vm.expectRevert(
            abi.encodeWithSelector(
                IComposeReceiverAccountBase.WrongComposeFrom.selector,
                bytes32(uint256(uint160(makeAddr("intruder"))))
            )
        );
        remotePa.lzCompose(address(fxrpOft), guid, forged, executor, "");

        // the GUID must recompute from the pinned origin peer
        bytes32 wrongGuid = GUID.generate(
            1, originEid, makeAddr("maliciousPeer"), dstEid,
            bytes32(uint256(uint160(address(fxrpOft))))
        );
        vm.prank(lzEndpoint);
        vm.expectRevert(
            abi.encodeWithSelector(IComposeReceiverAccountBase.WrongGuid.selector, wrongGuid)
        );
        remotePa.lzCompose(address(fxrpOft), wrongGuid, message, executor, "");
    }

    function testComposeRevertUnsupportedPayloads() public {
        PersonalAccountRemote remotePa = _createRemotePa();

        bytes memory wrongVersion = abi.encode(uint8(2), PA_ACTION_EXECUTE, bytes(""));
        _deliverExpectRevert(
            address(remotePa), 1, wrongVersion,
            abi.encodeWithSelector(
                IComposeReceiverAccountBase.UnsupportedPayloadVersion.selector, uint8(2)
            )
        );

        bytes memory wrongAction = abi.encode(PAYLOAD_VERSION_1, uint8(77), bytes(""));
        _deliverExpectRevert(
            address(remotePa), 1, wrongAction,
            abi.encodeWithSelector(IComposeReceiverAccountBase.UnsupportedAction.selector, uint8(77))
        );
    }

    function testComposeRevertTransportNotConfigured() public {
        PersonalAccountRemote remotePa = _createRemotePa();
        vm.prank(governance);
        IIComposeTransportFacet(address(controller)).clearComposeTransport();

        _deliverExpectRevert(
            address(remotePa), 1,
            _transferTokenPayload(bytes32("op-1"), makeAddr("token"), makeAddr("dest"), 1e18),
            IComposeTransportFacet.ComposeTransportNotConfigured.selector
        );
    }

    //
    // helpers
    //

    function _createRemotePa() private returns (PersonalAccountRemote) {
        return PersonalAccountRemote(payable(
            controller.createPersonalAccount(xrplOwner)
        ));
    }

    function _configureTransport() private {
        fxrpOft.setPeer(originEid, originPeer);
        vm.prank(governance);
        IIComposeTransportFacet(address(controller)).setComposeTransport(
            IComposeTransportFacet.Transport({
                lzEndpoint: lzEndpoint,
                oft: address(fxrpOft),
                originEid: originEid,
                originPeer: originPeer
            })
        );
    }

    function _deliver(
        address _remotePa,
        uint64 _nonce,
        bytes memory _payload
    )
        private
    {
        (bytes memory message, bytes32 guid) = _composeMessage(_remotePa, _nonce, _payload);
        vm.prank(lzEndpoint);
        IPersonalAccountRemote(_remotePa).lzCompose(
            address(fxrpOft), guid, message, executor, ""
        );
    }

    function _deliverExpectRevert(
        address _remotePa,
        uint64 _nonce,
        bytes memory _payload,
        bytes memory _expectedRevert
    )
        private
    {
        (bytes memory message, bytes32 guid) = _composeMessage(_remotePa, _nonce, _payload);
        vm.prank(lzEndpoint);
        vm.expectRevert(_expectedRevert);
        IPersonalAccountRemote(_remotePa).lzCompose(
            address(fxrpOft), guid, message, executor, ""
        );
    }

    function _deliverExpectRevert(
        address _remotePa,
        uint64 _nonce,
        bytes memory _payload,
        bytes4 _selector
    )
        private
    {
        _deliverExpectRevert(_remotePa, _nonce, _payload, abi.encodePacked(_selector));
    }

    /// The common instruction as a wallet builds it: a one-call transfer batch.
    function _transferTokenPayload(
        bytes32 _operationId,
        address _token,
        address _destination,
        uint256 _amount
    )
        private
        returns (bytes memory)
    {
        return _executePayload(_operationId, _transferCall(_token, _destination, _amount));
    }

    function _executePayload(
        bytes32 _operationId,
        IPersonalAccountRemote.Call[] memory _calls
    )
        private
        returns (bytes memory)
    {
        return _executePayloadAt(_operationId, uint64(block.timestamp + 1 hours), _calls);
    }

    function _pauseController() private {
        address pauser = makeAddr("pauser");
        address[] memory pausers = new address[](1);
        pausers[0] = pauser;
        vm.prank(governance);
        controller.addPausers(pausers);
        vm.prank(pauser);
        controller.pause();
    }

    function _unpauseController() private {
        address unpauser = makeAddr("unpauser");
        address[] memory unpausers = new address[](1);
        unpausers[0] = unpauser;
        vm.prank(governance);
        controller.addUnpausers(unpausers);
        vm.prank(unpauser);
        controller.unpause();
    }

    function _deployDiamond() private returns (IIMasterAccountController _controller) {
        if (baseCuts.length == 0) {
            IDiamond.FacetCut[] memory deployedBaseCuts = deployBaseFacets();
            for (uint256 i = 0; i < deployedBaseCuts.length; i++) {
                baseCuts.push(deployedBaseCuts[i]);
            }
        }
        DiamondArgs memory args = DiamondArgs({
            owner: initialOwner,
            initAddress: address(0),
            initCalldata: ""
        });
        bytes memory bytecode = abi.encodePacked(
            type(MasterAccountController).creationCode,
            abi.encode(baseCuts, args)
        );
        // salt from the nonce so repeated deployments (fresh diamonds) get unique addresses
        address deployed = IISingletonFactory(SINGLETON_FACTORY).deploy(
            bytecode,
            keccak256(abi.encode("loan-chain-pa-diamond", vm.getNonce(address(this))))
        );
        _controller = IIMasterAccountController(deployed);

        IDiamond.FacetCut[] memory smartAccountsCuts = deploySmartAccountsFacets();
        MasterAccountControllerInit init = new MasterAccountControllerInit();
        vm.prank(initialOwner);
        _controller.diamondCut(
            smartAccountsCuts,
            address(init),
            abi.encodeWithSelector(
                MasterAccountControllerInit.init.selector,
                executor,
                executorFee,
                sourceId,
                paymentProofValidityDurationSeconds,
                defaultInstructionFee,
                personalAccountImplementation
            )
        );

        vm.prank(initialOwner);
        _controller.transferOwnership(governance);
    }

    function _composeMessage(
        address _remotePa,
        uint64 _nonce,
        bytes memory _payload
    )
        private view
        returns (bytes memory _message, bytes32 _guid)
    {
        _message = OFTComposeMsgCodec.encode(
            _nonce,
            originEid,
            0,
            abi.encodePacked(bytes32(uint256(uint160(_remotePa))), _payload)
        );
        _guid = _guidFor(_nonce);
    }

    /// The GUID the endpoint would compute for a packet from the pinned origin peer.
    function _guidFor(uint64 _nonce) private view returns (bytes32) {
        return GUID.generate(
            _nonce,
            originEid,
            address(uint160(uint256(originPeer))),
            dstEid,
            bytes32(uint256(uint160(address(fxrpOft))))
        );
    }

    function _transferCall(
        address _token,
        address _destination,
        uint256 _amount
    )
        private
        pure
        returns (IPersonalAccountRemote.Call[] memory _calls)
    {
        _calls = new IPersonalAccountRemote.Call[](1);
        _calls[0] = IPersonalAccountRemote.Call({
            target: _token,
            value: 0,
            data: abi.encodeCall(IERC20.transfer, (_destination, _amount))
        });
    }

    function _executePayloadAt(
        bytes32 _operationId,
        uint64 _deadline,
        IPersonalAccountRemote.Call[] memory _calls
    )
        private
        pure
        returns (bytes memory)
    {
        return abi.encode(
            PAYLOAD_VERSION_1,
            PA_ACTION_EXECUTE,
            abi.encode(_operationId, _deadline, _calls)
        );
    }
}
