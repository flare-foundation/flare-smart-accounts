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
import {LoanSubaccount} from "../contracts/smartAccounts/implementation/LoanSubaccount.sol";
import {
    EthereumLoanSubaccount
} from "../contracts/smartAccounts/implementation/EthereumLoanSubaccount.sol";
import {LoanSubaccountProxy} from "../contracts/smartAccounts/proxy/LoanSubaccountProxy.sol";
import {
    EthereumLoanSettingsFacet
} from "../contracts/smartAccounts/facets/EthereumLoanSettingsFacet.sol";
import {IEthereumLoanSubaccount} from "../contracts/userInterfaces/IEthereumLoanSubaccount.sol";
import {
    IEthereumLoanSettingsFacet
} from "../contracts/userInterfaces/facets/IEthereumLoanSettingsFacet.sol";
import {
    IIEthereumLoanSettingsFacet
} from "../contracts/smartAccounts/interface/IIEthereumLoanSettingsFacet.sol";
import {IMorpho} from "../contracts/smartAccounts/interface/IMorpho.sol";
import {
    ILoanSubaccountsFacet,
    SUBACCOUNT_TYPE_LOAN
} from "../contracts/userInterfaces/facets/ILoanSubaccountsFacet.sol";
import {NotContractOwner} from "../contracts/diamond/libraries/LibDiamond.sol";
import {MintableERC20} from "../contracts/mock/MintableERC20.sol";
import {MockOft} from "../contracts/mock/MockOft.sol";
import {MockMorpho} from "../contracts/mock/MockMorpho.sol";
import {MockLzEndpoint} from "../contracts/mock/MockLzEndpoint.sol";
import {OFTComposeMsgCodec} from "@layerzerolabs/oft-evm/contracts/libs/OFTComposeMsgCodec.sol";
import {GUID} from "@layerzerolabs/lz-evm-protocol-v2/contracts/libs/GUID.sol";
import {IPauseFacet} from "../contracts/userInterfaces/facets/IPauseFacet.sol";
import {
    PAYLOAD_VERSION_1,
    ACTION_BORROW,
    ACTION_WITHDRAW,
    DESTINATION_KIND_EVM,
    DESTINATION_KIND_XRPL_WORMHOLE,
    SKIP_REASON_DUPLICATE,
    SKIP_REASON_EXPIRED
} from "../contracts/userInterfaces/IEthereumLoanSubaccount.sol";

/**
 * @title EthereumLoanSubaccountTest
 * @notice The Ethereum-side loan subaccount, step 1: the same frozen proxy resolves a
 * per-chain implementation through the controller-as-beacon, so the account keeps its
 * cross-chain CREATE2 address while behaving differently per chain. Covers initialization,
 * the implementation self-lock, resolution and upgrade routing, and address invariance
 * across implementations.
 */
// solhint-disable-next-line max-states-count
contract EthereumLoanSubaccountTest is Test, FacetsDeploy {
    address private constant SINGLETON_FACTORY = 0xce0042B868300000d44A59004Da54A005ffdcf9f;

    IIMasterAccountController private controller;
    EthereumLoanSubaccount private ethereumImpl;

    address private initialOwner;
    address private governance;
    address private parentPersonalAccount;
    address private personalAccountImplementation;

    address payable private executor;
    uint256 private executorFee;
    bytes32 private sourceId;
    uint256 private paymentProofValidityDurationSeconds;
    uint256 private defaultInstructionFee;

    MintableERC20 private fxrp;
    MintableERC20 private rlusd;
    MockOft private fxrpOft;
    address private lzEndpoint;
    MockMorpho private morpho;
    uint32 private originEid;
    bytes32 private originPeer;
    uint32 private dstEid;

    // base facets are CREATE2-deployed with a fixed salt, so they are deployed once and shared
    IDiamond.FacetCut[] private baseCuts;

    function setUp() public {
        initialOwner = makeAddr("initialOwner");
        governance = makeAddr("governance");
        // the parent Personal Account exists only on Flare; on this chain it is just an
        // address with no code, fixed into the subaccount's derivation
        parentPersonalAccount = makeAddr("parentPersonalAccount");
        executor = payable(makeAddr("executor"));
        executorFee = 100;
        sourceId = bytes32("testXRP");
        paymentProofValidityDurationSeconds = 1 days;
        defaultInstructionFee = 1_000_000;

        fxrp = new MintableERC20("F-XRPL", "fXRP", 6);
        rlusd = new MintableERC20("RLUSD", "RLUSD", 18);
        fxrpOft = new MockOft(fxrp, 0.01 ether);
        dstEid = 30101; // Ethereum
        lzEndpoint = address(new MockLzEndpoint(dstEid));
        fxrpOft.setEndpoint(lzEndpoint);
        morpho = new MockMorpho();
        originEid = 30295; // Flare
        originPeer = bytes32(uint256(uint160(makeAddr("flareSideAdapter"))));

        personalAccountImplementation = address(new PersonalAccount());
        controller = _deployDiamond();

        // the Ethereum-side diamond additionally carries the loan settings facet
        IDiamond.FacetCut[] memory settingsCut = new IDiamond.FacetCut[](1);
        settingsCut[0] = _buildFacetCut(
            address(new EthereumLoanSettingsFacet()),
            "EthereumLoanSettingsFacet",
            IDiamond.FacetCutAction.Add
        );
        vm.prank(governance);
        controller.diamondCut(settingsCut, address(0), "");

        // register the Ethereum-side implementation for the loan type (timelock is 0 in tests)
        ethereumImpl = new EthereumLoanSubaccount();
        vm.prank(governance);
        controller.setLoanSubaccountImplementation(
            SUBACCOUNT_TYPE_LOAN,
            address(ethereumImpl)
        );
    }

    function testDeployAndInitialize() public {
        EthereumLoanSubaccount subaccount = _deploySubaccount();

        assertEq(subaccount.controllerAddress(), address(controller));
        assertEq(subaccount.parentPersonalAccount(), parentPersonalAccount);
        assertEq(subaccount.subaccountType(), SUBACCOUNT_TYPE_LOAN);
        assertEq(subaccount.implementation(), address(ethereumImpl));
    }

    function testInitializeRevertAlreadyInitialized() public {
        EthereumLoanSubaccount subaccount = _deploySubaccount();

        vm.expectRevert(IEthereumLoanSubaccount.AlreadyInitialized.selector);
        subaccount.initialize(
            address(controller),
            parentPersonalAccount,
            SUBACCOUNT_TYPE_LOAN
        );
    }

    function testImplementationInitializeRevertAlreadyInitialized() public {
        // the implementation contract locks itself in its own constructor
        vm.expectRevert(IEthereumLoanSubaccount.AlreadyInitialized.selector);
        ethereumImpl.initialize(
            address(controller),
            parentPersonalAccount,
            SUBACCOUNT_TYPE_LOAN
        );
    }

    function testUpgradeRoutesToNewImplementation() public {
        EthereumLoanSubaccount subaccount = _deploySubaccount();
        assertEq(subaccount.implementation(), address(ethereumImpl));

        EthereumLoanSubaccount newImpl = new EthereumLoanSubaccount();
        vm.prank(governance);
        controller.setLoanSubaccountImplementation(
            SUBACCOUNT_TYPE_LOAN,
            address(newImpl)
        );

        // proxy resolves the new implementation, and existing state is preserved
        assertEq(subaccount.implementation(), address(newImpl));
        assertEq(subaccount.parentPersonalAccount(), parentPersonalAccount);
    }

    function testSameProxyResolvesPerChainImplementation() public {
        // the production setup in one test: the same proxy bytecode is deployed on every
        // chain, and each chain's diamond registers its own implementation for the type -
        // Flare the FAssets one, Ethereum this one. Switching the registration stands in
        // for looking at the other chain.
        EthereumLoanSubaccount subaccount = _deploySubaccount();
        assertEq(subaccount.implementation(), address(ethereumImpl));

        LoanSubaccount flareImpl = new LoanSubaccount();
        vm.prank(governance);
        controller.setLoanSubaccountImplementation(
            SUBACCOUNT_TYPE_LOAN,
            address(flareImpl)
        );

        // same account address, same state, per-chain behavior behind it
        assertEq(subaccount.implementation(), address(flareImpl));
        assertEq(subaccount.parentPersonalAccount(), parentPersonalAccount);
    }

    function testPredictedAddressIsImplementationIndependent() public {
        // the implementation never enters the CREATE2 derivation, so the predicted address
        // is identical whichever implementation - Flare's or Ethereum's - is registered;
        // this is what makes the account its own bridge destination across chains
        address predictedWithEthereumImpl = controller.getLoanSubaccount(
            "rOwner",
            SUBACCOUNT_TYPE_LOAN
        );

        LoanSubaccount flareImpl = new LoanSubaccount();
        vm.prank(governance);
        controller.setLoanSubaccountImplementation(
            SUBACCOUNT_TYPE_LOAN,
            address(flareImpl)
        );
        address predictedWithFlareImpl = controller.getLoanSubaccount(
            "rOwner",
            SUBACCOUNT_TYPE_LOAN
        );

        assertEq(predictedWithEthereumImpl, predictedWithFlareImpl);
    }

    function testRejectsNativeUntilExitExists() public {
        // there is no receive() yet: it is added together with the native exit in the
        // asset-moving steps, so the account can never hold native it cannot release
        vm.deal(address(this), 1 ether);
        (bool success, ) = address(ethereumImpl).call{value: 1}("");
        assertFalse(success);

        EthereumLoanSubaccount subaccount = _deploySubaccount();
        (success, ) = address(subaccount).call{value: 1}("");
        assertFalse(success);
    }

    //
    // step 2: the Ethereum loan settings
    //

    function testSetEthereumLoanSettings() public {
        _configureSettings();

        IEthereumLoanSettingsFacet.Settings memory stored =
            IEthereumLoanSettingsFacet(address(controller)).getEthereumLoanSettings();
        assertEq(stored.lzEndpoint, lzEndpoint);
        assertEq(stored.fxrpOft, address(fxrpOft));
        assertEq(stored.originEid, originEid);
        assertEq(stored.originPeer, originPeer);
        assertEq(stored.morpho, address(morpho));
        assertEq(stored.marketParams.loanToken, address(rlusd));
        assertEq(stored.marketParams.collateralToken, address(fxrp));
        assertEq(stored.marketParams.lltv, 0.77e18);
    }

    function testSetEthereumLoanSettingsRevertNotOwner() public {
        address notOwner = makeAddr("notOwner");
        vm.prank(notOwner);
        vm.expectRevert(
            abi.encodeWithSelector(NotContractOwner.selector, notOwner, governance)
        );
        IIEthereumLoanSettingsFacet(address(controller)).setEthereumLoanSettings(
            _defaultSettings()
        );
    }

    function testSetEthereumLoanSettingsRevertInvalidValues() public {
        fxrpOft.setPeer(originEid, originPeer);
        IEthereumLoanSettingsFacet.Settings memory settings;

        // the endpoint, Morpho and the OFT must be contracts
        settings = _defaultSettings();
        settings.lzEndpoint = makeAddr("noCode");
        _setSettingsExpectRevert(settings, IEthereumLoanSettingsFacet.InvalidLzEndpoint.selector);

        settings = _defaultSettings();
        settings.morpho = makeAddr("noCode");
        _setSettingsExpectRevert(settings, IEthereumLoanSettingsFacet.InvalidMorpho.selector);

        settings = _defaultSettings();
        settings.fxrpOft = makeAddr("noCode");
        _setSettingsExpectRevert(settings, ILoanSubaccountsFacet.InvalidFxrpOft.selector);

        settings = _defaultSettings();
        settings.originEid = 0;
        _setSettingsExpectRevert(settings, IEthereumLoanSettingsFacet.InvalidOriginEid.selector);

        settings = _defaultSettings();
        settings.originPeer = bytes32(0);
        _setSettingsExpectRevert(settings, IEthereumLoanSettingsFacet.InvalidOriginPeer.selector);

        // the market must name both tokens and a non-zero LLTV
        settings = _defaultSettings();
        settings.marketParams.loanToken = address(0);
        _setSettingsExpectRevert(settings, IEthereumLoanSettingsFacet.InvalidMarketParams.selector);

        settings = _defaultSettings();
        settings.marketParams.collateralToken = address(0);
        _setSettingsExpectRevert(settings, IEthereumLoanSettingsFacet.InvalidMarketParams.selector);

        settings = _defaultSettings();
        settings.marketParams.lltv = 0;
        _setSettingsExpectRevert(settings, IEthereumLoanSettingsFacet.InvalidMarketParams.selector);
    }

    function testSetEthereumLoanSettingsRevertWrongToken() public {
        // an OFT wrapping some other token than the market's collateral must be rejected
        MintableERC20 otherToken = new MintableERC20("Other", "OTH", 6);
        MockOft otherOft = new MockOft(otherToken, 0.01 ether);
        otherOft.setPeer(originEid, originPeer);

        IEthereumLoanSettingsFacet.Settings memory settings = _defaultSettings();
        settings.fxrpOft = address(otherOft);
        _setSettingsExpectRevert(settings, ILoanSubaccountsFacet.InvalidFxrpOft.selector);
    }

    function testSetEthereumLoanSettingsRevertWrongSharedDecimals() public {
        // the bridge-back sweep sends with minAmountLD == amountLD, so shared-decimal dust
        // would make it revert; such an OFT must be rejected up front
        fxrpOft.setPeer(originEid, originPeer);
        fxrpOft.setSharedDecimals(4);
        _setSettingsExpectRevert(
            _defaultSettings(), ILoanSubaccountsFacet.InvalidFxrpOft.selector
        );
    }

    function testSetEthereumLoanSettingsRevertWrongOftVersion() public {
        // the compose authentication depends on the canonical composeFrom encoding, so only
        // the canonical interface id and message-codec version 1 are accepted
        fxrpOft.setPeer(originEid, originPeer);

        fxrpOft.setOftVersion(0x02e49c2c, 2);
        _setSettingsExpectRevert(
            _defaultSettings(), ILoanSubaccountsFacet.InvalidFxrpOft.selector
        );

        fxrpOft.setOftVersion(0xdeadbeef, 1);
        _setSettingsExpectRevert(
            _defaultSettings(), ILoanSubaccountsFacet.InvalidFxrpOft.selector
        );

        fxrpOft.setOftVersion(0x02e49c2c, 1);
        vm.prank(governance);
        IIEthereumLoanSettingsFacet(address(controller)).setEthereumLoanSettings(
            _defaultSettings()
        );
    }

    function testSetEthereumLoanSettingsRevertPeerMismatch() public {
        // the live peer for the origin endpoint must be exactly the pinned remote OApp
        fxrpOft.setPeer(originEid, bytes32(uint256(0xbad)));
        _setSettingsExpectRevert(
            _defaultSettings(), IEthereumLoanSettingsFacet.InvalidOriginPeer.selector
        );
    }

    function testClearEthereumLoanSettingsRevertPartialZero() public {
        _configureSettings();

        // a struct with the addresses zeroed but a route or market still set is not a clear:
        // it falls through to validation and reverts, so a malformed clear cannot silently
        // wipe the settings
        IEthereumLoanSettingsFacet.Settings memory partialZero;
        partialZero.marketParams.lltv = 0.77e18;
        vm.prank(governance);
        vm.expectRevert(IEthereumLoanSettingsFacet.InvalidLzEndpoint.selector);
        IIEthereumLoanSettingsFacet(address(controller)).setEthereumLoanSettings(partialZero);

        // the configured settings are untouched
        assertEq(
            IEthereumLoanSettingsFacet(address(controller)).getEthereumLoanSettings().lzEndpoint,
            lzEndpoint
        );
    }

    function testSetEthereumLoanSettingsRevertWrongEndpointAssociation() public {
        // the OFT must be wired to the same endpoint that delivers lzCompose calls; a wrong
        // (or malicious) endpoint could fabricate every callback parameter
        fxrpOft.setPeer(originEid, originPeer);
        address otherEndpoint = makeAddr("otherEndpoint");
        vm.etch(otherEndpoint, hex"00");

        IEthereumLoanSettingsFacet.Settings memory settings = _defaultSettings();
        settings.lzEndpoint = otherEndpoint;
        _setSettingsExpectRevert(settings, IEthereumLoanSettingsFacet.InvalidLzEndpoint.selector);
    }

    function testSetEthereumLoanSettingsRevertDirtyOriginPeer() public {
        // the origin peer is an EVM address and must be cleanly zero-padded
        bytes32 dirtyPeer = bytes32(uint256(originPeer) | (uint256(1) << 200));
        fxrpOft.setPeer(originEid, dirtyPeer);

        IEthereumLoanSettingsFacet.Settings memory settings = _defaultSettings();
        settings.originPeer = dirtyPeer;
        _setSettingsExpectRevert(settings, IEthereumLoanSettingsFacet.InvalidOriginPeer.selector);
    }

    function testClearEthereumLoanSettings() public {
        _configureSettings();

        // clearing with all-zero settings disables the loan module until reconfigured
        IEthereumLoanSettingsFacet.Settings memory cleared;
        vm.prank(governance);
        IIEthereumLoanSettingsFacet(address(controller)).setEthereumLoanSettings(cleared);

        IEthereumLoanSettingsFacet.Settings memory stored =
            IEthereumLoanSettingsFacet(address(controller)).getEthereumLoanSettings();
        assertEq(stored.lzEndpoint, address(0));
        assertEq(stored.fxrpOft, address(0));
        assertEq(stored.originEid, 0);
        assertEq(stored.originPeer, bytes32(0));
        assertEq(stored.morpho, address(0));
        assertEq(stored.marketParams.loanToken, address(0));
    }

    //
    // step 3: the authenticated lzCompose entry point
    //

    function testLzComposeBorrowSuppliesBridgedAmountAndDisburses() public {
        address subaccount = _createConfiguredSubaccount();
        address destination = makeAddr("exchangeDeposit");
        // the authenticated bridged amount plus an unrelated donation on the same balance
        fxrp.mint(subaccount, 100e6);
        fxrp.mint(subaccount, 5e6);

        bytes32 operationId = bytes32("op-1");
        vm.expectEmit();
        emit IEthereumLoanSubaccount.LoanOpened(
            parentPersonalAccount,
            operationId,
            100e6,
            500e18,
            DESTINATION_KIND_EVM,
            bytes32(uint256(uint160(destination))),
            _guidFor(1)
        );
        _deliver(subaccount, 1, 100e6, _borrowPayload(
            operationId, DESTINATION_KIND_EVM, bytes32(uint256(uint160(destination))), 500e18
        ));

        // exactly the authenticated amount was supplied; the donation stays idle
        (uint256 collateral, uint256 debt) = morpho.positions(subaccount);
        assertEq(collateral, 100e6);
        assertEq(debt, 500e18);
        assertEq(fxrp.balanceOf(subaccount), 5e6);
        assertEq(rlusd.balanceOf(destination), 500e18);
        assertTrue(IEthereumLoanSubaccount(subaccount).usedOperations(operationId));
    }

    function testLzComposeBorrowOnlyTopUp() public {
        address subaccount = _createConfiguredSubaccount();
        fxrp.mint(subaccount, 100e6);

        // a zero borrow amount is a pure collateral top-up; destination fields are ignored
        _deliver(subaccount, 1, 100e6, _borrowPayload(bytes32("op-1"), 0, bytes32(0), 0));

        (uint256 collateral, uint256 debt) = morpho.positions(subaccount);
        assertEq(collateral, 100e6);
        assertEq(debt, 0);
    }

    function testLzComposeBorrowAgainstExistingCollateral() public {
        address subaccount = _createConfiguredSubaccount();
        fxrp.mint(subaccount, 100e6);
        _deliver(subaccount, 1, 100e6, _borrowPayload(bytes32("op-1"), 0, bytes32(0), 0));

        // a zero bridged amount with a non-zero borrow draws against the existing position
        address destination = makeAddr("exchangeDeposit");
        _deliver(subaccount, 2, 0, _borrowPayload(
            bytes32("op-2"), DESTINATION_KIND_EVM, bytes32(uint256(uint160(destination))), 300e18
        ));

        (, uint256 debt) = morpho.positions(subaccount);
        assertEq(debt, 300e18);
        assertEq(rlusd.balanceOf(destination), 300e18);
    }

    function testLzComposeWithdrawReturnsCollateralToTheAccount() public {
        address subaccount = _createConfiguredSubaccount();
        fxrp.mint(subaccount, 100e6);
        _deliver(subaccount, 1, 100e6, _borrowPayload(bytes32("op-1"), 0, bytes32(0), 0));

        bytes32 operationId = bytes32("op-2");
        vm.expectEmit();
        emit IEthereumLoanSubaccount.CollateralWithdrawn(
            parentPersonalAccount, operationId, 30e6, _guidFor(2)
        );
        _deliver(subaccount, 2, 0, _withdrawPayload(operationId, 30e6));

        // withdrawn to the account itself, where only the fixed rails can move it
        (uint256 collateral,) = morpho.positions(subaccount);
        assertEq(collateral, 70e6);
        assertEq(fxrp.balanceOf(subaccount), 30e6);
    }

    function testLzComposeRevertNonZeroComposeValue() public {
        address subaccount = _createConfiguredSubaccount();
        fxrp.mint(subaccount, 100e6);
        (bytes memory message, bytes32 guid) =
            _composeMessage(subaccount, 1, 100e6, _borrowPayload(bytes32("op-1"), 0, bytes32(0), 0));

        vm.deal(lzEndpoint, 1 ether);
        vm.prank(lzEndpoint);
        vm.expectRevert(IEthereumLoanSubaccount.NonZeroComposeValue.selector);
        IEthereumLoanSubaccount(subaccount).lzCompose{value: 1}(
            address(fxrpOft), guid, message, executor, ""
        );
    }

    function testLzComposeRevertOnlyEndpoint() public {
        address subaccount = _createConfiguredSubaccount();
        (bytes memory message, bytes32 guid) =
            _composeMessage(subaccount, 1, 100e6, _borrowPayload(bytes32("op-1"), 0, bytes32(0), 0));

        vm.prank(makeAddr("notTheEndpoint"));
        vm.expectRevert(IEthereumLoanSubaccount.OnlyEndpoint.selector);
        IEthereumLoanSubaccount(subaccount).lzCompose(address(fxrpOft), guid, message, executor, "");
    }

    function testLzComposeRevertWrongComposeSender() public {
        address subaccount = _createConfiguredSubaccount();
        (bytes memory message, bytes32 guid) =
            _composeMessage(subaccount, 1, 100e6, _borrowPayload(bytes32("op-1"), 0, bytes32(0), 0));

        address notTheOft = makeAddr("notTheOft");
        vm.prank(lzEndpoint);
        vm.expectRevert(
            abi.encodeWithSelector(IEthereumLoanSubaccount.WrongComposeSender.selector, notTheOft)
        );
        IEthereumLoanSubaccount(subaccount).lzCompose(notTheOft, guid, message, executor, "");
    }

    function testLzComposeRevertWrongSourceEid() public {
        address subaccount = _createConfiguredSubaccount();
        bytes memory message = OFTComposeMsgCodec.encode(
            1,
            originEid + 1,
            100e6,
            abi.encodePacked(
                bytes32(uint256(uint160(subaccount))),
                _borrowPayload(bytes32("op-1"), 0, bytes32(0), 0)
            )
        );

        vm.prank(lzEndpoint);
        vm.expectRevert(
            abi.encodeWithSelector(IEthereumLoanSubaccount.WrongSourceEid.selector, originEid + 1)
        );
        IEthereumLoanSubaccount(subaccount).lzCompose(
            address(fxrpOft), _guidFor(1), message, executor, ""
        );
    }

    function testLzComposeRevertWrongComposeFrom() public {
        // an attacker bridging their own FXRP to this account cannot execute a payload: the
        // canonical codec records them as the source-chain sender
        address subaccount = _createConfiguredSubaccount();
        bytes32 attacker = bytes32(uint256(uint160(makeAddr("attacker"))));
        bytes memory message = OFTComposeMsgCodec.encode(
            1,
            originEid,
            100e6,
            abi.encodePacked(attacker, _borrowPayload(bytes32("op-1"), 0, bytes32(0), 0))
        );

        vm.prank(lzEndpoint);
        vm.expectRevert(
            abi.encodeWithSelector(IEthereumLoanSubaccount.WrongComposeFrom.selector, attacker)
        );
        IEthereumLoanSubaccount(subaccount).lzCompose(
            address(fxrpOft), _guidFor(1), message, executor, ""
        );
    }

    function testLzComposeRevertWrongGuidForForgedPeer() public {
        // the temporary-peer-swap forgery: a malicious peer can forge composeFrom inside the
        // OFT message, but the endpoint computes the GUID from the true packet header, so it
        // can never match the one recomputed from the pinned origin peer
        address subaccount = _createConfiguredSubaccount();
        fxrp.mint(subaccount, 100e6);
        (bytes memory message,) =
            _composeMessage(subaccount, 1, 100e6, _borrowPayload(bytes32("op-1"), 0, bytes32(0), 0));
        bytes32 forgedGuid = GUID.generate(
            1, originEid, makeAddr("maliciousPeer"), dstEid,
            bytes32(uint256(uint160(address(fxrpOft))))
        );

        vm.prank(lzEndpoint);
        vm.expectRevert(
            abi.encodeWithSelector(IEthereumLoanSubaccount.WrongGuid.selector, forgedGuid)
        );
        IEthereumLoanSubaccount(subaccount).lzCompose(
            address(fxrpOft), forgedGuid, message, executor, ""
        );
    }

    function testLzComposeRevertWhenPausedThenRetriable() public {
        address subaccount = _createConfiguredSubaccount();
        fxrp.mint(subaccount, 100e6);
        (bytes memory message, bytes32 guid) =
            _composeMessage(subaccount, 1, 100e6, _borrowPayload(bytes32("op-1"), 0, bytes32(0), 0));

        _pauseController();
        vm.prank(lzEndpoint);
        vm.expectRevert(IPauseFacet.IsPaused.selector);
        IEthereumLoanSubaccount(subaccount).lzCompose(address(fxrpOft), guid, message, executor, "");

        // the compose stays queued at the endpoint; the same delivery succeeds after unpausing
        _unpauseController();
        vm.prank(lzEndpoint);
        IEthereumLoanSubaccount(subaccount).lzCompose(address(fxrpOft), guid, message, executor, "");
        (uint256 collateral,) = morpho.positions(subaccount);
        assertEq(collateral, 100e6);
    }

    function testLzComposeRevertNotConfigured() public {
        address subaccount = _createConfiguredSubaccount();
        (bytes memory message, bytes32 guid) =
            _composeMessage(subaccount, 1, 100e6, _borrowPayload(bytes32("op-1"), 0, bytes32(0), 0));

        IEthereumLoanSettingsFacet.Settings memory cleared;
        vm.prank(governance);
        IIEthereumLoanSettingsFacet(address(controller)).setEthereumLoanSettings(cleared);

        vm.prank(lzEndpoint);
        vm.expectRevert(IEthereumLoanSubaccount.EthereumLoanSettingsNotConfigured.selector);
        IEthereumLoanSubaccount(subaccount).lzCompose(address(fxrpOft), guid, message, executor, "");
    }

    function testLzComposeRevertUnsupportedPayloadShapes() public {
        address subaccount = _createConfiguredSubaccount();
        fxrp.mint(subaccount, 100e6);

        // unsupported schema version
        bytes memory payload = abi.encode(uint8(2), ACTION_BORROW, bytes(""));
        _deliverExpectRevert(
            subaccount, 1, payload,
            abi.encodeWithSelector(IEthereumLoanSubaccount.UnsupportedPayloadVersion.selector, 2)
        );

        // unsupported action
        payload = abi.encode(PAYLOAD_VERSION_1, uint8(9), bytes(""));
        _deliverExpectRevert(
            subaccount, 1, payload,
            abi.encodeWithSelector(IEthereumLoanSubaccount.UnsupportedAction.selector, 9)
        );

        // the reserved Wormhole destination kind
        payload = _borrowPayload(
            bytes32("op-1"), DESTINATION_KIND_XRPL_WORMHOLE, bytes32(uint256(1)), 500e18
        );
        _deliverExpectRevert(
            subaccount, 1, payload,
            abi.encodeWithSelector(
                IEthereumLoanSubaccount.UnsupportedDestinationKind.selector,
                DESTINATION_KIND_XRPL_WORMHOLE
            )
        );

        // a zero destination, and a destination with dirty upper bits
        payload = _borrowPayload(bytes32("op-1"), DESTINATION_KIND_EVM, bytes32(0), 500e18);
        _deliverExpectRevert(
            subaccount, 1, payload, IEthereumLoanSubaccount.InvalidDestination.selector
        );
        bytes32 dirty = bytes32(uint256(uint160(makeAddr("dest"))) | (uint256(1) << 200));
        payload = _borrowPayload(bytes32("op-1"), DESTINATION_KIND_EVM, dirty, 500e18);
        _deliverExpectRevert(
            subaccount, 1, payload, IEthereumLoanSubaccount.InvalidDestination.selector
        );

        // a borrow that would neither supply nor borrow
        payload = _borrowPayload(bytes32("op-1"), 0, bytes32(0), 0);
        _deliverExpectRevertZeroAmount(
            subaccount, 1, payload, IEthereumLoanSubaccount.NothingToDo.selector
        );
    }

    function testLzComposeSkipDuplicateOperation() public {
        address subaccount = _createConfiguredSubaccount();
        bytes32 operationId = bytes32("op-1");
        fxrp.mint(subaccount, 100e6);
        _deliver(subaccount, 1, 100e6, _borrowPayload(operationId, 0, bytes32(0), 0));

        // a retried instruction delivered twice must not double-execute; the second delivery
        // completes without effect and its bridged FXRP stays on the account
        fxrp.mint(subaccount, 100e6);
        vm.expectEmit();
        emit IEthereumLoanSubaccount.LoanActionSkipped(
            parentPersonalAccount, operationId, SKIP_REASON_DUPLICATE, _guidFor(2)
        );
        _deliver(subaccount, 2, 100e6, _borrowPayload(operationId, 0, bytes32(0), 0));

        (uint256 collateral,) = morpho.positions(subaccount);
        assertEq(collateral, 100e6);
        assertEq(fxrp.balanceOf(subaccount), 100e6);
    }

    function testLzComposeSkipExpiredDeadlineWithoutConsumingTheOperation() public {
        address subaccount = _createConfiguredSubaccount();
        bytes32 operationId = bytes32("op-1");
        fxrp.mint(subaccount, 100e6);

        bytes memory stale = abi.encode(
            PAYLOAD_VERSION_1,
            ACTION_BORROW,
            abi.encode(
                operationId, uint64(block.timestamp - 1), _marketId(), uint8(0), bytes32(0),
                uint256(0)
            )
        );
        vm.expectEmit();
        emit IEthereumLoanSubaccount.LoanActionSkipped(
            parentPersonalAccount, operationId, SKIP_REASON_EXPIRED, _guidFor(1)
        );
        _deliver(subaccount, 1, 100e6, stale);
        assertFalse(IEthereumLoanSubaccount(subaccount).usedOperations(operationId));

        // the same intent retries under the same operation id with a fresh deadline; the
        // retry is a real second packet, crediting its own amount - the first packet's stale
        // credit stays idle on the account for the fixed rails
        fxrp.mint(subaccount, 100e6);
        _deliver(subaccount, 2, 100e6, _borrowPayload(operationId, 0, bytes32(0), 0));
        (uint256 collateral,) = morpho.positions(subaccount);
        assertEq(collateral, 100e6);
        assertEq(fxrp.balanceOf(subaccount), 100e6);
        assertTrue(IEthereumLoanSubaccount(subaccount).usedOperations(operationId));
    }

    function testLzComposeRevertWrongMarket() public {
        address subaccount = _createConfiguredSubaccount();
        fxrp.mint(subaccount, 100e6);

        // signed for a different market than the one configured at delivery time: this is a
        // temporary state, so the delivery reverts (staying retriable) rather than letting a
        // permissionless deliverer consume the packet during the mismatch window
        bytes32 otherMarket = keccak256("some other market");
        bytes memory payload = abi.encode(
            PAYLOAD_VERSION_1,
            ACTION_BORROW,
            abi.encode(
                bytes32("op-1"), uint64(block.timestamp + 1 hours), otherMarket,
                uint8(0), bytes32(0), uint256(0)
            )
        );
        _deliverExpectRevert(
            subaccount, 1, payload,
            abi.encodeWithSelector(IEthereumLoanSubaccount.WrongMarket.selector, otherMarket)
        );
    }

    function testLzComposeRevertInvalidOperationId() public {
        address subaccount = _createConfiguredSubaccount();
        fxrp.mint(subaccount, 100e6);

        _deliverExpectRevert(
            subaccount, 1, _borrowPayload(bytes32(0), 0, bytes32(0), 0),
            IEthereumLoanSubaccount.InvalidOperationId.selector
        );
    }

    function testLzComposeRevertInsufficientComposeBalance() public {
        // the credited tokens were moved before the compose executed (the documented race):
        // the action fails closed instead of consuming unrelated idle balance
        address subaccount = _createConfiguredSubaccount();
        fxrp.mint(subaccount, 40e6);

        _deliverExpectRevert(
            subaccount, 1, _borrowPayload(bytes32("op-1"), 0, bytes32(0), 0),
            abi.encodeWithSelector(
                IEthereumLoanSubaccount.InsufficientComposeBalance.selector, 100e6, 40e6
            )
        );
    }

    function testCreateEthereumLoanSubaccountWithoutPersonalAccount() public {
        // the production creation route on this chain: no Personal Account exists or ever
        // will, the parent is resolved to its computed address
        string memory xrplOwner = "rEthereumOnlyOwner";
        address predicted = controller.getLoanSubaccount(xrplOwner, SUBACCOUNT_TYPE_LOAN);
        assertEq(predicted.code.length, 0);

        address created = IEthereumLoanSettingsFacet(address(controller))
            .createEthereumLoanSubaccount(xrplOwner, SUBACCOUNT_TYPE_LOAN);
        assertEq(created, predicted);
        assertNotEq(created.code.length, 0);

        // idempotent
        address again = IEthereumLoanSettingsFacet(address(controller))
            .createEthereumLoanSubaccount(xrplOwner, SUBACCOUNT_TYPE_LOAN);
        assertEq(again, created);
    }

    function testCreateEthereumLoanSubaccountRevertWhenPaused() public {
        _pauseController();
        vm.expectRevert(IPauseFacet.IsPaused.selector);
        IEthereumLoanSettingsFacet(address(controller))
            .createEthereumLoanSubaccount("rOwner", SUBACCOUNT_TYPE_LOAN);
    }

    //
    // helpers
    //

    function _defaultSettings()
        private
        returns (IEthereumLoanSettingsFacet.Settings memory)
    {
        return IEthereumLoanSettingsFacet.Settings({
            lzEndpoint: lzEndpoint,
            fxrpOft: address(fxrpOft),
            originEid: originEid,
            originPeer: originPeer,
            morpho: address(morpho),
            marketParams: IMorpho.MarketParams({
                loanToken: address(rlusd),
                collateralToken: address(fxrp),
                oracle: makeAddr("oracle"),
                irm: makeAddr("irm"),
                lltv: 0.77e18
            })
        });
    }

    function _configureSettings() private {
        fxrpOft.setPeer(originEid, originPeer);
        vm.prank(governance);
        IIEthereumLoanSettingsFacet(address(controller)).setEthereumLoanSettings(
            _defaultSettings()
        );
    }

    function _setSettingsExpectRevert(
        IEthereumLoanSettingsFacet.Settings memory _settings,
        bytes4 _selector
    )
        private
    {
        vm.prank(governance);
        vm.expectRevert(_selector);
        IIEthereumLoanSettingsFacet(address(controller)).setEthereumLoanSettings(_settings);
    }

    function _createConfiguredSubaccount() private returns (address) {
        _configureSettings();
        return address(_deploySubaccount());
    }

    function _deliver(
        address _subaccount,
        uint64 _nonce,
        uint256 _amountLD,
        bytes memory _payload
    )
        private
    {
        (bytes memory message, bytes32 guid) =
            _composeMessage(_subaccount, _nonce, _amountLD, _payload);
        vm.prank(lzEndpoint);
        IEthereumLoanSubaccount(_subaccount).lzCompose(
            address(fxrpOft), guid, message, executor, ""
        );
    }

    function _deliverExpectRevert(
        address _subaccount,
        uint64 _nonce,
        bytes memory _payload,
        bytes memory _expectedRevert
    )
        private
    {
        (bytes memory message, bytes32 guid) =
            _composeMessage(_subaccount, _nonce, 100e6, _payload);
        vm.prank(lzEndpoint);
        vm.expectRevert(_expectedRevert);
        IEthereumLoanSubaccount(_subaccount).lzCompose(
            address(fxrpOft), guid, message, executor, ""
        );
    }

    function _deliverExpectRevert(
        address _subaccount,
        uint64 _nonce,
        bytes memory _payload,
        bytes4 _selector
    )
        private
    {
        _deliverExpectRevert(_subaccount, _nonce, _payload, abi.encodePacked(_selector));
    }

    function _deliverExpectRevertZeroAmount(
        address _subaccount,
        uint64 _nonce,
        bytes memory _payload,
        bytes4 _selector
    )
        private
    {
        (bytes memory message, bytes32 guid) = _composeMessage(_subaccount, _nonce, 0, _payload);
        vm.prank(lzEndpoint);
        vm.expectRevert(_selector);
        IEthereumLoanSubaccount(_subaccount).lzCompose(
            address(fxrpOft), guid, message, executor, ""
        );
    }

    function _borrowPayload(
        bytes32 _operationId,
        uint8 _destinationKind,
        bytes32 _destination,
        uint256 _borrowAmount
    )
        private
        returns (bytes memory)
    {
        return abi.encode(
            PAYLOAD_VERSION_1,
            ACTION_BORROW,
            abi.encode(
                _operationId,
                uint64(block.timestamp + 1 hours),
                _marketId(),
                _destinationKind,
                _destination,
                _borrowAmount
            )
        );
    }

    function _withdrawPayload(
        bytes32 _operationId,
        uint256 _amount
    )
        private
        returns (bytes memory)
    {
        return abi.encode(
            PAYLOAD_VERSION_1,
            ACTION_WITHDRAW,
            abi.encode(_operationId, uint64(block.timestamp + 1 hours), _marketId(), _amount)
        );
    }

    function _marketId() private returns (bytes32) {
        return keccak256(abi.encode(_defaultSettings().marketParams));
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
            keccak256(abi.encode("ethereum-diamond", vm.getNonce(address(this))))
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

    function _deploySubaccount() private returns (EthereumLoanSubaccount) {
        LoanSubaccountProxy proxy = new LoanSubaccountProxy(
            address(controller),
            parentPersonalAccount,
            SUBACCOUNT_TYPE_LOAN
        );
        return EthereumLoanSubaccount(payable(address(proxy)));
    }

    function _composeMessage(
        address _subaccount,
        uint64 _nonce,
        uint256 _amountLD,
        bytes memory _payload
    )
        private view
        returns (bytes memory _message, bytes32 _guid)
    {
        _message = OFTComposeMsgCodec.encode(
            _nonce,
            originEid,
            _amountLD,
            abi.encodePacked(bytes32(uint256(uint160(_subaccount))), _payload)
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
