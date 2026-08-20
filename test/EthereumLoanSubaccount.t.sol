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
    ACTION_SET_RECOVERY,
    SKIP_REASON_DUPLICATE,
    SKIP_REASON_EXPIRED,
    SKIP_REASON_STALE_EPOCH
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

    function testReceiveGuard() public {
        // the implementation contract is never initialized and has no parent: it must not
        // accept native; an initialized proxy accepts it (bridge refunds), and recoverNative
        // is its exit
        vm.deal(address(this), 1 ether);
        (bool success, ) = address(ethereumImpl).call{value: 1}("");
        assertFalse(success);

        EthereumLoanSubaccount subaccount = _deploySubaccount();
        (success, ) = address(subaccount).call{value: 1}("");
        assertTrue(success);
        assertEq(address(subaccount).balance, 1);
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
        morpho.createMarket(_defaultSettings().marketParams);
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

    function testGetPinnedTokens() public {
        // zero until the first route registers; the pinned pair afterwards
        (address loanToken, address collateralToken) =
            IEthereumLoanSettingsFacet(address(controller)).getPinnedTokens();
        assertEq(loanToken, address(0));
        assertEq(collateralToken, address(0));

        _configureSettings();
        (loanToken, collateralToken) =
            IEthereumLoanSettingsFacet(address(controller)).getPinnedTokens();
        assertEq(loanToken, address(rlusd));
        assertEq(collateralToken, address(fxrp));

        // the registry stays enumerable for integrators and operations
        bytes32[] memory routeIds =
            IEthereumLoanSettingsFacet(address(controller)).getRouteIds();
        assertEq(routeIds.length, 1);
        assertEq(routeIds[0], _routeId());
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

        // clearing with all-zero settings disables the transport-dependent surface until
        // reconfigured; registered routes and repayment persist
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
            _routeId(),
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
        (, uint128 borrowShares, uint128 collateral) = morpho.position(_marketId(), subaccount);
        assertEq(collateral, 100e6);
        // first borrow: shares = assets scaled by the virtual-share offset
        assertEq(borrowShares, 500e18 * 1e6);
        assertEq(fxrp.balanceOf(subaccount), 5e6);
        assertEq(rlusd.balanceOf(destination), 500e18);
        assertTrue(IEthereumLoanSubaccount(subaccount).usedOperations(operationId));
    }

    function testLzComposeBorrowOnlyTopUp() public {
        address subaccount = _createConfiguredSubaccount();
        fxrp.mint(subaccount, 100e6);

        // a zero borrow amount is a pure collateral top-up; destination fields are ignored
        _deliver(subaccount, 1, 100e6, _borrowPayload(bytes32("op-1"), 0, bytes32(0), 0));

        (, uint128 borrowShares, uint128 collateral) = morpho.position(_marketId(), subaccount);
        assertEq(collateral, 100e6);
        assertEq(borrowShares, 0);
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

        (, uint128 borrowShares, ) = morpho.position(_marketId(), subaccount);
        assertEq(borrowShares, 300e18 * 1e6);
        assertEq(rlusd.balanceOf(destination), 300e18);
    }

    function testLzComposeWithdrawReturnsCollateralToTheAccount() public {
        address subaccount = _createConfiguredSubaccount();
        fxrp.mint(subaccount, 100e6);
        _deliver(subaccount, 1, 100e6, _borrowPayload(bytes32("op-1"), 0, bytes32(0), 0));

        bytes32 operationId = bytes32("op-2");
        vm.expectEmit();
        emit IEthereumLoanSubaccount.CollateralWithdrawn(
            parentPersonalAccount, operationId, _routeId(), 30e6, _guidFor(2)
        );
        _deliver(subaccount, 2, 0, _withdrawPayload(operationId, 30e6));

        // withdrawn to the account itself, where only the fixed rails can move it
        (, , uint128 collateral) = morpho.position(_marketId(), subaccount);
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
        (bytes memory message, bytes32 guid) = _composeMessage(
            subaccount, 1, 100e6,
            _borrowPayload(
                bytes32("op-1"), DESTINATION_KIND_EVM,
                bytes32(uint256(uint160(makeAddr("dest")))), 500e18
            )
        );

        _pauseController();
        vm.prank(lzEndpoint);
        vm.expectRevert(IPauseFacet.IsPaused.selector);
        IEthereumLoanSubaccount(subaccount).lzCompose(address(fxrpOft), guid, message, executor, "");

        // the compose stays queued at the endpoint; the same delivery succeeds after unpausing
        _unpauseController();
        vm.prank(lzEndpoint);
        IEthereumLoanSubaccount(subaccount).lzCompose(address(fxrpOft), guid, message, executor, "");
        (, , uint128 collateral) = morpho.position(_marketId(), subaccount);
        assertEq(collateral, 100e6);
    }

    function testLzComposeTopUpWorksWhilePaused() public {
        // a pure collateral top-up into the indebted route moves the position toward safety,
        // like repayment: it must stay available during an incident so the position can be
        // defended against liquidation
        address subaccount = _borrowedSubaccount(500e18);
        fxrp.mint(subaccount, 50e6);
        _pauseController();

        _deliver(subaccount, 2, 50e6, _borrowPayload(bytes32("op-2"), 0, bytes32(0), 0));
        (, , uint128 collateral) = morpho.position(_marketId(), subaccount);
        assertEq(collateral, 150e6);
    }

    function testDepositIdleFxrpDefendsIndebtedRouteWhilePaused() public {
        // the defensive case of the idle rail survives a pause: already-arrived collateral
        // can still protect the indebted position; the debt-free case stays gated
        address subaccount = _borrowedSubaccount(500e18);
        fxrp.mint(subaccount, 30e6);
        _pauseController();

        IEthereumLoanSubaccount(subaccount).depositIdleFxrp();
        (, , uint128 collateral) = morpho.position(_marketId(), subaccount);
        assertEq(collateral, 130e6);

        // once the debt is gone, a paused deposit is new exposure and reverts
        rlusd.mint(subaccount, 600e18);
        IEthereumLoanSubaccount(subaccount).repay(_routeId());
        fxrp.mint(subaccount, 10e6);
        vm.expectRevert(IPauseFacet.IsPaused.selector);
        IEthereumLoanSubaccount(subaccount).depositIdleFxrp();
    }

    function testLzComposeTopUpWhilePausedRequiresLiveDebt() public {
        // a paused composed top-up is allowed only into the route carrying live debt; into a
        // debt-free route it is new exposure and waits out the pause
        address subaccount = _createConfiguredSubaccount();
        fxrp.mint(subaccount, 100e6);
        _pauseController();

        _deliverExpectRevert(
            subaccount, 1, _borrowPayload(bytes32("op-1"), 0, bytes32(0), 0),
            IPauseFacet.IsPaused.selector
        );
    }

    function testDebtRoutePointerClearsLazilyAfterExternalLiquidation() public {
        // an external liquidation zeroes the debt without the account observing it: the next
        // debt-gated call verifies the pointer against the live position and clears it
        // (syncDebtRoute is the dedicated rescue; the pointed Morpho must answer)
        address subaccount = _borrowedSubaccount(500e18);
        assertEq(IEthereumLoanSubaccount(subaccount).debtRouteId(), _routeId());

        morpho.simulateLiquidation(_marketId(), subaccount);

        // debt-free now: the idle deposit targets the active route and clears the pointer
        fxrp.mint(subaccount, 20e6);
        vm.expectEmit();
        emit IEthereumLoanSubaccount.IdleFxrpDeposited(parentPersonalAccount, _routeId(), 20e6);
        IEthereumLoanSubaccount(subaccount).depositIdleFxrp();
        assertEq(IEthereumLoanSubaccount(subaccount).debtRouteId(), bytes32(0));
    }

    function testSyncDebtRouteClearsStalePointer() public {
        // the permissionless synchronizer clears a stale pointer without needing any other
        // rail: it verifies against the live position and performs no other state change
        address subaccount = _borrowedSubaccount(500e18);
        morpho.simulateLiquidation(_marketId(), subaccount);

        assertEq(IEthereumLoanSubaccount(subaccount).debtRouteId(), _routeId());
        assertEq(IEthereumLoanSubaccount(subaccount).syncDebtRoute(), bytes32(0));
        assertEq(IEthereumLoanSubaccount(subaccount).debtRouteId(), bytes32(0));
    }

    function testDebtRoutePointerSurvivesPartialLiquidation() public {
        // a partial liquidation leaves live borrow shares: the pointer must be retained so
        // the remaining position stays defensible and recognized as outstanding debt
        address subaccount = _borrowedSubaccount(500e18);
        (, uint128 borrowShares, ) = morpho.position(_marketId(), subaccount);
        uint128 liquidated = borrowShares / 2;
        morpho.simulatePartialLiquidation(_marketId(), subaccount, liquidated);

        assertEq(IEthereumLoanSubaccount(subaccount).syncDebtRoute(), _routeId());
        assertEq(IEthereumLoanSubaccount(subaccount).debtRouteId(), _routeId());
        (, uint128 remainingShares, uint128 collateral) =
            morpho.position(_marketId(), subaccount);
        assertEq(remainingShares, borrowShares - liquidated);
        // the liquidation seizes proportional collateral and shrinks the market totals by
        // the assets the repaid shares represent, so later conversions stay canonical
        assertEq(collateral, 50e6);
        (, , uint128 totalBorrowAssets, uint128 totalBorrowShares, , ) =
            morpho.market(_marketId());
        assertEq(totalBorrowShares, remainingShares);
        uint256 repaidAssets =
            (uint256(liquidated) * (500e18 + 1) + uint256(borrowShares) + 1e6 - 1) /
                (uint256(borrowShares) + 1e6);
        assertEq(totalBorrowAssets, 500e18 - repaidAssets);

        // the remaining debt stays repayable with canonical share conversion afterwards
        rlusd.mint(subaccount, 500e18);
        IEthereumLoanSubaccount(subaccount).repay(_routeId());
        (, uint128 finalShares, ) = morpho.position(_marketId(), subaccount);
        assertEq(finalShares, 0);
        assertEq(IEthereumLoanSubaccount(subaccount).debtRouteId(), bytes32(0));
    }

    function testSimulateLiquidationAccruesPendingInterestFirst() public {
        // real Morpho accrues interest before liquidating; the mock must do the same so the
        // repaid-assets conversion and the remaining market totals stay canonical
        address subaccount = _borrowedSubaccount(500e18);
        (, uint128 borrowShares, ) = morpho.position(_marketId(), subaccount);
        morpho.addPendingInterest(_marketId(), 50e18);

        morpho.simulateLiquidation(_marketId(), subaccount);

        assertEq(morpho.pendingInterest(_marketId()), 0);
        (, , uint128 totalBorrowAssets, uint128 totalBorrowShares, , ) =
            morpho.market(_marketId());
        assertEq(totalBorrowShares, 0);
        uint256 accruedTotal = 550e18;
        uint256 repaidAssets =
            (uint256(borrowShares) * (accruedTotal + 1) + uint256(borrowShares) + 1e6 - 1) /
                (uint256(borrowShares) + 1e6);
        assertEq(
            totalBorrowAssets,
            repaidAssets >= accruedTotal ? 0 : accruedTotal - repaidAssets
        );
        assertEq(IEthereumLoanSubaccount(subaccount).syncDebtRoute(), bytes32(0));
    }

    function testSimulateLiquidationRevertsOnDebtFreePosition() public {
        // real Morpho cannot liquidate a debt-free position: the mock must not silently
        // delete collateral-only positions
        address subaccount = _createConfiguredSubaccount();
        fxrp.mint(subaccount, 100e6);
        _deliver(subaccount, 1, 100e6, _borrowPayload(bytes32("op-1"), 0, bytes32(0), 0));

        vm.expectRevert(bytes("no debt to liquidate"));
        morpho.simulateLiquidation(_marketId(), subaccount);
    }

    function testDepositIdleFxrpTargetsTheIndebtedRoute() public {
        // a top-up credit whose compose failed must not be diverted into a debt-free route:
        // the permissionless deposit targets the sole route with live debt
        address subaccount = _borrowedSubaccount(500e18);
        bytes32 routeA = _routeId();

        IEthereumLoanSettingsFacet.Settings memory settingsB = _defaultSettings();
        settingsB.marketParams.lltv = 0.5e18;
        morpho.createMarket(settingsB.marketParams);
        vm.prank(governance);
        IIEthereumLoanSettingsFacet(address(controller)).setEthereumLoanSettings(settingsB);

        fxrp.mint(subaccount, 30e6);
        vm.expectEmit();
        emit IEthereumLoanSubaccount.IdleFxrpDeposited(parentPersonalAccount, routeA, 30e6);
        IEthereumLoanSubaccount(subaccount).depositIdleFxrp();

        (, , uint128 collateralA) = morpho.position(_marketId(), subaccount);
        assertEq(collateralA, 130e6);
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

        // the two addresses already in scope when a payload is composed are never valid
        // targets: disbursing to the account itself only opens debt its own proceeds must
        // repay, and the parent Personal Account holds no code and no key on this chain
        payload = _borrowPayload(
            bytes32("op-1"), DESTINATION_KIND_EVM, bytes32(uint256(uint160(subaccount))), 500e18
        );
        _deliverExpectRevert(
            subaccount, 1, payload, IEthereumLoanSubaccount.InvalidDestination.selector
        );
        payload = _borrowPayload(
            bytes32("op-1"),
            DESTINATION_KIND_EVM,
            bytes32(uint256(uint160(parentPersonalAccount))),
            500e18
        );
        _deliverExpectRevert(
            subaccount, 1, payload, IEthereumLoanSubaccount.InvalidDestination.selector
        );

        // a borrow that would neither supply nor borrow
        payload = _borrowPayload(bytes32("op-1"), 0, bytes32(0), 0);
        _deliverExpectRevertZeroAmount(
            subaccount, 1, payload, IEthereumLoanSubaccount.ZeroAmount.selector
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

        (, , uint128 collateral) = morpho.position(_marketId(), subaccount);
        assertEq(collateral, 100e6);
        assertEq(fxrp.balanceOf(subaccount), 100e6);
    }

    function testWithdrawAndSetRecoverySkipDuplicateOperation() public {
        // the duplicate terminal gate finalizes every action kind, not just borrows: a
        // consumed operation id skips a withdraw and a set-recovery without any effect
        address subaccount = _createConfiguredSubaccount();
        bytes32 operationId = bytes32("op-1");
        fxrp.mint(subaccount, 100e6);
        _deliver(subaccount, 1, 100e6, _borrowPayload(operationId, 0, bytes32(0), 0));

        vm.expectEmit();
        emit IEthereumLoanSubaccount.LoanActionSkipped(
            parentPersonalAccount, operationId, SKIP_REASON_DUPLICATE, _guidFor(2)
        );
        _deliver(subaccount, 2, 0, _withdrawPayload(operationId, 30e6));
        (, , uint128 collateral) = morpho.position(_marketId(), subaccount);
        assertEq(collateral, 100e6);

        vm.expectEmit();
        emit IEthereumLoanSubaccount.LoanActionSkipped(
            parentPersonalAccount, operationId, SKIP_REASON_DUPLICATE, _guidFor(3)
        );
        _deliver(subaccount, 3, 0, _setRecoveryPayload(
            operationId, 1, bytes32(uint256(uint160(makeAddr("recovery"))))
        ));
        assertEq(IEthereumLoanSubaccount(subaccount).recoveryDestination(), address(0));
    }

    function testLzComposeSkipExpiredDeadlineWithoutConsumingTheOperation() public {
        address subaccount = _createConfiguredSubaccount();
        bytes32 operationId = bytes32("op-1");
        fxrp.mint(subaccount, 100e6);

        bytes memory stale = abi.encode(
            PAYLOAD_VERSION_1,
            ACTION_BORROW,
            abi.encode(
                operationId, uint64(block.timestamp - 1), _routeId(), uint8(0), bytes32(0),
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
        (, , uint128 collateral) = morpho.position(_marketId(), subaccount);
        assertEq(collateral, 100e6);
        assertEq(fxrp.balanceOf(subaccount), 100e6);
        assertTrue(IEthereumLoanSubaccount(subaccount).usedOperations(operationId));
    }

    function testLzComposeRevertRouteNotActive() public {
        address subaccount = _createConfiguredSubaccount();
        fxrp.mint(subaccount, 100e6);
        bytes32 otherRoute = keccak256("some other route");

        // a debt increase signed for a route other than the active one: a temporary state,
        // so the delivery reverts (staying retriable) rather than letting a permissionless
        // deliverer consume the packet during the mismatch window
        bytes memory payload = abi.encode(
            PAYLOAD_VERSION_1,
            ACTION_BORROW,
            abi.encode(
                bytes32("op-1"), uint64(block.timestamp + 1 hours), otherRoute,
                DESTINATION_KIND_EVM, bytes32(uint256(uint160(makeAddr("dest")))), 500e18
            )
        );
        _deliverExpectRevert(
            subaccount, 1, payload,
            abi.encodeWithSelector(IEthereumLoanSubaccount.RouteNotActive.selector, otherRoute)
        );

        // a pure top-up is not bound to the active route, but the route must be registered
        payload = abi.encode(
            PAYLOAD_VERSION_1,
            ACTION_BORROW,
            abi.encode(
                bytes32("op-1"), uint64(block.timestamp + 1 hours), otherRoute,
                uint8(0), bytes32(0), uint256(0)
            )
        );
        _deliverExpectRevert(
            subaccount, 1, payload,
            abi.encodeWithSelector(
                IEthereumLoanSubaccount.RouteNotRegistered.selector, otherRoute
            )
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
    // step 4: routes, repayment, deposits, the bridge-back sweep and recovery
    //

    function testRoutesOutliveSettingsChanges() public {
        // the core registry property: positions stay repayable and withdrawable against the
        // route they were opened in, however the active configuration changes
        address subaccount = _createConfiguredSubaccount();
        bytes32 routeA = _routeId();
        fxrp.mint(subaccount, 100e6);
        address destination = makeAddr("exchangeDeposit");
        _deliver(subaccount, 1, 100e6, _borrowPayload(
            bytes32("op-1"), DESTINATION_KIND_EVM, bytes32(uint256(uint160(destination))), 500e18
        ));

        // governance moves to a new market (different LLTV): a different route
        IEthereumLoanSettingsFacet.Settings memory settingsB = _defaultSettings();
        settingsB.marketParams.lltv = 0.5e18;
        morpho.createMarket(settingsB.marketParams);
        vm.prank(governance);
        IIEthereumLoanSettingsFacet(address(controller)).setEthereumLoanSettings(settingsB);
        bytes32 routeB = keccak256(abi.encode(address(morpho), settingsB.marketParams));
        assertEq(
            IEthereumLoanSettingsFacet(address(controller)).getActiveRouteId(), routeB
        );

        // a debt increase on the old route reverts - it is no longer the active one. Its
        // packet's credit (the hardcoded 100e6 the helper claims) arrived with lzReceive and
        // stays stranded on the account
        fxrp.mint(subaccount, 100e6);
        _deliverExpectRevert(
            subaccount, 2,
            abi.encode(
                PAYLOAD_VERSION_1,
                ACTION_BORROW,
                abi.encode(
                    bytes32("op-2"), uint64(block.timestamp + 1 hours), routeA,
                    DESTINATION_KIND_EVM, bytes32(uint256(uint160(destination))), 100e18
                )
            ),
            abi.encodeWithSelector(IEthereumLoanSubaccount.RouteNotActive.selector, routeA)
        );

        // but the old position stays fully serviceable: it can even be defended with a pure
        // collateral top-up against liquidation... (a fresh intent: new operation id, new
        // packet with its own credit - a real endpoint binds each GUID to one exact message)
        fxrp.mint(subaccount, 10e6);
        bytes memory topUpA = abi.encode(
            PAYLOAD_VERSION_1,
            ACTION_BORROW,
            abi.encode(
                bytes32("op-2b"), uint64(block.timestamp + 1 hours), routeA,
                uint8(0), bytes32(0), uint256(0)
            )
        );
        _deliver(subaccount, 3, 10e6, topUpA);
        bytes32 marketA = _marketId();
        (, , uint128 collateralTopped) = morpho.position(marketA, subaccount);
        assertEq(collateralTopped, 110e6);
        // the first packet's stranded credit stayed idle, untouched by the second action
        assertEq(fxrp.balanceOf(subaccount), 100e6);

        // ...repaid, and its collateral withdrawn
        rlusd.mint(subaccount, 600e18);
        IEthereumLoanSubaccount(subaccount).repay(routeA);
        (, uint128 borrowShares, ) = morpho.position(marketA, subaccount);
        assertEq(borrowShares, 0);

        bytes memory withdrawA = abi.encode(
            PAYLOAD_VERSION_1,
            ACTION_WITHDRAW,
            abi.encode(bytes32("op-4"), uint64(block.timestamp + 1 hours), routeA, uint256(110e6))
        );
        _deliver(subaccount, 4, 0, withdrawA);
        (, , uint128 collateralA) = morpho.position(marketA, subaccount);
        assertEq(collateralA, 0);
        assertEq(fxrp.balanceOf(subaccount), 210e6);
    }

    function testBorrowRevertWhileOtherRouteHasDebt() public {
        // one outstanding debt route at a time: otherwise a permissionless repayment could
        // pick the safer route while the liquidation-sensitive one starves
        address subaccount = _borrowedSubaccount(500e18);
        bytes32 routeA = _routeId();

        IEthereumLoanSettingsFacet.Settings memory settingsB = _defaultSettings();
        settingsB.marketParams.lltv = 0.5e18;
        morpho.createMarket(settingsB.marketParams);
        vm.prank(governance);
        IIEthereumLoanSettingsFacet(address(controller)).setEthereumLoanSettings(settingsB);
        bytes32 routeB = keccak256(abi.encode(address(morpho), settingsB.marketParams));

        fxrp.mint(subaccount, 100e6);
        bytes memory borrowB = abi.encode(
            PAYLOAD_VERSION_1,
            ACTION_BORROW,
            abi.encode(
                bytes32("op-2"), uint64(block.timestamp + 1 hours), routeB,
                DESTINATION_KIND_EVM,
                bytes32(uint256(uint160(makeAddr("dest")))), uint256(100e18)
            )
        );
        _deliverExpectRevert(
            subaccount, 2, borrowB,
            abi.encodeWithSelector(IEthereumLoanSubaccount.OutstandingDebt.selector, routeA)
        );

        // after closing the old loan, the SAME packet (identical wrapper: a real endpoint
        // binds the GUID to one exact message, amountLD included) delivers successfully
        rlusd.mint(subaccount, 600e18);
        IEthereumLoanSubaccount(subaccount).repay(routeA);
        _deliver(subaccount, 2, 100e6, borrowB);
        assertTrue(IEthereumLoanSubaccount(subaccount).isBorrowedRoute(routeB));
        bytes32[] memory borrowed = IEthereumLoanSubaccount(subaccount).getBorrowedRoutes();
        assertEq(borrowed.length, 2);
        assertEq(borrowed[0], routeA);
        assertEq(borrowed[1], routeB);
    }

    function testDuplicateFinalizesOnInactiveRoute() public {
        // terminal gates run before route checks: a duplicate delivery for a route that is no
        // longer active finalizes without effect instead of reverting forever
        address subaccount = _borrowedSubaccount(500e18);
        bytes32 routeA = _routeId();

        IEthereumLoanSettingsFacet.Settings memory settingsB = _defaultSettings();
        settingsB.marketParams.lltv = 0.5e18;
        morpho.createMarket(settingsB.marketParams);
        vm.prank(governance);
        IIEthereumLoanSettingsFacet(address(controller)).setEthereumLoanSettings(settingsB);

        // redeliver the original borrow (same operation id, new packet) against inactive A
        fxrp.mint(subaccount, 100e6);
        vm.expectEmit();
        emit IEthereumLoanSubaccount.LoanActionSkipped(
            parentPersonalAccount, bytes32("op-borrow"), SKIP_REASON_DUPLICATE, _guidFor(9)
        );
        bytes memory replay = abi.encode(
            PAYLOAD_VERSION_1,
            ACTION_BORROW,
            abi.encode(
                bytes32("op-borrow"), uint64(block.timestamp + 1 hours), routeA,
                DESTINATION_KIND_EVM,
                bytes32(uint256(uint160(makeAddr("exchangeDeposit")))), uint256(500e18)
            )
        );
        _deliver(subaccount, 9, 100e6, replay);
    }

    function testSetRecoveryWorksWhilePaused() public {
        // rotating a compromised recovery destination is configuration toward safety and must
        // not wait for (and race) an unpause; outward recovery stays paused meanwhile
        address subaccount = _createConfiguredSubaccount();
        _pauseController();

        _deliver(subaccount, 1, 0, _setRecoveryPayload(
            bytes32("op-1"), 1, bytes32(uint256(uint160(makeAddr("safeRecovery"))))
        ));
        assertEq(
            IEthereumLoanSubaccount(subaccount).recoveryDestination(), makeAddr("safeRecovery")
        );

        MintableERC20 stray = new MintableERC20("Stray", "STR", 18);
        stray.mint(subaccount, 1e18);
        vm.expectRevert(IPauseFacet.IsPaused.selector);
        IEthereumLoanSubaccount(subaccount).recoverToken(address(stray));
    }

    function testWithdrawWithAttachedCreditLeavesItIdle() public {
        // a message-only action delivered with tokens attached executes normally; the credit
        // simply stays idle on the account for the fixed rails
        address subaccount = _createConfiguredSubaccount();
        fxrp.mint(subaccount, 100e6);
        _deliver(subaccount, 1, 100e6, _borrowPayload(bytes32("op-1"), 0, bytes32(0), 0));

        fxrp.mint(subaccount, 5e6);
        _deliver(subaccount, 2, 5e6, _withdrawPayload(bytes32("op-2"), 30e6));

        (, , uint128 collateral) = morpho.position(_marketId(), subaccount);
        assertEq(collateral, 70e6);
        assertEq(fxrp.balanceOf(subaccount), 35e6);
    }

    function testSetEthereumLoanSettingsRevertCodelessToken() public {
        // the first registration pins the tokens permanently, and a Morpho market can exist
        // for an address with no code - so both tokens must be contracts
        fxrpOft.setPeer(originEid, originPeer);
        IEthereumLoanSettingsFacet.Settings memory settings = _defaultSettings();
        settings.marketParams.loanToken = makeAddr("codelessToken");
        morpho.createMarket(settings.marketParams);
        _setSettingsExpectRevert(
            settings, IEthereumLoanSettingsFacet.InvalidMarketParams.selector
        );
    }

    function testSetEthereumLoanSettingsRevertCodelessCollateralToken() public {
        // the symmetric case: a codeless collateral token must be rejected too
        fxrpOft.setPeer(originEid, originPeer);
        IEthereumLoanSettingsFacet.Settings memory settings = _defaultSettings();
        settings.marketParams.collateralToken = makeAddr("codelessCollateral");
        morpho.createMarket(settings.marketParams);
        _setSettingsExpectRevert(
            settings, IEthereumLoanSettingsFacet.InvalidMarketParams.selector
        );
    }

    function testSetEthereumLoanSettingsRevertMismatchedRouteTokens() public {
        _configureSettings();

        // the token pair is pinned across routes: a different loan token must be rejected
        IEthereumLoanSettingsFacet.Settings memory settings = _defaultSettings();
        MintableERC20 otherLoanToken = new MintableERC20("Other", "OTH", 18);
        settings.marketParams.loanToken = address(otherLoanToken);
        morpho.createMarket(settings.marketParams);
        _setSettingsExpectRevert(
            settings, IEthereumLoanSettingsFacet.MismatchedRouteTokens.selector
        );
    }

    function testRepayPartialByAssets() public {
        address subaccount = _borrowedSubaccount(500e18);
        rlusd.mint(subaccount, 200e18);

        vm.expectEmit();
        emit IEthereumLoanSubaccount.LoanRepaid(parentPersonalAccount, _routeId(), 200e18);
        uint256 assets = IEthereumLoanSubaccount(subaccount).repay(_routeId());

        assertEq(assets, 200e18);
        assertEq(rlusd.balanceOf(subaccount), 0);
        (, uint128 borrowShares, ) = morpho.position(_marketId(), subaccount);
        assertEq(borrowShares, 300e18 * 1e6);
    }

    function testRepayFullClosesByShares() public {
        // the balance covers the debt: repaid by exact borrow shares, the surplus stays
        address subaccount = _borrowedSubaccount(500e18);
        rlusd.mint(subaccount, 600e18);

        uint256 assets = IEthereumLoanSubaccount(subaccount).repay(_routeId());

        assertEq(assets, 500e18);
        (, uint128 borrowShares, ) = morpho.position(_marketId(), subaccount);
        assertEq(borrowShares, 0);
        // the over-funded remainder is surplus on the account, recoverLoanToken's material
        assertEq(rlusd.balanceOf(subaccount), 100e18);
    }

    function testRepayClampsToAccruedDebt() public {
        // the documented user flow overfunds the repayment to cover interest accrued while
        // bridging; the clamp repays exactly the live debt and leaves the rest
        address subaccount = _borrowedSubaccount(500e18);
        morpho.addPendingInterest(_marketId(), 25e18);
        rlusd.mint(subaccount, 600e18);

        uint256 assets = IEthereumLoanSubaccount(subaccount).repay(_routeId());

        // full debt incl. accrued interest, repaid via exact shares (rounding up by at most 1)
        assertGe(assets, 525e18);
        assertLe(assets, 525e18 + 1);
        (, uint128 borrowShares, ) = morpho.position(_marketId(), subaccount);
        assertEq(borrowShares, 0);
    }

    function testRepayRevertNothingToRepay() public {
        address subaccount = _createConfiguredSubaccount();

        // no idle balance
        vm.expectRevert(IEthereumLoanSubaccount.NothingToRepay.selector);
        IEthereumLoanSubaccount(subaccount).repay(_routeId());

        // balance but no debt
        rlusd.mint(subaccount, 100e18);
        vm.expectRevert(IEthereumLoanSubaccount.NothingToRepay.selector);
        IEthereumLoanSubaccount(subaccount).repay(_routeId());
    }

    function testRepayRevertRouteNotRegistered() public {
        address subaccount = _createConfiguredSubaccount();
        rlusd.mint(subaccount, 100e18);

        bytes32 unknownRoute = keccak256("unknown");
        vm.expectRevert(
            abi.encodeWithSelector(
                IEthereumLoanSubaccount.RouteNotRegistered.selector, unknownRoute
            )
        );
        IEthereumLoanSubaccount(subaccount).repay(unknownRoute);
    }

    function testRepayWorksWhilePaused() public {
        // repaying moves the position toward safety and stays available during incidents
        address subaccount = _borrowedSubaccount(500e18);
        rlusd.mint(subaccount, 200e18);
        _pauseController();

        uint256 assets = IEthereumLoanSubaccount(subaccount).repay(_routeId());
        assertEq(assets, 200e18);
    }

    function testDepositIdleFxrp() public {
        address subaccount = _createConfiguredSubaccount();
        fxrp.mint(subaccount, 70e6);

        vm.expectEmit();
        emit IEthereumLoanSubaccount.IdleFxrpDeposited(parentPersonalAccount, _routeId(), 70e6);
        uint256 amount = IEthereumLoanSubaccount(subaccount).depositIdleFxrp();

        assertEq(amount, 70e6);
        (, , uint128 collateral) = morpho.position(_marketId(), subaccount);
        assertEq(collateral, 70e6);
        assertEq(fxrp.balanceOf(subaccount), 0);
    }

    function testDepositIdleFxrpReverts() public {
        address subaccount = _createConfiguredSubaccount();

        // nothing idle
        vm.expectRevert(IEthereumLoanSubaccount.NothingToDeposit.selector);
        IEthereumLoanSubaccount(subaccount).depositIdleFxrp();

        // new exposure is pause-gated
        fxrp.mint(subaccount, 70e6);
        _pauseController();
        vm.expectRevert(IPauseFacet.IsPaused.selector);
        IEthereumLoanSubaccount(subaccount).depositIdleFxrp();
        _unpauseController();

        // cleared settings leave no active route
        IEthereumLoanSettingsFacet.Settings memory cleared;
        vm.prank(governance);
        IIEthereumLoanSettingsFacet(address(controller)).setEthereumLoanSettings(cleared);
        vm.expectRevert(IEthereumLoanSubaccount.EthereumLoanSettingsNotConfigured.selector);
        IEthereumLoanSubaccount(subaccount).depositIdleFxrp();
    }

    function testSweepToOriginBridgesBackToOwnFlareAddress() public {
        address subaccount = _createConfiguredSubaccount();
        fxrp.mint(subaccount, 100e6);
        uint256 messagingFee = 0.01 ether;

        address caller = makeAddr("keeper");
        vm.deal(caller, messagingFee + 1 ether);
        vm.prank(caller);
        uint256 amount =
            IEthereumLoanSubaccount(subaccount).sweepToOrigin{value: messagingFee + 1 ether}();

        assertEq(amount, 100e6);
        assertEq(fxrp.balanceOf(subaccount), 0);
        assertEq(fxrp.balanceOf(address(fxrpOft)), 100e6);
        (uint32 dstEid, bytes32 to, uint256 amountLD, uint256 minAmountLD,,,) =
            fxrpOft.lastSendParam();
        assertEq(dstEid, originEid);
        assertEq(to, bytes32(uint256(uint160(subaccount))));
        assertEq(amountLD, 100e6);
        assertEq(minAmountLD, 100e6);
        // exactly the quoted fee spent, exactly this call's excess refunded
        assertEq(fxrpOft.lastValue(), messagingFee);
        assertEq(caller.balance, 1 ether);
    }

    function testSweepToOriginNeverSpendsAccountNative() public {
        // pre-existing native on the account must not subsidize a public caller
        address subaccount = _createConfiguredSubaccount();
        fxrp.mint(subaccount, 100e6);
        vm.deal(subaccount, 5 ether);
        uint256 messagingFee = 0.01 ether;

        address caller = makeAddr("keeper");
        vm.deal(caller, messagingFee);
        vm.prank(caller);
        IEthereumLoanSubaccount(subaccount).sweepToOrigin{value: messagingFee}();

        assertEq(subaccount.balance, 5 ether);
        assertEq(caller.balance, 0);
    }

    function testSweepToOriginReverts() public {
        address subaccount = _createConfiguredSubaccount();
        uint256 messagingFee = 0.01 ether;
        vm.deal(address(this), 1 ether);

        // nothing to sweep
        vm.expectRevert(IEthereumLoanSubaccount.NothingToSweep.selector);
        IEthereumLoanSubaccount(subaccount).sweepToOrigin{value: messagingFee}();

        fxrp.mint(subaccount, 100e6);

        // insufficient fee
        vm.expectRevert(
            abi.encodeWithSelector(
                IEthereumLoanSubaccount.InsufficientFundsForSweep.selector, messagingFee
            )
        );
        IEthereumLoanSubaccount(subaccount).sweepToOrigin{value: messagingFee - 1}();

        // a peer mutation fails closed
        fxrpOft.setPeer(originEid, bytes32(uint256(0xbad)));
        vm.expectRevert(IEthereumLoanSubaccount.WrongOriginPeer.selector);
        IEthereumLoanSubaccount(subaccount).sweepToOrigin{value: messagingFee}();
        fxrpOft.setPeer(originEid, originPeer);

        // every exit from this chain rides the OFT: the pause stops it
        _pauseController();
        vm.expectRevert(IPauseFacet.IsPaused.selector);
        IEthereumLoanSubaccount(subaccount).sweepToOrigin{value: messagingFee}();
    }

    function testSetRecoveryDestinationViaCompose() public {
        address subaccount = _createConfiguredSubaccount();
        address destination = makeAddr("recovery");

        vm.expectEmit();
        emit IEthereumLoanSubaccount.RecoveryDestinationSet(
            parentPersonalAccount, destination, 1, _guidFor(1)
        );
        _deliver(subaccount, 1, 0, _setRecoveryPayload(
            bytes32("op-1"), 1, bytes32(uint256(uint160(destination)))
        ));

        assertEq(IEthereumLoanSubaccount(subaccount).recoveryDestination(), destination);
        assertEq(IEthereumLoanSubaccount(subaccount).recoveryEpoch(), 1);
    }

    function testSetRecoveryDestinationSkipsStaleEpoch() public {
        // deliveries are unordered: an older authenticated update must not overwrite a newer
        // destination
        address subaccount = _createConfiguredSubaccount();
        address newer = makeAddr("newer");
        _deliver(subaccount, 1, 0, _setRecoveryPayload(
            bytes32("op-2"), 2, bytes32(uint256(uint160(newer)))
        ));

        vm.expectEmit();
        emit IEthereumLoanSubaccount.LoanActionSkipped(
            parentPersonalAccount, bytes32("op-1"), SKIP_REASON_STALE_EPOCH, _guidFor(2)
        );
        _deliver(subaccount, 2, 0, _setRecoveryPayload(
            bytes32("op-1"), 1, bytes32(uint256(uint160(makeAddr("older"))))
        ));

        assertEq(IEthereumLoanSubaccount(subaccount).recoveryDestination(), newer);
        assertEq(IEthereumLoanSubaccount(subaccount).recoveryEpoch(), 2);
        // staleness cannot be cured without changing the epoch itself, so the id is retired
        assertTrue(IEthereumLoanSubaccount(subaccount).usedOperations(bytes32("op-1")));
    }

    function testSetRecoveryDestinationRevertInvalidDestination() public {
        address subaccount = _createConfiguredSubaccount();
        _deliverExpectRevert(
            subaccount, 1, _setRecoveryPayload(bytes32("op-1"), 1, bytes32(0)),
            IEthereumLoanSubaccount.InvalidDestination.selector
        );
        // same rules as the borrow disbursement: the two addresses in scope when a payload
        // is composed are never valid recovery destinations
        _deliverExpectRevert(
            subaccount, 1,
            _setRecoveryPayload(bytes32("op-1"), 1, bytes32(uint256(uint160(subaccount)))),
            IEthereumLoanSubaccount.InvalidDestination.selector
        );
        _deliverExpectRevert(
            subaccount, 1,
            _setRecoveryPayload(
                bytes32("op-1"), 1, bytes32(uint256(uint160(parentPersonalAccount)))
            ),
            IEthereumLoanSubaccount.InvalidDestination.selector
        );
    }

    function testRecoverTokenToRecoveryDestination() public {
        address subaccount = _createConfiguredSubaccount();
        address destination = _setRecovery(subaccount);
        MintableERC20 stray = new MintableERC20("Stray", "STR", 18);
        stray.mint(subaccount, 42e18);

        uint256 amount = IEthereumLoanSubaccount(subaccount).recoverToken(address(stray));
        assertEq(amount, 42e18);
        assertEq(stray.balanceOf(destination), 42e18);
    }

    function testRecoverTokenGuards() public {
        address subaccount = _createConfiguredSubaccount();
        MintableERC20 stray = new MintableERC20("Stray", "STR", 18);
        stray.mint(subaccount, 42e18);

        // no destination stored yet
        vm.expectRevert(IEthereumLoanSubaccount.RecoveryDestinationNotSet.selector);
        IEthereumLoanSubaccount(subaccount).recoverToken(address(stray));

        address destination = _setRecovery(subaccount);

        // route tokens never leave through generic recovery
        vm.expectRevert(
            abi.encodeWithSelector(IEthereumLoanSubaccount.ProtectedToken.selector, address(fxrp))
        );
        IEthereumLoanSubaccount(subaccount).recoverToken(address(fxrp));
        vm.expectRevert(
            abi.encodeWithSelector(
                IEthereumLoanSubaccount.ProtectedToken.selector, address(rlusd)
            )
        );
        IEthereumLoanSubaccount(subaccount).recoverToken(address(rlusd));

        // outward recovery is pause-gated
        _pauseController();
        vm.expectRevert(IPauseFacet.IsPaused.selector);
        IEthereumLoanSubaccount(subaccount).recoverToken(address(stray));
        _unpauseController();

        // nothing to recover
        MintableERC20 empty = new MintableERC20("Empty", "EMP", 18);
        vm.expectRevert(IEthereumLoanSubaccount.NothingToRecover.selector);
        IEthereumLoanSubaccount(subaccount).recoverToken(address(empty));
        assertEq(stray.balanceOf(destination), 0);
    }

    function testRecoverLoanTokenSurplusAfterFullRepayment() public {
        address subaccount = _borrowedSubaccount(500e18);
        address destination = _setRecovery(subaccount);
        rlusd.mint(subaccount, 600e18);

        // while debt is outstanding, the balance is repayment material
        vm.expectRevert(
            abi.encodeWithSelector(IEthereumLoanSubaccount.OutstandingDebt.selector, _routeId())
        );
        IEthereumLoanSubaccount(subaccount).recoverLoanToken(address(rlusd));

        IEthereumLoanSubaccount(subaccount).repay(_routeId());
        uint256 amount = IEthereumLoanSubaccount(subaccount).recoverLoanToken(address(rlusd));
        assertEq(amount, 100e18);
        assertEq(rlusd.balanceOf(destination), 100e18);
    }

    function testRecoverLoanTokenRejectsNonLoanTokens() public {
        address subaccount = _createConfiguredSubaccount();
        _setRecovery(subaccount);

        // the collateral token never leaves through recovery
        fxrp.mint(subaccount, 10e6);
        vm.expectRevert(
            abi.encodeWithSelector(IEthereumLoanSubaccount.ProtectedToken.selector, address(fxrp))
        );
        IEthereumLoanSubaccount(subaccount).recoverLoanToken(address(fxrp));

        // a token that is no route's loan token belongs to recoverToken
        MintableERC20 stray = new MintableERC20("Stray", "STR", 18);
        stray.mint(subaccount, 1e18);
        vm.expectRevert(
            abi.encodeWithSelector(
                IEthereumLoanSubaccount.ProtectedToken.selector, address(stray)
            )
        );
        IEthereumLoanSubaccount(subaccount).recoverLoanToken(address(stray));
    }

    function testRecoverNative() public {
        address subaccount = _createConfiguredSubaccount();
        address destination = _setRecovery(subaccount);
        vm.deal(address(this), 3 ether);
        (bool success, ) = subaccount.call{value: 3 ether}("");
        assertTrue(success);

        uint256 amount = IEthereumLoanSubaccount(subaccount).recoverNative();
        assertEq(amount, 3 ether);
        assertEq(destination.balance, 3 ether);
        assertEq(subaccount.balance, 0);
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
        morpho.createMarket(_defaultSettings().marketParams);
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

    /// A configured subaccount with 100e6 FXRP collateral and `_borrowAmount` RLUSD debt.
    function _borrowedSubaccount(uint256 _borrowAmount) private returns (address) {
        address subaccount = _createConfiguredSubaccount();
        fxrp.mint(subaccount, 100e6);
        _deliver(subaccount, 1, 100e6, _borrowPayload(
            bytes32("op-borrow"), DESTINATION_KIND_EVM,
            bytes32(uint256(uint160(makeAddr("exchangeDeposit")))), _borrowAmount
        ));
        return subaccount;
    }

    function _setRecovery(address _subaccount) private returns (address _destination) {
        _destination = makeAddr("recovery");
        _deliver(_subaccount, 99, 0, _setRecoveryPayload(
            bytes32("op-recovery"), 1, bytes32(uint256(uint160(_destination)))
        ));
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
                _routeId(),
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
            abi.encode(_operationId, uint64(block.timestamp + 1 hours), _routeId(), _amount)
        );
    }


    function _marketId() private returns (bytes32) {
        return keccak256(abi.encode(_defaultSettings().marketParams));
    }

    function _routeId() private returns (bytes32) {
        return keccak256(abi.encode(address(morpho), _defaultSettings().marketParams));
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

    function _setRecoveryPayload(
        bytes32 _operationId,
        uint64 _epoch,
        bytes32 _destination
    )
        private view
        returns (bytes memory)
    {
        return abi.encode(
            PAYLOAD_VERSION_1,
            ACTION_SET_RECOVERY,
            abi.encode(
                _operationId, uint64(block.timestamp + 1 hours), _epoch, _destination
            )
        );
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
