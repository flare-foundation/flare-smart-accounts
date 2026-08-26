// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {FacetsDeploy} from "./utils/FacetsDeploy.t.sol";
import {IDiamond} from "../contracts/diamond/interfaces/IDiamond.sol";
import {DiamondArgs} from "../contracts/diamond/implementation/Diamond.sol";
import {IISingletonFactory} from "../contracts/smartAccounts/interface/IISingletonFactory.sol";
import {MasterAccountController} from "../contracts/smartAccounts/implementation/MasterAccountController.sol";
import {IIMasterAccountController} from "../contracts/smartAccounts/interface/IIMasterAccountController.sol";
import {MasterAccountControllerInit} from "../contracts/smartAccounts/facets/MasterAccountControllerInit.sol";
import {PersonalAccount} from "../contracts/smartAccounts/implementation/PersonalAccount.sol";
import {
    LoanChainPersonalAccount
} from "../contracts/smartAccounts/implementation/LoanChainPersonalAccount.sol";
import {
    LoanChainSettingsFacet
} from "../contracts/smartAccounts/facets/LoanChainSettingsFacet.sol";
import {
    ILoanChainPersonalAccount,
    PA_ACTION_TRANSFER_TOKEN
} from "../contracts/userInterfaces/ILoanChainPersonalAccount.sol";
import {
    ILoanChainAccountBase,
    PAYLOAD_VERSION_1,
    SKIP_REASON_DUPLICATE,
    SKIP_REASON_EXPIRED
} from "../contracts/userInterfaces/ILoanChainAccountBase.sol";
import {
    ILoanChainSettingsFacet
} from "../contracts/userInterfaces/facets/ILoanChainSettingsFacet.sol";
import {
    IILoanChainSettingsFacet
} from "../contracts/smartAccounts/interface/IILoanChainSettingsFacet.sol";
import {IPauseFacet} from "../contracts/userInterfaces/facets/IPauseFacet.sol";
import {MintableERC20} from "../contracts/mock/MintableERC20.sol";
import {MockReentrantToken} from "../contracts/mock/MockReentrantToken.sol";
import {MockOft} from "../contracts/mock/MockOft.sol";
import {MockLzEndpoint} from "../contracts/mock/MockLzEndpoint.sol";
import {OFTComposeMsgCodec} from "@layerzerolabs/oft-evm/contracts/libs/OFTComposeMsgCodec.sol";
import {GUID} from "@layerzerolabs/lz-evm-protocol-v2/contracts/libs/GUID.sol";
import {ILayerZeroComposer} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroComposer.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

/**
 * @title LoanChainPersonalAccountTest
 * @notice The loan-chain-side Personal Account: the compose-driven mirror of the user's
 * Flare Personal Account, at the same frozen CREATE2 address. Covers the explicit creation
 * route, beacon resolution, and the authenticated compose entry with the typed transfer
 * action.
 */
contract LoanChainPersonalAccountTest is Test, FacetsDeploy {
    address private constant SINGLETON_FACTORY = 0xce0042B868300000d44A59004Da54A005ffdcf9f;

    IIMasterAccountController private controller;
    LoanChainPersonalAccount private mirrorImpl;

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
        xrplOwner = "rMirrorPersonalAccountOwner";

        fxrp = new MintableERC20("F-XRPL", "fXRP", 6);
        fxrpOft = new MockOft(fxrp, 0.01 ether);
        dstEid = 30101; // Ethereum
        lzEndpoint = address(new MockLzEndpoint(dstEid));
        fxrpOft.setEndpoint(lzEndpoint);
        originEid = 30295; // Flare
        originPeer = bytes32(uint256(uint160(makeAddr("flareSideAdapter"))));

        personalAccountImplementation = address(new PersonalAccount());
        controller = _deployDiamond();

        // the loan-chain diamond additionally carries the loan settings facet
        IDiamond.FacetCut[] memory settingsCut = new IDiamond.FacetCut[](1);
        settingsCut[0] = _buildFacetCut(
            address(new LoanChainSettingsFacet()),
            "LoanChainSettingsFacet",
            IDiamond.FacetCutAction.Add
        );
        vm.prank(governance);
        controller.diamondCut(settingsCut, address(0), "");

        // register the loan-chain Personal Account implementation behind the PA beacon
        // (timelock is 0 in tests)
        mirrorImpl = new LoanChainPersonalAccount();
        vm.prank(governance);
        controller.setPersonalAccountImplementation(address(mirrorImpl));

        _configureTransport();
    }

    function testCreateLoanChainPersonalAccount() public {
        // the explicit creation route: PAs are created lazily by instructions on Flare, but
        // no instruction machinery exists here - creation is permissionless and idempotent
        address predicted = controller.getPersonalAccount(xrplOwner);
        assertEq(predicted.code.length, 0);

        address caller = makeAddr("anyone");
        vm.prank(caller);
        address created = ILoanChainSettingsFacet(address(controller))
            .createLoanChainPersonalAccount(xrplOwner);
        assertEq(created, predicted);
        assertNotEq(created.code.length, 0);

        // idempotent, and now registered
        address again = ILoanChainSettingsFacet(address(controller))
            .createLoanChainPersonalAccount(xrplOwner);
        assertEq(again, created);
        assertEq(controller.getPersonalAccount(xrplOwner), created);
    }

    function testCreateLoanChainPersonalAccountRevertWhenPaused() public {
        _pauseController();
        vm.expectRevert(IPauseFacet.IsPaused.selector);
        ILoanChainSettingsFacet(address(controller)).createLoanChainPersonalAccount(xrplOwner);
    }

    function testCreateLoanChainPersonalAccountRevertEmptyOwner() public {
        // the mirror implementation rejects an empty owner in initialize, so the whole
        // CREATE2 deployment reverts - no orphan mirror can exist for an impossible owner
        vm.expectRevert();
        ILoanChainSettingsFacet(address(controller)).createLoanChainPersonalAccount("");
    }

    function testMirrorResolvesViaBeacon() public {
        LoanChainPersonalAccount mirror = _createMirror();
        assertEq(mirror.implementation(), address(mirrorImpl));
        assertEq(mirror.xrplOwner(), xrplOwner);
        assertEq(mirror.controllerAddress(), address(controller));

        // the controller-as-beacon upgrades every mirror in one registration, exactly like
        // the Flare Personal Accounts
        LoanChainPersonalAccount newImpl = new LoanChainPersonalAccount();
        vm.prank(governance);
        controller.setPersonalAccountImplementation(address(newImpl));
        assertEq(mirror.implementation(), address(newImpl));
    }

    function testInitializeRevertAlreadyInitialized() public {
        LoanChainPersonalAccount mirror = _createMirror();
        vm.expectRevert(ILoanChainAccountBase.AlreadyInitialized.selector);
        mirror.initialize(address(controller), xrplOwner);
    }

    function testImplementationInitializeRevertAlreadyInitialized() public {
        // the implementation locks itself in its constructor
        vm.expectRevert(ILoanChainAccountBase.AlreadyInitialized.selector);
        mirrorImpl.initialize(address(controller), xrplOwner);
    }

    function testRejectsPlainNative() public {
        // nothing in the protocol ever pushes native at the mirror, so it has no receive()
        // and no native exit: a plain send reverts at the sender instead of landing on an
        // account that could not move it
        LoanChainPersonalAccount mirror = _createMirror();
        vm.deal(address(this), 2);

        (bool success, ) = address(mirror).call{value: 1}("");
        assertFalse(success);
        assertEq(address(mirror).balance, 0);
        (success, ) = address(mirrorImpl).call{value: 1}("");
        assertFalse(success);
    }

    //
    // the authenticated compose entry and the typed transfer actions
    //

    function testTransferTokenViaCompose() public {
        LoanChainPersonalAccount mirror = _createMirror();
        MintableERC20 stray = new MintableERC20("Stray", "STR", 18);
        stray.mint(address(mirror), 42e18);
        address destination = makeAddr("userChosenDestination");

        bytes32 operationId = bytes32("op-1");
        vm.expectEmit();
        emit ILoanChainPersonalAccount.TokenTransferred(
            address(stray), destination, 10e18, operationId, _guidFor(1)
        );
        _deliver(address(mirror), 1, _transferTokenPayload(
            operationId, address(stray), destination, 10e18
        ));

        assertEq(stray.balanceOf(destination), 10e18);
        assertEq(stray.balanceOf(address(mirror)), 32e18);
        assertTrue(mirror.usedOperations(operationId));
    }

    function testTransferGuards() public {
        LoanChainPersonalAccount mirror = _createMirror();
        MintableERC20 stray = new MintableERC20("Stray", "STR", 18);
        stray.mint(address(mirror), 42e18);

        // zero operation id
        _deliverExpectRevert(
            address(mirror), 1,
            _transferTokenPayload(bytes32(0), address(stray), makeAddr("dest"), 1e18),
            ILoanChainAccountBase.InvalidOperationId.selector
        );
        // zero amount
        _deliverExpectRevert(
            address(mirror), 1,
            _transferTokenPayload(bytes32("op-1"), address(stray), makeAddr("dest"), 0),
            ILoanChainPersonalAccount.ZeroAmount.selector
        );
        // destination shape rules: non-zero and not this account
        _deliverExpectRevert(
            address(mirror), 1,
            _transferTokenPayload(bytes32("op-1"), address(stray), address(0), 1e18),
            ILoanChainPersonalAccount.InvalidDestination.selector
        );
        _deliverExpectRevert(
            address(mirror), 1,
            _transferTokenPayload(bytes32("op-1"), address(stray), address(mirror), 1e18),
            ILoanChainPersonalAccount.InvalidDestination.selector
        );
    }

    function testTransferRevertWhenPausedThenRetriable() public {
        // outward moves stop while paused - even signed-looking traffic, since a transport
        // compromise is exactly what an incident looks like; the packet stays retriable
        LoanChainPersonalAccount mirror = _createMirror();
        MintableERC20 stray = new MintableERC20("Stray", "STR", 18);
        stray.mint(address(mirror), 42e18);
        bytes memory payload =
            _transferTokenPayload(bytes32("op-1"), address(stray), makeAddr("dest"), 1e18);

        _pauseController();
        _deliverExpectRevert(address(mirror), 1, payload, IPauseFacet.IsPaused.selector);
        assertFalse(mirror.usedOperations(bytes32("op-1")));

        _unpauseController();
        _deliver(address(mirror), 1, payload);
        assertEq(stray.balanceOf(makeAddr("dest")), 1e18);
    }

    function testTerminalSkipsRunBeforeThePauseGate() public {
        // a duplicate or expired delivery finalizes even while paused, instead of reverting
        // forever on an incident: terminal gates come before the pause check
        LoanChainPersonalAccount mirror = _createMirror();
        MintableERC20 stray = new MintableERC20("Stray", "STR", 18);
        stray.mint(address(mirror), 42e18);
        address destination = makeAddr("dest");
        _deliver(address(mirror), 1, _transferTokenPayload(
            bytes32("op-1"), address(stray), destination, 1e18
        ));

        _pauseController();
        vm.expectEmit();
        emit ILoanChainPersonalAccount.ActionSkipped(
            bytes32("op-1"), SKIP_REASON_DUPLICATE, _guidFor(2)
        );
        _deliver(address(mirror), 2, _transferTokenPayload(
            bytes32("op-1"), address(stray), destination, 1e18
        ));

        bytes memory expired = abi.encode(
            PAYLOAD_VERSION_1,
            PA_ACTION_TRANSFER_TOKEN,
            abi.encode(
                bytes32("op-2"), uint64(block.timestamp - 1), address(stray), destination, 1e18
            )
        );
        vm.expectEmit();
        emit ILoanChainPersonalAccount.ActionSkipped(
            bytes32("op-2"), SKIP_REASON_EXPIRED, _guidFor(3)
        );
        _deliver(address(mirror), 3, expired);
        assertFalse(mirror.usedOperations(bytes32("op-2")));
        assertEq(stray.balanceOf(destination), 1e18);
    }

    function testTransferFailureLeavesTheOperationRetriable() public {
        // a transfer that fails (here: balance too low) reverts the whole delivery, so the id
        // is not consumed and the exact same packet succeeds once the balance is there
        LoanChainPersonalAccount mirror = _createMirror();
        MintableERC20 stray = new MintableERC20("Stray", "STR", 18);
        stray.mint(address(mirror), 1e18);
        address destination = makeAddr("dest");
        bytes memory payload =
            _transferTokenPayload(bytes32("op-1"), address(stray), destination, 5e18);

        (bytes memory message, bytes32 guid) = _composeMessage(address(mirror), 1, payload);
        vm.prank(lzEndpoint);
        vm.expectRevert();
        mirror.lzCompose(address(fxrpOft), guid, message, executor, "");
        assertFalse(mirror.usedOperations(bytes32("op-1")));

        stray.mint(address(mirror), 4e18);
        _deliver(address(mirror), 1, payload);
        assertEq(stray.balanceOf(destination), 5e18);
        assertTrue(mirror.usedOperations(bytes32("op-1")));
    }

    function testMaliciousTokenCannotReenter() public {
        // a token whose transfer calls back into the account meets the transient guard -
        // asserted by the guard's own error, so the test fails if the guard is ever removed
        // (the callback would then fail later, on OnlyEndpoint, for another reason);
        // the whole action reverts and stays retriable - nothing executes twice or is consumed
        LoanChainPersonalAccount mirror = _createMirror();
        MockReentrantToken evil = new MockReentrantToken();
        evil.mint(address(mirror), 10e18);
        bytes memory payload =
            _transferTokenPayload(bytes32("op-1"), address(evil), makeAddr("dest"), 1e18);

        // re-entering the compose entry (the mirror's only public entry)
        (bytes memory message, bytes32 guid) = _composeMessage(address(mirror), 1, payload);
        evil.setCallback(
            address(mirror),
            abi.encodeCall(
                ILayerZeroComposer.lzCompose,
                (address(fxrpOft), guid, message, executor, "")
            )
        );
        _deliverExpectRevert(
            address(mirror), 1, payload,
            ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector
        );
        assertFalse(mirror.usedOperations(bytes32("op-1")));
        assertEq(evil.balanceOf(address(mirror)), 10e18);
    }

    function testComposeSkipDuplicateOperation() public {
        LoanChainPersonalAccount mirror = _createMirror();
        MintableERC20 stray = new MintableERC20("Stray", "STR", 18);
        stray.mint(address(mirror), 42e18);
        address destination = makeAddr("dest");

        _deliver(address(mirror), 1, _transferTokenPayload(
            bytes32("op-1"), address(stray), destination, 1e18
        ));

        // the same id delivered again finalizes without a second transfer
        vm.expectEmit();
        emit ILoanChainPersonalAccount.ActionSkipped(
            bytes32("op-1"), SKIP_REASON_DUPLICATE, _guidFor(2)
        );
        _deliver(address(mirror), 2, _transferTokenPayload(
            bytes32("op-1"), address(stray), destination, 1e18
        ));
        assertEq(stray.balanceOf(destination), 1e18);
    }

    function testComposeSkipExpiredWithoutConsumingTheOperation() public {
        LoanChainPersonalAccount mirror = _createMirror();
        MintableERC20 stray = new MintableERC20("Stray", "STR", 18);
        stray.mint(address(mirror), 42e18);

        bytes memory expired = abi.encode(
            PAYLOAD_VERSION_1,
            PA_ACTION_TRANSFER_TOKEN,
            abi.encode(
                bytes32("op-1"), uint64(block.timestamp - 1),
                address(stray), makeAddr("dest"), 1e18
            )
        );
        vm.expectEmit();
        emit ILoanChainPersonalAccount.ActionSkipped(
            bytes32("op-1"), SKIP_REASON_EXPIRED, _guidFor(1)
        );
        _deliver(address(mirror), 1, expired);
        assertFalse(mirror.usedOperations(bytes32("op-1")));
    }

    function testComposeAuthentication() public {
        LoanChainPersonalAccount mirror = _createMirror();
        MintableERC20 stray = new MintableERC20("Stray", "STR", 18);
        stray.mint(address(mirror), 42e18);
        bytes memory payload =
            _transferTokenPayload(bytes32("op-1"), address(stray), makeAddr("dest"), 1e18);
        (bytes memory message, bytes32 guid) = _composeMessage(address(mirror), 1, payload);

        // only the endpoint may deliver
        vm.prank(makeAddr("notTheEndpoint"));
        vm.expectRevert(ILoanChainAccountBase.OnlyEndpoint.selector);
        mirror.lzCompose(address(fxrpOft), guid, message, executor, "");

        // compose value is rejected, keeping a mistaken delivery retriable
        vm.deal(lzEndpoint, 1 ether);
        vm.prank(lzEndpoint);
        vm.expectRevert(ILoanChainAccountBase.NonZeroComposeValue.selector);
        mirror.lzCompose{value: 1}(address(fxrpOft), guid, message, executor, "");

        // the compose sender must be the configured OFT
        vm.prank(lzEndpoint);
        vm.expectRevert(
            abi.encodeWithSelector(
                ILoanChainAccountBase.WrongComposeSender.selector, makeAddr("otherOft")
            )
        );
        mirror.lzCompose(makeAddr("otherOft"), guid, message, executor, "");

        // the source-chain sender must be this account itself - its own Flare twin
        bytes memory forged = OFTComposeMsgCodec.encode(
            1, originEid, 0,
            abi.encodePacked(bytes32(uint256(uint160(makeAddr("intruder")))), payload)
        );
        vm.prank(lzEndpoint);
        vm.expectRevert(
            abi.encodeWithSelector(
                ILoanChainAccountBase.WrongComposeFrom.selector,
                bytes32(uint256(uint160(makeAddr("intruder"))))
            )
        );
        mirror.lzCompose(address(fxrpOft), guid, forged, executor, "");

        // the GUID must recompute from the pinned origin peer
        bytes32 wrongGuid = GUID.generate(
            1, originEid, makeAddr("maliciousPeer"), dstEid,
            bytes32(uint256(uint160(address(fxrpOft))))
        );
        vm.prank(lzEndpoint);
        vm.expectRevert(
            abi.encodeWithSelector(ILoanChainAccountBase.WrongGuid.selector, wrongGuid)
        );
        mirror.lzCompose(address(fxrpOft), wrongGuid, message, executor, "");
    }

    function testComposeRevertUnsupportedPayloads() public {
        LoanChainPersonalAccount mirror = _createMirror();

        bytes memory wrongVersion = abi.encode(uint8(2), PA_ACTION_TRANSFER_TOKEN, bytes(""));
        _deliverExpectRevert(
            address(mirror), 1, wrongVersion,
            abi.encodeWithSelector(
                ILoanChainAccountBase.UnsupportedPayloadVersion.selector, uint8(2)
            )
        );

        bytes memory wrongAction = abi.encode(PAYLOAD_VERSION_1, uint8(77), bytes(""));
        _deliverExpectRevert(
            address(mirror), 1, wrongAction,
            abi.encodeWithSelector(ILoanChainAccountBase.UnsupportedAction.selector, uint8(77))
        );
    }

    function testComposeRevertTransportNotConfigured() public {
        LoanChainPersonalAccount mirror = _createMirror();
        ILoanChainSettingsFacet.Transport memory cleared;
        vm.prank(governance);
        IILoanChainSettingsFacet(address(controller)).setLoanChainTransport(cleared);

        _deliverExpectRevert(
            address(mirror), 1,
            _transferTokenPayload(bytes32("op-1"), makeAddr("token"), makeAddr("dest"), 1e18),
            ILoanChainSettingsFacet.LoanChainTransportNotConfigured.selector
        );
    }

    //
    // helpers
    //

    function _createMirror() private returns (LoanChainPersonalAccount) {
        return LoanChainPersonalAccount(payable(
            ILoanChainSettingsFacet(address(controller)).createLoanChainPersonalAccount(xrplOwner)
        ));
    }

    function _configureTransport() private {
        fxrpOft.setPeer(originEid, originPeer);
        vm.prank(governance);
        IILoanChainSettingsFacet(address(controller)).setLoanChainTransport(
            ILoanChainSettingsFacet.Transport({
                lzEndpoint: lzEndpoint,
                fxrpOft: address(fxrpOft),
                originEid: originEid,
                originPeer: originPeer
            })
        );
    }

    function _deliver(
        address _mirror,
        uint64 _nonce,
        bytes memory _payload
    )
        private
    {
        (bytes memory message, bytes32 guid) = _composeMessage(_mirror, _nonce, _payload);
        vm.prank(lzEndpoint);
        ILoanChainPersonalAccount(_mirror).lzCompose(
            address(fxrpOft), guid, message, executor, ""
        );
    }

    function _deliverExpectRevert(
        address _mirror,
        uint64 _nonce,
        bytes memory _payload,
        bytes memory _expectedRevert
    )
        private
    {
        (bytes memory message, bytes32 guid) = _composeMessage(_mirror, _nonce, _payload);
        vm.prank(lzEndpoint);
        vm.expectRevert(_expectedRevert);
        ILoanChainPersonalAccount(_mirror).lzCompose(
            address(fxrpOft), guid, message, executor, ""
        );
    }

    function _deliverExpectRevert(
        address _mirror,
        uint64 _nonce,
        bytes memory _payload,
        bytes4 _selector
    )
        private
    {
        _deliverExpectRevert(_mirror, _nonce, _payload, abi.encodePacked(_selector));
    }

    function _transferTokenPayload(
        bytes32 _operationId,
        address _token,
        address _destination,
        uint256 _amount
    )
        private
        returns (bytes memory)
    {
        return abi.encode(
            PAYLOAD_VERSION_1,
            PA_ACTION_TRANSFER_TOKEN,
            abi.encode(
                _operationId, uint64(block.timestamp + 1 hours), _token, _destination, _amount
            )
        );
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
        address _mirror,
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
            abi.encodePacked(bytes32(uint256(uint160(_mirror))), _payload)
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
}
