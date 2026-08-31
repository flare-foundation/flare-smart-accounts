// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {FacetsDeploy} from "./utils/FacetsDeploy.t.sol";
import {IDiamond} from "../contracts/diamond/interfaces/IDiamond.sol";
import {DiamondArgs, FunctionNotFound} from "../contracts/diamond/implementation/Diamond.sol";
import {IISingletonFactory} from "../contracts/smartAccounts/interface/IISingletonFactory.sol";
import {MasterAccountController} from "../contracts/smartAccounts/implementation/MasterAccountController.sol";
import {IIMasterAccountController} from "../contracts/smartAccounts/interface/IIMasterAccountController.sol";
import {MasterAccountControllerInit} from "../contracts/smartAccounts/facets/MasterAccountControllerInit.sol";
import {PersonalAccount} from "../contracts/smartAccounts/implementation/PersonalAccount.sol";
import {LoanSubaccount} from "../contracts/smartAccounts/implementation/LoanSubaccount.sol";
import {PersonalAccountProxy} from "../contracts/smartAccounts/proxy/PersonalAccountProxy.sol";
import {
    LoanSubaccountRemote
} from "../contracts/smartAccounts/implementation/LoanSubaccountRemote.sol";
import {SubaccountProxy} from "../contracts/smartAccounts/proxy/SubaccountProxy.sol";
import {ComposeTransportFacet} from "../contracts/smartAccounts/facets/ComposeTransportFacet.sol";
import {LoanMarketsFacet} from "../contracts/smartAccounts/facets/LoanMarketsFacet.sol";
import {SubaccountsFacet} from "../contracts/smartAccounts/facets/SubaccountsFacet.sol";
import {PersonalAccountsFacet} from "../contracts/smartAccounts/facets/PersonalAccountsFacet.sol";
import {
    PersonalAccountRemote
} from "../contracts/smartAccounts/implementation/PersonalAccountRemote.sol";
import {TimelockFacet} from "../contracts/smartAccounts/facets/TimelockFacet.sol";
import {PauseFacet} from "../contracts/smartAccounts/facets/PauseFacet.sol";
import {ILoanSubaccountRemote} from "../contracts/userInterfaces/ILoanSubaccountRemote.sol";
import {
    ILoanSubaccount,
    ACTION_REDEEM_HOME,
    REDEEM_HOME_TTL
} from "../contracts/userInterfaces/ILoanSubaccount.sol";
import {IPersonalAccount} from "../contracts/userInterfaces/IPersonalAccount.sol";
import {
    IPersonalAccountRemote,
    PA_ACTION_EXECUTE
} from "../contracts/userInterfaces/IPersonalAccountRemote.sol";
import {IFlareContractRegistry} from "flare-periphery/src/flare/IFlareContractRegistry.sol";
import {IComposeTransportFacet} from "../contracts/userInterfaces/facets/IComposeTransportFacet.sol";
import {
    ILoanMarketsFacet,
    MAX_FEE_RATE
} from "../contracts/userInterfaces/facets/ILoanMarketsFacet.sol";
import {IIComposeTransportFacet} from "../contracts/smartAccounts/interface/IIComposeTransportFacet.sol";
import {IILoanMarketsFacet} from "../contracts/smartAccounts/interface/IILoanMarketsFacet.sol";
import {IMorpho} from "../contracts/smartAccounts/interface/IMorpho.sol";
import {
    ISubaccountsFacet,
    SUBACCOUNT_TYPE_LOAN
} from "../contracts/userInterfaces/facets/ISubaccountsFacet.sol";
import {ILoanBridgeSettingsFacet} from "../contracts/userInterfaces/facets/ILoanBridgeSettingsFacet.sol";
import {NotContractOwner} from "../contracts/diamond/libraries/LibDiamond.sol";
import {MintableERC20} from "../contracts/mock/MintableERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockOft} from "../contracts/mock/MockOft.sol";
import {MockAssetManager} from "../contracts/mock/MockAssetManager.sol";
import {MockMorpho} from "../contracts/mock/MockMorpho.sol";
import {MockFreezableToken} from "../contracts/mock/MockFreezableToken.sol";
import {MockLzEndpoint} from "../contracts/mock/MockLzEndpoint.sol";
import {OFTComposeMsgCodec} from "@layerzerolabs/oft-evm/contracts/libs/OFTComposeMsgCodec.sol";
import {GUID} from "@layerzerolabs/lz-evm-protocol-v2/contracts/libs/GUID.sol";
import {IPauseFacet} from "../contracts/userInterfaces/facets/IPauseFacet.sol";
import {ITimelockFacet} from "../contracts/userInterfaces/facets/ITimelockFacet.sol";
import {
    ACTION_BORROW,
    ACTION_WITHDRAW,
    ACTION_DEPOSIT_COLLATERAL,
    DESTINATION_KIND_EVM,
    DESTINATION_KIND_XRPL_WORMHOLE
} from "../contracts/userInterfaces/ILoanSubaccountRemote.sol";
import {
    IComposeReceiverAccountBase,
    PAYLOAD_VERSION_1,
    SKIP_REASON_DUPLICATE,
    SKIP_REASON_EXPIRED
} from "../contracts/userInterfaces/IComposeReceiverAccountBase.sol";

/**
 * @title LoanSubaccountRemoteTest
 * @notice The loan-chain-side subaccount (Ethereum, at launch), step 1: the same frozen
 * proxy resolves a per-chain implementation through the controller-as-beacon, so the
 * account keeps its cross-chain CREATE2 address while behaving differently per chain. Covers initialization,
 * the implementation self-lock, resolution and upgrade routing, and address invariance
 * across implementations.
 */
// solhint-disable-next-line max-states-count
contract LoanSubaccountRemoteTest is Test, FacetsDeploy {
    address private constant SINGLETON_FACTORY = 0xce0042B868300000d44A59004Da54A005ffdcf9f;
    /// The signed return-leg options a withdraw payload carries (the mock OFT ignores them).
    bytes private constant RETURN_OPTIONS = hex"0003";
    /// The signed delivery-value floor a withdraw payload carries.
    uint256 private constant RETURN_MIN_VALUE = 0.01 ether;
    address private constant FLARE_CONTRACT_REGISTRY = 0xaD67FE66660Fb8dFE9d6b1b4240d8650e30F6019;
    MockAssetManager private flareAssetManager;

    IIMasterAccountController private controller;
    LoanSubaccountRemote private loanChainImpl;

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

        // the remote diamond additionally carries the compose transport and the loan markets
        IDiamond.FacetCut[] memory settingsCut = new IDiamond.FacetCut[](2);
        settingsCut[0] = _buildFacetCut(
            address(new ComposeTransportFacet()),
            "ComposeTransportFacet",
            IDiamond.FacetCutAction.Add
        );
        settingsCut[1] = _buildFacetCut(
            address(new LoanMarketsFacet()),
            "LoanMarketsFacet",
            IDiamond.FacetCutAction.Add
        );
        vm.prank(governance);
        controller.diamondCut(settingsCut, address(0), "");

        // register the loan-chain implementation for the loan type (timelock is 0 in tests)
        loanChainImpl = new LoanSubaccountRemote();
        vm.prank(governance);
        controller.setSubaccountImplementation(
            SUBACCOUNT_TYPE_LOAN,
            address(loanChainImpl)
        );
    }

    function testDeployAndInitialize() public {
        LoanSubaccountRemote subaccount = _deploySubaccount();

        assertEq(subaccount.controllerAddress(), address(controller));
        assertEq(subaccount.parentPersonalAccount(), parentPersonalAccount);
        assertEq(subaccount.subaccountType(), SUBACCOUNT_TYPE_LOAN);
        assertEq(subaccount.implementation(), address(loanChainImpl));
    }

    function testInitializeRevertAlreadyInitialized() public {
        LoanSubaccountRemote subaccount = _deploySubaccount();

        vm.expectRevert(IComposeReceiverAccountBase.AlreadyInitialized.selector);
        subaccount.initialize(
            address(controller),
            parentPersonalAccount,
            SUBACCOUNT_TYPE_LOAN
        );
    }

    function testImplementationInitializeRevertAlreadyInitialized() public {
        // the implementation contract locks itself in its own constructor
        vm.expectRevert(IComposeReceiverAccountBase.AlreadyInitialized.selector);
        loanChainImpl.initialize(
            address(controller),
            parentPersonalAccount,
            SUBACCOUNT_TYPE_LOAN
        );
    }

    function testUpgradeRoutesToNewImplementation() public {
        LoanSubaccountRemote subaccount = _deploySubaccount();
        assertEq(subaccount.implementation(), address(loanChainImpl));

        LoanSubaccountRemote newImpl = new LoanSubaccountRemote();
        vm.prank(governance);
        controller.setSubaccountImplementation(
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
        // Flare the FAssets one, the loan chain this one. Switching the registration stands in
        // for looking at the other chain.
        LoanSubaccountRemote subaccount = _deploySubaccount();
        assertEq(subaccount.implementation(), address(loanChainImpl));
        assertEq(subaccount.parentPersonalAccount(), parentPersonalAccount);

        LoanSubaccount flareImpl = new LoanSubaccount();
        vm.prank(governance);
        controller.setSubaccountImplementation(
            SUBACCOUNT_TYPE_LOAN,
            address(flareImpl)
        );

        // same account address, per-chain behavior behind it: the registry now resolves the
        // type to the other chain's implementation. Reads through the account itself must go
        // through the matching chain's implementation: storage belongs to each proxy, and the
        // two chains share only the address - layouts may differ across chains, while every
        // chain-local upgrade lineage must preserve its proxies' layout
        assertEq(controller.implementationForType(SUBACCOUNT_TYPE_LOAN), address(flareImpl));
    }

    function testPredictedAddressIsImplementationIndependent() public {
        // the implementation never enters the CREATE2 derivation, so the predicted address
        // is identical whichever implementation - Flare's or the loan chain's - is registered;
        // this is what makes the account its own bridge destination across chains
        address predictedWithLoanChainImpl = controller.getSubaccount(
            "rOwner",
            SUBACCOUNT_TYPE_LOAN
        );

        LoanSubaccount flareImpl = new LoanSubaccount();
        vm.prank(governance);
        controller.setSubaccountImplementation(
            SUBACCOUNT_TYPE_LOAN,
            address(flareImpl)
        );
        address predictedWithFlareImpl = controller.getSubaccount(
            "rOwner",
            SUBACCOUNT_TYPE_LOAN
        );

        assertEq(predictedWithLoanChainImpl, predictedWithFlareImpl);
    }

    function testRejectsPlainNative() public {
        // the only protocol-delivered native is a withdraw delivery's compose value, spent or
        // forwarded within the same call, so the account has no receive() and no native exit:
        // a plain send reverts at the sender - implementation and proxy alike
        vm.deal(address(this), 1 ether);
        (bool success, ) = address(loanChainImpl).call{value: 1}("");
        assertFalse(success);

        LoanSubaccountRemote subaccount = _deploySubaccount();
        (success, ) = address(subaccount).call{value: 1}("");
        assertFalse(success);
        assertEq(address(subaccount).balance, 0);
    }

    //
    // step 2: the loan-chain settings
    //

    function testSetComposeTransportAndRegisterMarket() public {
        _configureSettings();

        IComposeTransportFacet.Transport memory transport =
            IComposeTransportFacet(address(controller)).getComposeTransport();
        assertEq(transport.lzEndpoint, lzEndpoint);
        assertEq(transport.oft, address(fxrpOft));
        assertEq(transport.originEid, originEid);
        assertEq(transport.originPeer, originPeer);

        ILoanMarketsFacet.Market memory market =
            ILoanMarketsFacet(address(controller)).getLoanMarket(
                SUBACCOUNT_TYPE_LOAN
            );
        assertEq(market.morpho, address(morpho));
        assertEq(market.marketParams.loanToken, address(rlusd));
        assertEq(market.marketParams.collateralToken, address(fxrp));
        assertEq(market.marketParams.lltv, 0.77e18);
        assertFalse(
            ILoanMarketsFacet(address(controller)).isLoanBorrowingDisabled(
                SUBACCOUNT_TYPE_LOAN
            )
        );

        // the fee terms were configured by the setters after registration
        ILoanMarketsFacet.FeeTerms memory terms =
            ILoanMarketsFacet(address(controller)).getLoanFeeTerms(SUBACCOUNT_TYPE_LOAN);
        assertEq(terms.feeFloor, 0.07e18);
        assertEq(terms.feeSpread, 0.01e18);
        assertEq(terms.feeRecipient, makeAddr("feeCollector"));
    }

    function testBorrowRevertsUntilFeeTermsConfigured() public {
        // registration alone does not price the type: the recipient is the activation
        // marker, so a borrow reverts - retriable, never consumed - until the terms are
        // configured, and the exact same packet delivers afterwards
        _configureTransport();
        morpho.createMarket(_defaultMarket().marketParams);
        vm.prank(governance);
        IILoanMarketsFacet(address(controller)).registerLoanMarket(
            SUBACCOUNT_TYPE_LOAN, _defaultMarket()
        );
        ILoanMarketsFacet.FeeTerms memory terms =
            ILoanMarketsFacet(address(controller)).getLoanFeeTerms(SUBACCOUNT_TYPE_LOAN);
        assertEq(terms.feeFloor, 0);
        assertEq(terms.feeSpread, 0);
        assertEq(terms.feeRecipient, address(0));

        address subaccount = address(_deploySubaccount());
        fxrp.mint(subaccount, 100e6);
        address destination = makeAddr("exchangeDeposit");
        bytes memory payload = _borrowPayload(
            bytes32("op-1"), DESTINATION_KIND_EVM,
            bytes32(uint256(uint160(destination))), 500e18
        );
        _deliverExpectRevert(
            subaccount, 1, payload, ILoanSubaccountRemote.FeeTermsNotConfigured.selector
        );

        // rates first, the recipient last - its set is the activation
        vm.startPrank(governance);
        _setDefaultFeeTerms(address(controller), SUBACCOUNT_TYPE_LOAN);
        vm.stopPrank();
        _deliver(subaccount, 1, 100e6, payload);
        assertEq(rlusd.balanceOf(destination), 500e18);
    }

    function testSetLoanFeeRatesZeroIsDeliberateFeeOff() public {
        // explicit zero floor and spread are legal - with the recipient set, the type is
        // configured and "fee off" is a deliberate state, distinct from unconfigured
        _configureSettings();
        vm.startPrank(governance);
        IILoanMarketsFacet(address(controller)).setLoanFeeRates(SUBACCOUNT_TYPE_LOAN, 0, 0);
        vm.stopPrank();
        ILoanMarketsFacet.FeeTerms memory stored =
            ILoanMarketsFacet(address(controller)).getLoanFeeTerms(SUBACCOUNT_TYPE_LOAN);
        assertEq(stored.feeFloor, 0);
        assertEq(stored.feeSpread, 0);
        assertEq(stored.feeRecipient, makeAddr("feeCollector"));
    }

    function testSetLoanFeeRatesAndRecipient() public {
        _configureSettings();
        vm.startPrank(governance);

        // rates change without touching the recipient; the caps are inclusive
        vm.expectEmit();
        emit ILoanMarketsFacet.LoanFeeRatesSet(SUBACCOUNT_TYPE_LOAN, MAX_FEE_RATE, MAX_FEE_RATE);
        IILoanMarketsFacet(address(controller)).setLoanFeeRates(
            SUBACCOUNT_TYPE_LOAN, MAX_FEE_RATE, MAX_FEE_RATE
        );
        ILoanMarketsFacet.FeeTerms memory terms =
            ILoanMarketsFacet(address(controller)).getLoanFeeTerms(SUBACCOUNT_TYPE_LOAN);
        assertEq(terms.feeFloor, MAX_FEE_RATE);
        assertEq(terms.feeSpread, MAX_FEE_RATE);
        assertEq(terms.feeRecipient, makeAddr("feeCollector"));

        // the recipient rotates without touching the rates
        address newCollector = makeAddr("newCollector");
        vm.expectEmit();
        emit ILoanMarketsFacet.LoanFeeRecipientSet(SUBACCOUNT_TYPE_LOAN, newCollector);
        IILoanMarketsFacet(address(controller)).setLoanFeeRecipient(
            SUBACCOUNT_TYPE_LOAN, newCollector
        );
        terms = ILoanMarketsFacet(address(controller)).getLoanFeeTerms(SUBACCOUNT_TYPE_LOAN);
        assertEq(terms.feeFloor, MAX_FEE_RATE);
        assertEq(terms.feeSpread, MAX_FEE_RATE);
        assertEq(terms.feeRecipient, newCollector);
        vm.stopPrank();
    }

    function testSetLoanFeeRatesReverts() public {
        _configureSettings();
        vm.startPrank(governance);

        // both setters need a registered market: terms exist exactly as long as the type does
        vm.expectRevert(
            abi.encodeWithSelector(ILoanMarketsFacet.MarketNotRegistered.selector, 9)
        );
        IILoanMarketsFacet(address(controller)).setLoanFeeRates(9, 0, 0);
        vm.expectRevert(
            abi.encodeWithSelector(ILoanMarketsFacet.MarketNotRegistered.selector, 9)
        );
        IILoanMarketsFacet(address(controller)).setLoanFeeRecipient(9, makeAddr("collector"));

        vm.expectRevert(ILoanMarketsFacet.InvalidFeeTerms.selector);
        IILoanMarketsFacet(address(controller)).setLoanFeeRates(
            SUBACCOUNT_TYPE_LOAN, MAX_FEE_RATE + 1, 0
        );
        vm.expectRevert(ILoanMarketsFacet.InvalidFeeTerms.selector);
        IILoanMarketsFacet(address(controller)).setLoanFeeRates(
            SUBACCOUNT_TYPE_LOAN, 0, MAX_FEE_RATE + 1
        );
        vm.expectRevert(ILoanMarketsFacet.InvalidFeeRecipient.selector);
        IILoanMarketsFacet(address(controller)).setLoanFeeRecipient(
            SUBACCOUNT_TYPE_LOAN, address(0)
        );
        vm.stopPrank();
    }

    function testSettingsRevertNotOwner() public {
        address notOwner = makeAddr("notOwner");
        vm.startPrank(notOwner);
        vm.expectRevert(
            abi.encodeWithSelector(NotContractOwner.selector, notOwner, governance)
        );
        IIComposeTransportFacet(address(controller)).setComposeTransport(_defaultTransport());
        vm.expectRevert(
            abi.encodeWithSelector(NotContractOwner.selector, notOwner, governance)
        );
        IILoanMarketsFacet(address(controller)).registerLoanMarket(
            SUBACCOUNT_TYPE_LOAN, _defaultMarket()
        );
        vm.expectRevert(
            abi.encodeWithSelector(NotContractOwner.selector, notOwner, governance)
        );
        IILoanMarketsFacet(address(controller)).disableLoanBorrowing(
            SUBACCOUNT_TYPE_LOAN
        );
        vm.expectRevert(
            abi.encodeWithSelector(NotContractOwner.selector, notOwner, governance)
        );
        IILoanMarketsFacet(address(controller)).enableLoanBorrowing(
            SUBACCOUNT_TYPE_LOAN
        );
        vm.expectRevert(
            abi.encodeWithSelector(NotContractOwner.selector, notOwner, governance)
        );
        IILoanMarketsFacet(address(controller)).setLoanFeeRates(
            SUBACCOUNT_TYPE_LOAN, 0.07e18, 0.01e18
        );
        vm.expectRevert(
            abi.encodeWithSelector(NotContractOwner.selector, notOwner, governance)
        );
        IILoanMarketsFacet(address(controller)).setLoanFeeRecipient(
            SUBACCOUNT_TYPE_LOAN, makeAddr("feeCollector")
        );
        vm.expectRevert(
            abi.encodeWithSelector(NotContractOwner.selector, notOwner, governance)
        );
        IIComposeTransportFacet(address(controller)).clearComposeTransport();
        vm.stopPrank();
    }

    function testSetComposeTransportRevertInvalidValues() public {
        fxrpOft.setPeer(originEid, originPeer);
        IComposeTransportFacet.Transport memory transport;

        // the endpoint and the OFT must be contracts
        transport = _defaultTransport();
        transport.lzEndpoint = makeAddr("noCode");
        _setTransportExpectRevert(transport, IComposeTransportFacet.InvalidLzEndpoint.selector);

        transport = _defaultTransport();
        transport.oft = makeAddr("noCode");
        _setTransportExpectRevert(transport, IComposeTransportFacet.InvalidOft.selector);

        transport = _defaultTransport();
        transport.originEid = 0;
        _setTransportExpectRevert(transport, IComposeTransportFacet.InvalidOriginEid.selector);

        transport = _defaultTransport();
        transport.originPeer = bytes32(0);
        _setTransportExpectRevert(transport, IComposeTransportFacet.InvalidOriginPeer.selector);
    }

    function testRegisterLoanMarketRevertInvalidValues() public {
        _configureTransport();
        ILoanMarketsFacet.Market memory market;

        // Morpho must be a contract
        market = _defaultMarket();
        market.morpho = makeAddr("noCode");
        _registerMarketExpectRevert(market, ILoanMarketsFacet.InvalidMorpho.selector);

        // the market must name both tokens and a non-zero LLTV
        market = _defaultMarket();
        market.marketParams.loanToken = address(0);
        _registerMarketExpectRevert(
            market, ILoanMarketsFacet.InvalidMarketParams.selector
        );

        market = _defaultMarket();
        market.marketParams.collateralToken = address(0);
        _registerMarketExpectRevert(
            market, ILoanMarketsFacet.InvalidMarketParams.selector
        );

        market = _defaultMarket();
        market.marketParams.lltv = 0;
        _registerMarketExpectRevert(
            market, ILoanMarketsFacet.InvalidMarketParams.selector
        );

        // the reserved type 0 can never be bound
        vm.prank(governance);
        vm.expectRevert(ISubaccountsFacet.InvalidSubaccountType.selector);
        IILoanMarketsFacet(address(controller)).registerLoanMarket(
            0, _defaultMarket()
        );
    }

    function testRegisterLoanMarketRevertWithoutTransport() public {
        // the transport pins FXRP's identity, which the market's collateral must match:
        // markets cannot be registered before the transport is configured
        morpho.createMarket(_defaultMarket().marketParams);
        _registerMarketExpectRevert(
            _defaultMarket(),
            IComposeTransportFacet.ComposeTransportNotConfigured.selector
        );
    }

    function testRegisterLoanMarketRevertWrongCollateral() public {
        // the market's collateral token must be exactly the OFT's own token
        _configureTransport();
        MintableERC20 otherToken = new MintableERC20("Other", "OTH", 6);
        ILoanMarketsFacet.Market memory market = _defaultMarket();
        market.marketParams.collateralToken = address(otherToken);
        morpho.createMarket(market.marketParams);
        _registerMarketExpectRevert(market, ILoanMarketsFacet.InvalidMarketParams.selector);
    }

    function testSetComposeTransportRevertWrongSharedDecimals() public {
        // the bridge-back sweep sends with minAmountLD == amountLD, so shared-decimal dust
        // would make it revert; such an OFT must be rejected up front
        fxrpOft.setPeer(originEid, originPeer);
        fxrpOft.setSharedDecimals(4);
        _setTransportExpectRevert(
            _defaultTransport(), IComposeTransportFacet.InvalidOft.selector
        );
    }

    function testSetComposeTransportRevertWrongOftVersion() public {
        // the compose authentication depends on the canonical composeFrom encoding, so only
        // the canonical interface id and message-codec version 1 are accepted
        fxrpOft.setPeer(originEid, originPeer);

        fxrpOft.setOftVersion(0x02e49c2c, 2);
        _setTransportExpectRevert(
            _defaultTransport(), IComposeTransportFacet.InvalidOft.selector
        );

        fxrpOft.setOftVersion(0xdeadbeef, 1);
        _setTransportExpectRevert(
            _defaultTransport(), IComposeTransportFacet.InvalidOft.selector
        );

        fxrpOft.setOftVersion(0x02e49c2c, 1);
        _setTransport(_defaultTransport());
    }

    function testSetComposeTransportRevertPeerMismatch() public {
        // the live peer for the origin endpoint must be exactly the pinned remote OApp
        fxrpOft.setPeer(originEid, bytes32(uint256(0xbad)));
        _setTransportExpectRevert(
            _defaultTransport(), IComposeTransportFacet.InvalidOriginPeer.selector
        );
    }

    function testSetComposeTransportRevertWrongEndpointAssociation() public {
        // the OFT must be wired to the same endpoint that delivers lzCompose calls; a wrong
        // (or malicious) endpoint could fabricate every callback parameter
        fxrpOft.setPeer(originEid, originPeer);
        address otherEndpoint = makeAddr("otherEndpoint");
        vm.etch(otherEndpoint, hex"00");

        IComposeTransportFacet.Transport memory transport = _defaultTransport();
        transport.lzEndpoint = otherEndpoint;
        _setTransportExpectRevert(transport, IComposeTransportFacet.InvalidLzEndpoint.selector);
    }

    function testSetComposeTransportRevertDirtyOriginPeer() public {
        // the origin peer is an EVM address and must be cleanly zero-padded
        bytes32 dirtyPeer = bytes32(uint256(originPeer) | (uint256(1) << 200));
        fxrpOft.setPeer(originEid, dirtyPeer);

        IComposeTransportFacet.Transport memory transport = _defaultTransport();
        transport.originPeer = dirtyPeer;
        _setTransportExpectRevert(transport, IComposeTransportFacet.InvalidOriginPeer.selector);
    }

    function testSetComposeTransportRevertZeroFields() public {
        _configureSettings();

        // the setter never clears: an all-zero struct and a partially zero struct both fall
        // through to validation and revert, so a malformed set cannot silently wipe the
        // transport - clearing is its own immediate call
        IComposeTransportFacet.Transport memory zero;
        _setTransportExpectRevert(zero, IComposeTransportFacet.InvalidLzEndpoint.selector);
        IComposeTransportFacet.Transport memory partialZero;
        partialZero.originEid = 5;
        _setTransportExpectRevert(partialZero, IComposeTransportFacet.InvalidLzEndpoint.selector);

        // the configured transport is untouched
        assertEq(
            IComposeTransportFacet(address(controller))
                .getComposeTransport().lzEndpoint,
            lzEndpoint
        );
    }

    function testClearComposeTransport() public {
        _configureSettings();

        // the clear is immediate and disables the transport-dependent surface until a new
        // transport is set; the registered market and repayment persist
        vm.prank(governance);
        vm.expectEmit();
        emit IComposeTransportFacet.ComposeTransportCleared();
        IIComposeTransportFacet(address(controller)).clearComposeTransport();

        IComposeTransportFacet.Transport memory stored =
            IComposeTransportFacet(address(controller)).getComposeTransport();
        assertEq(stored.lzEndpoint, address(0));
        assertEq(stored.oft, address(0));
        assertEq(stored.originEid, 0);
        assertEq(stored.originPeer, bytes32(0));

        // the write-once market binding is not part of the transport and survives
        assertEq(
            ILoanMarketsFacet(address(controller))
                .getLoanMarket(SUBACCOUNT_TYPE_LOAN).morpho,
            address(morpho)
        );
    }

    function testSetComposeTransportEmits() public {
        fxrpOft.setPeer(originEid, originPeer);
        vm.prank(governance);
        vm.expectEmit();
        emit IComposeTransportFacet.ComposeTransportSet(
            lzEndpoint, address(fxrpOft), originEid, originPeer
        );
        IIComposeTransportFacet(address(controller)).setComposeTransport(_defaultTransport());
    }

    function testIncidentRunbookCancelsQueuedTransportSetBeforeClear() public {
        // the runbook under a live timelock: cancel every queued transport set, then clear
        // immediately. A cancelled set can never execute, so the cleared state holds
        _configureTransport();
        vm.prank(governance);
        controller.setTimelockDuration(1 days);

        IComposeTransportFacet.Transport memory transport = _defaultTransport();
        bytes memory queuedSet =
            abi.encodeCall(IIComposeTransportFacet.setComposeTransport, (transport));
        // with a live timelock the owner call records instead of executing
        vm.prank(governance);
        IIComposeTransportFacet(address(controller)).setComposeTransport(transport);
        assertEq(controller.getExecuteTimelockedCallTimestamp(queuedSet), vm.getBlockTimestamp() + 1 days);

        vm.startPrank(governance);
        controller.cancelTimelockedCall(queuedSet);
        // the clear needs no timelock and takes effect in the same call
        IIComposeTransportFacet(address(controller)).clearComposeTransport();
        vm.stopPrank();
        assertEq(IComposeTransportFacet(address(controller)).getComposeTransport().lzEndpoint, address(0));

        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.expectRevert(ITimelockFacet.TimelockInvalidSelector.selector);
        controller.executeTimelockedCall(queuedSet);
        assertEq(IComposeTransportFacet(address(controller)).getComposeTransport().lzEndpoint, address(0));
    }

    function testClearDoesNotRetireQueuedTransportSet() public {
        // why the runbook cancels first: the clear does not touch the timelock, so a set queued
        // before it matures on schedule and anyone can execute it, restoring the route
        _configureTransport();
        vm.prank(governance);
        controller.setTimelockDuration(1 days);

        IComposeTransportFacet.Transport memory transport = _defaultTransport();
        bytes memory queuedSet =
            abi.encodeCall(IIComposeTransportFacet.setComposeTransport, (transport));
        vm.startPrank(governance);
        IIComposeTransportFacet(address(controller)).setComposeTransport(transport);
        IIComposeTransportFacet(address(controller)).clearComposeTransport();
        vm.stopPrank();
        assertEq(IComposeTransportFacet(address(controller)).getComposeTransport().lzEndpoint, address(0));

        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.prank(makeAddr("anyone"));
        controller.executeTimelockedCall(queuedSet);
        assertEq(IComposeTransportFacet(address(controller)).getComposeTransport().lzEndpoint, lzEndpoint);
    }

    function testRegisterLoanMarketIsWriteOnce() public {
        _configureSettings();

        // the binding is permanent: a different market means a new subaccount type
        ILoanMarketsFacet.Market memory other = _defaultMarket();
        other.marketParams.lltv = 0.5e18;
        morpho.createMarket(other.marketParams);
        vm.prank(governance);
        vm.expectRevert(
            abi.encodeWithSelector(
                ILoanMarketsFacet.MarketAlreadyRegistered.selector,
                SUBACCOUNT_TYPE_LOAN
            )
        );
        IILoanMarketsFacet(address(controller)).registerLoanMarket(
            SUBACCOUNT_TYPE_LOAN, other
        );
    }

    function testBorrowSwitchRequiresRegisteredMarket() public {
        vm.startPrank(governance);
        vm.expectRevert(
            abi.encodeWithSelector(
                ILoanMarketsFacet.MarketNotRegistered.selector, SUBACCOUNT_TYPE_LOAN
            )
        );
        IILoanMarketsFacet(address(controller)).disableLoanBorrowing(
            SUBACCOUNT_TYPE_LOAN
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                ILoanMarketsFacet.MarketNotRegistered.selector, SUBACCOUNT_TYPE_LOAN
            )
        );
        IILoanMarketsFacet(address(controller)).enableLoanBorrowing(
            SUBACCOUNT_TYPE_LOAN
        );
        vm.stopPrank();
    }

    function testSetComposeTransportRevertDifferentTokenAfterMarket() public {
        // once a market is bound, the collateral token is pinned: a replacement transport
        // wrapping a different token would strand the permanent binding and is rejected
        _configureSettings();
        MintableERC20 otherToken = new MintableERC20("Other", "OTH", 6);
        IComposeTransportFacet.Transport memory transport = _defaultTransport();
        transport.oft = address(_wiredOft(otherToken));
        _setTransportExpectRevert(transport, IComposeTransportFacet.InvalidOft.selector);
    }

    function testSetComposeTransportAllowsAdapterRotation() public {
        // the pin freezes the token, not the adapter: a new OFT wrapping the same token passes
        _configureSettings();
        IComposeTransportFacet.Transport memory transport = _defaultTransport();
        transport.oft = address(_wiredOft(fxrp));
        _setTransport(transport);
        assertEq(
            IComposeTransportFacet(address(controller)).getComposeTransport().oft,
            transport.oft
        );
    }

    function testTransportClearAndRestoreKeepsCollateralPin() public {
        // the pin is not transport state: it survives a clear, still rejects a wrong-token
        // transport, and the original same-token transport restores cleanly (a benign clear;
        // after an authentication-root compromise the tuple is rotated, never restored)
        _configureSettings();
        vm.prank(governance);
        IIComposeTransportFacet(address(controller)).clearComposeTransport();

        MintableERC20 otherToken = new MintableERC20("Other", "OTH", 6);
        IComposeTransportFacet.Transport memory wrongToken = _defaultTransport();
        wrongToken.oft = address(_wiredOft(otherToken));
        _setTransportExpectRevert(wrongToken, IComposeTransportFacet.InvalidOft.selector);

        _setTransport(_defaultTransport());
        assertEq(
            IComposeTransportFacet(address(controller)).getComposeTransport().oft,
            address(fxrpOft)
        );
    }

    function testRegisterSecondTypeRequiresPinnedCollateral() public {
        // with the pin set by the first registration, a second type cannot bind a market on
        // a different collateral token (rejected against the pinned transport's OFT)
        _configureSettings();
        MintableERC20 otherToken = new MintableERC20("Other", "OTH", 6);
        ILoanMarketsFacet.Market memory market = _defaultMarket();
        market.marketParams.collateralToken = address(otherToken);
        morpho.createMarket(market.marketParams);
        vm.prank(governance);
        vm.expectRevert(ILoanMarketsFacet.InvalidMarketParams.selector);
        IILoanMarketsFacet(address(controller)).registerLoanMarket(2, market);
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
        emit ILoanSubaccountRemote.LoanOpened(
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
        (, uint128 borrowShares, uint128 collateral) = morpho.position(_marketId(), subaccount);
        assertEq(collateral, 100e6);
        // first borrow: shares = assets scaled by the virtual-share offset
        assertEq(borrowShares, 500e18 * 1e6);
        assertEq(fxrp.balanceOf(subaccount), 5e6);
        assertEq(rlusd.balanceOf(destination), 500e18);
        assertTrue(ILoanSubaccountRemote(subaccount).usedOperations(operationId));
    }

    function testLzComposeDepositCollateral() public {
        address subaccount = _createConfiguredSubaccount();
        fxrp.mint(subaccount, 100e6);

        // the deposit action supplies exactly the authenticated bridged amount, no debt
        vm.expectEmit();
        emit ILoanSubaccountRemote.CollateralDeposited(
            parentPersonalAccount, bytes32("op-1"), 100e6, _guidFor(1)
        );
        _deliver(subaccount, 1, 100e6, _depositPayload(bytes32("op-1")));

        (, uint128 borrowShares, uint128 collateral) = morpho.position(_marketId(), subaccount);
        assertEq(collateral, 100e6);
        assertEq(borrowShares, 0);

        // a deposit that brings nothing is malformed, not a skip
        _deliverExpectRevertZeroAmount(
            subaccount, 2, _depositPayload(bytes32("op-2")), ILoanSubaccountRemote.ZeroAmount.selector
        );
    }

    function testLzComposeBorrowAgainstExistingCollateral() public {
        address subaccount = _createConfiguredSubaccount();
        fxrp.mint(subaccount, 100e6);
        _deliver(subaccount, 1, 100e6, _depositPayload(bytes32("op-1")));

        // a zero bridged amount with a non-zero borrow draws against the existing position
        address destination = makeAddr("exchangeDeposit");
        _deliver(subaccount, 2, 0, _borrowPayload(
            bytes32("op-2"), DESTINATION_KIND_EVM, bytes32(uint256(uint160(destination))), 300e18
        ));

        (, uint128 borrowShares, ) = morpho.position(_marketId(), subaccount);
        assertEq(borrowShares, 300e18 * 1e6);
        assertEq(rlusd.balanceOf(destination), 300e18);
    }

    function testLzComposeWithdrawBridgesCollateralHome() public {
        address subaccount = _createConfiguredSubaccount();
        fxrp.mint(subaccount, 100e6);
        _deliver(subaccount, 1, 100e6, _depositPayload(bytes32("op-1")));

        bytes32 operationId = bytes32("op-2");
        vm.expectEmit();
        emit ILoanSubaccountRemote.CollateralWithdrawn(
            parentPersonalAccount, operationId, 30e6, _guidFor(2)
        );
        _deliverWithValue(subaccount, 2, 0, _withdrawPayload(operationId, 30e6), 0.01 ether);

        // withdrawn and bridged home in the same execution: no idle window a redeposit
        // could touch
        (, , uint128 collateral) = morpho.position(_marketId(), subaccount);
        assertEq(collateral, 70e6);
        assertEq(fxrp.balanceOf(subaccount), 0);

        // the return send: exactly the withdrawn amount, the redeem-home compose, and the
        // signed return options
        (, , uint256 amountLD, , bytes memory optionsSent, bytes memory composeMsgSent, ) =
            fxrpOft.lastSendParam();
        assertEq(amountLD, 30e6);
        assertEq(optionsSent, RETURN_OPTIONS);
        assertEq(
            composeMsgSent,
            abi.encode(
                PAYLOAD_VERSION_1,
                ACTION_REDEEM_HOME,
                abi.encode(uint64(block.timestamp) + REDEEM_HOME_TTL)
            )
        );
    }

    function testLzComposeWithdrawRevertInsufficientReturnFee() public {
        // too little compose value for the return leg reverts the whole action - nothing is
        // withdrawn, the id stays unconsumed, and the delivery stays retriable (quotes drift)
        address subaccount = _createConfiguredSubaccount();
        fxrp.mint(subaccount, 100e6);
        _deliver(subaccount, 1, 100e6, _depositPayload(bytes32("op-1")));

        bytes32 operationId = bytes32("op-2");
        (bytes memory message, bytes32 guid) = _composeMessage(
            subaccount, 2, 0, _withdrawPayloadWithMin(operationId, 30e6, 0.0005 ether)
        );
        vm.deal(lzEndpoint, 0.001 ether);
        vm.prank(lzEndpoint);
        vm.expectRevert(
            abi.encodeWithSelector(
                ILoanSubaccountRemote.InsufficientFundsForSweep.selector, 0.01 ether
            )
        );
        ILoanSubaccountRemote(subaccount).lzCompose{value: 0.001 ether}(
            address(fxrpOft), guid, message, executor, ""
        );
        (, , uint128 collateral) = morpho.position(_marketId(), subaccount);
        assertEq(collateral, 100e6);
        assertFalse(ILoanSubaccountRemote(subaccount).usedOperations(operationId));
    }

    function testLzComposeWithdrawForwardsExcessToTheMirror() public {
        // the operator quotes the return leg generously and signs the whole prepayment as the
        // floor: a delivery covering only the live quote still reverts on the floor, and the
        // full delivery's excess lands on the mirror (the user's own account) - never on this
        // account (no native rail) and never with the executor
        address subaccount = _createConfiguredSubaccount();
        fxrp.mint(subaccount, 100e6);
        _deliver(subaccount, 1, 100e6, _depositPayload(bytes32("op-1")));

        bytes memory payload = _withdrawPayloadWithMin(bytes32("op-2"), 30e6, 0.05 ether);
        (bytes memory message, bytes32 guid) = _composeMessage(subaccount, 2, 0, payload);
        vm.deal(lzEndpoint, 0.01 ether);
        vm.prank(lzEndpoint);
        vm.expectRevert(
            abi.encodeWithSelector(
                ILoanSubaccountRemote.InsufficientDeliveryValue.selector, 0.05 ether
            )
        );
        ILoanSubaccountRemote(subaccount).lzCompose{value: 0.01 ether}(
            address(fxrpOft), guid, message, executor, ""
        );

        vm.expectEmit();
        emit ILoanSubaccountRemote.NativeSweptToParent(parentPersonalAccount, 0.04 ether);
        _deliverWithValue(subaccount, 2, 0, payload, 0.05 ether);
        assertEq(parentPersonalAccount.balance, 0.04 ether);
        assertEq(subaccount.balance, 0);
    }

    function testWithdrawDeliveryBelowSignedFloorReverts() public {
        // delivery is permissionless and the delivered value unauthenticated: below the
        // signed floor nothing consumes the packet - not execution, and not a terminal skip
        // (a zero-value front-run of a doomed packet must not burn the prepaid value)
        address subaccount = _createConfiguredSubaccount();
        fxrp.mint(subaccount, 100e6);
        _deliver(subaccount, 1, 100e6, _depositPayload(bytes32("op-1")));

        // execution path: a zero-value delivery reverts and stays retriable
        (bytes memory message, bytes32 guid) =
            _composeMessage(subaccount, 2, 0, _withdrawPayload(bytes32("op-2"), 30e6));
        vm.prank(lzEndpoint);
        vm.expectRevert(
            abi.encodeWithSelector(
                ILoanSubaccountRemote.InsufficientDeliveryValue.selector, RETURN_MIN_VALUE
            )
        );
        ILoanSubaccountRemote(subaccount).lzCompose(address(fxrpOft), guid, message, executor, "");
        assertFalse(ILoanSubaccountRemote(subaccount).usedOperations(bytes32("op-2")));

        // skip path: a zero-value delivery of a duplicate reverts the same way instead of
        // consuming the packet with the prepaid value undelivered
        bytes memory dupPayload = _withdrawPayload(bytes32("op-1"), 30e6);
        (message, guid) = _composeMessage(subaccount, 3, 0, dupPayload);
        vm.prank(lzEndpoint);
        vm.expectRevert(
            abi.encodeWithSelector(
                ILoanSubaccountRemote.InsufficientDeliveryValue.selector, RETURN_MIN_VALUE
            )
        );
        ILoanSubaccountRemote(subaccount).lzCompose(address(fxrpOft), guid, message, executor, "");

        // the same packet delivered at the floor terminal-skips and forwards the value
        vm.expectEmit();
        emit ILoanSubaccountRemote.LoanActionSkipped(
            parentPersonalAccount, bytes32("op-1"), SKIP_REASON_DUPLICATE, _guidFor(3)
        );
        _deliverWithValue(subaccount, 3, 0, dupPayload, RETURN_MIN_VALUE);
        assertEq(parentPersonalAccount.balance, RETURN_MIN_VALUE);
    }

    function testLzComposeRevertNonZeroComposeValue() public {
        address subaccount = _createConfiguredSubaccount();
        fxrp.mint(subaccount, 100e6);
        (bytes memory message, bytes32 guid) =
            _composeMessage(subaccount, 1, 100e6, _depositPayload(bytes32("op-1")));

        vm.deal(lzEndpoint, 1 ether);
        vm.prank(lzEndpoint);
        vm.expectRevert(IComposeReceiverAccountBase.NonZeroComposeValue.selector);
        ILoanSubaccountRemote(subaccount).lzCompose{value: 1}(
            address(fxrpOft), guid, message, executor, ""
        );
    }

    function testLzComposeRevertOnlyEndpoint() public {
        address subaccount = _createConfiguredSubaccount();
        (bytes memory message, bytes32 guid) =
            _composeMessage(subaccount, 1, 100e6, _depositPayload(bytes32("op-1")));

        vm.prank(makeAddr("notTheEndpoint"));
        vm.expectRevert(IComposeReceiverAccountBase.OnlyEndpoint.selector);
        ILoanSubaccountRemote(subaccount).lzCompose(address(fxrpOft), guid, message, executor, "");
    }

    function testLzComposeRevertWrongComposeSender() public {
        address subaccount = _createConfiguredSubaccount();
        (bytes memory message, bytes32 guid) =
            _composeMessage(subaccount, 1, 100e6, _depositPayload(bytes32("op-1")));

        address notTheOft = makeAddr("notTheOft");
        vm.prank(lzEndpoint);
        vm.expectRevert(
            abi.encodeWithSelector(IComposeReceiverAccountBase.WrongComposeSender.selector, notTheOft)
        );
        ILoanSubaccountRemote(subaccount).lzCompose(notTheOft, guid, message, executor, "");
    }

    function testLzComposeRevertWrongSourceEid() public {
        address subaccount = _createConfiguredSubaccount();
        bytes memory message = OFTComposeMsgCodec.encode(
            1,
            originEid + 1,
            100e6,
            abi.encodePacked(
                bytes32(uint256(uint160(subaccount))),
                _depositPayload(bytes32("op-1"))
            )
        );

        vm.prank(lzEndpoint);
        vm.expectRevert(
            abi.encodeWithSelector(IComposeReceiverAccountBase.WrongSourceEid.selector, originEid + 1)
        );
        ILoanSubaccountRemote(subaccount).lzCompose(
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
            abi.encodePacked(attacker, _depositPayload(bytes32("op-1")))
        );

        vm.prank(lzEndpoint);
        vm.expectRevert(
            abi.encodeWithSelector(IComposeReceiverAccountBase.WrongComposeFrom.selector, attacker)
        );
        ILoanSubaccountRemote(subaccount).lzCompose(
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
            _composeMessage(subaccount, 1, 100e6, _depositPayload(bytes32("op-1")));
        bytes32 forgedGuid = GUID.generate(
            1, originEid, makeAddr("maliciousPeer"), dstEid,
            bytes32(uint256(uint160(address(fxrpOft))))
        );

        vm.prank(lzEndpoint);
        vm.expectRevert(
            abi.encodeWithSelector(IComposeReceiverAccountBase.WrongGuid.selector, forgedGuid)
        );
        ILoanSubaccountRemote(subaccount).lzCompose(
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
        ILoanSubaccountRemote(subaccount).lzCompose(address(fxrpOft), guid, message, executor, "");

        // the compose stays queued at the endpoint; the same delivery succeeds after unpausing
        _unpauseController();
        vm.prank(lzEndpoint);
        ILoanSubaccountRemote(subaccount).lzCompose(address(fxrpOft), guid, message, executor, "");
        (, , uint128 collateral) = morpho.position(_marketId(), subaccount);
        assertEq(collateral, 100e6);
    }

    function testLzComposeDepositWorksWhilePaused() public {
        // a collateral deposit into the indebted position moves it toward safety, like
        // repayment: it must stay available during an incident so the position can be
        // defended against liquidation
        address subaccount = _borrowedSubaccount(500e18);
        fxrp.mint(subaccount, 50e6);
        _pauseController();

        _deliver(subaccount, 2, 50e6, _depositPayload(bytes32("op-2")));
        (, , uint128 collateral) = morpho.position(_marketId(), subaccount);
        assertEq(collateral, 150e6);
    }

    function testDepositIdleFxrpDefendsIndebtedPositionWhilePaused() public {
        // the defensive case of the idle rail survives a pause: already-arrived collateral
        // can still protect the indebted position; the debt-free case stays gated
        address subaccount = _borrowedSubaccount(500e18);
        fxrp.mint(subaccount, 30e6);
        _pauseController();

        ILoanSubaccountRemote(subaccount).depositIdleFxrp();
        (, , uint128 collateral) = morpho.position(_marketId(), subaccount);
        assertEq(collateral, 130e6);

        // once the debt is gone, a paused deposit is new exposure and reverts
        rlusd.mint(subaccount, 600e18);
        ILoanSubaccountRemote(subaccount).repay();
        fxrp.mint(subaccount, 10e6);
        vm.expectRevert(IPauseFacet.IsPaused.selector);
        ILoanSubaccountRemote(subaccount).depositIdleFxrp();
    }

    function testLzComposeDepositWhilePausedRequiresLiveDebt() public {
        // a paused composed deposit is allowed only when the position carries live debt; a
        // debt-free deposit is new exposure and waits out the pause
        address subaccount = _createConfiguredSubaccount();
        fxrp.mint(subaccount, 100e6);
        _pauseController();

        _deliverExpectRevert(
            subaccount, 1, _depositPayload(bytes32("op-1")),
            IPauseFacet.IsPaused.selector
        );
    }

    function testExternalLiquidationTurnsBalanceIntoSurplus() public {
        // debt is read live from Morpho on every check - nothing is cached, so an external
        // liquidation is visible to the very next call: the position is closed, repay has
        // nothing to repay, and the whole balance leaves as surplus
        address subaccount = _borrowedSubaccount(500e18);
        morpho.simulateLiquidation(_marketId(), subaccount);
        rlusd.mint(subaccount, 100e18);

        vm.expectEmit();
        emit ILoanSubaccountRemote.LoanSurplusRecovered(parentPersonalAccount, 100e18);
        assertEq(ILoanSubaccountRemote(subaccount).repay(), 0);
        assertEq(rlusd.balanceOf(parentPersonalAccount), 100e18);
        assertEq(rlusd.balanceOf(subaccount), 0);
    }

    function testPartialLiquidationKeepsCanonicalAccounting() public {
        // a partial liquidation leaves live borrow shares, seizes proportional collateral,
        // and shrinks the market totals by the assets the repaid shares represent, so later
        // conversions stay canonical
        address subaccount = _borrowedSubaccount(500e18);
        (, uint128 borrowShares, ) = morpho.position(_marketId(), subaccount);
        uint128 liquidated = borrowShares / 2;
        morpho.simulatePartialLiquidation(_marketId(), subaccount, liquidated);

        (, uint128 remainingShares, uint128 collateral) =
            morpho.position(_marketId(), subaccount);
        assertEq(remainingShares, borrowShares - liquidated);
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
        ILoanSubaccountRemote(subaccount).repay();
        (, uint128 finalShares, ) = morpho.position(_marketId(), subaccount);
        assertEq(finalShares, 0);
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
    }

    function testSimulateLiquidationRevertsOnDebtFreePosition() public {
        // real Morpho cannot liquidate a debt-free position: the mock must not silently
        // delete collateral-only positions
        address subaccount = _createConfiguredSubaccount();
        fxrp.mint(subaccount, 100e6);
        _deliver(subaccount, 1, 100e6, _depositPayload(bytes32("op-1")));

        vm.expectRevert(bytes("no debt to liquidate"));
        morpho.simulateLiquidation(_marketId(), subaccount);
    }

    function testLzComposeRevertTransportNotConfigured() public {
        address subaccount = _createConfiguredSubaccount();
        (bytes memory message, bytes32 guid) =
            _composeMessage(subaccount, 1, 100e6, _depositPayload(bytes32("op-1")));
        vm.prank(governance);
        IIComposeTransportFacet(address(controller)).clearComposeTransport();

        vm.prank(lzEndpoint);
        vm.expectRevert(
            IComposeTransportFacet.ComposeTransportNotConfigured.selector
        );
        ILoanSubaccountRemote(subaccount).lzCompose(address(fxrpOft), guid, message, executor, "");
    }

    function testLzComposeRevertUnsupportedPayloadShapes() public {
        address subaccount = _createConfiguredSubaccount();
        fxrp.mint(subaccount, 100e6);

        // unsupported schema version
        bytes memory payload = abi.encode(uint8(2), ACTION_BORROW, bytes(""));
        _deliverExpectRevert(
            subaccount, 1, payload,
            abi.encodeWithSelector(IComposeReceiverAccountBase.UnsupportedPayloadVersion.selector, 2)
        );

        // unsupported action
        payload = abi.encode(PAYLOAD_VERSION_1, uint8(9), bytes(""));
        _deliverExpectRevert(
            subaccount, 1, payload,
            abi.encodeWithSelector(IComposeReceiverAccountBase.UnsupportedAction.selector, 9)
        );

        // the reserved Wormhole destination kind
        payload = _borrowPayload(
            bytes32("op-1"), DESTINATION_KIND_XRPL_WORMHOLE, bytes32(uint256(1)), 500e18
        );
        _deliverExpectRevert(
            subaccount, 1, payload,
            abi.encodeWithSelector(
                ILoanSubaccountRemote.UnsupportedDestinationKind.selector,
                DESTINATION_KIND_XRPL_WORMHOLE
            )
        );

        // a zero destination, and a destination with dirty upper bits
        payload = _borrowPayload(bytes32("op-1"), DESTINATION_KIND_EVM, bytes32(0), 500e18);
        _deliverExpectRevert(
            subaccount, 1, payload, ILoanSubaccountRemote.InvalidDestination.selector
        );
        bytes32 dirty = bytes32(uint256(uint160(makeAddr("dest"))) | (uint256(1) << 200));
        payload = _borrowPayload(bytes32("op-1"), DESTINATION_KIND_EVM, dirty, 500e18);
        _deliverExpectRevert(
            subaccount, 1, payload, ILoanSubaccountRemote.InvalidDestination.selector
        );

        // disbursing to the account itself only opens debt its own proceeds must repay (the
        // parent Personal Account, by contrast, is a valid target - see the dedicated test)
        payload = _borrowPayload(
            bytes32("op-1"), DESTINATION_KIND_EVM, bytes32(uint256(uint160(subaccount))), 500e18
        );
        _deliverExpectRevert(
            subaccount, 1, payload, ILoanSubaccountRemote.InvalidDestination.selector
        );

        // a borrow with nothing to borrow is malformed even with collateral attached: a pure
        // deposit is its own action
        payload = _borrowPayload(bytes32("op-1"), DESTINATION_KIND_EVM, bytes32(uint256(1)), 0);
        _deliverExpectRevert(subaccount, 1, payload, ILoanSubaccountRemote.ZeroAmount.selector);
    }

    function testLzComposeSkipDuplicateOperation() public {
        address subaccount = _createConfiguredSubaccount();
        bytes32 operationId = bytes32("op-1");
        fxrp.mint(subaccount, 100e6);
        _deliver(subaccount, 1, 100e6, _depositPayload(operationId));

        // a retried instruction delivered twice must not double-execute; the second delivery
        // completes without effect and its bridged FXRP stays on the account
        fxrp.mint(subaccount, 100e6);
        vm.expectEmit();
        emit ILoanSubaccountRemote.LoanActionSkipped(
            parentPersonalAccount, operationId, SKIP_REASON_DUPLICATE, _guidFor(2)
        );
        _deliver(subaccount, 2, 100e6, _depositPayload(operationId));

        (, , uint128 collateral) = morpho.position(_marketId(), subaccount);
        assertEq(collateral, 100e6);
        assertEq(fxrp.balanceOf(subaccount), 100e6);
    }

    function testWithdrawSkipDuplicateOperation() public {
        // the duplicate terminal gate finalizes every action kind, not just borrows: a
        // consumed operation id skips a withdraw without any effect
        address subaccount = _createConfiguredSubaccount();
        bytes32 operationId = bytes32("op-1");
        fxrp.mint(subaccount, 100e6);
        _deliver(subaccount, 1, 100e6, _depositPayload(operationId));

        vm.expectEmit();
        emit ILoanSubaccountRemote.LoanActionSkipped(
            parentPersonalAccount, operationId, SKIP_REASON_DUPLICATE, _guidFor(2)
        );
        vm.expectEmit();
        emit ILoanSubaccountRemote.NativeSweptToParent(parentPersonalAccount, 0.01 ether);
        _deliverWithValue(subaccount, 2, 0, _withdrawPayload(operationId, 30e6), 0.01 ether);
        (, , uint128 collateral) = morpho.position(_marketId(), subaccount);
        assertEq(collateral, 100e6);
        // the skipped delivery's value went to the mirror, not stranding here
        assertEq(parentPersonalAccount.balance, 0.01 ether);
        assertEq(subaccount.balance, 0);
    }

    function testLzComposeSkipExpiredDeadlineWithoutConsumingTheOperation() public {
        address subaccount = _createConfiguredSubaccount();
        bytes32 operationId = bytes32("op-1");
        fxrp.mint(subaccount, 100e6);

        bytes memory stale = abi.encode(
            PAYLOAD_VERSION_1,
            ACTION_DEPOSIT_COLLATERAL,
            abi.encode(operationId, uint64(block.timestamp - 1))
        );
        vm.expectEmit();
        emit ILoanSubaccountRemote.LoanActionSkipped(
            parentPersonalAccount, operationId, SKIP_REASON_EXPIRED, _guidFor(1)
        );
        _deliver(subaccount, 1, 100e6, stale);
        assertFalse(ILoanSubaccountRemote(subaccount).usedOperations(operationId));

        // the same intent retries under the same operation id with a fresh deadline; the
        // retry is a real second packet, crediting its own amount - the first packet's stale
        // credit stays idle on the account for the fixed rails
        fxrp.mint(subaccount, 100e6);
        _deliver(subaccount, 2, 100e6, _depositPayload(operationId));
        (, , uint128 collateral) = morpho.position(_marketId(), subaccount);
        assertEq(collateral, 100e6);
        assertEq(fxrp.balanceOf(subaccount), 100e6);
        assertTrue(ILoanSubaccountRemote(subaccount).usedOperations(operationId));
    }

    function testLzComposeExecutesAtDeadlineBoundary() public {
        // the deadline is inclusive: an instruction delivered in the block whose time equals
        // its deadline executes, only a later block skips it - and the source-side pre-flight
        // accepts the same boundary, so a send it lets through is never a guaranteed skip
        address subaccount = _borrowedSubaccount(0);
        bytes memory payload = abi.encode(
            PAYLOAD_VERSION_1,
            ACTION_WITHDRAW,
            abi.encode(
                bytes32("op-w"), uint64(block.timestamp), uint256(40e6), RETURN_MIN_VALUE,
                RETURN_OPTIONS
            )
        );
        _deliverWithValue(subaccount, 2, 0, payload, 0.01 ether);
        (, , uint128 collateral) = morpho.position(_marketId(), subaccount);
        assertEq(collateral, 60e6);
        assertEq(fxrp.balanceOf(subaccount), 0);
        assertTrue(ILoanSubaccountRemote(subaccount).usedOperations(bytes32("op-w")));
    }

    function testLzComposeBorrowRevertBorrowingDisabled() public {
        // the borrow switch sunsets a pool: a debt increase reverts (retriable - a reversible
        // policy must not consume the packet); deposits, repayment and withdrawals still work
        address subaccount = _borrowedSubaccount(500e18);
        vm.prank(governance);
        vm.expectEmit();
        emit ILoanMarketsFacet.LoanBorrowingDisabled(SUBACCOUNT_TYPE_LOAN);
        IILoanMarketsFacet(address(controller)).disableLoanBorrowing(
            SUBACCOUNT_TYPE_LOAN
        );

        fxrp.mint(subaccount, 100e6);
        bytes memory borrowMore = _borrowPayload(
            bytes32("op-2"), DESTINATION_KIND_EVM,
            bytes32(uint256(uint160(makeAddr("dest")))), 100e18
        );
        _deliverExpectRevert(
            subaccount, 2, borrowMore, ILoanSubaccountRemote.BorrowingDisabled.selector
        );

        // a collateral deposit is not a debt increase and still works (a real second packet,
        // crediting its own amount; packet 2's credit stays idle for its later retry)
        fxrp.mint(subaccount, 100e6);
        _deliver(subaccount, 3, 100e6, _depositPayload(bytes32("op-3")));
        (, , uint128 collateral) = morpho.position(_marketId(), subaccount);
        assertEq(collateral, 200e6);

        // re-enabling makes the exact same packet deliverable again
        vm.prank(governance);
        vm.expectEmit();
        emit ILoanMarketsFacet.LoanBorrowingEnabled(SUBACCOUNT_TYPE_LOAN);
        IILoanMarketsFacet(address(controller)).enableLoanBorrowing(
            SUBACCOUNT_TYPE_LOAN
        );
        _deliver(subaccount, 2, 100e6, borrowMore);
        assertEq(rlusd.balanceOf(makeAddr("dest")), 100e18);
    }

    function testDuplicateFinalizesWhileBorrowingDisabled() public {
        // terminal gates run before the borrow switch: a duplicate delivery finalizes
        // without effect instead of reverting forever on a sunset pool
        address subaccount = _borrowedSubaccount(500e18);
        vm.prank(governance);
        IILoanMarketsFacet(address(controller)).disableLoanBorrowing(
            SUBACCOUNT_TYPE_LOAN
        );

        fxrp.mint(subaccount, 100e6);
        vm.expectEmit();
        emit ILoanSubaccountRemote.LoanActionSkipped(
            parentPersonalAccount, bytes32("op-borrow"), SKIP_REASON_DUPLICATE, _guidFor(9)
        );
        _deliver(subaccount, 9, 100e6, _borrowPayload(
            bytes32("op-borrow"), DESTINATION_KIND_EVM,
            bytes32(uint256(uint160(makeAddr("exchangeDeposit")))), 500e18
        ));
    }

    function testBorrowingDisabledLeavesExitsOpen() public {
        // the switch stops exactly one thing - new debt; every exit stays open on the sunset
        // pool: composed withdrawal, repayment, and recovery of the surplus
        address subaccount = _borrowedSubaccount(500e18);
        vm.prank(governance);
        IILoanMarketsFacet(address(controller)).disableLoanBorrowing(
            SUBACCOUNT_TYPE_LOAN
        );

        _deliverWithValue(subaccount, 2, 0, _withdrawPayload(bytes32("op-w"), 30e6), 0.01 ether);
        (, , uint128 collateral) = morpho.position(_marketId(), subaccount);
        assertEq(collateral, 70e6);

        rlusd.mint(subaccount, 600e18);
        assertEq(ILoanSubaccountRemote(subaccount).repay(), 500e18);
        // the surplus left with the same call
        assertEq(rlusd.balanceOf(parentPersonalAccount), 100e18);
    }

    function testBorrowDisbursesToParent() public {
        // the parent Personal Account is the user's own compose-driven account on this
        // chain, so disbursing into it is a legitimate destination - the proceeds then leave
        // it only by the user's signed transfer
        address subaccount = _createConfiguredSubaccount();
        fxrp.mint(subaccount, 100e6);
        _deliver(subaccount, 1, 100e6, _borrowPayload(
            bytes32("op-1"), DESTINATION_KIND_EVM,
            bytes32(uint256(uint160(parentPersonalAccount))), 500e18
        ));
        assertEq(rlusd.balanceOf(parentPersonalAccount), 500e18);
    }

    function testBorrowingDisabledIsPerType() public {
        // the switch isolates per type: sunsetting one pool leaves another borrowing
        _configureSettings();
        uint256 typeB = 2;
        ILoanMarketsFacet.Market memory marketB = _defaultMarket();
        marketB.marketParams.lltv = 0.5e18;
        morpho.createMarket(marketB.marketParams);
        vm.startPrank(governance);
        controller.setSubaccountImplementation(typeB, address(loanChainImpl));
        IILoanMarketsFacet(address(controller)).registerLoanMarket(
            typeB, marketB
        );
        _setDefaultFeeTerms(address(controller), typeB);
        IILoanMarketsFacet(address(controller)).disableLoanBorrowing(
            SUBACCOUNT_TYPE_LOAN
        );
        vm.stopPrank();

        address subaccountA = address(_deploySubaccount());
        fxrp.mint(subaccountA, 100e6);
        _deliverExpectRevert(
            subaccountA, 1,
            _borrowPayload(
                bytes32("op-a"), DESTINATION_KIND_EVM,
                bytes32(uint256(uint160(makeAddr("destA")))), 100e18
            ),
            ILoanSubaccountRemote.BorrowingDisabled.selector
        );

        address subaccountB = address(new SubaccountProxy(
            address(controller), parentPersonalAccount, typeB
        ));
        fxrp.mint(subaccountB, 100e6);
        _deliver(subaccountB, 2, 100e6, _borrowPayload(
            bytes32("op-b"), DESTINATION_KIND_EVM,
            bytes32(uint256(uint160(makeAddr("destB")))), 100e18
        ));
        assertEq(rlusd.balanceOf(makeAddr("destB")), 100e18);
    }

    function testLzComposeRevertInvalidOperationId() public {
        address subaccount = _createConfiguredSubaccount();
        fxrp.mint(subaccount, 100e6);

        _deliverExpectRevert(
            subaccount, 1, _depositPayload(bytes32(0)),
            IComposeReceiverAccountBase.InvalidOperationId.selector
        );
    }

    function testLzComposeRevertInsufficientComposeBalance() public {
        // the credited tokens were moved before the compose executed (the documented race):
        // the action fails closed instead of consuming unrelated idle balance
        address subaccount = _createConfiguredSubaccount();
        fxrp.mint(subaccount, 40e6);

        _deliverExpectRevert(
            subaccount, 1, _depositPayload(bytes32("op-1")),
            abi.encodeWithSelector(
                ILoanSubaccountRemote.InsufficientComposeBalance.selector, 100e6, 40e6
            )
        );
    }

    function testCreateSubaccountWithoutPersonalAccount() public {
        // the generic creation route works on this chain: no Personal Account exists or
        // ever will, the parent falls back to its computed address
        string memory xrplOwner = "rLoanChainOnlyOwner";
        address predicted = controller.getSubaccount(xrplOwner, SUBACCOUNT_TYPE_LOAN);
        assertEq(predicted.code.length, 0);

        address created = controller.createSubaccount(xrplOwner, SUBACCOUNT_TYPE_LOAN);
        assertEq(created, predicted);
        assertNotEq(created.code.length, 0);

        // idempotent
        address again = controller.createSubaccount(xrplOwner, SUBACCOUNT_TYPE_LOAN);
        assertEq(again, created);
    }

    function testCreateSubaccountRevertWhenPaused() public {
        _pauseController();
        vm.expectRevert(IPauseFacet.IsPaused.selector);
        controller.createSubaccount("rOwner", SUBACCOUNT_TYPE_LOAN);
    }

    //
    // step 4: repayment, deposits, the bridge-back sweep and recovery
    //

    function testSecondTypeBindsItsOwnMarket() public {
        // a new pool is a new subaccount type: same implementation, own write-once market,
        // own deterministic CREATE2 address for the same owner - positions on different
        // pools never share an account
        _configureSettings();
        uint256 typeB = 2;
        ILoanMarketsFacet.Market memory marketB = _defaultMarket();
        marketB.marketParams.lltv = 0.5e18;
        morpho.createMarket(marketB.marketParams);
        vm.startPrank(governance);
        controller.setSubaccountImplementation(typeB, address(loanChainImpl));
        IILoanMarketsFacet(address(controller)).registerLoanMarket(
            typeB, marketB
        );
        _setDefaultFeeTerms(address(controller), typeB);
        vm.stopPrank();

        // both accounts materialize through the production CREATE2 route, one per type
        string memory xrplOwner = "rTwoPoolsOwner";
        address subaccountA = controller.createSubaccount(xrplOwner, SUBACCOUNT_TYPE_LOAN);
        address subaccountB = controller.createSubaccount(xrplOwner, typeB);
        assertEq(subaccountA, controller.getSubaccount(xrplOwner, SUBACCOUNT_TYPE_LOAN));
        assertEq(subaccountB, controller.getSubaccount(xrplOwner, typeB));
        assertNotEq(subaccountA, subaccountB);

        // each account borrows on its own pool, independently
        fxrp.mint(subaccountA, 100e6);
        _deliver(subaccountA, 1, 100e6, _borrowPayload(
            bytes32("op-a"), DESTINATION_KIND_EVM,
            bytes32(uint256(uint160(makeAddr("destA")))), 300e18
        ));
        fxrp.mint(subaccountB, 50e6);
        _deliver(subaccountB, 2, 50e6, _borrowPayload(
            bytes32("op-b"), DESTINATION_KIND_EVM,
            bytes32(uint256(uint160(makeAddr("destB")))), 100e18
        ));

        bytes32 marketIdB = keccak256(abi.encode(marketB.marketParams));
        (, uint128 sharesA, uint128 collateralA) = morpho.position(_marketId(), subaccountA);
        (, uint128 sharesB, uint128 collateralB) = morpho.position(marketIdB, subaccountB);
        assertEq(collateralA, 100e6);
        assertEq(collateralB, 50e6);
        assertGt(sharesA, 0);
        assertGt(sharesB, 0);
        // neither account has any position on the other's market, in either direction
        (, uint128 crossSharesA, uint128 crossCollateralA) =
            morpho.position(marketIdB, subaccountA);
        assertEq(crossSharesA, 0);
        assertEq(crossCollateralA, 0);
        (, uint128 crossSharesB, uint128 crossCollateralB) =
            morpho.position(_marketId(), subaccountB);
        assertEq(crossSharesB, 0);
        assertEq(crossCollateralB, 0);
    }

    function testBorrowRevertMarketNotRegistered() public {
        // mis-sync fail-safe: a type with no market yet cannot execute composed actions
        // (retriable revert), but the transport-only bridge-back works - funds never strand
        _configureSettings();
        uint256 typeB = 2;
        vm.prank(governance);
        controller.setSubaccountImplementation(typeB, address(loanChainImpl));
        SubaccountProxy proxyB = new SubaccountProxy(
            address(controller), parentPersonalAccount, typeB
        );
        address subaccountB = address(proxyB);
        fxrp.mint(subaccountB, 100e6);

        _deliverExpectRevert(
            subaccountB, 1, _depositPayload(bytes32("op-1")),
            abi.encodeWithSelector(
                ILoanMarketsFacet.MarketNotRegistered.selector, typeB
            )
        );
        // the revert rolled the whole delivery back: the id stays unconsumed for a retry
        assertFalse(ILoanSubaccountRemote(subaccountB).usedOperations(bytes32("op-1")));

        // the stranded credit exits over the transport without needing a market - as the
        // signed action it now is, called by the parent
        uint256 messagingFee = 0.01 ether;
        vm.deal(parentPersonalAccount, messagingFee);
        vm.prank(parentPersonalAccount);
        uint256 amount =
            ILoanSubaccountRemote(subaccountB).sweepToOrigin{value: messagingFee}("");
        assertEq(amount, 100e6);
    }

    function testBorrowRetriesAfterMarketRegistration() public {
        // the mis-sync revert is retriable: once governance registers the type's market,
        // the exact same packet delivers
        _configureSettings();
        uint256 typeB = 2;
        vm.prank(governance);
        controller.setSubaccountImplementation(typeB, address(loanChainImpl));
        address subaccountB = address(new SubaccountProxy(
            address(controller), parentPersonalAccount, typeB
        ));
        fxrp.mint(subaccountB, 100e6);

        bytes memory payload = _depositPayload(bytes32("op-1"));
        _deliverExpectRevert(
            subaccountB, 1, payload,
            abi.encodeWithSelector(
                ILoanMarketsFacet.MarketNotRegistered.selector, typeB
            )
        );
        assertFalse(ILoanSubaccountRemote(subaccountB).usedOperations(bytes32("op-1")));

        ILoanMarketsFacet.Market memory marketB = _defaultMarket();
        marketB.marketParams.lltv = 0.5e18;
        morpho.createMarket(marketB.marketParams);
        vm.startPrank(governance);
        IILoanMarketsFacet(address(controller)).registerLoanMarket(
            typeB, marketB
        );
        _setDefaultFeeTerms(address(controller), typeB);
        vm.stopPrank();

        _deliver(subaccountB, 1, 100e6, payload);
        (, , uint128 collateral) =
            morpho.position(keccak256(abi.encode(marketB.marketParams)), subaccountB);
        assertEq(collateral, 100e6);
        assertTrue(ILoanSubaccountRemote(subaccountB).usedOperations(bytes32("op-1")));
    }

    function testRepayPartialByAssets() public {
        address subaccount = _borrowedSubaccount(500e18);
        rlusd.mint(subaccount, 200e18);

        vm.expectEmit();
        emit ILoanSubaccountRemote.LoanRepaid(parentPersonalAccount, 200e18);
        uint256 assets = ILoanSubaccountRemote(subaccount).repay();

        assertEq(assets, 200e18);
        assertEq(rlusd.balanceOf(subaccount), 0);
        (, uint128 borrowShares, ) = morpho.position(_marketId(), subaccount);
        assertEq(borrowShares, 300e18 * 1e6);
    }

    function testRepayFullClosesBySharesAndRecoversSurplus() public {
        // the balance covers the debt: repaid by exact borrow shares, and the over-funded
        // remainder leaves to the parent in the same call
        address subaccount = _borrowedSubaccount(500e18);
        rlusd.mint(subaccount, 600e18);

        vm.expectEmit();
        emit ILoanSubaccountRemote.LoanRepaid(parentPersonalAccount, 500e18);
        vm.expectEmit();
        emit ILoanSubaccountRemote.LoanSurplusRecovered(parentPersonalAccount, 100e18);
        uint256 assets = ILoanSubaccountRemote(subaccount).repay();

        assertEq(assets, 500e18);
        (, uint128 borrowShares, ) = morpho.position(_marketId(), subaccount);
        assertEq(borrowShares, 0);
        assertEq(rlusd.balanceOf(subaccount), 0);
        assertEq(rlusd.balanceOf(parentPersonalAccount), 100e18);
    }

    function testRepayClampsToAccruedDebt() public {
        // the documented user flow overfunds the repayment to cover interest accrued while
        // bridging; the clamp repays exactly the live debt and leaves the rest
        address subaccount = _borrowedSubaccount(500e18);
        morpho.addPendingInterest(_marketId(), 25e18);
        rlusd.mint(subaccount, 600e18);

        uint256 assets = ILoanSubaccountRemote(subaccount).repay();

        // full debt incl. accrued interest, repaid via exact shares (rounding up by at most 1)
        assertGe(assets, 525e18);
        assertLe(assets, 525e18 + 1);
        (, uint128 borrowShares, ) = morpho.position(_marketId(), subaccount);
        assertEq(borrowShares, 0);
        // the rest left as surplus in the same call
        assertEq(rlusd.balanceOf(subaccount), 0);
        assertEq(rlusd.balanceOf(parentPersonalAccount), 600e18 - assets);
    }

    function testRepayRevertNothingToRepay() public {
        // no idle balance at all
        address subaccount = _createConfiguredSubaccount();
        vm.expectRevert(ILoanSubaccountRemote.NothingToRepay.selector);
        ILoanSubaccountRemote(subaccount).repay();
    }

    function testRepayWithoutDebtRecoversWholeBalance() public {
        // loan tokens on a debt-free account (sent by mistake, or arriving after the close)
        // are surplus: repay is their exit, with nothing repaid
        address subaccount = _createConfiguredSubaccount();
        rlusd.mint(subaccount, 100e18);
        assertEq(ILoanSubaccountRemote(subaccount).repay(), 0);
        assertEq(rlusd.balanceOf(parentPersonalAccount), 100e18);
        assertEq(rlusd.balanceOf(subaccount), 0);
    }

    function testRepayKeepsBalanceWhileDebtRemains() public {
        // while the position has debt, the loan-token balance is repayment material: a
        // partial repay consumes it and nothing leaves to the parent
        address subaccount = _borrowedSubaccount(500e18);
        rlusd.mint(subaccount, 100e18);
        assertEq(ILoanSubaccountRemote(subaccount).repay(), 100e18);
        assertEq(rlusd.balanceOf(parentPersonalAccount), 0);
        assertEq(rlusd.balanceOf(subaccount), 0);
    }

    function testRepayRevertMarketNotRegistered() public {
        // an unconfigured type has no market to repay into
        address subaccount = address(_deploySubaccount());
        rlusd.mint(subaccount, 100e18);

        vm.expectRevert(
            abi.encodeWithSelector(
                ILoanMarketsFacet.MarketNotRegistered.selector, SUBACCOUNT_TYPE_LOAN
            )
        );
        ILoanSubaccountRemote(subaccount).repay();
    }

    function testRepayWorksWhilePaused() public {
        // repaying moves the position toward safety and stays available during incidents
        address subaccount = _borrowedSubaccount(500e18);
        rlusd.mint(subaccount, 200e18);
        _pauseController();

        uint256 assets = ILoanSubaccountRemote(subaccount).repay();
        assertEq(assets, 200e18);
    }

    function testRepayWorksWithClearedTransport() public {
        // clearing the transport kills composed actions and the sweep, never repayment
        address subaccount = _borrowedSubaccount(500e18);
        vm.prank(governance);
        IIComposeTransportFacet(address(controller)).clearComposeTransport();

        rlusd.mint(subaccount, 600e18);
        uint256 assets = ILoanSubaccountRemote(subaccount).repay();
        assertEq(assets, 500e18);
        // nor does the surplus push
        assertEq(rlusd.balanceOf(parentPersonalAccount), 100e18);

        // the defensive idle deposit needs no transport either
        fxrp.mint(subaccount, 10e6);
        ILoanSubaccountRemote(subaccount).depositIdleFxrp();
        (, , uint128 collateral) = morpho.position(_marketId(), subaccount);
        assertEq(collateral, 110e6);
    }

    function testTransportClearRetainsBorrowSwitchAndRecovery() public {
        // the nuclear lever zeroes only the LayerZero surface: the per-type borrow switch
        // survives the clear, and recovery to the parent needs no transport at all
        address subaccount = _createConfiguredSubaccount();
        vm.startPrank(governance);
        IILoanMarketsFacet(address(controller)).disableLoanBorrowing(
            SUBACCOUNT_TYPE_LOAN
        );
        IIComposeTransportFacet(address(controller)).clearComposeTransport();
        vm.stopPrank();

        assertTrue(
            ILoanMarketsFacet(address(controller))
                .isLoanBorrowingDisabled(SUBACCOUNT_TYPE_LOAN)
        );
        rlusd.mint(subaccount, 1e18);
        assertEq(ILoanSubaccountRemote(subaccount).repay(), 0);
        assertEq(rlusd.balanceOf(parentPersonalAccount), 1e18);
    }

    function testDepositIdleFxrp() public {
        address subaccount = _createConfiguredSubaccount();
        fxrp.mint(subaccount, 70e6);

        vm.expectEmit();
        emit ILoanSubaccountRemote.IdleFxrpDeposited(parentPersonalAccount, 70e6);
        uint256 amount = ILoanSubaccountRemote(subaccount).depositIdleFxrp();

        assertEq(amount, 70e6);
        (, , uint128 collateral) = morpho.position(_marketId(), subaccount);
        assertEq(collateral, 70e6);
        assertEq(fxrp.balanceOf(subaccount), 0);
    }

    function testDepositIdleFxrpReverts() public {
        address subaccount = _createConfiguredSubaccount();

        // nothing idle
        vm.expectRevert(ILoanSubaccountRemote.NothingToDeposit.selector);
        ILoanSubaccountRemote(subaccount).depositIdleFxrp();

        // new exposure is pause-gated
        fxrp.mint(subaccount, 70e6);
        _pauseController();
        vm.expectRevert(IPauseFacet.IsPaused.selector);
        ILoanSubaccountRemote(subaccount).depositIdleFxrp();
    }

    function testSweepToOriginBridgesBackToOwnFlareAddress() public {
        address subaccount = _createConfiguredSubaccount();
        fxrp.mint(subaccount, 100e6);
        uint256 messagingFee = 0.01 ether;

        // the exit is a signed action: only the parent (the mirror) may call it
        address caller = parentPersonalAccount;
        vm.deal(caller, messagingFee + 1 ether);
        vm.prank(caller);
        uint256 amount =
            ILoanSubaccountRemote(subaccount).sweepToOrigin{value: messagingFee + 1 ether}("");

        assertEq(amount, 100e6);
        assertEq(fxrp.balanceOf(subaccount), 0);
        assertEq(fxrp.balanceOf(address(fxrpOft)), 100e6);
        (uint32 sentDstEid, bytes32 to, uint256 amountLD, uint256 minAmountLD,, bytes memory composeMsg,) =
            fxrpOft.lastSendParam();
        assertEq(sentDstEid, originEid);
        assertEq(to, bytes32(uint256(uint160(subaccount))));
        assertEq(amountLD, 100e6);
        assertEq(minAmountLD, 100e6);
        // the redeem-home compose: the Flare twin redeems exactly this credit on arrival, until
        // the stamped deadline
        assertEq(
            composeMsg,
            abi.encode(
                PAYLOAD_VERSION_1, ACTION_REDEEM_HOME, abi.encode(uint64(block.timestamp) + REDEEM_HOME_TTL)
            )
        );
        // exactly the quoted fee spent, exactly this call's excess refunded
        assertEq(fxrpOft.lastValue(), messagingFee);
        assertEq(caller.balance, 1 ether);
    }

    function testSweepToOriginPassesTheCallerOptionsThrough() public {
        // the Flare-side gas (and any redemption fee as compose value) is the caller's to set
        address subaccount = _createConfiguredSubaccount();
        fxrp.mint(subaccount, 100e6);
        bytes memory options = hex"0003010011010000000000000000000000000000c350";
        vm.deal(parentPersonalAccount, 0.01 ether);
        vm.prank(parentPersonalAccount);
        ILoanSubaccountRemote(subaccount).sweepToOrigin{value: 0.01 ether}(options);
        (,,,, bytes memory sentOptions,,) = fxrpOft.lastSendParam();
        assertEq(sentOptions, options);
    }

    function testSweepToOriginNeverSpendsAccountNative() public {
        // pre-existing native on the account must not subsidize the parent's sweep - the
        // LayerZero fee is paid from msg.value alone
        address subaccount = _createConfiguredSubaccount();
        fxrp.mint(subaccount, 100e6);
        vm.deal(subaccount, 5 ether);
        uint256 messagingFee = 0.01 ether;

        vm.deal(parentPersonalAccount, messagingFee);
        vm.prank(parentPersonalAccount);
        ILoanSubaccountRemote(subaccount).sweepToOrigin{value: messagingFee}("");

        assertEq(subaccount.balance, 5 ether);
        assertEq(parentPersonalAccount.balance, 0);
    }

    function testSweepToOriginReverts() public {
        address subaccount = _createConfiguredSubaccount();
        uint256 messagingFee = 0.01 ether;
        vm.deal(address(this), 1 ether);
        vm.deal(parentPersonalAccount, 1 ether);

        // the exit is a signed action: anyone else is rejected before anything is read
        fxrp.mint(subaccount, 100e6);
        vm.expectRevert(ILoanSubaccountRemote.OnlyParent.selector);
        ILoanSubaccountRemote(subaccount).sweepToOrigin{value: messagingFee}("");

        // nothing to sweep
        vm.prank(parentPersonalAccount);
        vm.expectRevert(
            abi.encodeWithSelector(
                ILoanSubaccountRemote.InsufficientFundsForSweep.selector, messagingFee
            )
        );
        ILoanSubaccountRemote(subaccount).sweepToOrigin{value: messagingFee - 1}("");

        // a peer mutation fails closed
        fxrpOft.setPeer(originEid, bytes32(uint256(0xbad)));
        vm.prank(parentPersonalAccount);
        vm.expectRevert(ILoanSubaccountRemote.WrongOriginPeer.selector);
        ILoanSubaccountRemote(subaccount).sweepToOrigin{value: messagingFee}("");
        fxrpOft.setPeer(originEid, originPeer);

        // every exit from this chain rides the OFT: the pause stops it
        _pauseController();
        vm.prank(parentPersonalAccount);
        vm.expectRevert(IPauseFacet.IsPaused.selector);
        ILoanSubaccountRemote(subaccount).sweepToOrigin{value: messagingFee}("");
        _unpauseController();

        // nothing to sweep (checked after authorization)
        fxrp.burn(subaccount, 100e6);
        vm.prank(parentPersonalAccount);
        vm.expectRevert(ILoanSubaccountRemote.NothingToSweep.selector);
        ILoanSubaccountRemote(subaccount).sweepToOrigin{value: messagingFee}("");
    }

    function testDepositFrontRunLeavesSignedSweepHarmless() public {
        // the residue race that remains: a gas-only depositIdleFxrp can beat the signed exit;
        // the sweep then reverts NothingToSweep (the batch stays retriable) and the funds sit
        // as the user's own collateral - never redirected
        address subaccount = _createConfiguredSubaccount();
        fxrp.mint(subaccount, 50e6);
        ILoanSubaccountRemote(subaccount).depositIdleFxrp();

        vm.deal(parentPersonalAccount, 0.01 ether);
        vm.prank(parentPersonalAccount);
        vm.expectRevert(ILoanSubaccountRemote.NothingToSweep.selector);
        ILoanSubaccountRemote(subaccount).sweepToOrigin{value: 0.01 ether}("");
        (, , uint128 collateral) = morpho.position(_marketId(), subaccount);
        assertEq(collateral, 50e6);
    }

    function testSignedSweepToOriginThroughTheMirror() public {
        // the remote exit end to end, one owner throughout: the production-created PA sends
        // the signed batch while the beacon resolves the Flare implementation; the SAME proxy
        // becomes the mirror when the beacon switches (same address, per-chain implementation,
        // exactly the production model), executes the batch, funds the fee from its own native
        // balance, and takes the excess refund into its plain receive()
        _configureSettings();
        string memory exitOwner = "rSignedExitOwner";
        address subaccount = controller.createSubaccount(exitOwner, SUBACCOUNT_TYPE_LOAN);
        fxrp.mint(subaccount, 9e6);
        _flareSenderOnThisDiamond(); // wires the Flare bridge settings on this diamond

        address pa = controller.createPersonalAccount(exitOwner);
        assertEq(LoanSubaccountRemote(payable(subaccount)).parentPersonalAccount(), pa);
        vm.deal(pa, 0.01 ether);
        IPersonalAccount.Call[] memory batch = new IPersonalAccount.Call[](1);
        batch[0] = IPersonalAccount.Call({
            target: subaccount,
            value: 0.05 ether,
            data: abi.encodeCall(ILoanSubaccountRemote.sweepToOrigin, (""))
        });
        IPersonalAccount.Call[] memory calls = new IPersonalAccount.Call[](1);
        calls[0] = IPersonalAccount.Call({
            target: pa,
            value: 0.01 ether,
            data: abi.encodeCall(
                IPersonalAccount.sendCrossChainUserOp,
                (batch, bytes32("op-exit"), uint64(block.timestamp + 1 hours), "")
            )
        });
        vm.prank(address(controller));
        IPersonalAccount(pa).executeUserOp(calls);
        (uint256 amountLD, bytes memory payload) = _lastSentCompose();
        assertEq(amountLD, 0);
        // the send targets the sender's own address: composeFrom on delivery is the sender
        (, bytes32 to, , , , , ) = fxrpOft.lastSendParam();
        assertEq(to, bytes32(uint256(uint160(pa))));

        // the same proxy is the mirror once the beacon switches. On separate chains each
        // proxy is initialized by its own implementation; on this shared diamond the switch
        // leaves the mirror layout's xrplOwner slot (2) unset, so write what the mirror's
        // initialize would have written (short-string encoding)
        vm.prank(governance);
        controller.setPersonalAccountImplementation(address(new PersonalAccountRemote()));
        vm.store(
            pa,
            bytes32(uint256(2)),
            bytes32(bytes(exitOwner)) | bytes32(uint256(bytes(exitOwner).length * 2))
        );

        // underfunded mirror: the batch's 0.05 call value exceeds the balance, the whole
        // delivery reverts and the exact packet stays retriable
        vm.deal(pa, 0.01 ether);
        (bytes memory message, bytes32 guid) = _composeMessage(pa, 3, 0, payload);
        vm.prank(lzEndpoint);
        vm.expectRevert();
        IPersonalAccountRemote(pa).lzCompose(address(fxrpOft), guid, message, executor, "");
        assertFalse(IPersonalAccountRemote(pa).usedOperations(bytes32("op-exit")));
        assertEq(fxrp.balanceOf(subaccount), 9e6);

        // funded, the exact same packet replays and succeeds: bridged home with the
        // redeem-home compose, exactly the quoted fee spent, the excess refunded to the mirror
        vm.deal(pa, 1 ether);
        vm.prank(lzEndpoint);
        IPersonalAccountRemote(pa).lzCompose(address(fxrpOft), guid, message, executor, "");
        (uint256 sweptLD, ) = _lastSentCompose();
        assertEq(sweptLD, 9e6);
        assertEq(fxrp.balanceOf(subaccount), 0);
        assertEq(pa.balance, 1 ether - 0.01 ether);
        assertTrue(IPersonalAccountRemote(pa).usedOperations(bytes32("op-exit")));

        // a batch whose call value cannot cover the live fee rolls back whole too
        fxrp.mint(subaccount, 5e6);
        IPersonalAccountRemote.Call[] memory poorCalls = new IPersonalAccountRemote.Call[](1);
        poorCalls[0] = IPersonalAccountRemote.Call({
            target: subaccount,
            value: 0.001 ether,
            data: abi.encodeCall(ILoanSubaccountRemote.sweepToOrigin, (""))
        });
        bytes memory poor = abi.encode(
            PAYLOAD_VERSION_1,
            PA_ACTION_EXECUTE,
            abi.encode(bytes32("op-poor"), uint64(block.timestamp + 1 hours), poorCalls)
        );
        (message, guid) = _composeMessage(pa, 4, 0, poor);
        vm.prank(lzEndpoint);
        vm.expectRevert();
        IPersonalAccountRemote(pa).lzCompose(address(fxrpOft), guid, message, executor, "");
        assertEq(fxrp.balanceOf(subaccount), 5e6);
        assertFalse(IPersonalAccountRemote(pa).usedOperations(bytes32("op-poor")));
    }

    function testRetiredSweepDepositActionIsUnsupported() public {
        // action id 4 is retired, never reused: a packet carrying it fails closed
        address subaccount = _createConfiguredSubaccount();
        fxrp.mint(subaccount, 100e6);
        _deliverExpectRevert(
            subaccount, 1, abi.encode(PAYLOAD_VERSION_1, uint8(4), bytes("")),
            abi.encodeWithSelector(
                IComposeReceiverAccountBase.UnsupportedAction.selector, uint8(4)
            )
        );
    }

    function testSurplusRecoveryWorksWhilePaused() public {
        // the surplus push is inward consolidation to the account's own parent, not an exit,
        // so the pause does not gate it; the parent's signed user operations are what the
        // pause stops
        address subaccount = _createConfiguredSubaccount();
        _pauseController();

        rlusd.mint(subaccount, 1e18);
        assertEq(ILoanSubaccountRemote(subaccount).repay(), 0);
        assertEq(rlusd.balanceOf(parentPersonalAccount), 1e18);
    }

    function testWithdrawWithAttachedCreditLeavesItIdle() public {
        // a message-only action delivered with tokens attached executes normally; the credit
        // simply stays idle on the account for the fixed rails
        address subaccount = _createConfiguredSubaccount();
        fxrp.mint(subaccount, 100e6);
        _deliver(subaccount, 1, 100e6, _depositPayload(bytes32("op-1")));

        fxrp.mint(subaccount, 5e6);
        _deliverWithValue(subaccount, 2, 5e6, _withdrawPayload(bytes32("op-2"), 30e6), 0.01 ether);

        // exactly the withdrawn amount bridges home; the attached credit stays for the rails
        (, , uint128 collateral) = morpho.position(_marketId(), subaccount);
        assertEq(collateral, 70e6);
        assertEq(fxrp.balanceOf(subaccount), 5e6);
    }

    function testRegisterLoanMarketRevertCodelessToken() public {
        // the binding is permanent, and a Morpho market can exist for an address with no
        // code - so both tokens must be contracts
        _configureTransport();
        ILoanMarketsFacet.Market memory market = _defaultMarket();
        market.marketParams.loanToken = makeAddr("codelessToken");
        morpho.createMarket(market.marketParams);
        _registerMarketExpectRevert(
            market, ILoanMarketsFacet.InvalidMarketParams.selector
        );
    }

    function testRegisterLoanMarketRevertCodelessCollateralToken() public {
        // the symmetric case: a codeless collateral token must be rejected too
        _configureTransport();
        ILoanMarketsFacet.Market memory market = _defaultMarket();
        market.marketParams.collateralToken = makeAddr("codelessCollateral");
        morpho.createMarket(market.marketParams);
        _registerMarketExpectRevert(
            market, ILoanMarketsFacet.InvalidMarketParams.selector
        );
    }

    function testRegisterLoanMarketRevertNonexistentMarket() public {
        // the market must actually exist on the Morpho contract, or every credited compose
        // action against it would revert
        _configureTransport();
        _registerMarketExpectRevert(
            _defaultMarket(), ILoanMarketsFacet.InvalidMarketParams.selector
        );
    }

    function testRepaySurplusPushFailureDoesNotRevertRepayment() public {
        // an RLUSD-like freeze on the parent: the surplus push fails, but the repayment that
        // just closed the debt stands - the surplus stays here and any later repay retries it
        _configureSettings();
        uint256 typeB = 2;
        MockFreezableToken frozenRlusd = new MockFreezableToken("Frozen RLUSD", "RLUSD", 18);
        ILoanMarketsFacet.Market memory marketB = _defaultMarket();
        marketB.marketParams.loanToken = address(frozenRlusd);
        morpho.createMarket(marketB.marketParams);
        vm.startPrank(governance);
        controller.setSubaccountImplementation(typeB, address(loanChainImpl));
        IILoanMarketsFacet(address(controller)).registerLoanMarket(
            typeB, marketB
        );
        _setDefaultFeeTerms(address(controller), typeB);
        vm.stopPrank();

        address subaccount = controller.createSubaccount("rFrozenParentOwner", typeB);
        address parent = LoanSubaccountRemote(payable(subaccount)).parentPersonalAccount();
        fxrp.mint(subaccount, 100e6);
        _deliver(subaccount, 1, 100e6, _borrowPayload(
            bytes32("op-frz"), DESTINATION_KIND_EVM,
            bytes32(uint256(uint160(makeAddr("destFrz")))), 300e18
        ));

        frozenRlusd.mint(subaccount, 400e18);
        frozenRlusd.setFrozen(parent, true);

        vm.expectEmit();
        emit ILoanSubaccountRemote.LoanRepaid(parent, 300e18);
        vm.expectEmit();
        emit ILoanSubaccountRemote.LoanSurplusRetained(parent, 100e18);
        uint256 assets = ILoanSubaccountRemote(subaccount).repay();

        // the debt is closed and the repayment stood; only the push was deferred
        assertEq(assets, 300e18);
        bytes32 marketIdB = keccak256(abi.encode(marketB.marketParams));
        (, uint128 shares, ) = morpho.position(marketIdB, subaccount);
        assertEq(shares, 0);
        assertEq(frozenRlusd.balanceOf(subaccount), 100e18);
        assertEq(frozenRlusd.balanceOf(parent), 0);

        // unfrozen, the next permissionless repay retries the push
        frozenRlusd.setFrozen(parent, false);
        vm.expectEmit();
        emit ILoanSubaccountRemote.LoanSurplusRecovered(parent, 100e18);
        assertEq(ILoanSubaccountRemote(subaccount).repay(), 0);
        assertEq(frozenRlusd.balanceOf(parent), 100e18);
        assertEq(frozenRlusd.balanceOf(subaccount), 0);
    }

    function testDebtFreeSurplusRecoveryNeedsNoAccrual() public {
        // the debt-free path reads only the position: a reverting IRM (broken or hostile)
        // cannot trap recoverable loan tokens
        address subaccount = _createConfiguredSubaccount();
        rlusd.mint(subaccount, 100e18);
        morpho.setAccrueInterestReverts(true);

        assertEq(ILoanSubaccountRemote(subaccount).repay(), 0);
        assertEq(rlusd.balanceOf(parentPersonalAccount), 100e18);

        // with live debt, repayment still needs accrual - the guard is scoped to debt-free
        morpho.setAccrueInterestReverts(false);
        address indebted = controller.createSubaccount("rIndebtedAccrualOwner", SUBACCOUNT_TYPE_LOAN);
        fxrp.mint(indebted, 100e6);
        _deliver(indebted, 1, 100e6, _borrowPayload(
            bytes32("op-acc"), DESTINATION_KIND_EVM,
            bytes32(uint256(uint160(makeAddr("destAcc")))), 300e18
        ));
        morpho.setAccrueInterestReverts(true);
        rlusd.mint(indebted, 100e18);
        vm.expectRevert(bytes("IRM reverted"));
        ILoanSubaccountRemote(indebted).repay();
    }

    function testStrayTokenHasNoExit() public {
        // no generic recovery rail: a stray token strands until a beacon upgrade adds one -
        // accepted on both subaccounts. Every token the protocol routes here has its own rail
        // (FXRP: depositIdleFxrp / sweepToOrigin; the loan token: repay)
        address subaccount = _createConfiguredSubaccount();
        MintableERC20 stray = new MintableERC20("Stray", "STR", 18);
        stray.mint(subaccount, 42e18);
        assertEq(stray.balanceOf(subaccount), 42e18);
    }

    function testFlareSendersProduceThePayloadsTheLoanChainDecodes() public {
        // sender and receiver in one place: the Flare-side senders (LoanSubaccount,
        // PersonalAccount) and the loan-chain decoders (LoanSubaccountRemote,
        // PersonalAccountRemote) run on this one diamond, so the bytes the Flare side
        // actually hands to the OFT's send are what the receivers execute - wrapped by the
        // canonical compose codec exactly as the OFT's lzReceive -> sendCompose wraps them
        // (composeFrom being the receiver's own address: sender and receiver share it in
        // production). No hand-built payload in between
        address subaccount = _createConfiguredSubaccount();
        address sender = _flareSenderOnThisDiamond();
        uint64 deadline = uint64(block.timestamp + 1 hours);
        vm.deal(parentPersonalAccount, 1 ether);

        // borrow: the sender bridges 100e6 with the typed payload; the receiver supplies the
        // credited amount and disburses the loan to the parent (the mirror's address)
        fxrp.mint(sender, 100e6);
        vm.prank(parentPersonalAccount);
        ILoanSubaccount(sender).borrow{value: 0.01 ether}(
            100e6, 500e18, DESTINATION_KIND_EVM, bytes32(uint256(uint160(parentPersonalAccount))),
            bytes32("op-b"), deadline, ""
        );
        (uint256 amountLD, bytes memory payload) = _lastSentCompose();
        assertEq(amountLD, 100e6);
        fxrp.mint(subaccount, amountLD); // the OFT's credit on the receiving side
        _deliver(subaccount, 1, amountLD, payload);
        (, , uint128 collateral) = morpho.position(_marketId(), subaccount);
        assertEq(collateral, 100e6);
        assertEq(rlusd.balanceOf(parentPersonalAccount), 500e18);

        // withdraw: message-only out, atomic on arrival - the receiver withdraws the
        // collateral and bridges it home in the same execution, under the signed return
        // options, paid by the delivered compose value
        vm.prank(parentPersonalAccount);
        ILoanSubaccount(sender).withdraw{value: 0.01 ether}(
            40e6, bytes32("op-w"), deadline,
            ILoanSubaccount.WithdrawOptions({
                destinationOptions: "",
                returnOptions: hex"0003",
                minComposeValue: 0.01 ether
            })
        );
        (amountLD, payload) = _lastSentCompose();
        assertEq(amountLD, 0);
        _deliverWithValue(subaccount, 2, 0, payload, 0.01 ether);
        (, , collateral) = morpho.position(_marketId(), subaccount);
        assertEq(collateral, 60e6);
        assertEq(fxrp.balanceOf(subaccount), 0);

        // the withdraw's return leg is a real bridge-back: deliver it to the Flare twin on
        // this same diamond, which authenticates it against the bridge settings and runs the
        // sweep-redeem logic on arrival - here its dust branch, since the parent has no code
        // on this diamond (the redemption itself is covered in the Flare suite)
        (amountLD, payload) = _lastSentCompose();
        assertEq(amountLD, 40e6);
        flareAssetManager.setMinimumRedeemAmountUBA(1_000e6);
        fxrp.mint(sender, amountLD);
        _deliverToFlareReceiver(sender, 6, amountLD, payload);
        assertEq(fxrp.balanceOf(sender), 0);
        assertEq(fxrp.balanceOf(parentPersonalAccount), 40e6);

        // the signed deposit: exactly the signed amount travels and is supplied, no debt
        fxrp.mint(sender, 30e6);
        vm.prank(parentPersonalAccount);
        ILoanSubaccount(sender).depositCollateral{value: 0.01 ether}(30e6, bytes32("op-d"), deadline, "");
        (amountLD, payload) = _lastSentCompose();
        assertEq(amountLD, 30e6);
        fxrp.mint(subaccount, amountLD);
        _deliver(subaccount, 4, amountLD, payload);
        (, , collateral) = morpho.position(_marketId(), subaccount);
        assertEq(collateral, 90e6);
        assertTrue(ILoanSubaccountRemote(subaccount).usedOperations(bytes32("op-d")));


        // the Personal Account's transfer: sent by a Flare PersonalAccount through
        // executeUserOp, decoded by a mirror created behind the same beacon
        address destination = makeAddr("userChosen");
        _sendTransferFromFlarePersonalAccount(destination, deadline);
        (amountLD, payload) = _lastSentCompose();
        assertEq(amountLD, 0);
        address mirror = _mirrorOnThisDiamond("rMirrorOwner");
        rlusd.mint(mirror, 500e18);
        _deliverToMirror(mirror, 5, payload);
        assertEq(rlusd.balanceOf(destination), 500e18);
        assertEq(rlusd.balanceOf(mirror), 0);
        assertTrue(IPersonalAccountRemote(mirror).usedOperations(bytes32("op-t")));
    }

    function testMinimalLoanChainDiamondTopology() public {
        // the intended loan-chain cut: the generic subaccount surface, the PA beacon
        // surface, the compose transport and the loan markets - never the Flare-only
        // LoanBridgeSettingsFacet. The full-suite diamond could hide an accidental
        // dependency; this minimal one proves there is none (base facets reused from
        // setUp - their fixed CREATE2 salts would collide again)
        DiamondArgs memory args = DiamondArgs({
            owner: initialOwner,
            initAddress: address(0),
            initCalldata: ""
        });
        MasterAccountController minimal = new MasterAccountController(baseCuts, args);

        IDiamond.FacetCut[] memory cuts = new IDiamond.FacetCut[](6);
        cuts[0] = _buildFacetCut(
            address(new SubaccountsFacet()), "SubaccountsFacet", IDiamond.FacetCutAction.Add
        );
        cuts[1] = _buildFacetCut(
            address(new TimelockFacet()), "TimelockFacet", IDiamond.FacetCutAction.Add
        );
        cuts[2] = _buildFacetCut(
            address(new PauseFacet()), "PauseFacet", IDiamond.FacetCutAction.Add
        );
        cuts[3] = _buildFacetCut(
            address(new ComposeTransportFacet()),
            "ComposeTransportFacet",
            IDiamond.FacetCutAction.Add
        );
        cuts[4] = _buildFacetCut(
            address(new LoanMarketsFacet()), "LoanMarketsFacet", IDiamond.FacetCutAction.Add
        );
        cuts[5] = _buildFacetCut(
            address(new PersonalAccountsFacet()),
            "PersonalAccountsFacet",
            IDiamond.FacetCutAction.Add
        );
        IIMasterAccountController minimalController =
            IIMasterAccountController(address(minimal));
        vm.prank(initialOwner);
        minimalController.diamondCut(cuts, address(0), "");

        // the loan flow works on the minimal topology: register the implementation,
        // configure the settings, create the subaccount (timelock duration defaults to 0)
        morpho.createMarket(_defaultMarket().marketParams);
        fxrpOft.setPeer(originEid, originPeer);
        vm.startPrank(initialOwner);
        minimalController.setSubaccountImplementation(SUBACCOUNT_TYPE_LOAN, address(loanChainImpl));
        IIComposeTransportFacet(address(minimal)).setComposeTransport(_defaultTransport());
        IILoanMarketsFacet(address(minimal)).registerLoanMarket(
            SUBACCOUNT_TYPE_LOAN, _defaultMarket()
        );
        _setDefaultFeeTerms(address(minimal), SUBACCOUNT_TYPE_LOAN);
        vm.stopPrank();
        string memory xrplOwner = "rMinimalTopologyOwner";
        address subaccount = minimalController.createSubaccount(xrplOwner, SUBACCOUNT_TYPE_LOAN);
        assertGt(subaccount.code.length, 0);

        // created before its mirror, the subaccount is bound to the computed - still
        // codeless - mirror address, and the surplus push parks the tokens there; creating
        // the mirror later puts code and the registry entry at that same address, with the
        // parked balance now under the user's signature
        address parent = LoanSubaccountRemote(payable(subaccount)).parentPersonalAccount();
        assertEq(parent.code.length, 0);
        rlusd.mint(subaccount, 5e18);
        assertEq(ILoanSubaccountRemote(subaccount).repay(), 0);
        assertEq(rlusd.balanceOf(parent), 5e18);

        // the mirror Personal Account also materializes on the minimal topology, behind the
        // PA beacon, through the generic creation route on the PersonalAccountsFacet - but
        // only once the implementation is registered: the frozen BeaconProxy asks the beacon
        // at construction, and an unset beacon fails the creation closed
        vm.expectRevert();
        minimalController.createPersonalAccount(xrplOwner);
        PersonalAccountRemote mirrorImpl = new PersonalAccountRemote();
        vm.prank(initialOwner);
        minimalController.setPersonalAccountImplementation(address(mirrorImpl));
        address mirror = minimalController.createPersonalAccount(xrplOwner);
        assertGt(mirror.code.length, 0);
        assertEq(minimalController.getPersonalAccount(xrplOwner), mirror);
        assertEq(mirror, parent);
        assertEq(rlusd.balanceOf(mirror), 5e18);

        // the Flare-only bridge settings are not routable on this diamond
        vm.expectRevert(
            abi.encodeWithSelector(
                FunctionNotFound.selector,
                ILoanBridgeSettingsFacet.getLoanBridgeSettings.selector
            )
        );
        ILoanBridgeSettingsFacet(address(minimal)).getLoanBridgeSettings();
    }

    //
    // helpers
    //

    function _defaultTransport()
        private
        returns (IComposeTransportFacet.Transport memory)
    {
        return IComposeTransportFacet.Transport({
            lzEndpoint: lzEndpoint,
            oft: address(fxrpOft),
            originEid: originEid,
            originPeer: originPeer
        });
    }

    function _defaultMarket()
        private
        returns (ILoanMarketsFacet.Market memory)
    {
        return ILoanMarketsFacet.Market({
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

    /// Configures the meeting-example fee terms (floor 7%, spread 1% annually, a fixed
    /// collector) for `_subaccountType`: rates first, then the recipient - the activation
    /// marker. The caller must already be pranked as the diamond's owner.
    function _setDefaultFeeTerms(address _diamond, uint256 _subaccountType) private {
        IILoanMarketsFacet(_diamond).setLoanFeeRates(_subaccountType, 0.07e18, 0.01e18);
        IILoanMarketsFacet(_diamond).setLoanFeeRecipient(
            _subaccountType, makeAddr("feeCollector")
        );
    }

    /// A valid alternate OFT adapter wrapping `_token`, wired like the default one.
    function _wiredOft(MintableERC20 _token) private returns (MockOft _oft) {
        _oft = new MockOft(_token, 0.01 ether);
        _oft.setEndpoint(lzEndpoint);
        _oft.setPeer(originEid, originPeer);
    }

    function _configureTransport() private {
        fxrpOft.setPeer(originEid, originPeer);
        _setTransport(_defaultTransport());
    }

    function _setTransport(IComposeTransportFacet.Transport memory _transport) private {
        vm.prank(governance);
        IIComposeTransportFacet(address(controller)).setComposeTransport(_transport);
    }

    function _configureSettings() private {
        _configureTransport();
        morpho.createMarket(_defaultMarket().marketParams);
        vm.startPrank(governance);
        IILoanMarketsFacet(address(controller)).registerLoanMarket(
            SUBACCOUNT_TYPE_LOAN, _defaultMarket()
        );
        _setDefaultFeeTerms(address(controller), SUBACCOUNT_TYPE_LOAN);
        vm.stopPrank();
    }

    function _setTransportExpectRevert(
        IComposeTransportFacet.Transport memory _transport,
        bytes4 _selector
    )
        private
    {
        vm.prank(governance);
        vm.expectRevert(_selector);
        IIComposeTransportFacet(address(controller)).setComposeTransport(_transport);
    }

    function _registerMarketExpectRevert(
        ILoanMarketsFacet.Market memory _market,
        bytes4 _selector
    )
        private
    {
        vm.prank(governance);
        vm.expectRevert(_selector);
        IILoanMarketsFacet(address(controller)).registerLoanMarket(
            SUBACCOUNT_TYPE_LOAN, _market
        );
    }

    /// A Flare-side LoanSubaccount sender wired on this diamond as a second type, with the
    /// Flare bridge settings pointing at this chain and the FAssets registry it reads FXRP from.
    function _flareSenderOnThisDiamond() private returns (address _sender) {
        flareAssetManager = new MockAssetManager(fxrp);
        uint256 senderType = 7;
        vm.prank(governance);
        controller.setSubaccountImplementation(senderType, address(new LoanSubaccount()));
        _sender = address(new SubaccountProxy(address(controller), parentPersonalAccount, senderType));

        vm.mockCall(
            FLARE_CONTRACT_REGISTRY,
            abi.encodeWithSelector(
                IFlareContractRegistry.getContractAddressByHash.selector,
                keccak256(abi.encode("AssetManagerFXRP"))
            ),
            abi.encode(address(flareAssetManager))
        );
        bytes32 peer = bytes32(uint256(uint160(address(fxrpOft))));
        fxrpOft.setPeer(dstEid, peer);
        vm.prank(governance);
        controller.setLoanBridgeSettings(address(fxrpOft), dstEid, peer);
    }

    /// A Flare PersonalAccount behind this diamond's beacon (the Flare implementation is the
    /// one registered in setUp) sends a one-call transfer batch for the mirror through
    /// executeUserOp, as in production.
    function _sendTransferFromFlarePersonalAccount(address _destination, uint64 _deadline) private {
        address flarePa = address(new PersonalAccountProxy(address(controller), "rSenderOwner"));
        vm.deal(flarePa, 0.01 ether);
        IPersonalAccount.Call[] memory batch = new IPersonalAccount.Call[](1);
        batch[0] = IPersonalAccount.Call({
            target: address(rlusd),
            value: 0,
            data: abi.encodeCall(IERC20.transfer, (_destination, 500e18))
        });
        IPersonalAccount.Call[] memory calls = new IPersonalAccount.Call[](1);
        calls[0] = IPersonalAccount.Call({
            target: flarePa,
            value: 0.01 ether,
            data: abi.encodeCall(
                IPersonalAccount.sendCrossChainUserOp, (batch, bytes32("op-t"), _deadline, "")
            )
        });
        vm.prank(address(controller));
        IPersonalAccount(flarePa).executeUserOp(calls);
    }

    /// The loan-chain mirror for `_xrplOwner`, after switching the PA beacon to the mirror
    /// implementation (Flare Personal Accounts created earlier on this diamond are not touched
    /// again).
    function _mirrorOnThisDiamond(string memory _xrplOwner) private returns (address) {
        vm.prank(governance);
        controller.setPersonalAccountImplementation(address(new PersonalAccountRemote()));
        return controller.createPersonalAccount(_xrplOwner);
    }

    /// Delivers a loan-chain-built compose to a Flare-side receiver on this diamond: srcEid is
    /// this (loan) chain, the pinned peer is the bridge settings' one (this OFT), the guid the
    /// endpoint here would compute.
    function _deliverToFlareReceiver(
        address _receiver,
        uint64 _nonce,
        uint256 _amountLD,
        bytes memory _payload
    )
        private
    {
        bytes memory message = OFTComposeMsgCodec.encode(
            _nonce, dstEid, _amountLD, abi.encodePacked(bytes32(uint256(uint160(_receiver))), _payload)
        );
        bytes32 guid = GUID.generate(
            _nonce, dstEid, address(fxrpOft), dstEid, bytes32(uint256(uint160(address(fxrpOft))))
        );
        vm.prank(lzEndpoint);
        ILoanSubaccount(_receiver).lzCompose(address(fxrpOft), guid, message, executor, "");
    }

    function _deliverToMirror(address _mirror, uint64 _nonce, bytes memory _payload) private {
        (bytes memory message, bytes32 guid) = _composeMessage(_mirror, _nonce, 0, _payload);
        vm.prank(lzEndpoint);
        IPersonalAccountRemote(_mirror).lzCompose(address(fxrpOft), guid, message, executor, "");
    }

    function _createConfiguredSubaccount() private returns (address) {
        _configureSettings();
        return address(_deploySubaccount());
    }

    /// A configured subaccount with 100e6 FXRP collateral and `_borrowAmount` RLUSD debt.
    function _borrowedSubaccount(uint256 _borrowAmount) private returns (address) {
        address subaccount = _createConfiguredSubaccount();
        fxrp.mint(subaccount, 100e6);
        bytes memory payload = _borrowAmount == 0
            ? _depositPayload(bytes32("op-borrow"))
            : _borrowPayload(
                bytes32("op-borrow"), DESTINATION_KIND_EVM,
                bytes32(uint256(uint160(makeAddr("exchangeDeposit")))), _borrowAmount
            );
        _deliver(subaccount, 1, 100e6, payload);
        return subaccount;
    }

    function _deliver(
        address _subaccount,
        uint64 _nonce,
        uint256 _amountLD,
        bytes memory _payload
    )
        private
    {
        _deliverWithValue(_subaccount, _nonce, _amountLD, _payload, 0);
    }

    /// Delivers with compose value, as the executor does for a withdraw (the return-leg fee).
    function _deliverWithValue(
        address _subaccount,
        uint64 _nonce,
        uint256 _amountLD,
        bytes memory _payload,
        uint256 _value
    )
        private
    {
        (bytes memory message, bytes32 guid) =
            _composeMessage(_subaccount, _nonce, _amountLD, _payload);
        vm.deal(lzEndpoint, _value);
        vm.prank(lzEndpoint);
        ILoanSubaccountRemote(_subaccount).lzCompose{value: _value}(
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
        ILoanSubaccountRemote(_subaccount).lzCompose(
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
        ILoanSubaccountRemote(_subaccount).lzCompose(
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
                _destinationKind,
                _destination,
                _borrowAmount
            )
        );
    }

    function _depositPayload(
        bytes32 _operationId
    )
        private
        returns (bytes memory)
    {
        return abi.encode(
            PAYLOAD_VERSION_1,
            ACTION_DEPOSIT_COLLATERAL,
            abi.encode(_operationId, uint64(block.timestamp + 1 hours))
        );
    }

    function _withdrawPayload(
        bytes32 _operationId,
        uint256 _amount
    )
        private
        returns (bytes memory)
    {
        return _withdrawPayloadWithMin(_operationId, _amount, RETURN_MIN_VALUE);
    }

    function _withdrawPayloadWithMin(
        bytes32 _operationId,
        uint256 _amount,
        uint256 _minComposeValue
    )
        private
        returns (bytes memory)
    {
        return abi.encode(
            PAYLOAD_VERSION_1,
            ACTION_WITHDRAW,
            abi.encode(
                _operationId, uint64(block.timestamp + 1 hours), _amount, _minComposeValue,
                RETURN_OPTIONS
            )
        );
    }

    function _marketId() private returns (bytes32) {
        return keccak256(abi.encode(_defaultMarket().marketParams));
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

    function _deploySubaccount() private returns (LoanSubaccountRemote) {
        SubaccountProxy proxy = new SubaccountProxy(
            address(controller),
            parentPersonalAccount,
            SUBACCOUNT_TYPE_LOAN
        );
        return LoanSubaccountRemote(payable(address(proxy)));
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

    /// The amount and compose payload of the last send the Flare side handed to the OFT.
    function _lastSentCompose() private view returns (uint256 _amountLD, bytes memory _payload) {
        (, , _amountLD, , , _payload, ) = fxrpOft.lastSendParam();
    }
}
