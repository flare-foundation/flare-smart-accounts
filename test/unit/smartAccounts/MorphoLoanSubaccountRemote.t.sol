// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test, stdError} from "forge-std/Test.sol";
import {IControlledAccount} from "../../../contracts/userInterfaces/IControlledAccount.sol";
import {IPersonalAccountsFacet} from "../../../contracts/userInterfaces/facets/IPersonalAccountsFacet.sol";
import {ISubaccount} from "../../../contracts/userInterfaces/ISubaccount.sol";
import {FacetsDeploy} from "../../utils/FacetsDeploy.t.sol";
import {IDiamond} from "../../../contracts/diamond/interfaces/IDiamond.sol";
import {DiamondArgs, FunctionNotFound} from "../../../contracts/diamond/implementation/Diamond.sol";
import {IISingletonFactory} from "../../../contracts/smartAccounts/interface/IISingletonFactory.sol";
import {MasterAccountController} from "../../../contracts/smartAccounts/implementation/MasterAccountController.sol";
import {IIMasterAccountController} from "../../../contracts/smartAccounts/interface/IIMasterAccountController.sol";
import {MasterAccountControllerInit} from "../../../contracts/smartAccounts/facets/MasterAccountControllerInit.sol";
import {PersonalAccount} from "../../../contracts/smartAccounts/implementation/PersonalAccount.sol";
import {LoanSubaccount} from "../../../contracts/smartAccounts/implementation/LoanSubaccount.sol";
import {PersonalAccountProxy} from "../../../contracts/smartAccounts/proxy/PersonalAccountProxy.sol";
import {
    MorphoLoanSubaccountRemote
} from "../../../contracts/smartAccounts/implementation/MorphoLoanSubaccountRemote.sol";
import {SubaccountProxy} from "../../../contracts/smartAccounts/proxy/SubaccountProxy.sol";
import {MockNativeRejectingParent} from "../../../contracts/mock/MockNativeRejectingParent.sol";
import {ComposeTransportFacet} from "../../../contracts/smartAccounts/facets/ComposeTransportFacet.sol";
import {MorphoLoanMarketsFacet} from "../../../contracts/smartAccounts/facets/MorphoLoanMarketsFacet.sol";
import {SubaccountsFacet} from "../../../contracts/smartAccounts/facets/SubaccountsFacet.sol";
import {PersonalAccountsFacet} from "../../../contracts/smartAccounts/facets/PersonalAccountsFacet.sol";
import {
    PersonalAccountRemote
} from "../../../contracts/smartAccounts/implementation/PersonalAccountRemote.sol";
import {TimelockFacet} from "../../../contracts/smartAccounts/facets/TimelockFacet.sol";
import {PauseFacet} from "../../../contracts/smartAccounts/facets/PauseFacet.sol";
import {IMorphoLoanSubaccountRemote} from "../../../contracts/userInterfaces/IMorphoLoanSubaccountRemote.sol";
import {
    ILoanSubaccount,
    ACTION_BORROW,
    ACTION_WITHDRAW,
    ACTION_DEPOSIT_COLLATERAL,
    ACTION_CANCEL,
    DESTINATION_KIND_EVM,
    DESTINATION_KIND_XRPL_WORMHOLE
} from "../../../contracts/userInterfaces/ILoanSubaccount.sol";
import {ACTION_REDEEM_HOME} from "../../../contracts/userInterfaces/ILoanSubaccount.sol";
import {IPersonalAccount} from "../../../contracts/userInterfaces/IPersonalAccount.sol";
import {IPersonalAccountRemote} from "../../../contracts/userInterfaces/IPersonalAccountRemote.sol";
import {IFlareContractRegistry} from "flare-periphery/src/flare/IFlareContractRegistry.sol";
import {IComposeTransportFacet} from "../../../contracts/userInterfaces/facets/IComposeTransportFacet.sol";
import {
    IMorphoLoanMarketsFacet,
    MAX_FEE_RATE
} from "../../../contracts/userInterfaces/facets/IMorphoLoanMarketsFacet.sol";
import {IIComposeTransportFacet} from "../../../contracts/smartAccounts/interface/IIComposeTransportFacet.sol";
import {IIMorphoLoanMarketsFacet} from "../../../contracts/smartAccounts/interface/IIMorphoLoanMarketsFacet.sol";
import {IMorpho} from "../../../contracts/smartAccounts/interface/IMorpho.sol";
import {
    ISubaccountsFacet,
    SUBACCOUNT_TYPE_NONE
} from "../../../contracts/userInterfaces/facets/ISubaccountsFacet.sol";
import {SUBACCOUNT_TYPE_MORPHO_LOAN} from "../../../deployment/lib/SubaccountTypes.sol";
import {IBridgeRoutesFacet} from "../../../contracts/userInterfaces/facets/IBridgeRoutesFacet.sol";
import {NotContractOwner} from "../../../contracts/diamond/libraries/LibDiamond.sol";
import {MintableERC20} from "../../../contracts/mock/MintableERC20.sol";
import {MockReentrantToken} from "../../../contracts/mock/MockReentrantToken.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {MorphoMath} from "../../../contracts/smartAccounts/library/MorphoMath.sol";
import {MockOft} from "../../../contracts/mock/MockOft.sol";
import {MockAssetManager} from "../../../contracts/mock/MockAssetManager.sol";
import {MockMorpho} from "../../../contracts/mock/MockMorpho.sol";
import {MockOracle} from "../../../contracts/mock/MockOracle.sol";
import {MockIrm} from "../../../contracts/mock/MockIrm.sol";
import {MockFreezableToken} from "../../../contracts/mock/MockFreezableToken.sol";
import {MockLzEndpoint} from "../../../contracts/mock/MockLzEndpoint.sol";
import {OFTComposeMsgCodec} from "@layerzerolabs/oft-evm/contracts/libs/OFTComposeMsgCodec.sol";
import {GUID} from "@layerzerolabs/lz-evm-protocol-v2/contracts/libs/GUID.sol";
import {IPauseFacet} from "../../../contracts/userInterfaces/facets/IPauseFacet.sol";
import {ITimelockFacet} from "../../../contracts/userInterfaces/facets/ITimelockFacet.sol";
import {
    IComposeReceiverAccountBase,
    PAYLOAD_VERSION_1,
    SKIP_REASON_DUPLICATE,
    SKIP_REASON_EXPIRED
} from "../../../contracts/userInterfaces/IComposeReceiverAccountBase.sol";

/**
 * @title MorphoLoanSubaccountRemoteTest
 * @notice The loan-chain-side subaccount (Ethereum, at launch): the same frozen proxy
 * resolves a per-chain implementation through the controller-as-beacon, so the account keeps
 * its cross-chain CREATE2 address while behaving differently per chain. Covers creation and
 * implementation resolution, the authenticated compose actions, the Morpho rails, the Flare
 * fee accounting and gates, and cross-chain payload integration.
 */
// solhint-disable-next-line max-states-count
contract MorphoLoanSubaccountRemoteTest is Test, FacetsDeploy {
    address private constant SINGLETON_FACTORY = 0xce0042B868300000d44A59004Da54A005ffdcf9f;
    /// The signed return-leg options a withdraw payload carries (the mock OFT ignores them).
    bytes private constant RETURN_OPTIONS = hex"0003";
    /// The signed delivery-value floor a withdraw payload carries.
    uint256 private constant RETURN_MIN_VALUE = 0.01 ether;
    address private constant FLARE_CONTRACT_REGISTRY = 0xaD67FE66660Fb8dFE9d6b1b4240d8650e30F6019;
    MockAssetManager private flareAssetManager;

    IIMasterAccountController private controller;
    MorphoLoanSubaccountRemote private loanChainImpl;

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
    MockOracle private oracle;
    MockIrm private irm;
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
        // the mock's canonical health check stays off by default (the fee tests never lean on
        // it); the Morpho-interplay tests switch it on
        morpho.setHealthCheckDisabled(true);
        // Morpho oracle convention, 1e36-scaled: 1 FXRP (6 decimals) = 20 RLUSD (18 decimals), so
        // the fee fixtures' 1000 RLUSD on 100 FXRP sit at 50% LTV, inside Morpho's line and the
        // cover gate; the gate tests that reason at 1 FXRP = 2 RLUSD set that price themselves
        oracle = new MockOracle(2e49);
        // a rate-zero IRM: interest arrives only where a test sets a rate or queues it
        irm = new MockIrm();
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

        // register the loan-chain implementation for the loan type (timelock is 0 in tests)
        loanChainImpl = new MorphoLoanSubaccountRemote();
        vm.prank(governance);
        controller.setSubaccountImplementation(
            SUBACCOUNT_TYPE_MORPHO_LOAN,
            address(loanChainImpl)
        );
    }

    function testDeployAndInitialize() public {
        vm.expectEmit();
        emit ISubaccount.SubaccountInitialized(
            address(controller), parentPersonalAccount, SUBACCOUNT_TYPE_MORPHO_LOAN
        );
        MorphoLoanSubaccountRemote subaccount = _deploySubaccount();

        assertEq(subaccount.controllerAddress(), address(controller));
        assertEq(subaccount.parentPersonalAccount(), parentPersonalAccount);
        assertEq(subaccount.subaccountType(), SUBACCOUNT_TYPE_MORPHO_LOAN);
        assertEq(subaccount.implementation(), address(loanChainImpl));
    }

    function testInitializeRevertAlreadyInitialized() public {
        MorphoLoanSubaccountRemote subaccount = _deploySubaccount();

        vm.expectRevert(IControlledAccount.AlreadyInitialized.selector);
        subaccount.initialize(
            address(controller),
            parentPersonalAccount,
            SUBACCOUNT_TYPE_MORPHO_LOAN
        );
    }

    function testImplementationInitializeRevertAlreadyInitialized() public {
        // the implementation contract locks itself in its own constructor
        vm.expectRevert(IControlledAccount.AlreadyInitialized.selector);
        loanChainImpl.initialize(
            address(controller),
            parentPersonalAccount,
            SUBACCOUNT_TYPE_MORPHO_LOAN
        );
    }

    function testUpgradeRoutesToNewImplementation() public {
        MorphoLoanSubaccountRemote subaccount = _deploySubaccount();
        assertEq(subaccount.implementation(), address(loanChainImpl));

        MorphoLoanSubaccountRemote newImpl = new MorphoLoanSubaccountRemote();
        vm.prank(governance);
        controller.setSubaccountImplementation(
            SUBACCOUNT_TYPE_MORPHO_LOAN,
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
        MorphoLoanSubaccountRemote subaccount = _deploySubaccount();
        assertEq(subaccount.implementation(), address(loanChainImpl));
        assertEq(subaccount.parentPersonalAccount(), parentPersonalAccount);

        LoanSubaccount flareImpl = new LoanSubaccount();
        vm.prank(governance);
        controller.setSubaccountImplementation(
            SUBACCOUNT_TYPE_MORPHO_LOAN,
            address(flareImpl)
        );

        // same account address, per-chain behavior behind it: the registry now resolves the
        // type to the other chain's implementation. Reads through the account itself must go
        // through the matching chain's implementation: storage belongs to each proxy, and the
        // two chains share only the address - layouts may differ across chains, while every
        // chain-local upgrade lineage must preserve its proxies' layout
        assertEq(controller.implementationForType(SUBACCOUNT_TYPE_MORPHO_LOAN), address(flareImpl));
    }

    function testPredictedAddressIsImplementationIndependent() public {
        // the implementation never enters the CREATE2 derivation, so the predicted address
        // is identical whichever implementation - Flare's or the loan chain's - is registered;
        // this is what makes the account its own bridge destination across chains
        address predictedWithLoanChainImpl = controller.getSubaccount(
            "rOwner",
            SUBACCOUNT_TYPE_MORPHO_LOAN
        );

        LoanSubaccount flareImpl = new LoanSubaccount();
        vm.prank(governance);
        controller.setSubaccountImplementation(
            SUBACCOUNT_TYPE_MORPHO_LOAN,
            address(flareImpl)
        );
        address predictedWithFlareImpl = controller.getSubaccount(
            "rOwner",
            SUBACCOUNT_TYPE_MORPHO_LOAN
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

        MorphoLoanSubaccountRemote subaccount = _deploySubaccount();
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

        IMorphoLoanMarketsFacet.Market memory market =
            IMorphoLoanMarketsFacet(address(controller)).getLoanMarket(
                SUBACCOUNT_TYPE_MORPHO_LOAN
            );
        assertEq(market.morpho, address(morpho));
        assertEq(market.marketParams.loanToken, address(rlusd));
        assertEq(market.marketParams.collateralToken, address(fxrp));
        assertEq(market.marketParams.lltv, 0.77e18);
        assertFalse(
            IMorphoLoanMarketsFacet(address(controller)).isLoanBorrowingDisabled(
                SUBACCOUNT_TYPE_MORPHO_LOAN
            )
        );

        // the fee terms were configured by the setters after registration
        IMorphoLoanMarketsFacet.FeeTerms memory terms =
            IMorphoLoanMarketsFacet(address(controller)).getLoanFeeTerms(SUBACCOUNT_TYPE_MORPHO_LOAN);
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
        IIMorphoLoanMarketsFacet(address(controller)).registerLoanMarket(
            SUBACCOUNT_TYPE_MORPHO_LOAN, _defaultMarket()
        );
        IMorphoLoanMarketsFacet.FeeTerms memory terms =
            IMorphoLoanMarketsFacet(address(controller)).getLoanFeeTerms(SUBACCOUNT_TYPE_MORPHO_LOAN);
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
            subaccount, 1, payload, IMorphoLoanSubaccountRemote.FeeTermsNotConfigured.selector
        );

        // the one activating set opens borrowing: the same packet now delivers
        vm.startPrank(governance);
        _setFeeRates(0.07e18, 0.01e18);
        vm.stopPrank();
        terms = IMorphoLoanMarketsFacet(address(controller)).getLoanFeeTerms(SUBACCOUNT_TYPE_MORPHO_LOAN);
        assertEq(terms.feeFloor, 0.07e18);
        assertEq(terms.feeRecipient, makeAddr("feeCollector"));
        _deliver(subaccount, 1, 100e6, payload);
        assertEq(rlusd.balanceOf(destination), 500e18);
    }

    function testZeroRateActivationIsDeliberateFeeOff() public {
        // an explicit zero-rate configuration is a legal fee-off: the activating set names a
        // collector with both rates at zero, borrowing opens, and nothing ever accrues
        _configureTransport();
        morpho.createMarket(_defaultMarket().marketParams);
        vm.startPrank(governance);
        IIMorphoLoanMarketsFacet(address(controller)).registerLoanMarket(
            SUBACCOUNT_TYPE_MORPHO_LOAN, _defaultMarket()
        );
        _setFeeRates(0, 0);
        vm.stopPrank();
        IMorphoLoanMarketsFacet.FeeTerms memory terms =
            IMorphoLoanMarketsFacet(address(controller)).getLoanFeeTerms(SUBACCOUNT_TYPE_MORPHO_LOAN);
        assertEq(terms.feeFloor, 0);
        assertEq(terms.feeSpread, 0);
        assertEq(terms.feeRecipient, makeAddr("feeCollector"));

        // the fee-off type borrows and accrues nothing
        address subaccount = address(_deploySubaccount());
        fxrp.mint(subaccount, 100e6);
        _deliver(subaccount, 1, 100e6, _borrowPayload(
            bytes32("op-1"), DESTINATION_KIND_EVM,
            bytes32(uint256(uint160(makeAddr("dest")))), 500e18
        ));
        vm.warp(vm.getBlockTimestamp() + 365 days);
        IMorphoLoanSubaccountRemote(subaccount).checkpointFee();
        (, uint256 feeDebtX18, , , , ) = IMorphoLoanSubaccountRemote(subaccount).getLoanFeeState();
        assertEq(feeDebtX18, 0);
    }

    function testSetLoanFeeTermsZeroRatesIsDeliberateFeeOff() public {
        // explicit zero floor and spread are legal - with the recipient set, the type is
        // configured and "fee off" is a deliberate state, distinct from unconfigured
        _configureSettings();
        vm.startPrank(governance);
        _setFeeRates(0, 0);
        vm.stopPrank();
        IMorphoLoanMarketsFacet.FeeTerms memory stored =
            IMorphoLoanMarketsFacet(address(controller)).getLoanFeeTerms(SUBACCOUNT_TYPE_MORPHO_LOAN);
        assertEq(stored.feeFloor, 0);
        assertEq(stored.feeSpread, 0);
        assertEq(stored.feeRecipient, makeAddr("feeCollector"));
    }

    function testSetLoanFeeTerms() public {
        _configureSettings();
        vm.startPrank(governance);

        // a rate change restates the collector; the caps are inclusive
        vm.expectEmit();
        emit IMorphoLoanMarketsFacet.LoanFeeTermsSet(
            SUBACCOUNT_TYPE_MORPHO_LOAN, MAX_FEE_RATE, MAX_FEE_RATE, makeAddr("feeCollector")
        );
        _setFeeRates(MAX_FEE_RATE, MAX_FEE_RATE);
        IMorphoLoanMarketsFacet.FeeTerms memory terms =
            IMorphoLoanMarketsFacet(address(controller)).getLoanFeeTerms(SUBACCOUNT_TYPE_MORPHO_LOAN);
        assertEq(terms.feeFloor, MAX_FEE_RATE);
        assertEq(terms.feeSpread, MAX_FEE_RATE);
        assertEq(terms.feeRecipient, makeAddr("feeCollector"));

        // a collector rotation restates the rates
        address newCollector = makeAddr("newCollector");
        vm.expectEmit();
        emit IMorphoLoanMarketsFacet.LoanFeeTermsSet(
            SUBACCOUNT_TYPE_MORPHO_LOAN, MAX_FEE_RATE, MAX_FEE_RATE, newCollector
        );
        IIMorphoLoanMarketsFacet(address(controller)).setLoanFeeTerms(
            SUBACCOUNT_TYPE_MORPHO_LOAN, _feeTerms(MAX_FEE_RATE, MAX_FEE_RATE, newCollector)
        );
        terms = IMorphoLoanMarketsFacet(address(controller)).getLoanFeeTerms(SUBACCOUNT_TYPE_MORPHO_LOAN);
        assertEq(terms.feeFloor, MAX_FEE_RATE);
        assertEq(terms.feeSpread, MAX_FEE_RATE);
        assertEq(terms.feeRecipient, newCollector);
        vm.stopPrank();
    }

    function testSetLoanFeeTermsReverts() public {
        _configureSettings();
        vm.startPrank(governance);
        address collector = makeAddr("collector");

        // the setter needs a registered market: terms exist exactly as long as the type does
        vm.expectRevert(
            abi.encodeWithSelector(IMorphoLoanMarketsFacet.MarketNotRegistered.selector, 9)
        );
        IIMorphoLoanMarketsFacet(address(controller)).setLoanFeeTerms(9, _feeTerms(0, 0, collector));

        vm.expectRevert(IMorphoLoanMarketsFacet.InvalidFeeTerms.selector);
        IIMorphoLoanMarketsFacet(address(controller)).setLoanFeeTerms(
            SUBACCOUNT_TYPE_MORPHO_LOAN, _feeTerms(MAX_FEE_RATE + 1, 0, collector)
        );
        vm.expectRevert(IMorphoLoanMarketsFacet.InvalidFeeTerms.selector);
        IIMorphoLoanMarketsFacet(address(controller)).setLoanFeeTerms(
            SUBACCOUNT_TYPE_MORPHO_LOAN, _feeTerms(0, MAX_FEE_RATE + 1, collector)
        );
        vm.expectRevert(IMorphoLoanMarketsFacet.InvalidFeeRecipient.selector);
        IIMorphoLoanMarketsFacet(address(controller)).setLoanFeeTerms(
            SUBACCOUNT_TYPE_MORPHO_LOAN, _feeTerms(0, 0, address(0))
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
        IIMorphoLoanMarketsFacet(address(controller)).registerLoanMarket(
            SUBACCOUNT_TYPE_MORPHO_LOAN, _defaultMarket()
        );
        vm.expectRevert(
            abi.encodeWithSelector(NotContractOwner.selector, notOwner, governance)
        );
        IIMorphoLoanMarketsFacet(address(controller)).disableLoanBorrowing(
            SUBACCOUNT_TYPE_MORPHO_LOAN
        );
        vm.expectRevert(
            abi.encodeWithSelector(NotContractOwner.selector, notOwner, governance)
        );
        IIMorphoLoanMarketsFacet(address(controller)).enableLoanBorrowing(
            SUBACCOUNT_TYPE_MORPHO_LOAN
        );
        vm.expectRevert(
            abi.encodeWithSelector(NotContractOwner.selector, notOwner, governance)
        );
        _setFeeRates(0.07e18, 0.01e18);
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
        IMorphoLoanMarketsFacet.Market memory market;

        // Morpho must be a contract
        market = _defaultMarket();
        market.morpho = makeAddr("noCode");
        _registerMarketExpectRevert(market, IMorphoLoanMarketsFacet.InvalidMorpho.selector);

        // the market must name both tokens and a non-zero LLTV
        market = _defaultMarket();
        market.marketParams.loanToken = address(0);
        _registerMarketExpectRevert(
            market, IMorphoLoanMarketsFacet.InvalidMarketParams.selector
        );

        market = _defaultMarket();
        market.marketParams.collateralToken = address(0);
        _registerMarketExpectRevert(
            market, IMorphoLoanMarketsFacet.InvalidMarketParams.selector
        );

        market = _defaultMarket();
        market.marketParams.lltv = 0;
        _registerMarketExpectRevert(
            market, IMorphoLoanMarketsFacet.InvalidMarketParams.selector
        );

        // the reserved type 0 can never be bound
        vm.prank(governance);
        vm.expectRevert(ISubaccountsFacet.InvalidSubaccountType.selector);
        IIMorphoLoanMarketsFacet(address(controller)).registerLoanMarket(
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
        IMorphoLoanMarketsFacet.Market memory market = _defaultMarket();
        market.marketParams.collateralToken = address(otherToken);
        morpho.createMarket(market.marketParams);
        _registerMarketExpectRevert(market, IMorphoLoanMarketsFacet.InvalidMarketParams.selector);
    }

    function testSetComposeTransportRevertWrongSharedDecimals() public {
        // the withdraw's return leg sends with minAmountLD == amountLD, so shared-decimal dust
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
            IMorphoLoanMarketsFacet(address(controller))
                .getLoanMarket(SUBACCOUNT_TYPE_MORPHO_LOAN).morpho,
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
        IMorphoLoanMarketsFacet.Market memory other = _defaultMarket();
        other.marketParams.lltv = 0.5e18;
        morpho.createMarket(other.marketParams);
        vm.prank(governance);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMorphoLoanMarketsFacet.MarketAlreadyRegistered.selector,
                SUBACCOUNT_TYPE_MORPHO_LOAN
            )
        );
        IIMorphoLoanMarketsFacet(address(controller)).registerLoanMarket(
            SUBACCOUNT_TYPE_MORPHO_LOAN, other
        );
    }

    function testBorrowSwitchRequiresRegisteredMarket() public {
        vm.startPrank(governance);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMorphoLoanMarketsFacet.MarketNotRegistered.selector, SUBACCOUNT_TYPE_MORPHO_LOAN
            )
        );
        IIMorphoLoanMarketsFacet(address(controller)).disableLoanBorrowing(
            SUBACCOUNT_TYPE_MORPHO_LOAN
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                IMorphoLoanMarketsFacet.MarketNotRegistered.selector, SUBACCOUNT_TYPE_MORPHO_LOAN
            )
        );
        IIMorphoLoanMarketsFacet(address(controller)).enableLoanBorrowing(
            SUBACCOUNT_TYPE_MORPHO_LOAN
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
        IMorphoLoanMarketsFacet.Market memory market = _defaultMarket();
        market.marketParams.collateralToken = address(otherToken);
        morpho.createMarket(market.marketParams);
        vm.prank(governance);
        vm.expectRevert(IMorphoLoanMarketsFacet.InvalidMarketParams.selector);
        IIMorphoLoanMarketsFacet(address(controller)).registerLoanMarket(2, market);
    }

    //
    // step 3: the authenticated lzCompose entry point
    //

    function testLzComposeBorrowSuppliesTheWholeIdleBalanceAndDisburses() public {
        address subaccount = _createConfiguredSubaccount();
        address destination = makeAddr("exchangeDeposit");
        // the authenticated bridged amount plus a donation on the same balance: every FXRP here
        // is the user's own and has one route, so both go in
        fxrp.mint(subaccount, 100e6);
        fxrp.mint(subaccount, 5e6);

        bytes32 operationId = bytes32("op-1");
        vm.expectEmit();
        emit IMorphoLoanSubaccountRemote.LoanOpened(
            parentPersonalAccount,
            operationId,
            105e6,
            500e18,
            DESTINATION_KIND_EVM,
            bytes32(uint256(uint160(destination))),
            _guidFor(1)
        );
        _deliver(subaccount, 1, 100e6, _borrowPayload(
            operationId, DESTINATION_KIND_EVM, bytes32(uint256(uint160(destination))), 500e18
        ));

        // the whole idle balance was supplied, donation included
        (, uint128 borrowShares, uint128 collateral) = morpho.position(_marketId(), subaccount);
        assertEq(collateral, 105e6);
        // first borrow: shares = assets scaled by the virtual-share offset
        assertEq(borrowShares, 500e18 * 1e6);
        assertEq(fxrp.balanceOf(subaccount), 0);
        assertEq(rlusd.balanceOf(destination), 500e18);
        assertTrue(IMorphoLoanSubaccountRemote(subaccount).usedOperations(operationId));
    }

    function testLzComposeDepositCollateral() public {
        address subaccount = _createConfiguredSubaccount();
        fxrp.mint(subaccount, 100e6);

        // the deposit action supplies the credit (the whole idle balance - here exactly the
        // authenticated amount), no debt
        vm.expectEmit();
        emit IMorphoLoanSubaccountRemote.CollateralDeposited(
            parentPersonalAccount, 100e6, _guidFor(1)
        );
        _deliver(subaccount, 1, 100e6, _depositPayload());

        (, uint128 borrowShares, uint128 collateral) = morpho.position(_marketId(), subaccount);
        assertEq(collateral, 100e6);
        assertEq(borrowShares, 0);

        // a deposit that brings nothing is malformed, not a skip
        _deliverExpectRevertZeroAmount(
            subaccount, 2, _depositPayload(), IMorphoLoanSubaccountRemote.ZeroAmount.selector
        );
    }

    function testLzComposeBorrowAgainstExistingCollateral() public {
        address subaccount = _createConfiguredSubaccount();
        fxrp.mint(subaccount, 100e6);
        _deliver(subaccount, 1, 100e6, _depositPayload());

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
        _deliver(subaccount, 1, 100e6, _depositPayload());

        bytes32 operationId = bytes32("op-2");
        vm.expectEmit();
        emit IMorphoLoanSubaccountRemote.CollateralWithdrawn(
            parentPersonalAccount, operationId, 30e6, _guidFor(2)
        );
        uint256 oftBalanceBefore = fxrp.balanceOf(address(fxrpOft));
        _deliverWithValue(subaccount, 2, 0, _withdrawPayload(operationId, 30e6), 0.01 ether);

        // withdrawn and bridged home in the same execution: no idle window a redeposit
        // could touch
        (, , uint128 collateral) = morpho.position(_marketId(), subaccount);
        assertEq(collateral, 70e6);
        assertEq(fxrp.balanceOf(subaccount), 0);
        // the adapter actually pulled the withdrawn FXRP
        assertEq(fxrp.balanceOf(address(fxrpOft)), oftBalanceBefore + 30e6);

        // the return send: to this account's own address on the origin chain, exactly the
        // withdrawn amount with no slippage, the redeem-home compose, the signed return
        // options, and the parent as the adapter's refund address
        (
            uint32 sentDstEid,
            bytes32 to,
            uint256 amountLD,
            uint256 minAmountLD,
            bytes memory optionsSent,
            bytes memory composeMsgSent,
        ) = fxrpOft.lastSendParam();
        assertEq(sentDstEid, originEid);
        assertEq(to, bytes32(uint256(uint160(subaccount))));
        assertEq(amountLD, 30e6);
        assertEq(minAmountLD, 30e6);
        assertEq(fxrpOft.lastRefundAddress(), parentPersonalAccount);
        assertEq(fxrpOft.lastValue(), 0.01 ether);
        assertEq(optionsSent, RETURN_OPTIONS);
        assertEq(composeMsgSent, abi.encode(PAYLOAD_VERSION_1, ACTION_REDEEM_HOME, bytes("")));
    }

    function testLzComposeWithdrawRevertInsufficientReturnFee() public {
        // too little compose value for the return leg reverts the whole action - nothing is
        // withdrawn, the id stays unconsumed, and the delivery stays retriable (quotes drift)
        address subaccount = _createConfiguredSubaccount();
        fxrp.mint(subaccount, 100e6);
        _deliver(subaccount, 1, 100e6, _depositPayload());

        bytes32 operationId = bytes32("op-2");
        (bytes memory message, bytes32 guid) = _composeMessage(
            subaccount, 2, 0, _withdrawPayloadWithMin(operationId, 30e6, 0.0005 ether)
        );
        vm.deal(lzEndpoint, 0.001 ether);
        vm.prank(lzEndpoint);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMorphoLoanSubaccountRemote.InsufficientFundsForBridgeHome.selector, 0.01 ether
            )
        );
        IMorphoLoanSubaccountRemote(subaccount).lzCompose{value: 0.001 ether}(
            address(fxrpOft), guid, message, executor, ""
        );
        (, , uint128 collateral) = morpho.position(_marketId(), subaccount);
        assertEq(collateral, 100e6);
        assertFalse(IMorphoLoanSubaccountRemote(subaccount).usedOperations(operationId));
    }

    function testLzComposeWithdrawForwardsExcessToTheParent() public {
        // the operator quotes the return leg generously and signs the whole prepayment as the
        // floor: a delivery covering only the live quote still reverts on the floor, and the
        // full delivery's excess lands on the parent (the user's own account) - never on this
        // account (no native rail) and never with the executor
        address subaccount = _createConfiguredSubaccount();
        fxrp.mint(subaccount, 100e6);
        _deliver(subaccount, 1, 100e6, _depositPayload());

        bytes memory payload = _withdrawPayloadWithMin(bytes32("op-2"), 30e6, 0.05 ether);
        (bytes memory message, bytes32 guid) = _composeMessage(subaccount, 2, 0, payload);
        vm.deal(lzEndpoint, 0.01 ether);
        vm.prank(lzEndpoint);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMorphoLoanSubaccountRemote.InsufficientDeliveryValue.selector, 0.05 ether
            )
        );
        IMorphoLoanSubaccountRemote(subaccount).lzCompose{value: 0.01 ether}(
            address(fxrpOft), guid, message, executor, ""
        );

        vm.expectEmit();
        emit IMorphoLoanSubaccountRemote.NativeSweptToParent(parentPersonalAccount, 0.04 ether);
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
        _deliver(subaccount, 1, 100e6, _borrowPayload(
            bytes32("op-1"), DESTINATION_KIND_EVM, bytes32(uint256(uint160(makeAddr("dest")))), 100e18
        ));

        // execution path: a zero-value delivery reverts and stays retriable
        (bytes memory message, bytes32 guid) =
            _composeMessage(subaccount, 2, 0, _withdrawPayload(bytes32("op-2"), 30e6));
        vm.prank(lzEndpoint);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMorphoLoanSubaccountRemote.InsufficientDeliveryValue.selector, RETURN_MIN_VALUE
            )
        );
        IMorphoLoanSubaccountRemote(subaccount).lzCompose(address(fxrpOft), guid, message, executor, "");
        assertFalse(IMorphoLoanSubaccountRemote(subaccount).usedOperations(bytes32("op-2")));

        // skip path: a zero-value delivery of a duplicate reverts the same way instead of
        // consuming the packet with the prepaid value undelivered
        bytes memory dupPayload = _withdrawPayload(bytes32("op-1"), 30e6);
        (message, guid) = _composeMessage(subaccount, 3, 0, dupPayload);
        vm.prank(lzEndpoint);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMorphoLoanSubaccountRemote.InsufficientDeliveryValue.selector, RETURN_MIN_VALUE
            )
        );
        IMorphoLoanSubaccountRemote(subaccount).lzCompose(address(fxrpOft), guid, message, executor, "");

        // the same packet delivered at the floor terminal-skips and forwards the value
        vm.expectEmit();
        emit IMorphoLoanSubaccountRemote.LoanActionSkipped(
            parentPersonalAccount, bytes32("op-1"), SKIP_REASON_DUPLICATE, _guidFor(3)
        );
        _deliverWithValue(subaccount, 3, 0, dupPayload, RETURN_MIN_VALUE);
        assertEq(parentPersonalAccount.balance, RETURN_MIN_VALUE);
    }

    function testLzComposeRevertNonZeroComposeValue() public {
        address subaccount = _createConfiguredSubaccount();
        fxrp.mint(subaccount, 100e6);
        (bytes memory message, bytes32 guid) =
            _composeMessage(subaccount, 1, 100e6, _depositPayload());

        vm.deal(lzEndpoint, 1 ether);
        vm.prank(lzEndpoint);
        vm.expectRevert(IComposeReceiverAccountBase.NonZeroComposeValue.selector);
        IMorphoLoanSubaccountRemote(subaccount).lzCompose{value: 1}(
            address(fxrpOft), guid, message, executor, ""
        );
    }

    function testLzComposeRevertOnlyEndpoint() public {
        address subaccount = _createConfiguredSubaccount();
        (bytes memory message, bytes32 guid) =
            _composeMessage(subaccount, 1, 100e6, _depositPayload());

        vm.prank(makeAddr("notTheEndpoint"));
        vm.expectRevert(IComposeReceiverAccountBase.OnlyEndpoint.selector);
        IMorphoLoanSubaccountRemote(subaccount).lzCompose(address(fxrpOft), guid, message, executor, "");
    }

    function testLzComposeRevertWrongComposeSender() public {
        address subaccount = _createConfiguredSubaccount();
        (bytes memory message, bytes32 guid) =
            _composeMessage(subaccount, 1, 100e6, _depositPayload());

        address notTheOft = makeAddr("notTheOft");
        vm.prank(lzEndpoint);
        vm.expectRevert(
            abi.encodeWithSelector(IComposeReceiverAccountBase.WrongComposeSender.selector, notTheOft)
        );
        IMorphoLoanSubaccountRemote(subaccount).lzCompose(notTheOft, guid, message, executor, "");
    }

    function testLzComposeRevertWrongSourceEid() public {
        address subaccount = _createConfiguredSubaccount();
        bytes memory message = OFTComposeMsgCodec.encode(
            1,
            originEid + 1,
            100e6,
            abi.encodePacked(
                bytes32(uint256(uint160(subaccount))),
                _depositPayload()
            )
        );

        vm.prank(lzEndpoint);
        vm.expectRevert(
            abi.encodeWithSelector(IComposeReceiverAccountBase.WrongSourceEid.selector, originEid + 1)
        );
        IMorphoLoanSubaccountRemote(subaccount).lzCompose(
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
            abi.encodePacked(attacker, _depositPayload())
        );

        vm.prank(lzEndpoint);
        vm.expectRevert(
            abi.encodeWithSelector(IComposeReceiverAccountBase.WrongComposeFrom.selector, attacker)
        );
        IMorphoLoanSubaccountRemote(subaccount).lzCompose(
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
            _composeMessage(subaccount, 1, 100e6, _depositPayload());
        bytes32 forgedGuid = GUID.generate(
            1, originEid, makeAddr("maliciousPeer"), dstEid,
            bytes32(uint256(uint160(address(fxrpOft))))
        );

        vm.prank(lzEndpoint);
        vm.expectRevert(
            abi.encodeWithSelector(IComposeReceiverAccountBase.WrongGuid.selector, forgedGuid)
        );
        IMorphoLoanSubaccountRemote(subaccount).lzCompose(
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
        IMorphoLoanSubaccountRemote(subaccount).lzCompose(address(fxrpOft), guid, message, executor, "");

        // the compose stays queued at the endpoint; the same delivery succeeds after unpausing
        _unpauseController();
        vm.prank(lzEndpoint);
        IMorphoLoanSubaccountRemote(subaccount).lzCompose(address(fxrpOft), guid, message, executor, "");
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

        _deliver(subaccount, 2, 50e6, _depositPayload());
        (, , uint128 collateral) = morpho.position(_marketId(), subaccount);
        assertEq(collateral, 150e6);
    }

    function testDepositIdleFxrpDefendsIndebtedPositionWhilePaused() public {
        // the defensive case of the idle rail survives a pause: already-arrived collateral
        // can still protect the indebted position; the debt-free case stays gated
        address subaccount = _borrowedSubaccount(500e18);
        fxrp.mint(subaccount, 30e6);
        _pauseController();

        IMorphoLoanSubaccountRemote(subaccount).depositIdleFxrp();
        (, , uint128 collateral) = morpho.position(_marketId(), subaccount);
        assertEq(collateral, 130e6);

        // once the debt is gone, a paused deposit is new exposure and reverts
        rlusd.mint(subaccount, 600e18);
        IMorphoLoanSubaccountRemote(subaccount).repay();
        fxrp.mint(subaccount, 10e6);
        vm.expectRevert(IPauseFacet.IsPaused.selector);
        IMorphoLoanSubaccountRemote(subaccount).depositIdleFxrp();
    }

    function testLzComposeDepositWhilePausedRequiresLiveDebt() public {
        // a paused composed deposit is allowed only when the position carries live debt; a
        // debt-free deposit is new exposure and waits out the pause
        address subaccount = _createConfiguredSubaccount();
        fxrp.mint(subaccount, 100e6);
        _pauseController();

        _deliverExpectRevert(
            subaccount, 1, _depositPayload(),
            IPauseFacet.IsPaused.selector
        );
    }

    function testDepositsConsultThePauseBeforeThePosition() public {
        // the defensive rule reads the pause first, on every deposit: a controller that cannot
        // answer the pause question refuses both deposits even for an indebted position - fail
        // closed, like every other gate - rather than letting the position read decide alone.
        // No production path reaches this (the pause facet is cut with the rest), so the getter
        // is made to answer as a diamond without that facet would. The position read is made to
        // revert too, distinctly: the pause error surfacing proves the position was never asked
        address subaccount = _borrowedSubaccount(500e18);
        fxrp.mint(subaccount, 30e6);
        bytes memory noPauseFacet =
            abi.encodeWithSelector(FunctionNotFound.selector, IPauseFacet.isPaused.selector);
        vm.mockCallRevert(
            address(controller), abi.encodeWithSelector(IPauseFacet.isPaused.selector), noPauseFacet
        );
        vm.mockCallRevert(
            address(morpho),
            abi.encodeWithSelector(IMorpho.position.selector, _marketId(), subaccount),
            abi.encodeWithSignature("Error(string)", "position read before the pause")
        );

        vm.expectRevert(noPauseFacet);
        IMorphoLoanSubaccountRemote(subaccount).depositIdleFxrp();
        _deliverExpectRevert(subaccount, 2, _depositPayload(), noPauseFacet);

        vm.clearMockedCalls();
        (, , uint128 collateral) = morpho.position(_marketId(), subaccount);
        assertEq(collateral, 100e6);
    }

    function testBorrowRefusesAnyDeliveredComposeValue() public {
        // the borrow does not opt into compose value, so the base rejects a delivery carrying
        // any - one wei is enough. Pinned on the borrow specifically because the floor field
        // now lives in its payload: were `ACTION_BORROW` ever added to `_acceptsComposeValue`
        // without also handling the native, an EVM disbursement with a zero floor would be
        // allowed to arrive with value that this path never spends and the account cannot
        // recover. This assertion is what fails first if that happens
        address subaccount = _createConfiguredSubaccount();
        fxrp.mint(subaccount, 100e6);
        (bytes memory message, bytes32 guid) = _composeMessage(
            subaccount, 1, 100e6,
            _borrowPayload(
                bytes32("op-1"), DESTINATION_KIND_EVM,
                bytes32(uint256(uint160(makeAddr("dest")))), 300e18
            )
        );

        vm.deal(lzEndpoint, 1 ether);
        vm.prank(lzEndpoint);
        vm.expectRevert(IComposeReceiverAccountBase.NonZeroComposeValue.selector);
        IMorphoLoanSubaccountRemote(subaccount).lzCompose{value: 1}(
            address(fxrpOft), guid, message, executor, ""
        );
    }

    function testBorrowRefusesADeliveryValueFloorOnTheEvmKind() public {
        // the floor is reserved for a kind that pays for its own onward delivery; the EVM
        // disbursement spends nothing here, so a payload naming one is malformed. The Flare
        // sender refuses the same instruction before the bridge fee, so this can only arrive
        // hand-built - which is exactly what the frozen schema has to be pinned against
        address subaccount = _createConfiguredSubaccount();
        fxrp.mint(subaccount, 100e6);
        _deliverExpectRevert(
            subaccount, 1,
            _borrowPayloadWithFloor(bytes32("op-1"), _soon(), DESTINATION_KIND_EVM, _dest(), 1),
            IMorphoLoanSubaccountRemote.UnexpectedDeliveryValueFloor.selector
        );
    }

    function testBorrowFloorIsCheckedBeforeEveryConsumingBranch() public {
        // the floor comes before every branch that finalizes the packet, exactly as in the
        // withdraw. Two orderings are pinned here, because both are silent if it slips:
        // it precedes the destination-kind judgement (which happens downstream at the
        // disbursement), so an underfunded packet is refused for the missing value; and it
        // precedes the terminal gates, so an underfunded delivery of an ALREADY-CONSUMED id
        // reverts and stays retriable instead of being finalized as a duplicate skip
        address subaccount = _createConfiguredSubaccount();
        bytes32 operationId = bytes32("op-1");
        fxrp.mint(subaccount, 100e6);
        _deliverExpectRevert(
            subaccount, 1,
            _borrowPayloadWithFloor(
                operationId, _soon(), DESTINATION_KIND_XRPL_WORMHOLE, _dest(), 1 ether
            ),
            abi.encodeWithSelector(IMorphoLoanSubaccountRemote.InsufficientDeliveryValue.selector, 1 ether)
        );

        // consume the id with a real borrow, then re-deliver the underfunded packet: the floor
        // still refuses it, rather than the terminal gate skipping it away
        _deliver(subaccount, 2, 100e6, _borrowPayload(
            operationId, DESTINATION_KIND_EVM, bytes32(uint256(uint160(makeAddr("dest")))), 300e18
        ));
        _deliverExpectRevert(
            subaccount, 3,
            _borrowPayloadWithFloor(
                operationId, _soon(), DESTINATION_KIND_XRPL_WORMHOLE, _dest(), 1 ether
            ),
            abi.encodeWithSelector(IMorphoLoanSubaccountRemote.InsufficientDeliveryValue.selector, 1 ether)
        );
    }

    function testBorrowRejectsTheRetiredFiveWordPayload() public {
        // `abi.decode` tolerates trailing data for a static tuple, so a round trip alone would
        // still pass against a five-word decoder. This pins the other direction: the six-word
        // schema is required, and a five-word payload does not decode
        address subaccount = _createConfiguredSubaccount();
        fxrp.mint(subaccount, 100e6);
        (bytes memory message, bytes32 guid) =
            _composeMessage(subaccount, 1, 100e6, _borrowPayloadFiveWords(bytes32("op-1"), _soon(), _dest()));
        vm.prank(lzEndpoint);
        vm.expectRevert();
        IMorphoLoanSubaccountRemote(subaccount).lzCompose(address(fxrpOft), guid, message, executor, "");
    }

    function testExternalLiquidationTurnsBalanceIntoSurplus() public {
        // debt is read live from Morpho on every check - nothing is cached, so an external
        // liquidation is visible to the very next call: the position is closed, repay has
        // nothing to repay, and the whole balance leaves as surplus
        address subaccount = _borrowedSubaccount(500e18);
        _liquidate(subaccount, 0);
        rlusd.mint(subaccount, 100e18);

        vm.expectEmit();
        emit IMorphoLoanSubaccountRemote.LoanSurplusRecovered(parentPersonalAccount, 100e18);
        assertEq(IMorphoLoanSubaccountRemote(subaccount).repay(), 0);
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
        _liquidate(subaccount, liquidated);

        (, uint128 remainingShares, uint128 collateral) =
            morpho.position(_marketId(), subaccount);
        assertEq(remainingShares, borrowShares - liquidated);
        assertEq(collateral, 50e6);
        // the seized collateral left the pool to the liquidator - past the account entirely
        assertEq(fxrp.balanceOf(makeAddr("liquidator")), 50e6);
        (, , uint128 totalBorrowAssets, uint128 totalBorrowShares, , ) =
            morpho.market(_marketId());
        assertEq(totalBorrowShares, remainingShares);
        uint256 repaidAssets =
            (uint256(liquidated) * (500e18 + 1) + uint256(borrowShares) + 1e6 - 1) /
                (uint256(borrowShares) + 1e6);
        assertEq(totalBorrowAssets, 500e18 - repaidAssets);

        // the remaining debt stays repayable with canonical share conversion afterwards
        rlusd.mint(subaccount, 500e18);
        IMorphoLoanSubaccountRemote(subaccount).repay();
        (, uint128 finalShares, ) = morpho.position(_marketId(), subaccount);
        assertEq(finalShares, 0);
    }

    function testSimulateLiquidationAccruesPendingInterestFirst() public {
        // real Morpho accrues interest before liquidating; the mock must do the same so the
        // repaid-assets conversion and the remaining market totals stay canonical
        address subaccount = _borrowedSubaccount(500e18);
        (, uint128 borrowShares, ) = morpho.position(_marketId(), subaccount);
        morpho.addPendingInterest(_marketId(), 50e18);

        _liquidate(subaccount, 0);

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
        _deliver(subaccount, 1, 100e6, _depositPayload());

        vm.expectRevert(bytes("no debt to liquidate"));
        morpho.simulateLiquidation(_defaultMarket().marketParams, subaccount);
    }

    //
    // the Flare fee: checkpoint accounting and collection
    //

    function testBorrowInitializesFeeBaseline() public {
        // the borrow's pre-checkpoint re-baselines (clock + terms snapshot) and the post-sync
        // reads the canonical debt from Morpho - the first period accrues on the real
        // principal at the current terms, never on zero or stale ones
        address subaccount = _borrowedSubaccount(1000e18);
        (uint256 principal, uint256 feeDebtX18, , uint64 last, uint64 fl, uint64 sp) =
            IMorphoLoanSubaccountRemote(subaccount).getLoanFeeState();
        assertEq(principal, 1000e18);
        assertEq(feeDebtX18, 0);
        assertEq(last, vm.getBlockTimestamp());
        assertEq(fl, 0.07e18);
        assertEq(sp, 0.01e18);
    }

    function testCheckpointChargesFloorWhenMarketInterestIsLow() public {
        // the worked example's first year: 6% market interest under a 7% floor - the fee is
        // the difference, and the principal re-capitalizes to the live debt
        address subaccount = _borrowedSubaccount(1000e18);
        vm.warp(vm.getBlockTimestamp() + 365 days);
        morpho.addPendingInterest(_marketId(), 60e18);

        vm.expectEmit();
        emit IMorphoLoanSubaccountRemote.LoanFeeCheckpointed(
            parentPersonalAccount, 1060e18, 10e18 * 1e18
        );
        IMorphoLoanSubaccountRemote(subaccount).checkpointFee();
        (uint256 principal, , uint256 collectible, , , ) =
            IMorphoLoanSubaccountRemote(subaccount).getLoanFeeState();
        assertEq(principal, 1060e18);
        assertEq(collectible, 10e18);
    }

    function testCheckpointChargesInterestPlusSpreadAboveFloor() public {
        // above the floor the user pays market interest plus the spread; only the spread
        // part is Flare's
        _configureSettings();
        vm.startPrank(governance);
        _setFeeRates(0.05e18, 0.03e18);
        vm.stopPrank();
        address subaccount = address(_deploySubaccount());
        fxrp.mint(subaccount, 100e6);
        _deliver(subaccount, 1, 100e6, _borrowPayload(
            bytes32("op-borrow"), DESTINATION_KIND_EVM,
            bytes32(uint256(uint160(makeAddr("dest")))), 1000e18
        ));
        vm.warp(vm.getBlockTimestamp() + 365 days);
        morpho.addPendingInterest(_marketId(), 100e18);

        IMorphoLoanSubaccountRemote(subaccount).checkpointFee();
        // owed = max(5% * 1000, 100 + 3% * 1000) = 130; the fee is 130 - 100 = 30
        (uint256 principal, , uint256 collectible, , , ) =
            IMorphoLoanSubaccountRemote(subaccount).getLoanFeeState();
        assertEq(principal, 1100e18);
        assertEq(collectible, 30e18);
    }

    function testExternalRepaymentClampsToZeroInterest() public {
        // a debt decrease the account did not cause counts as zero interest: the elapsed
        // period still owes the full floor on the old base (the donation leak), and only the
        // future base shrinks
        address subaccount = _borrowedSubaccount(1000e18);
        vm.warp(vm.getBlockTimestamp() + 365 days);
        _externalRepay(subaccount, 900e18);

        IMorphoLoanSubaccountRemote(subaccount).checkpointFee();
        (uint256 principal, uint256 feeDebtX18, , , , ) =
            IMorphoLoanSubaccountRemote(subaccount).getLoanFeeState();
        assertApproxEqAbs(principal, 100e18, 1);
        assertEq(feeDebtX18, 70e18 * 1e18);

        // the shrunken base is what the next period is priced on
        vm.warp(vm.getBlockTimestamp() + 365 days);
        IMorphoLoanSubaccountRemote(subaccount).checkpointFee();
        (, feeDebtX18, , , , ) = IMorphoLoanSubaccountRemote(subaccount).getLoanFeeState();
        assertEq(feeDebtX18, 70e18 * 1e18 + principal * 0.07e18);
    }

    function testLiquidationKeepsFloorAccruingUntilPing() public {
        // a liquidation extinguishes debt with no event the account can see: the floor keeps
        // accruing on the stale principal until someone pings - prospectively only - and the
        // accrued claim is never auto-written-off
        address subaccount = _borrowedSubaccount(1000e18);
        vm.warp(vm.getBlockTimestamp() + 365 days);
        _liquidate(subaccount, 0);

        IMorphoLoanSubaccountRemote(subaccount).checkpointFee();
        (uint256 principal, uint256 feeDebtX18, , , , ) =
            IMorphoLoanSubaccountRemote(subaccount).getLoanFeeState();
        assertEq(principal, 0);
        assertEq(feeDebtX18, 70e18 * 1e18);

        // zero principal accrues nothing further; the claim simply stays outstanding
        vm.warp(vm.getBlockTimestamp() + 365 days);
        IMorphoLoanSubaccountRemote(subaccount).checkpointFee();
        (, feeDebtX18, , , , ) = IMorphoLoanSubaccountRemote(subaccount).getLoanFeeState();
        assertEq(feeDebtX18, 70e18 * 1e18);
    }

    function testCheckpointIsSharesFirstAndMorphoIndependentWhenDebtFree() public {
        // no Morpho liveness where none is needed: zero principal makes no Morpho call at
        // all, and zero live shares settle at zero debt without touching the IRM
        address borrowed = _borrowedSubaccount(1000e18);
        address subaccount = address(_deploySubaccount());
        morpho.setAccrueInterestReverts(true);
        IMorphoLoanSubaccountRemote(subaccount).checkpointFee();
        morpho.setAccrueInterestReverts(false);
        vm.warp(vm.getBlockTimestamp() + 365 days);
        _liquidate(borrowed, 0);
        morpho.setAccrueInterestReverts(true);
        // principal is stale-positive but the position has no shares: the checkpoint settles
        // at zero debt, charges the floor, and never invokes the IRM
        IMorphoLoanSubaccountRemote(borrowed).checkpointFee();
        (uint256 principal, uint256 feeDebtX18, , , , ) =
            IMorphoLoanSubaccountRemote(borrowed).getLoanFeeState();
        assertEq(principal, 0);
        assertEq(feeDebtX18, 70e18 * 1e18);
    }

    function testSameBlockCheckpointResyncsPrincipal() public {
        // the front-run regression: checkpoint at t, external repayment, checkpoint in the
        // same block - the zero-time checkpoint skips the fee math but must still re-read the
        // debt, or the next period would be charged on the stale pre-repayment base
        address subaccount = _borrowedSubaccount(1000e18);
        vm.warp(vm.getBlockTimestamp() + 365 days);
        IMorphoLoanSubaccountRemote(subaccount).checkpointFee();
        _externalRepay(subaccount, 900e18);
        IMorphoLoanSubaccountRemote(subaccount).checkpointFee();
        (uint256 principal, uint256 feeDebtX18, , , , ) =
            IMorphoLoanSubaccountRemote(subaccount).getLoanFeeState();
        assertApproxEqAbs(principal, 100e18, 1);
        assertEq(feeDebtX18, 70e18 * 1e18);

        vm.warp(vm.getBlockTimestamp() + 365 days);
        IMorphoLoanSubaccountRemote(subaccount).checkpointFee();
        (, feeDebtX18, , , , ) = IMorphoLoanSubaccountRemote(subaccount).getLoanFeeState();
        // the second year is priced on ~100, not the stale 1000
        assertEq(feeDebtX18, 70e18 * 1e18 + principal * 0.07e18);
    }

    function testRateChangeAppliesFromTheNextCheckpointOnly() public {
        // periods are priced at the SNAPSHOTTED terms: a rate change never reprices elapsed
        // time in either direction - a checkpoint settles the old period at the old rate and
        // only then adopts the new one
        address subaccount = _borrowedSubaccount(1000e18);
        vm.warp(vm.getBlockTimestamp() + 365 days);
        vm.startPrank(governance);
        _setFeeRates(0.14e18, 0.02e18);
        vm.stopPrank();

        // the elapsed year is still the old 7%
        IMorphoLoanSubaccountRemote(subaccount).checkpointFee();
        (, uint256 feeDebtX18, , , uint64 fl, ) =
            IMorphoLoanSubaccountRemote(subaccount).getLoanFeeState();
        assertEq(feeDebtX18, 70e18 * 1e18);
        assertEq(fl, 0.14e18);

        // the next year is the new 14%
        vm.warp(vm.getBlockTimestamp() + 365 days);
        IMorphoLoanSubaccountRemote(subaccount).checkpointFee();
        (, feeDebtX18, , , , ) = IMorphoLoanSubaccountRemote(subaccount).getLoanFeeState();
        assertEq(feeDebtX18, 210e18 * 1e18);

        // the decrease direction: a dormant account keeps paying its snapshotted higher rate
        // until someone pings - the cut is never retroactive either
        vm.startPrank(governance);
        _setFeeRates(0.035e18, 0.005e18);
        vm.stopPrank();
        vm.warp(vm.getBlockTimestamp() + 365 days);
        IMorphoLoanSubaccountRemote(subaccount).checkpointFee();
        (, feeDebtX18, , , , ) = IMorphoLoanSubaccountRemote(subaccount).getLoanFeeState();
        assertEq(feeDebtX18, 350e18 * 1e18);

        vm.warp(vm.getBlockTimestamp() + 365 days);
        IMorphoLoanSubaccountRemote(subaccount).checkpointFee();
        (, feeDebtX18, , , , ) = IMorphoLoanSubaccountRemote(subaccount).getLoanFeeState();
        assertEq(feeDebtX18, 385e18 * 1e18);
    }

    function testCheckpointTruncationBoundOnIndivisiblePartition() public {
        // the documented bound: each /YEAR division truncates below one X18 unit, so a
        // partition of N checkpoints loses at most N such units against the single reading -
        // never a base unit, never more
        address subaccount = _borrowedSubaccount(1000e18);
        uint256 perSecond = (1000e18 * uint256(0.07e18)) / 365 days; // truncated, as mulDiv
        uint256 threeSeconds = (1000e18 * uint256(0.07e18)) * 3 / 365 days;

        for (uint256 i = 0; i < 3; i++) {
            vm.warp(vm.getBlockTimestamp() + 1);
            IMorphoLoanSubaccountRemote(subaccount).checkpointFee();
        }
        (, uint256 partitioned, , , , ) = IMorphoLoanSubaccountRemote(subaccount).getLoanFeeState();
        assertEq(partitioned, 3 * perSecond);
        assertLe(partitioned, threeSeconds);
        assertLt(threeSeconds - partitioned, 3);
    }

    function testReBorrowAfterFullCloseStartsAFreshPeriod() public {
        // a complete close zeroes the base; the idle gap accrues nothing, and a re-borrow
        // re-baselines at the current terms - no stale clock, no stale snapshot
        address subaccount = _borrowedSubaccount(1000e18);
        vm.warp(vm.getBlockTimestamp() + 365 days);
        rlusd.mint(subaccount, 1070e18);
        IMorphoLoanSubaccountRemote(subaccount).repay();
        (uint256 principal, uint256 feeDebtX18, , , , ) =
            IMorphoLoanSubaccountRemote(subaccount).getLoanFeeState();
        assertEq(principal, 0);
        assertEq(feeDebtX18, 0);

        // a year idle, then borrow again - only the new period accrues, at the current rates
        vm.warp(vm.getBlockTimestamp() + 365 days);
        vm.startPrank(governance);
        _setFeeRates(0.14e18, 0.02e18);
        vm.stopPrank();
        vm.expectEmit();
        emit IMorphoLoanSubaccountRemote.LoanFeePrincipalSynced(parentPersonalAccount, 500e18);
        _deliver(subaccount, 2, 0, _borrowPayload(
            bytes32("op-2"), DESTINATION_KIND_EVM,
            bytes32(uint256(uint160(makeAddr("dest")))), 500e18
        ));
        vm.warp(vm.getBlockTimestamp() + 365 days);
        IMorphoLoanSubaccountRemote(subaccount).checkpointFee();
        (principal, feeDebtX18, , , , ) = IMorphoLoanSubaccountRemote(subaccount).getLoanFeeState();
        assertEq(principal, 500e18);
        assertEq(feeDebtX18, 70e18 * 1e18);
    }

    function testMockAccruesBeforeEveryConversion() public {
        // the multi-borrower regression: canonical Morpho accrues before converting assets
        // and shares in borrow and repay, so a direct external repayment with pending
        // interest must use the accrued exchange rate - a stale-rate mock would shift the
        // other borrower's measured debt
        address subaccountA = _borrowedSubaccount(1000e18);
        address subaccountB =
            controller.createSubaccount("rSecondBorrowerOwner", SUBACCOUNT_TYPE_MORPHO_LOAN);
        fxrp.mint(subaccountB, 100e6);
        _deliver(subaccountB, 1, 100e6, _borrowPayload(
            bytes32("op-b"), DESTINATION_KIND_EVM,
            bytes32(uint256(uint160(makeAddr("dest")))), 1000e18
        ));
        morpho.addPendingInterest(_marketId(), 100e18);

        // A's external repayment of 500 converts at the ACCRUED rate (total 2100, not 2000)
        _externalRepay(subaccountA, 500e18);
        vm.warp(vm.getBlockTimestamp() + 1);
        IMorphoLoanSubaccountRemote(subaccountB).checkpointFee();
        (uint256 principalB, , , , , ) = IMorphoLoanSubaccountRemote(subaccountB).getLoanFeeState();
        // B's share of the interest is exactly half: 1000 + 50; a stale-rate conversion
        // would have shifted this to ~1066
        assertApproxEqAbs(principalB, 1050e18, 1);
    }

    function testCheckpointPartitionPreservesTheFloorTotal() public {
        // two half-year checkpoints charge exactly the full-year floor; the
        // indivisible-partition test covers the sub-X18 truncation bound
        address subaccount = _borrowedSubaccount(1000e18);
        vm.warp(vm.getBlockTimestamp() + 365 days / 2);
        IMorphoLoanSubaccountRemote(subaccount).checkpointFee();
        (, uint256 halfYear, , , , ) = IMorphoLoanSubaccountRemote(subaccount).getLoanFeeState();
        assertEq(halfYear, 35e18 * 1e18);

        vm.warp(vm.getBlockTimestamp() + 365 days / 2);
        IMorphoLoanSubaccountRemote(subaccount).checkpointFee();
        (, uint256 fullYear, , , , ) = IMorphoLoanSubaccountRemote(subaccount).getLoanFeeState();
        assertEq(fullYear, 70e18 * 1e18);
    }

    function testZeroRatesAccrueNothing() public {
        // a deliberate fee-off type: configured recipient, zero rates - borrowing works and
        // the checkpoint charges nothing, interest or not
        _configureSettings();
        vm.startPrank(governance);
        _setFeeRates(0, 0);
        vm.stopPrank();
        address subaccount = address(_deploySubaccount());
        fxrp.mint(subaccount, 100e6);
        _deliver(subaccount, 1, 100e6, _borrowPayload(
            bytes32("op-borrow"), DESTINATION_KIND_EVM,
            bytes32(uint256(uint160(makeAddr("dest")))), 1000e18
        ));
        vm.warp(vm.getBlockTimestamp() + 365 days);
        morpho.addPendingInterest(_marketId(), 60e18);

        IMorphoLoanSubaccountRemote(subaccount).checkpointFee();
        (, uint256 feeDebtX18, , , , ) = IMorphoLoanSubaccountRemote(subaccount).getLoanFeeState();
        assertEq(feeDebtX18, 0);
    }

    function testSecondBorrowSettlesTheElapsedPeriodFirst() public {
        // the worked example's second year opening: the new borrow's pre-checkpoint prices
        // the elapsed period on the old base, and the post-sync capitalizes to the canonical
        // new debt - the borrowed amount is never classified as market interest
        address subaccount = _borrowedSubaccount(1000e18);
        vm.warp(vm.getBlockTimestamp() + 365 days);
        morpho.addPendingInterest(_marketId(), 60e18);

        // the packet brings 100 FXRP more, so the doubled debt stays under the cover
        // (200 FXRP = 4000 RLUSD against 1.5 x (2060 + 2 x 10) = 3120)
        fxrp.mint(subaccount, 100e6);
        _deliver(subaccount, 2, 100e6, _borrowPayload(
            bytes32("op-2"), DESTINATION_KIND_EVM,
            bytes32(uint256(uint160(makeAddr("dest")))), 1000e18
        ));
        (uint256 principal, , uint256 collectible, uint64 last, , ) =
            IMorphoLoanSubaccountRemote(subaccount).getLoanFeeState();
        assertApproxEqAbs(principal, 2060e18, 1);
        assertEq(collectible, 10e18);
        assertEq(last, vm.getBlockTimestamp());
    }

    function testCheckpointFeeRevertsUnregisteredType() public {
        _configureSettings();
        uint256 typeB = 2;
        vm.prank(governance);
        controller.setSubaccountImplementation(typeB, address(loanChainImpl));
        address subaccountB = address(new SubaccountProxy(
            address(controller), parentPersonalAccount, typeB
        ));
        vm.expectRevert(
            abi.encodeWithSelector(IMorphoLoanMarketsFacet.MarketNotRegistered.selector, typeB)
        );
        IMorphoLoanSubaccountRemote(subaccountB).checkpointFee();
    }

    function testRepayCollectsFeeThenPushesOnlyTheSurplus() public {
        // the pinned order: Morpho first, then the fee from the remainder, then the surplus -
        // closing through the rails costs the live debt plus the collectible, in one call
        address subaccount = _borrowedSubaccount(1000e18);
        vm.warp(vm.getBlockTimestamp() + 365 days);
        rlusd.mint(subaccount, 1100e18);

        vm.expectEmit();
        emit IMorphoLoanSubaccountRemote.LoanFeeCollected(makeAddr("feeCollector"), 70e18);
        vm.expectEmit();
        emit IMorphoLoanSubaccountRemote.LoanSurplusRecovered(parentPersonalAccount, 30e18);
        assertEq(IMorphoLoanSubaccountRemote(subaccount).repay(), 1000e18);
        assertEq(rlusd.balanceOf(makeAddr("feeCollector")), 70e18);
        assertEq(rlusd.balanceOf(parentPersonalAccount), 30e18);
        assertEq(rlusd.balanceOf(subaccount), 0);
        (, uint256 feeDebtX18, , , , ) = IMorphoLoanSubaccountRemote(subaccount).getLoanFeeState();
        assertEq(feeDebtX18, 0);
    }

    function testRepayPartialPaymentIsSplitProRata() public {
        // a payment short of debt plus fee is split pro rata: with debt 1000 and fee 70, a
        // 1050 payment pays the fee 1050 x 70 / 1070 (rounded down) and Morpho the rest, so
        // both shrink in the same 1000:70 proportion; the next payment covering what is left
        // closes the debt, pays the remaining fee and releases the surplus
        address subaccount = _borrowedSubaccount(1000e18);
        vm.warp(vm.getBlockTimestamp() + 365 days);
        rlusd.mint(subaccount, 1050e18);
        uint256 feeShare = uint256(1050e18) * 70e18 / 1070e18;

        vm.expectEmit();
        emit IMorphoLoanSubaccountRemote.LoanFeeCollected(makeAddr("feeCollector"), feeShare);
        vm.expectEmit();
        emit IMorphoLoanSubaccountRemote.LoanRepaid(parentPersonalAccount, 1050e18 - feeShare);
        assertEq(IMorphoLoanSubaccountRemote(subaccount).repay(), 1050e18 - feeShare);
        assertEq(rlusd.balanceOf(makeAddr("feeCollector")), feeShare);
        assertEq(rlusd.balanceOf(subaccount), 0);
        (uint256 principal, uint256 feeDebtX18, , , , ) =
            IMorphoLoanSubaccountRemote(subaccount).getLoanFeeState();
        assertEq(feeDebtX18, (70e18 - feeShare) * 1e18);
        assertApproxEqAbs(principal, 1000e18 - (1050e18 - feeShare), 1);
        // the proportion survives the split: 1000:70 before, the same after (within the
        // share's round-down and the debt's share-conversion wei, scaled)
        assertApproxEqAbs(principal * 70, (70e18 - feeShare) * 1000, 2000);

        rlusd.mint(subaccount, 30e18);
        IMorphoLoanSubaccountRemote(subaccount).repay();
        assertEq(rlusd.balanceOf(makeAddr("feeCollector")), 70e18);
        assertApproxEqAbs(rlusd.balanceOf(parentPersonalAccount), 10e18, 2);
        (, feeDebtX18, , , , ) = IMorphoLoanSubaccountRemote(subaccount).getLoanFeeState();
        assertEq(feeDebtX18, 0);
        (, uint128 borrowShares, ) = morpho.position(_marketId(), subaccount);
        assertEq(borrowShares, 0);
    }

    function testRepayFeeLegPaysWhilePaused() public {
        // the pause never holds a fee payment: the money goes to Flare's own recipient, so a
        // covering repay during a pause closes the debt, pays the fee and pushes the surplus
        // exactly as when unpaused - nothing is reserved
        address subaccount = _borrowedSubaccount(1000e18);
        vm.warp(vm.getBlockTimestamp() + 365 days);
        rlusd.mint(subaccount, 1100e18);
        _pauseController();

        vm.expectEmit();
        emit IMorphoLoanSubaccountRemote.LoanFeeCollected(makeAddr("feeCollector"), 70e18);
        vm.expectEmit();
        emit IMorphoLoanSubaccountRemote.LoanSurplusRecovered(parentPersonalAccount, 30e18);
        assertEq(IMorphoLoanSubaccountRemote(subaccount).repay(), 1000e18);
        assertEq(rlusd.balanceOf(makeAddr("feeCollector")), 70e18);
        assertEq(rlusd.balanceOf(parentPersonalAccount), 30e18);
        assertEq(rlusd.balanceOf(subaccount), 0);
    }

    function testRepayCoveringTheDebtButNotTheFeeLeavesBothOpenProRata() public {
        // the pinned strict rule: a payment that covers the debt but not the fee is still
        // split, leaving a pro-rata sliver of both (the rounding edge aside, pinned
        // separately) - closing the debt alone would hand a debt-first route to anyone who
        // sends exactly the debt
        address subaccount = _borrowedSubaccount(1000e18);
        vm.warp(vm.getBlockTimestamp() + 365 days);
        rlusd.mint(subaccount, 1000e18);
        uint256 feeShare = uint256(1000e18) * 70e18 / 1070e18;

        assertEq(IMorphoLoanSubaccountRemote(subaccount).repay(), 1000e18 - feeShare);
        assertEq(rlusd.balanceOf(makeAddr("feeCollector")), feeShare);
        (uint256 principal, uint256 feeDebtX18, , , , ) =
            IMorphoLoanSubaccountRemote(subaccount).getLoanFeeState();
        assertEq(feeDebtX18, (70e18 - feeShare) * 1e18);
        assertApproxEqAbs(principal, feeShare, 1);
        (, uint128 borrowShares, ) = morpho.position(_marketId(), subaccount);
        assertGt(borrowShares, 0);
    }

    function testRepayProRataFeeShareIsPaidWhilePaused() public {
        // a partial payment during a pause is split exactly as when unpaused: the fee's share
        // is paid, the rest repays Morpho
        address subaccount = _borrowedSubaccount(1000e18);
        vm.warp(vm.getBlockTimestamp() + 365 days);
        rlusd.mint(subaccount, 100e18);
        _pauseController();
        uint256 feeShare = uint256(100e18) * 70e18 / 1070e18;

        vm.expectEmit();
        emit IMorphoLoanSubaccountRemote.LoanFeeCollected(makeAddr("feeCollector"), feeShare);
        vm.expectEmit();
        emit IMorphoLoanSubaccountRemote.LoanRepaid(parentPersonalAccount, 100e18 - feeShare);
        assertEq(IMorphoLoanSubaccountRemote(subaccount).repay(), 100e18 - feeShare);
        assertEq(rlusd.balanceOf(makeAddr("feeCollector")), feeShare);
        assertEq(rlusd.balanceOf(subaccount), 0);
        (, uint256 feeDebtX18, , , , ) = IMorphoLoanSubaccountRemote(subaccount).getLoanFeeState();
        assertEq(feeDebtX18, (70e18 - feeShare) * 1e18);
    }

    function testRepayProRataRoundsTheFeeShareDown() public {
        // the fee's share is rounded down and the remainder goes to the debt: one wei against
        // debt 1000 and fee 70 pays no fee at all
        address subaccount = _borrowedSubaccount(1000e18);
        vm.warp(vm.getBlockTimestamp() + 365 days);
        rlusd.mint(subaccount, 1);

        assertEq(IMorphoLoanSubaccountRemote(subaccount).repay(), 1);
        assertEq(rlusd.balanceOf(makeAddr("feeCollector")), 0);
        (, uint256 feeDebtX18, , , , ) = IMorphoLoanSubaccountRemote(subaccount).getLoanFeeState();
        assertEq(feeDebtX18, 70e18 * 1e18);
    }

    function testRepayProRataRoundingRemainderCanCompleteTheDebt() public {
        // one wei short of debt plus fee: the fee's share rounds down to the fee less one
        // wei, the remainder is exactly the debt, and the debt closes by shares - the split
        // reaches the close only when its round-down leaves Morpho exactly the debt (an edge
        // one wei wide here, F/D wide in general - see the next test)
        address subaccount = _borrowedSubaccount(1000e18);
        vm.warp(vm.getBlockTimestamp() + 365 days);
        IMorphoLoanSubaccountRemote(subaccount).checkpointFee();
        (uint256 principal, , uint256 collectible, , , ) =
            IMorphoLoanSubaccountRemote(subaccount).getLoanFeeState();
        rlusd.mint(subaccount, principal + collectible - 1);

        vm.expectEmit();
        emit IMorphoLoanSubaccountRemote.LoanFeeCollected(makeAddr("feeCollector"), collectible - 1);
        assertEq(IMorphoLoanSubaccountRemote(subaccount).repay(), principal);
        assertEq(rlusd.balanceOf(makeAddr("feeCollector")), collectible - 1);
        assertEq(rlusd.balanceOf(subaccount), 0);
        (, uint128 borrowShares, ) = morpho.position(_marketId(), subaccount);
        assertEq(borrowShares, 0);
        // the one wei stays owed: a whole base unit is never forgiven
        (, uint256 feeDebtX18, , , , ) = IMorphoLoanSubaccountRemote(subaccount).getLoanFeeState();
        assertEq(feeDebtX18, 1e18);
    }

    function testRepayProRataRoundingEdgeWidensWhenTheFeeExceedsTheDebt() public {
        // the close-from-the-split edge is about F/D base units wide, not one: with debt 2
        // and fee 7 (after a debt-only external repayment) a payment four wei short of debt
        // plus fee rounds the fee share down by four and leaves Morpho exactly the debt
        _configureSettings();
        (, address subaccount) = _parentAndSubaccount("rWideEdgeOwner");
        fxrp.mint(subaccount, 100e6);
        _deliver(subaccount, 1, 100e6, _borrowPayload(
            bytes32("op-borrow"), DESTINATION_KIND_EVM,
            bytes32(uint256(uint160(makeAddr("dest")))), 100e18
        ));
        vm.warp(vm.getBlockTimestamp() + 365 days);
        _externalRepay(subaccount, 98e18);
        IMorphoLoanSubaccountRemote(subaccount).checkpointFee();
        (uint256 principal, , uint256 collectible, , , ) =
            IMorphoLoanSubaccountRemote(subaccount).getLoanFeeState();
        assertApproxEqAbs(principal, 2e18, 1);
        assertEq(collectible, 7e18);
        uint256 payment = principal + collectible - 4;
        uint256 feeShare = payment * collectible / (principal + collectible);
        assertEq(payment - feeShare, principal);
        rlusd.mint(subaccount, payment);

        vm.expectEmit();
        emit IMorphoLoanSubaccountRemote.LoanFeeCollected(makeAddr("feeCollector"), feeShare);
        assertEq(IMorphoLoanSubaccountRemote(subaccount).repay(), principal);
        (, uint128 borrowShares, ) = morpho.position(_marketId(), subaccount);
        assertEq(borrowShares, 0);
        assertEq(rlusd.balanceOf(subaccount), 0);
        (, uint256 feeDebtX18, , , , ) = IMorphoLoanSubaccountRemote(subaccount).getLoanFeeState();
        assertEq(feeDebtX18, (collectible - feeShare) * 1e18);
    }

    //
    // step 3: the exit gates
    //

    function testWithdrawForgivesDustOnDebtFreeExit() public {
        // a sub-unit remainder survives collection (round-down-and-carry) and, once the
        // position is debt-free, can never be paid or grow - the gate forgives it instead of
        // parking the exit forever
        _configureSettings();
        (, address subaccount) = _parentAndSubaccount("rDustExitOwner");
        fxrp.mint(subaccount, 100e6);
        _deliver(subaccount, 1, 100e6, _borrowPayload(
            bytes32("op-borrow"), DESTINATION_KIND_EVM,
            bytes32(uint256(uint160(makeAddr("dest")))), 1000e18
        ));
        vm.warp(vm.getBlockTimestamp() + 1);
        rlusd.mint(subaccount, 1100e18);
        IMorphoLoanSubaccountRemote(subaccount).repay();
        (, uint256 dustX18, uint256 collectible, , , ) =
            IMorphoLoanSubaccountRemote(subaccount).getLoanFeeState();
        assertEq(collectible, 0);
        assertGt(dustX18, 0);

        vm.expectEmit();
        emit IMorphoLoanSubaccountRemote.LoanFeeRemainderForgiven(dustX18);
        _deliverWithValue(
            subaccount, 2, 0,
            _withdrawPayload(bytes32("op-w"), 100e6),
            RETURN_MIN_VALUE
        );
        (, dustX18, , , , ) = IMorphoLoanSubaccountRemote(subaccount).getLoanFeeState();
        assertEq(dustX18, 0);
    }

    function testWithdrawWithinTheCoverPassesUncollected() public {
        // the exit gate: while the remaining collateral covers 1.5x the debt plus twice the
        // collectible fee, a withdrawal collects nothing - the position IS the fee's security
        _configureSettings();
        oracle.setPrice(2e48); // 1 FXRP = 2 RLUSD, the price these numbers are written at
        (, address subaccount) = _parentAndSubaccount("rSecuredOwner");
        fxrp.mint(subaccount, 100e6);
        _deliver(subaccount, 1, 100e6, _borrowPayload(
            bytes32("op-borrow"), DESTINATION_KIND_EVM,
            bytes32(uint256(uint160(makeAddr("dest")))), 100e18
        ));
        vm.warp(vm.getBlockTimestamp() + 30 days);
        IMorphoLoanSubaccountRemote(subaccount).checkpointFee();
        (, uint256 feeBefore, uint256 collectible, , , ) =
            IMorphoLoanSubaccountRemote(subaccount).getLoanFeeState();
        assertGt(collectible, 0);

        // remaining 90 FXRP is worth 180 RLUSD >= 1.5 x (100 + 2 x ~0.575) = ~151.7: no caps,
        // no collection
        assertGe(_valueOf(90e6), _requiredCover(100e18, collectible));
        _deliverWithValue(
            subaccount, 2, 0,
            _withdrawPayload(bytes32("op-w"), 10e6),
            RETURN_MIN_VALUE
        );
        assertEq(rlusd.balanceOf(makeAddr("feeCollector")), 0);
        assertEq(fxrp.balanceOf(makeAddr("feeCollector")), 0);
        (, uint256 feeAfter, , , , ) = IMorphoLoanSubaccountRemote(subaccount).getLoanFeeState();
        assertEq(feeAfter, feeBefore);
        (, , uint256 amountLD, , , , ) = fxrpOft.lastSendParam();
        assertEq(amountLD, 10e6);
    }

    function testWithdrawStrippingTheCoverIsBlockedUntilRepaid() public {
        // the exit that would leave the position uncovered is refused - nothing is taken from
        // the collateral; debt and fee are paid in loan tokens through repay, then the same
        // packet passes
        _configureSettings();
        oracle.setPrice(2e48); // 1 FXRP = 2 RLUSD, the price these numbers are written at
        (, address subaccount) = _parentAndSubaccount("rStrippingOwner");
        fxrp.mint(subaccount, 100e6);
        _deliver(subaccount, 1, 100e6, _borrowPayload(
            bytes32("op-borrow"), DESTINATION_KIND_EVM,
            bytes32(uint256(uint160(makeAddr("dest")))), 100e18
        ));
        vm.warp(vm.getBlockTimestamp() + 30 days);
        IMorphoLoanSubaccountRemote(subaccount).checkpointFee();
        (, , uint256 collectible, , , ) =
            IMorphoLoanSubaccountRemote(subaccount).getLoanFeeState();

        // remaining 2 FXRP (4 RLUSD) cannot cover the ~151.7 the position needs: refused, id
        // unconsumed
        bytes memory payload = _withdrawPayload(bytes32("op-w"), 98e6);
        (bytes memory message, bytes32 guid) = _composeMessage(subaccount, 2, 0, payload);
        vm.deal(lzEndpoint, RETURN_MIN_VALUE);
        vm.prank(lzEndpoint);
        vm.expectRevert(_uncovered(_requiredCover(100e18, collectible), 4e18));
        IMorphoLoanSubaccountRemote(subaccount).lzCompose{value: RETURN_MIN_VALUE}(
            address(fxrpOft), guid, message, executor, ""
        );
        assertFalse(IMorphoLoanSubaccountRemote(subaccount).usedOperations(bytes32("op-w")));
        assertEq(fxrp.balanceOf(makeAddr("feeCollector")), 0);

        // loan tokens to the account, repay closes the debt and pays the fee, the packet passes
        rlusd.mint(subaccount, 110e18);
        IMorphoLoanSubaccountRemote(subaccount).repay();
        assertEq(rlusd.balanceOf(makeAddr("feeCollector")), collectible);
        _deliverWithValue(subaccount, 2, 0, payload, RETURN_MIN_VALUE);
        assertTrue(IMorphoLoanSubaccountRemote(subaccount).usedOperations(bytes32("op-w")));
        (, , uint256 amountLD, , , , ) = fxrpOft.lastSendParam();
        assertEq(amountLD, 98e6);
    }

    function testWithdrawDeadOracleParksAndRepayIsTheEscape() public {
        // a reverting oracle values the remainder at nothing, so the gate refuses the exit:
        // the escape is repay - settle debt and fee through the subaccount, then the same
        // packet passes with nothing owed, oracle-free
        _configureSettings();
        oracle.setPrice(2e48); // 1 FXRP = 2 RLUSD, the price these numbers are written at
        (, address subaccount) = _parentAndSubaccount("rDeadOracleGateOwner");
        fxrp.mint(subaccount, 100e6);
        _deliver(subaccount, 1, 100e6, _borrowPayload(
            bytes32("op-borrow"), DESTINATION_KIND_EVM,
            bytes32(uint256(uint160(makeAddr("dest")))), 100e18
        ));
        vm.warp(vm.getBlockTimestamp() + 30 days);
        IMorphoLoanSubaccountRemote(subaccount).checkpointFee();
        (, , uint256 collectible, , , ) =
            IMorphoLoanSubaccountRemote(subaccount).getLoanFeeState();
        // a live oracle would pass this withdrawal (180 left against ~151.7); the dead one
        // values the remainder at nothing
        assertGe(_valueOf(90e6), _requiredCover(100e18, collectible));
        oracle.setPriceReverts(true);

        bytes memory payload = _withdrawPayload(bytes32("op-w"), 10e6);
        (bytes memory message, bytes32 guid) = _composeMessage(subaccount, 2, 0, payload);
        vm.deal(lzEndpoint, RETURN_MIN_VALUE);
        vm.prank(lzEndpoint);
        vm.expectRevert(_uncovered(_requiredCover(100e18, collectible), 0));
        IMorphoLoanSubaccountRemote(subaccount).lzCompose{value: RETURN_MIN_VALUE}(
            address(fxrpOft), guid, message, executor, ""
        );

        rlusd.mint(subaccount, 110e18);
        IMorphoLoanSubaccountRemote(subaccount).repay();
        _deliverWithValue(subaccount, 2, 0, payload, RETURN_MIN_VALUE);
        assertTrue(IMorphoLoanSubaccountRemote(subaccount).usedOperations(bytes32("op-w")));
    }

    function testWithdrawZeroPricedOracleRefusesAndRepayIsTheEscape() public {
        // a zero price (answering, not reverting) also values the remainder at nothing: the
        // same refusal with the id unconsumed, and the same escape - once nothing is owed the
        // retried packet passes without ever reading the still-zero oracle
        _configureSettings();
        oracle.setPrice(2e48); // 1 FXRP = 2 RLUSD, the price these numbers are written at
        (, address subaccount) = _parentAndSubaccount("rZeroPriceGateOwner");
        fxrp.mint(subaccount, 100e6);
        _deliver(subaccount, 1, 100e6, _borrowPayload(
            bytes32("op-borrow"), DESTINATION_KIND_EVM,
            bytes32(uint256(uint160(makeAddr("dest")))), 100e18
        ));
        vm.warp(vm.getBlockTimestamp() + 30 days);
        IMorphoLoanSubaccountRemote(subaccount).checkpointFee();
        (, , uint256 collectible, , , ) =
            IMorphoLoanSubaccountRemote(subaccount).getLoanFeeState();
        assertGe(_valueOf(90e6), _requiredCover(100e18, collectible));
        oracle.setPrice(0);

        bytes memory payload = _withdrawPayload(bytes32("op-w"), 10e6);
        (bytes memory message, bytes32 guid) = _composeMessage(subaccount, 2, 0, payload);
        vm.deal(lzEndpoint, RETURN_MIN_VALUE);
        vm.prank(lzEndpoint);
        vm.expectRevert(_uncovered(_requiredCover(100e18, collectible), 0));
        IMorphoLoanSubaccountRemote(subaccount).lzCompose{value: RETURN_MIN_VALUE}(
            address(fxrpOft), guid, message, executor, ""
        );
        assertFalse(IMorphoLoanSubaccountRemote(subaccount).usedOperations(bytes32("op-w")));

        rlusd.mint(subaccount, 110e18);
        IMorphoLoanSubaccountRemote(subaccount).repay();
        assertEq(rlusd.balanceOf(makeAddr("feeCollector")), collectible);
        _deliverWithValue(subaccount, 2, 0, payload, RETURN_MIN_VALUE);
        assertTrue(IMorphoLoanSubaccountRemote(subaccount).usedOperations(bytes32("op-w")));
        assertEq(oracle.storedPrice(), 0);
    }

    function testDeadOracleWithLiveDebtRefusesAtTheGateNotAtMorpho() public {
        // canonical Morpho reads the oracle in withdrawCollateral while borrow shares are live,
        // so a dead oracle would block a live-debt withdrawal there too - but the gate comes
        // first and refuses on its own, valuing the remainder at nothing, with nothing
        // collectible and the id unconsumed. The escape is the spec's: settle through repay
        // (no shares, no health check, no oracle), then the packet passes oracle-free
        morpho.setHealthCheckDisabled(false);
        _configureSettings();
        (, address subaccount) = _parentAndSubaccount("rMorphoDeadOracleOwner");
        fxrp.mint(subaccount, 1000e6);
        _deliver(subaccount, 1, 1000e6, _borrowPayload(
            bytes32("op-borrow"), DESTINATION_KIND_EVM,
            bytes32(uint256(uint160(makeAddr("dest")))), 500e18
        ));
        oracle.setPriceReverts(true);

        bytes memory payload = _withdrawPayload(bytes32("op-w"), 10e6);
        (bytes memory message, bytes32 guid) = _composeMessage(subaccount, 2, 0, payload);
        vm.deal(lzEndpoint, RETURN_MIN_VALUE);
        vm.prank(lzEndpoint);
        vm.expectRevert(_uncovered(_requiredCover(500e18, 0), 0));
        IMorphoLoanSubaccountRemote(subaccount).lzCompose{value: RETURN_MIN_VALUE}(
            address(fxrpOft), guid, message, executor, ""
        );
        assertFalse(IMorphoLoanSubaccountRemote(subaccount).usedOperations(bytes32("op-w")));

        rlusd.mint(subaccount, 501e18);
        IMorphoLoanSubaccountRemote(subaccount).repay();
        _deliverWithValue(subaccount, 2, 0, payload, RETURN_MIN_VALUE);
        assertTrue(IMorphoLoanSubaccountRemote(subaccount).usedOperations(bytes32("op-w")));
        assertTrue(oracle.priceReverts());
    }

    function testExitGateIsStricterThanMorphoHealth() public {
        // the gate is Morpho's liquidation line with a 15.5% headroom (1.5x at LLTV 77%), so it
        // implies Morpho's health check: a fresh 1000 RLUSD loan on 1000 FXRP (2000 RLUSD) may
        // run down to 1299 RLUSD of collateral at Morpho, but the gate keeps 1500 RLUSD = 750
        // FXRP in the position - with nothing collectible, the debt alone sets the cover
        morpho.setHealthCheckDisabled(false);
        _configureSettings();
        oracle.setPrice(2e48); // 1 FXRP = 2 RLUSD, the price these numbers are written at
        (, address subaccount) = _parentAndSubaccount("rMorphoHealthOwner");
        fxrp.mint(subaccount, 1000e6);
        _deliver(subaccount, 1, 1000e6, _borrowPayload(
            bytes32("op-borrow"), DESTINATION_KIND_EVM,
            bytes32(uint256(uint160(makeAddr("dest")))), 1000e18
        ));

        // Morpho alone allows 350 FXRP out (650 left = 1300 RLUSD x 77% = 1001 >= 1000) - proved
        // directly and rolled back, so the gate is the only thing in the way below
        uint256 snapshot = vm.snapshotState();
        vm.prank(subaccount);
        morpho.withdrawCollateral(_defaultMarket().marketParams, 350e6, subaccount, subaccount);
        vm.revertToState(snapshot);

        // 251 out leaves 749 FXRP = 1498 RLUSD < 1500: refused by the gate, id unconsumed
        bytes memory tooMuch = _withdrawPayload(bytes32("op-w"), 251e6);
        (bytes memory message, bytes32 guid) = _composeMessage(subaccount, 2, 0, tooMuch);
        vm.deal(lzEndpoint, RETURN_MIN_VALUE);
        vm.prank(lzEndpoint);
        vm.expectRevert(_uncovered(1500e18, 1498e18));
        IMorphoLoanSubaccountRemote(subaccount).lzCompose{value: RETURN_MIN_VALUE}(
            address(fxrpOft), guid, message, executor, ""
        );
        assertFalse(IMorphoLoanSubaccountRemote(subaccount).usedOperations(bytes32("op-w")));

        // 250 out leaves exactly 1500: the boundary passes
        _deliverWithValue(
            subaccount, 2, 0, _withdrawPayload(bytes32("op-w"), 250e6), RETURN_MIN_VALUE
        );
        assertTrue(IMorphoLoanSubaccountRemote(subaccount).usedOperations(bytes32("op-w")));
        (, , uint128 collateral) = morpho.position(_marketId(), subaccount);
        assertEq(collateral, 750e6);
    }

    function testOverlapTopUpOnTheSubaccountPaysTheFeeProRata() public {
        // the band the gate's headroom opens: with live debt, a remainder Morpho's health check
        // accepts (debt <= 77% of it) can still fall short of the cover - here after a debt-only
        // external repayment left a large fee next to a small debt. Subaccount RLUSD pays the
        // fee pro rata with the debt, so a top-up shrinks both claims - here enough for the gate
        // to pass with the loan still open
        morpho.setHealthCheckDisabled(false);
        _configureSettings();
        oracle.setPrice(2e48); // 1 FXRP = 2 RLUSD, the price these numbers are written at
        (, address subaccount) = _parentAndSubaccount("rOverlapOwner");
        fxrp.mint(subaccount, 100e6);
        _deliver(subaccount, 1, 100e6, _borrowPayload(
            bytes32("op-borrow"), DESTINATION_KIND_EVM,
            bytes32(uint256(uint160(makeAddr("dest")))), 100e18
        ));
        vm.warp(vm.getBlockTimestamp() + 365 days);
        // a year's fee on the 100 borrowed is 7; the debt then drops to 10 outside the rails
        _externalRepay(subaccount, 90e18);

        // Morpho itself allows exactly this withdrawal at the live debt - 8 FXRP left = 16 RLUSD
        // carries 12.32 at LLTV 77% - proved directly and rolled back, so the gate is the only
        // thing in the way below
        uint256 snapshot = vm.snapshotState();
        vm.prank(subaccount);
        morpho.withdrawCollateral(_defaultMarket().marketParams, 92e6, subaccount, subaccount);
        vm.revertToState(snapshot);

        // the gate wants 1.5 x (10 + 2 x 7) = 36 against the 16 left - refused, id unconsumed
        IMorphoLoanSubaccountRemote(subaccount).checkpointFee();
        (uint256 debt, , uint256 collectible, , , ) =
            IMorphoLoanSubaccountRemote(subaccount).getLoanFeeState();
        assertEq(collectible, 7e18);
        assertApproxEqAbs(debt, 10e18, 1);
        bytes memory payload = _withdrawPayload(bytes32("op-w"), 92e6);
        (bytes memory message, bytes32 guid) = _composeMessage(subaccount, 2, 0, payload);
        vm.deal(lzEndpoint, RETURN_MIN_VALUE);
        vm.prank(lzEndpoint);
        vm.expectRevert(_uncovered(_requiredCover(debt, collectible), 16e18));
        IMorphoLoanSubaccountRemote(subaccount).lzCompose{value: RETURN_MIN_VALUE}(
            address(fxrpOft), guid, message, executor, ""
        );
        assertFalse(IMorphoLoanSubaccountRemote(subaccount).usedOperations(bytes32("op-w")));

        // a 10 RLUSD top-up is split 10 x 7 / 17 to the fee and 10 x 10 / 17 to the debt: the
        // fee falls to ~2.88 and the debt to ~4.12, still 10:7, and the cover to
        // 1.5 x (4.12 + 2 x 2.88) = ~14.8 <= 16
        rlusd.mint(subaccount, 10e18);
        uint256 feeShare = Math.mulDiv(10e18, collectible, debt + collectible);
        IMorphoLoanSubaccountRemote(subaccount).repay();
        assertEq(rlusd.balanceOf(makeAddr("feeCollector")), feeShare);
        (uint256 principal, , uint256 collectibleAfter, , , ) =
            IMorphoLoanSubaccountRemote(subaccount).getLoanFeeState();
        assertEq(collectibleAfter, collectible - feeShare);
        assertApproxEqAbs(principal, debt - (10e18 - feeShare), 1);
        assertLe(_requiredCover(principal, collectibleAfter), 16e18);

        // the same packet now passes, the debt still open
        _deliverWithValue(subaccount, 2, 0, payload, RETURN_MIN_VALUE);
        assertTrue(IMorphoLoanSubaccountRemote(subaccount).usedOperations(bytes32("op-w")));
        (, , uint256 amountLD, , , , ) = fxrpOft.lastSendParam();
        assertEq(amountLD, 92e6);
        (, uint128 borrowShares, ) = morpho.position(_marketId(), subaccount);
        assertGt(borrowShares, 0);
    }

    function testCoverGateIsStricterThanMorphoHealthOnBorrow() public {
        // the borrow side of the gate: 100 FXRP = 200 RLUSD carry at most 154 RLUSD at Morpho's
        // 77% LLTV but only 133.33 under the cover (1.5 x D <= 200). Morpho's check runs first,
        // inside its borrow: 1000 reverts there; 134 passes Morpho and is refused by the gate
        // (cover 201 > 200) with nothing supplied or disbursed and the id unconsumed; 133 executes
        morpho.setHealthCheckDisabled(false);
        address subaccount = _createConfiguredSubaccount();
        oracle.setPrice(2e48);
        fxrp.mint(subaccount, 100e6);
        bytes32 dest = bytes32(uint256(uint160(makeAddr("dest"))));

        _deliverExpectRevert(
            subaccount, 1, _borrowPayload(bytes32("op-1"), DESTINATION_KIND_EVM, dest, 1000e18),
            bytes("insufficient collateral")
        );
        _deliverExpectRevert(
            subaccount, 1, _borrowPayload(bytes32("op-1"), DESTINATION_KIND_EVM, dest, 134e18),
            _uncovered(201e18, 200e18)
        );
        assertFalse(IMorphoLoanSubaccountRemote(subaccount).usedOperations(bytes32("op-1")));
        assertEq(fxrp.balanceOf(subaccount), 100e6);
        assertEq(rlusd.balanceOf(makeAddr("dest")), 0);

        _deliver(
            subaccount, 1, 100e6,
            _borrowPayload(bytes32("op-1"), DESTINATION_KIND_EVM, dest, 133e18)
        );
        assertTrue(IMorphoLoanSubaccountRemote(subaccount).usedOperations(bytes32("op-1")));
        assertEq(rlusd.balanceOf(makeAddr("dest")), 133e18);
        (, , uint128 collateral) = morpho.position(_marketId(), subaccount);
        assertEq(collateral, 100e6);
    }

    function testBorrowGateCountsTheFeeAndTheSuppliedCredit() public {
        // the gate on a second borrow counts the fee twice and the credit the packet brings: 100
        // borrowed on 100 FXRP (200 RLUSD) a year ago owes 7 of fee; a packet bringing 100 FXRP
        // more (400 RLUSD in all) may add at most 152.67 - 1.5 x (100 + b + 14) <= 400. 153 is
        // refused with the whole delivery rolled back (the credit stays idle, the id unconsumed),
        // 152 executes, supplying the credit with it
        _configureSettings();
        oracle.setPrice(2e48);
        (, address subaccount) = _parentAndSubaccount("rBorrowFeeOwner");
        bytes32 dest = bytes32(uint256(uint160(makeAddr("dest"))));
        fxrp.mint(subaccount, 100e6);
        _deliver(
            subaccount, 1, 100e6, _borrowPayload(bytes32("op-1"), DESTINATION_KIND_EVM, dest, 100e18)
        );
        vm.warp(vm.getBlockTimestamp() + 365 days);
        fxrp.mint(subaccount, 100e6);

        _deliverExpectRevert(
            subaccount, 2, _borrowPayload(bytes32("op-2"), DESTINATION_KIND_EVM, dest, 153e18),
            _uncovered(_requiredCover(253e18, 7e18), 400e18)
        );
        assertFalse(IMorphoLoanSubaccountRemote(subaccount).usedOperations(bytes32("op-2")));
        assertEq(fxrp.balanceOf(subaccount), 100e6);
        (, , uint128 collateral) = morpho.position(_marketId(), subaccount);
        assertEq(collateral, 100e6);
        assertEq(rlusd.balanceOf(makeAddr("dest")), 100e18);

        _deliver(
            subaccount, 2, 100e6, _borrowPayload(bytes32("op-2"), DESTINATION_KIND_EVM, dest, 152e18)
        );
        assertTrue(IMorphoLoanSubaccountRemote(subaccount).usedOperations(bytes32("op-2")));
        assertEq(fxrp.balanceOf(subaccount), 0);
        (, , collateral) = morpho.position(_marketId(), subaccount);
        assertEq(collateral, 200e6);
        assertEq(rlusd.balanceOf(makeAddr("dest")), 252e18);
        (uint256 principal, , uint256 collectible, , , ) =
            IMorphoLoanSubaccountRemote(subaccount).getLoanFeeState();
        assertEq(principal, 252e18);
        assertEq(collectible, 7e18);
    }

    function testDeadOracleBlocksBorrowAtMorphoThenAtTheGate() public {
        // canonical Morpho reads the oracle inside borrow, so a dead oracle refuses there first;
        // the gate's own refusal, valuing the collateral at nothing, is observable with Morpho's
        // check switched off. Either way nothing is supplied, the id stays unconsumed and the
        // same packet borrows once the oracle answers again
        morpho.setHealthCheckDisabled(false);
        address subaccount = _createConfiguredSubaccount();
        fxrp.mint(subaccount, 100e6);
        bytes memory payload = _borrowPayload(
            bytes32("op-1"), DESTINATION_KIND_EVM, bytes32(uint256(uint160(makeAddr("dest")))), 100e18
        );
        oracle.setPriceReverts(true);

        _deliverExpectRevert(subaccount, 1, payload, bytes("oracle reverted"));
        assertFalse(IMorphoLoanSubaccountRemote(subaccount).usedOperations(bytes32("op-1")));
        assertEq(fxrp.balanceOf(subaccount), 100e6);

        morpho.setHealthCheckDisabled(true);
        _deliverExpectRevert(subaccount, 1, payload, _uncovered(_requiredCover(100e18, 0), 0));
        assertFalse(IMorphoLoanSubaccountRemote(subaccount).usedOperations(bytes32("op-1")));
        assertEq(fxrp.balanceOf(subaccount), 100e6);

        oracle.setPriceReverts(false);
        _deliver(subaccount, 1, 100e6, payload);
        assertTrue(IMorphoLoanSubaccountRemote(subaccount).usedOperations(bytes32("op-1")));
        assertEq(rlusd.balanceOf(makeAddr("dest")), 100e18);
    }

    //
    // the read surface: quotes computed by the code the actions enforce
    //

    function testGetLoanPositionMatchesACheckpointInTheSameBlock() public {
        // the projection is what a checkpoint in this block stores: Morpho's debt brought forward
        // at the rate model's rate, the fee's running period priced at the snapshotted terms.
        // 1000 borrowed at ~5% a year, 100 days on: the view's debt and fee equal the stored ones
        // after checkpointFee, and a second read in the same block repeats them
        address subaccount = _borrowedSubaccount(1000e18);
        irm.setRate(1585489599);
        vm.warp(vm.getBlockTimestamp() + 100 days);

        IMorphoLoanSubaccountRemote.LoanPosition memory projected =
            IMorphoLoanSubaccountRemote(subaccount).getLoanPosition();
        assertGt(projected.debt, 1000e18);
        assertGt(projected.feeDebtX18, 0);
        IMorphoLoanSubaccountRemote(subaccount).checkpointFee();
        (uint256 principal, uint256 feeDebtX18, uint256 collectible, , , ) =
            IMorphoLoanSubaccountRemote(subaccount).getLoanFeeState();
        assertEq(principal, projected.debt);
        assertEq(feeDebtX18, projected.feeDebtX18);
        assertEq(collectible, projected.feeDebtX18 / 1e18);

        IMorphoLoanSubaccountRemote.LoanPosition memory again =
            IMorphoLoanSubaccountRemote(subaccount).getLoanPosition();
        assertEq(again.debt, projected.debt);
        assertEq(again.feeDebtX18, projected.feeDebtX18);
    }

    function testGetLoanPositionReportsBalancesPriceCoverAndHealth() public {
        // the position's plain facts: collateral in and beside the position, loan tokens waiting
        // for repay, the price, value, LLTV, the gate's demand and Morpho's health factor -
        // and a dead oracle reported as zeros, the cover unchanged
        address subaccount = _createConfiguredSubaccount();
        fxrp.mint(subaccount, 100e6);
        _deliver(subaccount, 1, 100e6, _depositPayload());

        IMorphoLoanSubaccountRemote.LoanPosition memory p =
            IMorphoLoanSubaccountRemote(subaccount).getLoanPosition();
        assertEq(p.collateral, 100e6);
        assertEq(p.debt, 0);
        assertEq(p.requiredCover, 0);
        assertEq(p.morphoHealthFactor, type(uint256).max);

        _deliver(subaccount, 2, 0, _borrowPayload(
            bytes32("op-2"), DESTINATION_KIND_EVM,
            bytes32(uint256(uint160(makeAddr("dest")))), 500e18
        ));
        fxrp.mint(subaccount, 5e6);
        rlusd.mint(subaccount, 3e18);
        p = IMorphoLoanSubaccountRemote(subaccount).getLoanPosition();
        assertEq(p.collateral, 100e6);
        assertEq(p.idleCollateral, 5e6);
        assertEq(p.idleLoanToken, 3e18);
        assertEq(p.debt, 500e18);
        assertEq(p.feeDebtX18, 0);
        assertEq(p.oraclePrice, 2e49);
        assertEq(p.collateralValue, 2000e18);
        assertEq(p.lltv, 0.77e18);
        assertEq(p.requiredCover, 750e18);
        // 2000 x 0.77 / 500
        assertEq(p.morphoHealthFactor, 3.08e18);

        oracle.setPriceReverts(true);
        p = IMorphoLoanSubaccountRemote(subaccount).getLoanPosition();
        assertEq(p.oraclePrice, 0);
        assertEq(p.collateralValue, 0);
        assertEq(p.morphoHealthFactor, 0);
        assertEq(p.requiredCover, 750e18);
    }

    function testGetLoanLimitsBorrowBoundIsExact() public {
        // 100 FXRP in the position, 20 idle, 30 with the packet: 150 FXRP = 300 RLUSD carry
        // 300 x 0.77 / 1.155 = 200 under the cover - one unit more is refused, the bound
        // executes with the credit supplied, and sitting at the cover nothing more is allowed
        address subaccount = _createConfiguredSubaccount();
        oracle.setPrice(2e48);
        fxrp.mint(subaccount, 100e6);
        _deliver(subaccount, 1, 100e6, _depositPayload());
        fxrp.mint(subaccount, 20e6);
        bytes32 dest = bytes32(uint256(uint160(makeAddr("dest"))));

        IMorphoLoanSubaccountRemote.LoanLimits memory limits =
            IMorphoLoanSubaccountRemote(subaccount).getLoanLimits(30e6);
        assertEq(limits.maxBorrowByCover, 200e18);
        assertEq(limits.maxWithdraw, 100e6);
        assertEq(limits.marketLiquidity, 1e30);

        uint256 snapshot = vm.snapshotState();
        fxrp.mint(subaccount, 30e6);
        _deliverExpectRevert(
            subaccount, 2, _borrowPayload(bytes32("op-2"), DESTINATION_KIND_EVM, dest, 200e18 + 1),
            _uncovered(_requiredCover(200e18 + 1, 0), 300e18)
        );
        vm.revertToState(snapshot);

        fxrp.mint(subaccount, 30e6);
        _deliver(subaccount, 2, 30e6, _borrowPayload(bytes32("op-2"), DESTINATION_KIND_EVM, dest, 200e18));
        (, , uint128 collateral) = morpho.position(_marketId(), subaccount);
        assertEq(collateral, 150e6);
        limits = IMorphoLoanSubaccountRemote(subaccount).getLoanLimits(0);
        assertEq(limits.maxBorrowByCover, 0);
        assertEq(limits.maxWithdraw, 0);
    }

    function testGetLoanLimitsWithdrawBoundIsExactAndLiquidityIsSeparate() public {
        // 100 borrowed on 200 FXRP a year ago: the cover 1.5 x (100 + 14) = 171 RLUSD keeps 85.5
        // FXRP, so 114.5 may leave - one unit more is refused. The pool's liquidity is its own
        // bound: with 150 supplied against 100 borrowed, 50 remain, and Morpho refuses 51 where
        // the cover would have allowed it
        address subaccount = _createConfiguredSubaccount();
        oracle.setPrice(2e48);
        fxrp.mint(subaccount, 200e6);
        bytes32 dest = bytes32(uint256(uint160(makeAddr("dest"))));
        _deliver(subaccount, 1, 200e6, _borrowPayload(bytes32("op-1"), DESTINATION_KIND_EVM, dest, 100e18));
        vm.warp(vm.getBlockTimestamp() + 365 days);
        morpho.setTotalSupplyAssets(_marketId(), 150e18);

        IMorphoLoanSubaccountRemote.LoanLimits memory limits =
            IMorphoLoanSubaccountRemote(subaccount).getLoanLimits(0);
        assertEq(limits.maxWithdraw, 114.5e6);
        assertEq(limits.marketLiquidity, 50e18);
        assertGt(limits.maxBorrowByCover, 51e18);

        uint256 snapshot = vm.snapshotState();
        bytes memory tooMuch = _withdrawPayload(bytes32("op-w"), 114.5e6 + 1);
        (bytes memory message, bytes32 guid) = _composeMessage(subaccount, 2, 0, tooMuch);
        bytes memory refusal = _uncovered(171e18, _valueOf(85.5e6 - 1));
        vm.deal(lzEndpoint, RETURN_MIN_VALUE);
        vm.prank(lzEndpoint);
        vm.expectRevert(refusal);
        IMorphoLoanSubaccountRemote(subaccount).lzCompose{value: RETURN_MIN_VALUE}(
            address(fxrpOft), guid, message, executor, ""
        );
        _deliverWithValue(subaccount, 2, 0, _withdrawPayload(bytes32("op-w"), 114.5e6), RETURN_MIN_VALUE);
        assertTrue(IMorphoLoanSubaccountRemote(subaccount).usedOperations(bytes32("op-w")));
        vm.revertToState(snapshot);

        (bytes memory borrowMessage, bytes32 borrowGuid) = _composeMessage(
            subaccount, 3, 0, _borrowPayload(bytes32("op-3"), DESTINATION_KIND_EVM, dest, 51e18)
        );
        vm.prank(lzEndpoint);
        vm.expectRevert(bytes("insufficient liquidity"));
        IMorphoLoanSubaccountRemote(subaccount).lzCompose(address(fxrpOft), borrowGuid, borrowMessage, executor, "");
        _deliver(subaccount, 3, 0, _borrowPayload(bytes32("op-3"), DESTINATION_KIND_EVM, dest, 50e18));
        assertTrue(IMorphoLoanSubaccountRemote(subaccount).usedOperations(bytes32("op-3")));
    }

    function testPreviewRepayMatchesRepay() public {
        // the expected allocation is the actual one when the collector accepts: a partial
        // payment's pro-rata split, then a closing top-up's fee, debt and surplus
        _configureSettings();
        (address parent, address subaccount) = _borrowedPairWithFee("rPreviewRepayOwner");
        rlusd.mint(subaccount, 30e18);
        IMorphoLoanSubaccountRemote.RepayPreview memory q =
            IMorphoLoanSubaccountRemote(subaccount).previewRepay(100e18);
        assertEq(q.feePaid, uint256(130e18) * 70e18 / 1070e18);
        assertEq(q.debtPaid, 130e18 - q.feePaid);
        assertEq(q.surplus, 0);
        assertEq(q.closingTopUp, 1070e18 - 30e18);

        rlusd.mint(subaccount, 100e18);
        uint256 collectorBefore = rlusd.balanceOf(makeAddr("feeCollector"));
        assertEq(IMorphoLoanSubaccountRemote(subaccount).repay(), q.debtPaid);
        assertEq(rlusd.balanceOf(makeAddr("feeCollector")) - collectorBefore, q.feePaid);
        (uint256 principal, , uint256 collectible, , , ) =
            IMorphoLoanSubaccountRemote(subaccount).getLoanFeeState();
        assertEq(principal, q.debtAfter);
        assertEq(collectible, q.collectibleAfter);
        assertEq(rlusd.balanceOf(parent), 0);

        q = IMorphoLoanSubaccountRemote(subaccount).previewRepay(principal + collectible + 1e18);
        assertEq(q.closingTopUp, principal + collectible);
        assertEq(q.feePaid, collectible);
        assertEq(q.debtPaid, principal);
        assertEq(q.surplus, 1e18);
        assertEq(q.debtAfter, 0);
        assertEq(q.collectibleAfter, 0);
        rlusd.mint(subaccount, principal + collectible + 1e18);
        collectorBefore = rlusd.balanceOf(makeAddr("feeCollector"));
        assertEq(IMorphoLoanSubaccountRemote(subaccount).repay(), q.debtPaid);
        assertEq(rlusd.balanceOf(makeAddr("feeCollector")) - collectorBefore, q.feePaid);
        assertEq(rlusd.balanceOf(parent), q.surplus);
        (principal, , collectible, , , ) = IMorphoLoanSubaccountRemote(subaccount).getLoanFeeState();
        assertEq(principal, 0);
        assertEq(collectible, 0);
    }

    function testPreviewRepayIsExpectedNotGuaranteedUnderAFrozenCollector() public {
        // the documented caveat, pinned: the preview assumes the fee transfer succeeds; with the
        // collector frozen, repay defers the share to the debt instead, so the actual fee paid
        // is zero and the debt repaid is the whole payment
        _configureSettings();
        uint256 typeB = 2;
        MockFreezableToken frozenRlusd = new MockFreezableToken("Frozen RLUSD", "RLUSD", 18);
        IMorphoLoanMarketsFacet.Market memory marketB = _defaultMarket();
        marketB.marketParams.loanToken = address(frozenRlusd);
        morpho.createMarket(marketB.marketParams);
        vm.startPrank(governance);
        controller.setSubaccountImplementation(typeB, address(loanChainImpl));
        IIMorphoLoanMarketsFacet(address(controller)).registerLoanMarket(typeB, marketB);
        _setDefaultFeeTerms(address(controller), typeB);
        vm.stopPrank();
        address subaccount = controller.createSubaccount("rFrozenPreviewOwner", typeB);
        fxrp.mint(subaccount, 100e6);
        _deliver(subaccount, 1, 100e6, _borrowPayload(
            bytes32("op-frz"), DESTINATION_KIND_EVM,
            bytes32(uint256(uint160(makeAddr("dest")))), 1000e18
        ));
        vm.warp(vm.getBlockTimestamp() + 365 days);
        frozenRlusd.mint(subaccount, 100e18);
        frozenRlusd.setFrozen(makeAddr("feeCollector"), true);

        IMorphoLoanSubaccountRemote.RepayPreview memory q = IMorphoLoanSubaccountRemote(subaccount).previewRepay(0);
        assertEq(q.feePaid, uint256(100e18) * 70e18 / 1070e18);
        assertEq(q.debtPaid, 100e18 - q.feePaid);

        assertEq(IMorphoLoanSubaccountRemote(subaccount).repay(), 100e18);
        assertEq(frozenRlusd.balanceOf(makeAddr("feeCollector")), 0);
        (, , uint256 collectible, , , ) = IMorphoLoanSubaccountRemote(subaccount).getLoanFeeState();
        assertEq(collectible, 70e18);
    }

    function testPreviewWithdrawMinimumTopUpIsExact() public {
        // the overlap scenario: 92 of 100 FXRP out is refused at 16 against 36; the preview's
        // minimum top-up, repaid, makes the same packet pass, and one unit less does not
        _configureSettings();
        oracle.setPrice(2e48);
        (, address subaccount) = _parentAndSubaccount("rMinTopUpOwner");
        fxrp.mint(subaccount, 100e6);
        _deliver(subaccount, 1, 100e6, _borrowPayload(
            bytes32("op-borrow"), DESTINATION_KIND_EVM,
            bytes32(uint256(uint160(makeAddr("dest")))), 100e18
        ));
        vm.warp(vm.getBlockTimestamp() + 365 days);
        _externalRepay(subaccount, 90e18);

        IMorphoLoanSubaccountRemote.WithdrawPreview memory w =
            IMorphoLoanSubaccountRemote(subaccount).previewWithdraw(92e6);
        assertFalse(w.coverSatisfied);
        assertEq(
            w.requiredCover,
            _requiredCover(IMorphoLoanSubaccountRemote(subaccount).getLoanPosition().debt, 7e18)
        );
        assertEq(w.remainingValue, 16e18);
        assertGt(w.minimumTopUp, 9e18);
        assertLt(w.minimumTopUp, 10e18);

        bytes memory payload = _withdrawPayload(bytes32("op-w"), 92e6);
        uint256 snapshot = vm.snapshotState();
        rlusd.mint(subaccount, w.minimumTopUp - 1);
        IMorphoLoanSubaccountRemote(subaccount).repay();
        assertFalse(IMorphoLoanSubaccountRemote(subaccount).previewWithdraw(92e6).coverSatisfied);
        IMorphoLoanSubaccountRemote.WithdrawPreview memory short_ =
            IMorphoLoanSubaccountRemote(subaccount).previewWithdraw(92e6);
        (bytes memory message, bytes32 guid) = _composeMessage(subaccount, 2, 0, payload);
        vm.deal(lzEndpoint, RETURN_MIN_VALUE);
        vm.prank(lzEndpoint);
        vm.expectRevert(_uncovered(short_.requiredCover, short_.remainingValue));
        IMorphoLoanSubaccountRemote(subaccount).lzCompose{value: RETURN_MIN_VALUE}(
            address(fxrpOft), guid, message, executor, ""
        );
        vm.revertToState(snapshot);

        rlusd.mint(subaccount, w.minimumTopUp);
        IMorphoLoanSubaccountRemote(subaccount).repay();
        assertTrue(IMorphoLoanSubaccountRemote(subaccount).previewWithdraw(92e6).coverSatisfied);
        _deliverWithValue(subaccount, 2, 0, payload, RETURN_MIN_VALUE);
        assertTrue(IMorphoLoanSubaccountRemote(subaccount).usedOperations(bytes32("op-w")));
    }

    function testViewsWithoutTheOracle() public {
        // the repay preview needs no oracle, like repay; the position reports the dead oracle as
        // zeros; nothing owed passes the withdraw preview oracle-free and the whole collateral may
        // leave; with debt, only closing both claims reopens the exit and nothing may be borrowed
        address subaccount = _createConfiguredSubaccount();
        fxrp.mint(subaccount, 100e6);
        _deliver(subaccount, 1, 100e6, _depositPayload());
        rlusd.mint(subaccount, 4e18);
        oracle.setPriceReverts(true);

        IMorphoLoanSubaccountRemote.RepayPreview memory q = IMorphoLoanSubaccountRemote(subaccount).previewRepay(0);
        assertEq(q.surplus, 4e18);
        assertEq(q.closingTopUp, 0);
        IMorphoLoanSubaccountRemote.WithdrawPreview memory w =
            IMorphoLoanSubaccountRemote(subaccount).previewWithdraw(50e6);
        assertTrue(w.coverSatisfied);
        assertEq(w.requiredCover, 0);
        assertEq(w.remainingValue, 0);
        assertEq(w.minimumTopUp, 0);
        IMorphoLoanSubaccountRemote.LoanLimits memory limits =
            IMorphoLoanSubaccountRemote(subaccount).getLoanLimits(0);
        assertEq(limits.maxWithdraw, 100e6);
        assertEq(limits.maxBorrowByCover, 0);

        oracle.setPriceReverts(false);
        _deliver(subaccount, 2, 0, _borrowPayload(
            bytes32("op-2"), DESTINATION_KIND_EVM,
            bytes32(uint256(uint160(makeAddr("dest")))), 100e18
        ));
        oracle.setPriceReverts(true);
        w = IMorphoLoanSubaccountRemote(subaccount).previewWithdraw(1);
        assertFalse(w.coverSatisfied);
        assertEq(w.requiredCover, 150e18);
        assertEq(w.remainingValue, 0);
        // the 4 idle already count: closing needs the debt less them
        assertEq(w.minimumTopUp, 100e18 - 4e18);
        assertEq(w.minimumTopUp, IMorphoLoanSubaccountRemote(subaccount).previewRepay(0).closingTopUp);
        limits = IMorphoLoanSubaccountRemote(subaccount).getLoanLimits(0);
        assertEq(limits.maxWithdraw, 0);
        assertEq(limits.maxBorrowByCover, 0);
    }

    function testPreviewRepayNeedsNoRateModelWhenDebtFree() public {
        // shares-first, like repay: a debt closed outside the rails leaves a fee owed and zero
        // shares; with the rate model dead the position views revert (every debt-bearing action
        // would) but the repay preview still quotes the fee-only settlement and the surplus, and
        // repay delivers exactly that
        _configureSettings();
        (address parent, address subaccount) = _parentAndSubaccount("rDeadIrmRepayOwner");
        fxrp.mint(subaccount, 100e6);
        _deliver(subaccount, 1, 100e6, _borrowPayload(
            bytes32("op-borrow"), DESTINATION_KIND_EVM,
            bytes32(uint256(uint160(makeAddr("dest")))), 1000e18
        ));
        _externalRepay(subaccount, 1000e18);
        vm.warp(vm.getBlockTimestamp() + 365 days);
        irm.setReverts(true);

        vm.expectRevert(bytes("IRM reverted"));
        IMorphoLoanSubaccountRemote(subaccount).getLoanPosition();

        rlusd.mint(subaccount, 75e18);
        IMorphoLoanSubaccountRemote.RepayPreview memory q = IMorphoLoanSubaccountRemote(subaccount).previewRepay(0);
        assertEq(q.feePaid, 70e18);
        assertEq(q.debtPaid, 0);
        assertEq(q.surplus, 5e18);
        assertEq(q.closingTopUp, 0);

        assertEq(IMorphoLoanSubaccountRemote(subaccount).repay(), 0);
        assertEq(rlusd.balanceOf(makeAddr("feeCollector")), 70e18);
        assertEq(rlusd.balanceOf(parent), 5e18);
    }

    function testProjectionRevertsWhereCanonicalAccrualWould() public {
        // the projection adds interest into uint128 totals as canonical accrual does: a pool at
        // the uint128 ceiling with any interest due makes both the view and the checkpoint revert,
        // instead of the view quoting a position no accrual can reach
        address subaccount = _borrowedSubaccount(1000e18);
        irm.setRate(1585489599);
        morpho.setTotalSupplyAssets(_marketId(), type(uint128).max);
        vm.warp(vm.getBlockTimestamp() + 1 days);

        uint256 interest = MorphoMath.wMulDown(1000e18, MorphoMath.wTaylorCompounded(1585489599, 1 days));
        vm.expectRevert(
            abi.encodeWithSelector(
                SafeCast.SafeCastOverflowedUintDowncast.selector, 128, uint256(type(uint128).max) + interest
            )
        );
        IMorphoLoanSubaccountRemote(subaccount).getLoanPosition();
        // the mock's accrual adds into its uint128 supply total and overflows the same way
        vm.expectRevert(stdError.arithmeticError);
        IMorphoLoanSubaccountRemote(subaccount).checkpointFee();
    }

    function testProjectedDebtWithoutARateModel() public {
        // a market registered without a rate model earns nothing: the view's debt stays the
        // principal over a year, and the checkpoint agrees
        _configureSettings();
        uint256 typeB = 2;
        IMorphoLoanMarketsFacet.Market memory marketB = _defaultMarket();
        marketB.marketParams.irm = address(0);
        morpho.createMarket(marketB.marketParams);
        vm.startPrank(governance);
        controller.setSubaccountImplementation(typeB, address(loanChainImpl));
        IIMorphoLoanMarketsFacet(address(controller)).registerLoanMarket(typeB, marketB);
        _setDefaultFeeTerms(address(controller), typeB);
        vm.stopPrank();
        address subaccount = controller.createSubaccount("rNoIrmOwner", typeB);
        fxrp.mint(subaccount, 100e6);
        _deliver(subaccount, 1, 100e6, _borrowPayload(
            bytes32("op-1"), DESTINATION_KIND_EVM,
            bytes32(uint256(uint160(makeAddr("dest")))), 100e18
        ));
        vm.warp(vm.getBlockTimestamp() + 365 days);

        IMorphoLoanSubaccountRemote.LoanPosition memory p = IMorphoLoanSubaccountRemote(subaccount).getLoanPosition();
        assertEq(p.debt, 100e18);
        assertEq(p.feeDebtX18 / 1e18, 7e18);
        IMorphoLoanSubaccountRemote(subaccount).checkpointFee();
        (uint256 principal, , uint256 collectible, , , ) = IMorphoLoanSubaccountRemote(subaccount).getLoanFeeState();
        assertEq(principal, 100e18);
        assertEq(collectible, 7e18);
    }

    function testPreviewBorrowMatchesTheGate() public {
        // the borrow preview is the gate's verdict for a borrow: 100 FXRP in the position, 20
        // idle, 30 with the packet = 300 RLUSD of cover. 200 passes exactly (debt after 200, cover
        // 300); 200 plus one unit fails, and the delivery is refused with the preview's numbers
        address subaccount = _createConfiguredSubaccount();
        oracle.setPrice(2e48);
        fxrp.mint(subaccount, 100e6);
        _deliver(subaccount, 1, 100e6, _depositPayload());
        fxrp.mint(subaccount, 20e6);
        bytes32 dest = bytes32(uint256(uint160(makeAddr("dest"))));

        IMorphoLoanSubaccountRemote.BorrowPreview memory fits =
            IMorphoLoanSubaccountRemote(subaccount).previewBorrow(200e18, 30e6);
        assertTrue(fits.coverSatisfied);
        assertEq(fits.requiredCover, 300e18);
        assertEq(fits.collateralValue, 300e18);
        assertEq(fits.debtAfter, 200e18);
        assertEq(fits.marketLiquidity, 1e30);
        IMorphoLoanSubaccountRemote.BorrowPreview memory tooMuch =
            IMorphoLoanSubaccountRemote(subaccount).previewBorrow(200e18 + 1, 30e6);
        assertFalse(tooMuch.coverSatisfied);
        assertEq(tooMuch.debtAfter, 200e18 + 1);
        assertEq(tooMuch.requiredCover, _requiredCover(200e18 + 1, 0));

        fxrp.mint(subaccount, 30e6);
        _deliverExpectRevert(
            subaccount, 2, _borrowPayload(bytes32("op-2"), DESTINATION_KIND_EVM, dest, 200e18 + 1),
            _uncovered(tooMuch.requiredCover, tooMuch.collateralValue)
        );
        _deliver(subaccount, 2, 30e6, _borrowPayload(bytes32("op-2"), DESTINATION_KIND_EVM, dest, 200e18));
        assertEq(IMorphoLoanSubaccountRemote(subaccount).getLoanPosition().debt, fits.debtAfter);
    }

    function testLiquidationPriceIsMorphosEdge() public {
        // the lowest price at which Morpho still holds the position healthy, both floors included:
        // 100 borrowed on 100 FXRP needs 129.87 RLUSD of value, so 1.2987 RLUSD per FXRP. The
        // threshold is probed through the mock's canonical health check with a zero-amount
        // withdrawal - a mock-only probe: canonical Morpho rejects a zero amount before it checks
        // health, so on the real market the same check is reached with any positive amount. At
        // that price the check passes and the health factor reads at least 1; one unit below, it
        // refuses and the factor reads below 1. Debt-free the price is zero; debt with no
        // collateral makes it the maximum
        morpho.setHealthCheckDisabled(false);
        address subaccount = _createConfiguredSubaccount();
        oracle.setPrice(2e48);
        fxrp.mint(subaccount, 100e6);
        assertEq(IMorphoLoanSubaccountRemote(subaccount).getLoanPosition().liquidationPrice, 0);
        _deliver(subaccount, 1, 100e6, _borrowPayload(
            bytes32("op-1"), DESTINATION_KIND_EVM, bytes32(uint256(uint160(makeAddr("dest")))), 100e18
        ));
        uint256 price = IMorphoLoanSubaccountRemote(subaccount).getLoanPosition().liquidationPrice;
        assertEq(
            price,
            Math.mulDiv(Math.mulDiv(100e18, 1e18, 0.77e18, Math.Rounding.Ceil), 1e36, 100e6, Math.Rounding.Ceil)
        );

        oracle.setPrice(price);
        assertGe(IMorphoLoanSubaccountRemote(subaccount).getLoanPosition().morphoHealthFactor, 1e18);
        vm.prank(subaccount);
        morpho.withdrawCollateral(_defaultMarket().marketParams, 0, subaccount, subaccount);

        oracle.setPrice(price - 1);
        assertLt(IMorphoLoanSubaccountRemote(subaccount).getLoanPosition().morphoHealthFactor, 1e18);
        vm.prank(subaccount);
        vm.expectRevert(bytes("insufficient collateral"));
        morpho.withdrawCollateral(_defaultMarket().marketParams, 0, subaccount, subaccount);

        // debt left with no collateral (the health check switched off to strip it): liquidatable
        // at any price
        morpho.setHealthCheckDisabled(true);
        vm.prank(subaccount);
        morpho.withdrawCollateral(_defaultMarket().marketParams, 100e6, subaccount, subaccount);
        assertEq(IMorphoLoanSubaccountRemote(subaccount).getLoanPosition().liquidationPrice, type(uint256).max);
    }

    function testWithdrawBeyondCollateralRevertsAtMorpho() public {
        // the account passes the signed amount through; Morpho's own bound (an underflow in
        // canonical Morpho, a require in the mock) rejects more than the position holds
        _configureSettings();
        (, address subaccount) = _parentAndSubaccount("rOverdrawOwner");
        fxrp.mint(subaccount, 100e6);
        _deliver(subaccount, 1, 100e6, _depositPayload());

        bytes memory payload = _withdrawPayload(bytes32("op-w"), 101e6);
        (bytes memory message, bytes32 guid) = _composeMessage(subaccount, 2, 0, payload);
        vm.deal(lzEndpoint, RETURN_MIN_VALUE);
        vm.prank(lzEndpoint);
        vm.expectRevert(bytes("withdraw exceeds collateral"));
        IMorphoLoanSubaccountRemote(subaccount).lzCompose{value: RETURN_MIN_VALUE}(
            address(fxrpOft), guid, message, executor, ""
        );
        assertFalse(IMorphoLoanSubaccountRemote(subaccount).usedOperations(bytes32("op-w")));
    }

    function testExitGateBoundaryIsInclusive() public {
        // remaining value == the required cover passes uncollected (>=); half an FXRP less in
        // the remainder is refused - a >=/> regression flips exactly this pair
        _configureSettings();
        oracle.setPrice(2e48); // 1 FXRP = 2 RLUSD, the price these numbers are written at
        (, address subaccount) = _parentAndSubaccount("rExactSecurityOwner");
        fxrp.mint(subaccount, 200e6);
        _deliver(subaccount, 1, 200e6, _borrowPayload(
            bytes32("op-borrow"), DESTINATION_KIND_EVM,
            bytes32(uint256(uint160(makeAddr("dest")))), 100e18
        ));
        vm.warp(vm.getBlockTimestamp() + 365 days);
        IMorphoLoanSubaccountRemote(subaccount).checkpointFee();

        // a year's fee on 100 is 7, so the cover is 1.5 x (100 + 14) = 171 RLUSD = 85.5 FXRP;
        // 115 out leaves 85 FXRP = 170 RLUSD < 171: uncovered, refused
        assertEq(_requiredCover(100e18, 7e18), 171e18);
        bytes memory uncovered = _withdrawPayload(bytes32("op-w1"), 115e6);
        (bytes memory message, bytes32 guid) = _composeMessage(subaccount, 2, 0, uncovered);
        vm.deal(lzEndpoint, RETURN_MIN_VALUE);
        vm.prank(lzEndpoint);
        vm.expectRevert(_uncovered(171e18, 170e18));
        IMorphoLoanSubaccountRemote(subaccount).lzCompose{value: RETURN_MIN_VALUE}(
            address(fxrpOft), guid, message, executor, ""
        );

        // 114.5 out leaves 85.5 FXRP = 171 RLUSD == the cover: exactly covered, rides uncollected
        _deliverWithValue(
            subaccount, 3, 0, _withdrawPayload(bytes32("op-w2"), 114.5e6), RETURN_MIN_VALUE
        );
        (, uint256 feeDebtX18, , , , ) = IMorphoLoanSubaccountRemote(subaccount).getLoanFeeState();
        assertEq(feeDebtX18, 7e18 * 1e18);
    }

    function testExitGateValuesTheRemainderRoundedDown() public {
        // the remainder's value rounds down while the cover rounds up: at a price one unit under
        // 2e48, 85.5 FXRP are worth 171 RLUSD minus a fraction of a base unit, which floors to one
        // base unit short of the 171 cover - refused; a round-up would have passed it. At 2e48
        // the same packet passes
        _configureSettings();
        (, address subaccount) = _parentAndSubaccount("rRoundingOwner");
        fxrp.mint(subaccount, 200e6);
        _deliver(subaccount, 1, 200e6, _borrowPayload(
            bytes32("op-borrow"), DESTINATION_KIND_EVM,
            bytes32(uint256(uint160(makeAddr("dest")))), 100e18
        ));
        vm.warp(vm.getBlockTimestamp() + 365 days);
        oracle.setPrice(2e48 - 1);

        bytes memory payload = _withdrawPayload(bytes32("op-w"), 114.5e6);
        (bytes memory message, bytes32 guid) = _composeMessage(subaccount, 2, 0, payload);
        vm.deal(lzEndpoint, RETURN_MIN_VALUE);
        vm.prank(lzEndpoint);
        vm.expectRevert(_uncovered(171e18, 171e18 - 1));
        IMorphoLoanSubaccountRemote(subaccount).lzCompose{value: RETURN_MIN_VALUE}(
            address(fxrpOft), guid, message, executor, ""
        );
        assertFalse(IMorphoLoanSubaccountRemote(subaccount).usedOperations(bytes32("op-w")));

        oracle.setPrice(2e48);
        _deliverWithValue(subaccount, 2, 0, payload, RETURN_MIN_VALUE);
        assertTrue(IMorphoLoanSubaccountRemote(subaccount).usedOperations(bytes32("op-w")));
    }

    function testExitGateFollowsTheMarketLltv() public {
        // the cover is a headroom over the market's own liquidation line, not a flat 1.5x: on a
        // 50% LLTV market a fresh 100 RLUSD loan needs 100 x 1.155 / 0.5 = 231 RLUSD left (a flat
        // 1.5x would ask 150), so 885 of 1000 FXRP out (230 left) is refused and 884.5 out (231
        // left) passes - both healthy at Morpho, whose line there is 200
        morpho.setHealthCheckDisabled(false);
        _configureSettings();
        oracle.setPrice(2e48); // 1 FXRP = 2 RLUSD, the price these numbers are written at
        uint256 typeB = 2;
        IMorphoLoanMarketsFacet.Market memory marketB = _defaultMarket();
        marketB.marketParams.lltv = 0.5e18;
        morpho.createMarket(marketB.marketParams);
        vm.startPrank(governance);
        controller.setSubaccountImplementation(typeB, address(loanChainImpl));
        IIMorphoLoanMarketsFacet(address(controller)).registerLoanMarket(typeB, marketB);
        _setDefaultFeeTerms(address(controller), typeB);
        vm.stopPrank();
        address subaccount = address(new SubaccountProxy(
            address(controller), parentPersonalAccount, typeB
        ));
        fxrp.mint(subaccount, 1000e6);
        _deliver(subaccount, 1, 1000e6, _borrowPayload(
            bytes32("op-borrow"), DESTINATION_KIND_EVM,
            bytes32(uint256(uint160(makeAddr("dest")))), 100e18
        ));

        bytes memory tooMuch = _withdrawPayload(bytes32("op-w"), 885e6);
        (bytes memory message, bytes32 guid) = _composeMessage(subaccount, 2, 0, tooMuch);
        vm.deal(lzEndpoint, RETURN_MIN_VALUE);
        vm.prank(lzEndpoint);
        vm.expectRevert(_uncovered(231e18, 230e18));
        IMorphoLoanSubaccountRemote(subaccount).lzCompose{value: RETURN_MIN_VALUE}(
            address(fxrpOft), guid, message, executor, ""
        );
        assertFalse(IMorphoLoanSubaccountRemote(subaccount).usedOperations(bytes32("op-w")));

        _deliverWithValue(
            subaccount, 2, 0, _withdrawPayload(bytes32("op-w"), 884.5e6), RETURN_MIN_VALUE
        );
        assertTrue(IMorphoLoanSubaccountRemote(subaccount).usedOperations(bytes32("op-w")));
        (, , uint128 collateral) =
            morpho.position(keccak256(abi.encode(marketB.marketParams)), subaccount);
        assertEq(collateral, 115.5e6);
    }

    function testPausedWithdrawTerminalSkipsFinalizeFreshOnesWait() public {
        // the pinned pause placement: duplicates finalize during a pause (value to the
        // parent), a fresh withdrawal reverts before consuming anything
        _configureSettings();
        (address parent, address subaccount) = _borrowedPairWithFee("rPausedGateOwner");
        // clear debt and fee first so the withdrawal itself is gate-free
        rlusd.mint(subaccount, 1100e18);
        IMorphoLoanSubaccountRemote(subaccount).repay();
        bytes memory executed = _withdrawPayload(bytes32("op-w"), 40e6);
        _deliverWithValue(subaccount, 2, 0, executed, RETURN_MIN_VALUE);
        _pauseController();

        // the duplicate finalizes even while paused, its value forwarded to the parent
        uint256 parentNativeBefore = parent.balance;
        vm.expectEmit();
        emit IMorphoLoanSubaccountRemote.LoanActionSkipped(
            parent, bytes32("op-w"), SKIP_REASON_DUPLICATE, _guidFor(3)
        );
        _deliverWithValue(subaccount, 3, 0, executed, RETURN_MIN_VALUE);
        assertEq(parent.balance, parentNativeBefore + RETURN_MIN_VALUE);

        // a fresh withdrawal waits out the pause, nothing consumed
        bytes memory fresh = _withdrawPayload(bytes32("op-w2"), 10e6);
        (bytes memory message, bytes32 guid) = _composeMessage(subaccount, 4, 0, fresh);
        vm.deal(lzEndpoint, RETURN_MIN_VALUE);
        vm.prank(lzEndpoint);
        vm.expectRevert(IPauseFacet.IsPaused.selector);
        IMorphoLoanSubaccountRemote(subaccount).lzCompose{value: RETURN_MIN_VALUE}(
            address(fxrpOft), guid, message, executor, ""
        );
        assertFalse(IMorphoLoanSubaccountRemote(subaccount).usedOperations(bytes32("op-w2")));
    }

    //
    // step 4: the adversarial pass - assembled-system scenarios
    //

    function testExternalRepayThenWithdrawBypassIsBlocked() public {
        // the design's founding attack: extinguish the Morpho debt directly (bypassing
        // repay so the fee leg never runs), then walk the collateral out - the gate refuses
        // regardless, and only paying the fee in loan tokens reopens it
        _configureSettings();
        (, address subaccount) = _borrowedPairWithFee("rBypassOwner");
        // no ping in between: the withdrawal's own checkpoint must discover the whole
        // year's fee across the external repayment (shares-first, floor on the old base)
        _externalRepay(subaccount, 1000e18);

        // debt-free, the cover is 3x the 70 fee: 210 against nothing left
        bytes memory stripping = _withdrawPayload(bytes32("op-w"), 100e6);
        (bytes memory message, bytes32 guid) = _composeMessage(subaccount, 2, 0, stripping);
        vm.deal(lzEndpoint, RETURN_MIN_VALUE);
        vm.prank(lzEndpoint);
        vm.expectRevert(_uncovered(210e18, 0));
        IMorphoLoanSubaccountRemote(subaccount).lzCompose{value: RETURN_MIN_VALUE}(
            address(fxrpOft), guid, message, executor, ""
        );
        assertFalse(IMorphoLoanSubaccountRemote(subaccount).usedOperations(bytes32("op-w")));

        // the fee paid in loan tokens through repay - the whole
        // collateral goes home
        rlusd.mint(subaccount, 70e18);
        IMorphoLoanSubaccountRemote(subaccount).repay();
        assertEq(rlusd.balanceOf(makeAddr("feeCollector")), 70e18);
        _deliverWithValue(subaccount, 2, 0, stripping, RETURN_MIN_VALUE);
        (, , uint256 amountLD, , , , ) = fxrpOft.lastSendParam();
        assertEq(amountLD, 100e6);
        (, uint256 feeDebtX18, , , , ) = IMorphoLoanSubaccountRemote(subaccount).getLoanFeeState();
        assertEq(feeDebtX18, 0);
    }

    function testSelfLiquidationLeavesTheClaimStanding() public {
        // the accepted junior-claim risk, end to end: a (self-)liquidation strips the
        // position past the gates, but the claim is never auto-written-off - later assets
        // on the account still answer to it
        _configureSettings();
        (, address subaccount) = _borrowedPairWithFee("rSelfLiqOwner");
        _liquidate(subaccount, 0);
        IMorphoLoanSubaccountRemote(subaccount).checkpointFee();
        (, uint256 feeDebtX18, , , , ) = IMorphoLoanSubaccountRemote(subaccount).getLoanFeeState();
        assertEq(feeDebtX18, 70e18 * 1e18);

        // idle FXRP arriving later has one route home - into the position, then a signed
        // withdraw - and that withdraw cannot pass the now-unsecured claim
        fxrp.mint(subaccount, 5e6);
        IMorphoLoanSubaccountRemote(subaccount).depositIdleFxrp();
        bytes memory payload = _withdrawPayload(bytes32("op-w"), 5e6);
        (bytes memory message, bytes32 guid) = _composeMessage(subaccount, 2, 0, payload);
        vm.deal(lzEndpoint, RETURN_MIN_VALUE);
        vm.prank(lzEndpoint);
        vm.expectRevert(_uncovered(210e18, 0));
        IMorphoLoanSubaccountRemote(subaccount).lzCompose{value: RETURN_MIN_VALUE}(
            address(fxrpOft), guid, message, executor, ""
        );

        // paying the claim (the free direction + repay) reopens the exit
        rlusd.mint(subaccount, 70e18);
        IMorphoLoanSubaccountRemote(subaccount).repay();
        assertEq(rlusd.balanceOf(makeAddr("feeCollector")), 70e18);
        _deliverWithValue(subaccount, 2, 0, payload, RETURN_MIN_VALUE);
        (, , uint256 amountLD, , , , ) = fxrpOft.lastSendParam();
        assertEq(amountLD, 5e6);
    }

    function testRepayConsumingSubaccountRlusdIsRepayFuel() public {
        // the grief that motivated (and outlived) the parent-funded mode, proven moot:
        // RLUSD parked on the subaccount IS repay fuel - a third party calling repay
        // deleverages the user, which is correct behavior, not a loss
        _configureSettings();
        (, address subaccount) = _borrowedPairWithFee("rGriefOwner");
        (, uint128 sharesBefore, ) = morpho.position(_marketId(), subaccount);
        rlusd.mint(subaccount, 100e18);

        vm.prank(makeAddr("griefer"));
        IMorphoLoanSubaccountRemote(subaccount).repay();
        (, uint128 sharesAfter, ) = morpho.position(_marketId(), subaccount);
        assertLt(sharesAfter, sharesBefore);
        assertEq(rlusd.balanceOf(subaccount), 0);
        // the fee is measured and paid pro rata - nothing was stolen, nothing collected
        // beyond the payment's share of it
        uint256 feeShare = uint256(100e18) * 70e18 / 1070e18;
        (, uint256 feeDebtX18, , , , ) = IMorphoLoanSubaccountRemote(subaccount).getLoanFeeState();
        assertEq(feeDebtX18, (70e18 - feeShare) * 1e18);
        assertEq(rlusd.balanceOf(makeAddr("feeCollector")), feeShare);
    }

    function testSequentialExitsWithPriceMovesKeepTheLedgerConsistent() public {
        // the stateful chain single tests cannot catch: secured exits, price moves, more
        // accrual, then a refused exit reopened by repay - the ledger must be exact throughout
        _configureSettings();
        oracle.setPrice(2e48); // 1 FXRP = 2 RLUSD, the price these numbers are written at
        (, address subaccount) = _parentAndSubaccount("rSequenceOwner");
        fxrp.mint(subaccount, 300e6);
        _deliver(subaccount, 1, 300e6, _borrowPayload(
            bytes32("op-borrow"), DESTINATION_KIND_EVM,
            bytes32(uint256(uint160(makeAddr("dest")))), 100e18
        ));

        // half a year: fee 3.5; remaining 250 FXRP = 500 RLUSD >= 1.5 x (100 + 7) = 160.5 -
        // covered, uncollected
        vm.warp(vm.getBlockTimestamp() + 365 days / 2);
        _deliverWithValue(
            subaccount, 2, 0,
            _withdrawPayload(bytes32("op-w1"), 50e6),
            RETURN_MIN_VALUE
        );
        (, uint256 feeDebtX18, , , , ) = IMorphoLoanSubaccountRemote(subaccount).getLoanFeeState();
        assertEq(feeDebtX18, 3.5e18 * 1e18);

        // price halves; remaining 200 FXRP = 200 RLUSD still >= 160.5 - still covered
        oracle.setPrice(1e48);
        _deliverWithValue(
            subaccount, 3, 0,
            _withdrawPayload(bytes32("op-w2"), 50e6),
            RETURN_MIN_VALUE
        );
        assertEq(fxrp.balanceOf(makeAddr("feeCollector")), 0);

        // another half year (fee 7, cover 1.5 x (100 + 14) = 171) and another halving: taking
        // 150 would leave 50 FXRP = 25 RLUSD - the next exit is refused at the CURRENT price
        vm.warp(vm.getBlockTimestamp() + 365 days / 2);
        oracle.setPrice(0.5e48);
        bytes memory refused = _withdrawPayload(bytes32("op-w3"), 150e6);
        (bytes memory message, bytes32 guid) = _composeMessage(subaccount, 4, 0, refused);
        vm.deal(lzEndpoint, RETURN_MIN_VALUE);
        vm.prank(lzEndpoint);
        vm.expectRevert(_uncovered(171e18, 25e18));
        IMorphoLoanSubaccountRemote(subaccount).lzCompose{value: RETURN_MIN_VALUE}(
            address(fxrpOft), guid, message, executor, ""
        );

        // debt and fee paid in loan tokens through repay: the exit passes in full, and the
        // ledger is exact at every step
        rlusd.mint(subaccount, 108e18);
        IMorphoLoanSubaccountRemote(subaccount).repay();
        assertEq(rlusd.balanceOf(makeAddr("feeCollector")), 7e18);
        _deliverWithValue(subaccount, 4, 0, refused, RETURN_MIN_VALUE);
        (, , uint256 amountLD, , , , ) = fxrpOft.lastSendParam();
        assertEq(amountLD, 150e6);
        (, feeDebtX18, , , , ) = IMorphoLoanSubaccountRemote(subaccount).getLoanFeeState();
        assertEq(feeDebtX18, 0);
    }

    function testRateChangeRunbookRehearsalWithAMissedAccount() public {
        // the three-step runbook over three borrowers, one deliberately missed: the pinged
        // accounts switch rates exactly at the boundary, the missed one keeps its old
        // snapshot for BOTH years and is never retroactively repriced
        _configureSettings();
        address[3] memory subaccounts;
        string[3] memory owners = ["rRunbookA", "rRunbookB", "rRunbookC"];
        for (uint256 i = 0; i < 3; i++) {
            subaccounts[i] = controller.createSubaccount(owners[i], SUBACCOUNT_TYPE_MORPHO_LOAN);
            fxrp.mint(subaccounts[i], 100e6);
            _deliver(subaccounts[i], 1, 100e6, _borrowPayload(
                bytes32("op-borrow"), DESTINATION_KIND_EVM,
                bytes32(uint256(uint160(makeAddr("dest")))), 1000e18
            ));
        }
        vm.warp(vm.getBlockTimestamp() + 365 days);

        // step 1: pre-change pass (C missed); step 2: the change; step 3: post-change pass
        IMorphoLoanSubaccountRemote(subaccounts[0]).checkpointFee();
        IMorphoLoanSubaccountRemote(subaccounts[1]).checkpointFee();
        vm.startPrank(governance);
        _setFeeRates(0.14e18, 0.02e18);
        vm.stopPrank();
        IMorphoLoanSubaccountRemote(subaccounts[0]).checkpointFee();
        IMorphoLoanSubaccountRemote(subaccounts[1]).checkpointFee();

        vm.warp(vm.getBlockTimestamp() + 365 days);
        for (uint256 i = 0; i < 3; i++) {
            IMorphoLoanSubaccountRemote(subaccounts[i]).checkpointFee();
        }
        // A and B: year 1 at 7% (70) + year 2 at 14% (140)
        (, uint256 feeA, , , , ) = IMorphoLoanSubaccountRemote(subaccounts[0]).getLoanFeeState();
        (, uint256 feeB, , , , ) = IMorphoLoanSubaccountRemote(subaccounts[1]).getLoanFeeState();
        assertEq(feeA, 210e18 * 1e18);
        assertEq(feeB, 210e18 * 1e18);
        // C, missed by both passes: two years at the OLD 7% snapshot - late, in the user's
        // favor, never retroactive
        (, uint256 feeC, , , , ) = IMorphoLoanSubaccountRemote(subaccounts[2]).getLoanFeeState();
        assertEq(feeC, 140e18 * 1e18);
    }

    function testIdleCreditSurvivesTheGatesUntouched() public {
        // a skipped borrow (here: expired) leaves its authenticated credit idle; the fee gate
        // never reaches for it - a refused withdrawal leaves the balance exactly where it was,
        // and depositIdleFxrp later absorbs it
        _configureSettings();
        (address pairParent, address subaccount) = _borrowedPairWithFee("rIdleCreditOwner");
        fxrp.mint(subaccount, 20e6);
        vm.expectEmit();
        emit IMorphoLoanSubaccountRemote.LoanActionSkipped(
            pairParent, bytes32("op-2"), SKIP_REASON_EXPIRED, _guidFor(2)
        );
        _deliver(subaccount, 2, 20e6, _borrowPayloadAt(
            bytes32("op-2"), uint64(vm.getBlockTimestamp() - 1), DESTINATION_KIND_EVM,
            bytes32(uint256(uint160(makeAddr("dest")))), 100e18
        ));

        // the elapsed year is priced at the 7% SNAPSHOT (fee 70, cover 1.5 x (1000 + 140) =
        // 1710 against the 1200 that 60 FXRP are worth): the uncovered exit is refused and the
        // idle 20 is untouched - it is not fee fuel
        bytes memory payload = _withdrawPayload(bytes32("op-w"), 40e6);
        (bytes memory message, bytes32 guid) = _composeMessage(subaccount, 3, 0, payload);
        vm.deal(lzEndpoint, RETURN_MIN_VALUE);
        vm.prank(lzEndpoint);
        vm.expectRevert(_uncovered(1710e18, 1200e18));
        IMorphoLoanSubaccountRemote(subaccount).lzCompose{value: RETURN_MIN_VALUE}(
            address(fxrpOft), guid, message, executor, ""
        );
        assertEq(fxrp.balanceOf(makeAddr("feeCollector")), 0);
        assertEq(fxrp.balanceOf(subaccount), 20e6);

        IMorphoLoanSubaccountRemote(subaccount).depositIdleFxrp();
        assertEq(fxrp.balanceOf(subaccount), 0);
        (, , uint128 collateral) = morpho.position(_marketId(), subaccount);
        assertEq(collateral, 120e6);
    }

    function testMixedInterestCheckpointPathDependenceIsThePromise() public {
        // the design's per-checkpoint promise, pinned: zero interest in the first half-year,
        // heavy interest in the second - the account checkpointed halfway owes exactly 40 (35
        // floor + 5 spread), the untouched one exactly 10 (interest ate the whole-year floor;
        // in the spread branch the interest cancels, so neither depends on Morpho's rounding).
        // Both are correct; the advertised measurement is per-checkpoint, not whole-period.
        _configureSettings();
        address pinged = controller.createSubaccount("rPingedOwner", SUBACCOUNT_TYPE_MORPHO_LOAN);
        address dormant = controller.createSubaccount("rDormantOwner", SUBACCOUNT_TYPE_MORPHO_LOAN);
        fxrp.mint(pinged, 100e6);
        fxrp.mint(dormant, 100e6);
        _deliver(pinged, 1, 100e6, _borrowPayload(
            bytes32("op-borrow"), DESTINATION_KIND_EVM,
            bytes32(uint256(uint160(makeAddr("dest")))), 1000e18
        ));
        _deliver(dormant, 1, 100e6, _borrowPayload(
            bytes32("op-borrow"), DESTINATION_KIND_EVM,
            bytes32(uint256(uint160(makeAddr("dest")))), 1000e18
        ));

        vm.warp(vm.getBlockTimestamp() + 365 days / 2);
        IMorphoLoanSubaccountRemote(pinged).checkpointFee();
        // the market's interest arrives entirely in the second half: 100 per position
        morpho.addPendingInterest(_marketId(), 200e18);
        vm.warp(vm.getBlockTimestamp() + 365 days / 2);
        IMorphoLoanSubaccountRemote(pinged).checkpointFee();
        IMorphoLoanSubaccountRemote(dormant).checkpointFee();

        (, uint256 feePinged, , , , ) = IMorphoLoanSubaccountRemote(pinged).getLoanFeeState();
        (, uint256 feeDormant, , , , ) = IMorphoLoanSubaccountRemote(dormant).getLoanFeeState();
        assertEq(feePinged, 40e18 * 1e18);
        assertEq(feeDormant, 10e18 * 1e18);
    }

    function testRepayFrozenFeeRecipientReservesAndRetries() public {
        // a recipient the token refuses must never roll back the repayment: the fee stays
        // owed and reserved, and a later repay retries the transfer
        _configureSettings();
        uint256 typeB = 2;
        MockFreezableToken frozenRlusd = new MockFreezableToken("Frozen RLUSD", "RLUSD", 18);
        IMorphoLoanMarketsFacet.Market memory marketB = _defaultMarket();
        marketB.marketParams.loanToken = address(frozenRlusd);
        morpho.createMarket(marketB.marketParams);
        vm.startPrank(governance);
        controller.setSubaccountImplementation(typeB, address(loanChainImpl));
        IIMorphoLoanMarketsFacet(address(controller)).registerLoanMarket(typeB, marketB);
        _setDefaultFeeTerms(address(controller), typeB);
        vm.stopPrank();
        address subaccount = controller.createSubaccount("rFrozenFeeOwner", typeB);
        fxrp.mint(subaccount, 100e6);
        _deliver(subaccount, 1, 100e6, _borrowPayload(
            bytes32("op-frz"), DESTINATION_KIND_EVM,
            bytes32(uint256(uint160(makeAddr("dest")))), 1000e18
        ));
        vm.warp(vm.getBlockTimestamp() + 365 days);
        frozenRlusd.mint(subaccount, 1100e18);
        frozenRlusd.setFrozen(makeAddr("feeCollector"), true);

        vm.expectEmit();
        emit IMorphoLoanSubaccountRemote.LoanFeeReserved(makeAddr("feeCollector"), 70e18);
        IMorphoLoanSubaccountRemote(subaccount).repay();
        assertEq(frozenRlusd.balanceOf(subaccount), 70e18);
        (, uint256 feeDebtX18, , , , ) = IMorphoLoanSubaccountRemote(subaccount).getLoanFeeState();
        assertEq(feeDebtX18, 70e18 * 1e18);

        frozenRlusd.setFrozen(makeAddr("feeCollector"), false);
        IMorphoLoanSubaccountRemote(subaccount).repay();
        assertEq(frozenRlusd.balanceOf(makeAddr("feeCollector")), 70e18);
        (, feeDebtX18, , , , ) = IMorphoLoanSubaccountRemote(subaccount).getLoanFeeState();
        assertEq(feeDebtX18, 0);
    }

    function testRepayProRataFeeShareRefusedByTheTokenRepaysDebtInstead() public {
        // a recipient the token refuses: the fee's share of a partial payment repays debt
        // instead (LoanFeeDeferred), the repayment stands and the fee stays owed; unfrozen,
        // the next payment pays its share normally
        _configureSettings();
        uint256 typeB = 2;
        MockFreezableToken frozenRlusd = new MockFreezableToken("Frozen RLUSD", "RLUSD", 18);
        IMorphoLoanMarketsFacet.Market memory marketB = _defaultMarket();
        marketB.marketParams.loanToken = address(frozenRlusd);
        morpho.createMarket(marketB.marketParams);
        vm.startPrank(governance);
        controller.setSubaccountImplementation(typeB, address(loanChainImpl));
        IIMorphoLoanMarketsFacet(address(controller)).registerLoanMarket(typeB, marketB);
        _setDefaultFeeTerms(address(controller), typeB);
        vm.stopPrank();
        address subaccount = controller.createSubaccount("rFrozenShareOwner", typeB);
        fxrp.mint(subaccount, 100e6);
        _deliver(subaccount, 1, 100e6, _borrowPayload(
            bytes32("op-frz"), DESTINATION_KIND_EVM,
            bytes32(uint256(uint160(makeAddr("dest")))), 1000e18
        ));
        vm.warp(vm.getBlockTimestamp() + 365 days);
        frozenRlusd.mint(subaccount, 100e18);
        frozenRlusd.setFrozen(makeAddr("feeCollector"), true);
        uint256 feeShare = uint256(100e18) * 70e18 / 1070e18;

        vm.expectEmit();
        emit IMorphoLoanSubaccountRemote.LoanFeeDeferred(makeAddr("feeCollector"), feeShare);
        assertEq(IMorphoLoanSubaccountRemote(subaccount).repay(), 100e18);
        assertEq(frozenRlusd.balanceOf(subaccount), 0);
        assertEq(frozenRlusd.balanceOf(makeAddr("feeCollector")), 0);
        (, uint256 feeDebtX18, , , , ) = IMorphoLoanSubaccountRemote(subaccount).getLoanFeeState();
        assertEq(feeDebtX18, 70e18 * 1e18);

        frozenRlusd.setFrozen(makeAddr("feeCollector"), false);
        frozenRlusd.mint(subaccount, 97e18);
        IMorphoLoanSubaccountRemote(subaccount).repay();
        assertApproxEqAbs(frozenRlusd.balanceOf(makeAddr("feeCollector")), 7e18, 1);
    }

    function testFrozenSubaccountKeepsTheExitGatedUntilUnfrozen() public {
        // the repay path runs through this address: frozen, no loan tokens can reach it and
        // repay has nothing to work with, so an uncovered exit stays refused until
        // unfreezing, funding and repaying
        _configureSettings();
        uint256 typeB = 2;
        MockFreezableToken frozenRlusd = new MockFreezableToken("Frozen RLUSD", "RLUSD", 18);
        IMorphoLoanMarketsFacet.Market memory marketB = _defaultMarket();
        marketB.marketParams.loanToken = address(frozenRlusd);
        morpho.createMarket(marketB.marketParams);
        vm.startPrank(governance);
        controller.setSubaccountImplementation(typeB, address(loanChainImpl));
        IIMorphoLoanMarketsFacet(address(controller)).registerLoanMarket(typeB, marketB);
        _setDefaultFeeTerms(address(controller), typeB);
        vm.stopPrank();
        address subaccount = controller.createSubaccount("rFrozenSubaccountOwner", typeB);
        fxrp.mint(subaccount, 100e6);
        _deliver(subaccount, 1, 100e6, _borrowPayload(
            bytes32("op-frz"), DESTINATION_KIND_EVM,
            bytes32(uint256(uint160(makeAddr("dest")))), 1000e18
        ));
        vm.warp(vm.getBlockTimestamp() + 365 days);
        frozenRlusd.setFrozen(subaccount, true);

        // 2 FXRP left = 40 RLUSD against the 1710 the 1000 debt and the 70 fee need: refused
        bytes memory payload = _withdrawPayload(bytes32("op-w"), 98e6);
        (bytes memory message, bytes32 guid) = _composeMessage(subaccount, 2, 0, payload);
        vm.deal(lzEndpoint, RETURN_MIN_VALUE);
        vm.prank(lzEndpoint);
        vm.expectRevert(_uncovered(1710e18, 40e18));
        IMorphoLoanSubaccountRemote(subaccount).lzCompose{value: RETURN_MIN_VALUE}(
            address(fxrpOft), guid, message, executor, ""
        );
        assertFalse(IMorphoLoanSubaccountRemote(subaccount).usedOperations(bytes32("op-w")));

        // the settlement cannot even be funded while frozen
        vm.expectRevert(
            abi.encodeWithSelector(MockFreezableToken.FrozenAccount.selector, subaccount)
        );
        frozenRlusd.mint(subaccount, 1100e18);
        vm.expectRevert(IMorphoLoanSubaccountRemote.NothingToRepay.selector);
        IMorphoLoanSubaccountRemote(subaccount).repay();

        frozenRlusd.setFrozen(subaccount, false);
        frozenRlusd.mint(subaccount, 1100e18);
        IMorphoLoanSubaccountRemote(subaccount).repay();
        assertEq(frozenRlusd.balanceOf(makeAddr("feeCollector")), 70e18);
        _deliverWithValue(subaccount, 2, 0, payload, RETURN_MIN_VALUE);
        assertTrue(IMorphoLoanSubaccountRemote(subaccount).usedOperations(bytes32("op-w")));
        (, , uint256 amountLD, , , , ) = fxrpOft.lastSendParam();
        assertEq(amountLD, 98e6);
    }

    function testRepayFeeFirstCallbackCannotReenter() public {
        // the fee's share now moves before the Morpho repayment: a loan token whose transfers
        // call back into repay meets the transient guard on that first leg (and again on
        // Morpho's pull). Recorded rather than bubbled, so the transfers go through and the
        // guard's own error is asserted - the split then completes exactly as with a plain
        // token; bubbled, the Morpho pull's callback reverts the whole call and nothing moves
        _configureSettings();
        uint256 typeB = 2;
        MockReentrantToken evil = new MockReentrantToken();
        IMorphoLoanMarketsFacet.Market memory marketB = _defaultMarket();
        marketB.marketParams.loanToken = address(evil);
        morpho.createMarket(marketB.marketParams);
        vm.startPrank(governance);
        controller.setSubaccountImplementation(typeB, address(loanChainImpl));
        IIMorphoLoanMarketsFacet(address(controller)).registerLoanMarket(typeB, marketB);
        _setDefaultFeeTerms(address(controller), typeB);
        vm.stopPrank();
        address subaccount = controller.createSubaccount("rEvilRepayOwner", typeB);
        fxrp.mint(subaccount, 100e6);
        _deliver(subaccount, 1, 100e6, _borrowPayload(
            bytes32("op-evil"), DESTINATION_KIND_EVM,
            bytes32(uint256(uint160(makeAddr("dest")))), 1000e18
        ));
        vm.warp(vm.getBlockTimestamp() + 365 days);
        evil.mint(subaccount, 100e18);
        evil.setCallback(subaccount, abi.encodeCall(IMorphoLoanSubaccountRemote.repay, ()));
        evil.setSoftFailures(true);
        uint256 feeShare = uint256(100e18) * 70e18 / 1070e18;

        vm.expectEmit();
        emit IMorphoLoanSubaccountRemote.LoanFeeCollected(makeAddr("feeCollector"), feeShare);
        assertEq(IMorphoLoanSubaccountRemote(subaccount).repay(), 100e18 - feeShare);
        assertEq(evil.callbackFailures(), 2);
        assertEq(
            evil.lastCallbackRevert(),
            abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector)
        );
        assertEq(evil.balanceOf(makeAddr("feeCollector")), feeShare);
        (, uint256 feeDebtX18, , , , ) = IMorphoLoanSubaccountRemote(subaccount).getLoanFeeState();
        assertEq(feeDebtX18, (70e18 - feeShare) * 1e18);

        evil.setSoftFailures(false);
        evil.mint(subaccount, 100e18);
        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        IMorphoLoanSubaccountRemote(subaccount).repay();
    }

    function testInitializeValidatesItsArgumentsOnAClearedAccount() public {
        // defense in depth: the proxy always passes its own constructor arguments, and it
        // resolves the implementation through the controller first, so these guards cannot be
        // reached in production. Clearing the controller slot re-opens `initialize` on a live
        // account, which is the only way to exercise them.
        address subaccount = address(_deploySubaccount());
        vm.store(subaccount, bytes32(0), bytes32(0));

        vm.expectRevert(IControlledAccount.InvalidControllerAddress.selector);
        ISubaccount(subaccount).initialize(address(0), parentPersonalAccount, SUBACCOUNT_TYPE_MORPHO_LOAN);

        vm.expectRevert(ISubaccount.InvalidParentPersonalAccount.selector);
        ISubaccount(subaccount).initialize(address(controller), address(0), SUBACCOUNT_TYPE_MORPHO_LOAN);

        vm.expectRevert(ISubaccountsFacet.InvalidSubaccountType.selector);
        ISubaccount(subaccount).initialize(
            address(controller), parentPersonalAccount, SUBACCOUNT_TYPE_NONE
        );
    }

    function testWithdrawReturnLegRefundFailureRevertsTheDelivery() public {
        // the return leg forwards its excess compose value to the parent, and this account has
        // no native exit, so a parent that cannot receive native reverts the whole delivery
        // (retriable) instead of stranding the excess here; with the exact quote nothing is
        // forwarded and the withdrawal passes - the account's own native is never touched
        _configureSettings();
        MockNativeRejectingParent rejectingParent = new MockNativeRejectingParent();
        address subaccount = address(new SubaccountProxy(
            address(controller), address(rejectingParent), SUBACCOUNT_TYPE_MORPHO_LOAN
        ));
        fxrp.mint(subaccount, 5e6);
        IMorphoLoanSubaccountRemote(subaccount).depositIdleFxrp();
        vm.deal(subaccount, 5 ether);

        bytes memory payload = _withdrawPayload(bytes32("op-w"), 5e6);
        (bytes memory message, bytes32 guid) = _composeMessage(subaccount, 1, 0, payload);
        vm.deal(lzEndpoint, 0.02 ether);
        vm.prank(lzEndpoint);
        vm.expectRevert(IMorphoLoanSubaccountRemote.RefundFailed.selector);
        IMorphoLoanSubaccountRemote(subaccount).lzCompose{value: 0.02 ether}(
            address(fxrpOft), guid, message, executor, ""
        );
        assertFalse(IMorphoLoanSubaccountRemote(subaccount).usedOperations(bytes32("op-w")));
        (, , uint128 collateral) = morpho.position(_marketId(), subaccount);
        assertEq(collateral, 5e6);

        _deliverWithValue(subaccount, 1, 0, payload, 0.01 ether);
        (, , uint256 amountLD, , , , ) = fxrpOft.lastSendParam();
        assertEq(amountLD, 5e6);
        assertEq(fxrpOft.lastValue(), 0.01 ether);
        assertEq(subaccount.balance, 5 ether);
    }

    function testWithdrawReturnLegFailsClosedOnPeerMutation() public {
        // a peer mutation on the OFT after configuration must fail the return leg closed, not
        // bridge the withdrawn collateral toward an unknown remote OApp: the delivery reverts
        // with nothing withdrawn and the id unconsumed, and passes once the peer is restored
        address subaccount = _createConfiguredSubaccount();
        fxrp.mint(subaccount, 100e6);
        _deliver(subaccount, 1, 100e6, _depositPayload());
        fxrpOft.setPeer(originEid, bytes32(uint256(0xbad)));

        bytes memory payload = _withdrawPayload(bytes32("op-2"), 30e6);
        (bytes memory message, bytes32 guid) = _composeMessage(subaccount, 2, 0, payload);
        vm.deal(lzEndpoint, RETURN_MIN_VALUE);
        vm.prank(lzEndpoint);
        vm.expectRevert(IMorphoLoanSubaccountRemote.WrongOriginPeer.selector);
        IMorphoLoanSubaccountRemote(subaccount).lzCompose{value: RETURN_MIN_VALUE}(
            address(fxrpOft), guid, message, executor, ""
        );
        assertFalse(IMorphoLoanSubaccountRemote(subaccount).usedOperations(bytes32("op-2")));
        (, , uint128 collateral) = morpho.position(_marketId(), subaccount);
        assertEq(collateral, 100e6);

        fxrpOft.setPeer(originEid, originPeer);
        _deliverWithValue(subaccount, 2, 0, payload, RETURN_MIN_VALUE);
        assertTrue(IMorphoLoanSubaccountRemote(subaccount).usedOperations(bytes32("op-2")));
    }

    function testSkippedWithdrawValueForwardFailureReverts() public {
        // a terminal skip forwards its delivered value to the parent, since the endpoint is no
        // refund target and this account has no native exit: a parent that cannot receive it
        // reverts the delivery, which keeps the value with the endpoint and the packet retriable
        _configureSettings();
        MockNativeRejectingParent rejectingParent = new MockNativeRejectingParent();
        address subaccount = address(new SubaccountProxy(
            address(controller), address(rejectingParent), SUBACCOUNT_TYPE_MORPHO_LOAN
        ));

        bytes memory payload = _withdrawPayload(bytes32("op-w"), 10e6);
        (bytes memory message, bytes32 guid) = _composeMessage(subaccount, 1, 0, payload);
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        vm.deal(lzEndpoint, RETURN_MIN_VALUE);
        vm.prank(lzEndpoint);
        vm.expectRevert(IMorphoLoanSubaccountRemote.RefundFailed.selector);
        IMorphoLoanSubaccountRemote(subaccount).lzCompose{value: RETURN_MIN_VALUE}(
            address(fxrpOft), guid, message, executor, ""
        );
        assertFalse(IMorphoLoanSubaccountRemote(subaccount).usedOperations(bytes32("op-w")));
    }

    function testLzComposeRevertTransportNotConfigured() public {
        address subaccount = _createConfiguredSubaccount();
        (bytes memory message, bytes32 guid) =
            _composeMessage(subaccount, 1, 100e6, _depositPayload());
        vm.prank(governance);
        IIComposeTransportFacet(address(controller)).clearComposeTransport();

        vm.prank(lzEndpoint);
        vm.expectRevert(
            IComposeTransportFacet.ComposeTransportNotConfigured.selector
        );
        IMorphoLoanSubaccountRemote(subaccount).lzCompose(address(fxrpOft), guid, message, executor, "");
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
                IMorphoLoanSubaccountRemote.UnsupportedDestinationKind.selector,
                DESTINATION_KIND_XRPL_WORMHOLE
            )
        );

        // a zero destination, and a destination with dirty upper bits
        payload = _borrowPayload(bytes32("op-1"), DESTINATION_KIND_EVM, bytes32(0), 500e18);
        _deliverExpectRevert(
            subaccount, 1, payload, IMorphoLoanSubaccountRemote.InvalidDestination.selector
        );
        bytes32 dirty = bytes32(uint256(uint160(makeAddr("dest"))) | (uint256(1) << 200));
        payload = _borrowPayload(bytes32("op-1"), DESTINATION_KIND_EVM, dirty, 500e18);
        _deliverExpectRevert(
            subaccount, 1, payload, IMorphoLoanSubaccountRemote.InvalidDestination.selector
        );

        // disbursing to the account itself only opens debt its own proceeds must repay (the
        // parent Personal Account, by contrast, is a valid target - see the dedicated test)
        payload = _borrowPayload(
            bytes32("op-1"), DESTINATION_KIND_EVM, bytes32(uint256(uint160(subaccount))), 500e18
        );
        _deliverExpectRevert(
            subaccount, 1, payload, IMorphoLoanSubaccountRemote.InvalidDestination.selector
        );

        // a borrow with nothing to borrow is malformed even with collateral attached: a pure
        // deposit is its own action
        payload = _borrowPayload(bytes32("op-1"), DESTINATION_KIND_EVM, bytes32(uint256(1)), 0);
        _deliverExpectRevert(subaccount, 1, payload, IMorphoLoanSubaccountRemote.ZeroAmount.selector);
    }

    function testLzComposeSkipDuplicateOperation() public {
        address subaccount = _createConfiguredSubaccount();
        bytes32 operationId = bytes32("op-1");
        address destination = makeAddr("exchangeDeposit");
        fxrp.mint(subaccount, 100e6);
        _deliver(subaccount, 1, 100e6, _borrowPayload(
            operationId, DESTINATION_KIND_EVM, bytes32(uint256(uint160(destination))), 300e18
        ));

        // a retried instruction delivered twice must not double-execute: the second delivery
        // completes without effect - no second borrow - and its bridged FXRP stays on the
        // account for the rail
        fxrp.mint(subaccount, 100e6);
        vm.expectEmit();
        emit IMorphoLoanSubaccountRemote.LoanActionSkipped(
            parentPersonalAccount, operationId, SKIP_REASON_DUPLICATE, _guidFor(2)
        );
        _deliver(subaccount, 2, 100e6, _borrowPayload(
            operationId, DESTINATION_KIND_EVM, bytes32(uint256(uint160(destination))), 300e18
        ));

        (, uint128 borrowShares, uint128 collateral) = morpho.position(_marketId(), subaccount);
        assertEq(collateral, 100e6);
        assertEq(borrowShares, 300e18 * 1e6);
        assertEq(rlusd.balanceOf(destination), 300e18);
        assertEq(fxrp.balanceOf(subaccount), 100e6);
    }

    function testWithdrawSkipDuplicateOperation() public {
        // the duplicate terminal gate finalizes every action kind that carries an id: an
        // operation id consumed by a borrow skips a withdraw without any effect
        address subaccount = _createConfiguredSubaccount();
        bytes32 operationId = bytes32("op-1");
        fxrp.mint(subaccount, 100e6);
        _deliver(subaccount, 1, 100e6, _borrowPayload(
            operationId, DESTINATION_KIND_EVM, bytes32(uint256(uint160(makeAddr("dest")))), 100e18
        ));

        vm.expectEmit();
        emit IMorphoLoanSubaccountRemote.LoanActionSkipped(
            parentPersonalAccount, operationId, SKIP_REASON_DUPLICATE, _guidFor(2)
        );
        vm.expectEmit();
        emit IMorphoLoanSubaccountRemote.NativeSweptToParent(parentPersonalAccount, 0.01 ether);
        _deliverWithValue(subaccount, 2, 0, _withdrawPayload(operationId, 30e6), 0.01 ether);
        (, , uint128 collateral) = morpho.position(_marketId(), subaccount);
        assertEq(collateral, 100e6);
        // the skipped delivery's value went to the parent, not stranding here
        assertEq(parentPersonalAccount.balance, 0.01 ether);
        assertEq(subaccount.balance, 0);
    }

    function testLzComposeSkipExpiredDeadlineWithoutConsumingTheOperation() public {
        address subaccount = _createConfiguredSubaccount();
        bytes32 operationId = bytes32("op-1");
        address destination = makeAddr("exchangeDeposit");
        fxrp.mint(subaccount, 100e6);

        vm.expectEmit();
        emit IMorphoLoanSubaccountRemote.LoanActionSkipped(
            parentPersonalAccount, operationId, SKIP_REASON_EXPIRED, _guidFor(1)
        );
        _deliver(subaccount, 1, 100e6, _borrowPayloadAt(
            operationId, uint64(block.timestamp - 1), DESTINATION_KIND_EVM,
            bytes32(uint256(uint160(destination))), 300e18
        ));
        assertFalse(IMorphoLoanSubaccountRemote(subaccount).usedOperations(operationId));

        // the same intent retries under the same operation id with a fresh deadline; the
        // retry is a real second packet, crediting its own amount - and the first packet's
        // stale credit rides along into the position with it
        fxrp.mint(subaccount, 100e6);
        _deliver(subaccount, 2, 100e6, _borrowPayload(
            operationId, DESTINATION_KIND_EVM, bytes32(uint256(uint160(destination))), 300e18
        ));
        (, uint128 borrowShares, uint128 collateral) = morpho.position(_marketId(), subaccount);
        assertEq(collateral, 200e6);
        assertEq(borrowShares, 300e18 * 1e6);
        assertEq(fxrp.balanceOf(subaccount), 0);
        assertTrue(IMorphoLoanSubaccountRemote(subaccount).usedOperations(operationId));
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
        assertTrue(IMorphoLoanSubaccountRemote(subaccount).usedOperations(bytes32("op-w")));
    }

    function testLzComposeBorrowRevertBorrowingDisabled() public {
        // the borrow switch sunsets a pool: a debt increase reverts (retriable - a reversible
        // policy must not consume the packet); deposits, repayment and withdrawals still work
        address subaccount = _borrowedSubaccount(500e18);
        vm.prank(governance);
        vm.expectEmit();
        emit IMorphoLoanMarketsFacet.LoanBorrowingDisabled(SUBACCOUNT_TYPE_MORPHO_LOAN);
        IIMorphoLoanMarketsFacet(address(controller)).disableLoanBorrowing(
            SUBACCOUNT_TYPE_MORPHO_LOAN
        );

        fxrp.mint(subaccount, 100e6);
        bytes memory borrowMore = _borrowPayload(
            bytes32("op-2"), DESTINATION_KIND_EVM,
            bytes32(uint256(uint160(makeAddr("dest")))), 100e18
        );
        _deliverExpectRevert(
            subaccount, 2, borrowMore, IMorphoLoanSubaccountRemote.BorrowingDisabled.selector
        );

        // a collateral deposit is not a debt increase and still works (a real second packet,
        // crediting its own amount; packet 2's idle credit rides along into the position)
        fxrp.mint(subaccount, 100e6);
        _deliver(subaccount, 3, 100e6, _depositPayload());
        (, , uint128 collateral) = morpho.position(_marketId(), subaccount);
        assertEq(collateral, 300e6);

        // re-enabling makes the exact same packet deliverable again: nothing left to supply,
        // the signed borrow executes against the position
        vm.prank(governance);
        vm.expectEmit();
        emit IMorphoLoanMarketsFacet.LoanBorrowingEnabled(SUBACCOUNT_TYPE_MORPHO_LOAN);
        IIMorphoLoanMarketsFacet(address(controller)).enableLoanBorrowing(
            SUBACCOUNT_TYPE_MORPHO_LOAN
        );
        _deliver(subaccount, 2, 100e6, borrowMore);
        assertEq(rlusd.balanceOf(makeAddr("dest")), 100e18);
        (, , collateral) = morpho.position(_marketId(), subaccount);
        assertEq(collateral, 300e6);
    }

    function testDuplicateFinalizesWhileBorrowingDisabled() public {
        // terminal gates run before the borrow switch: a duplicate delivery finalizes
        // without effect instead of reverting forever on a sunset pool
        address subaccount = _borrowedSubaccount(500e18);
        vm.prank(governance);
        IIMorphoLoanMarketsFacet(address(controller)).disableLoanBorrowing(
            SUBACCOUNT_TYPE_MORPHO_LOAN
        );

        fxrp.mint(subaccount, 100e6);
        vm.expectEmit();
        emit IMorphoLoanSubaccountRemote.LoanActionSkipped(
            parentPersonalAccount, bytes32("op-borrow"), SKIP_REASON_DUPLICATE, _guidFor(9)
        );
        _deliver(subaccount, 9, 100e6, _borrowPayload(
            bytes32("op-borrow"), DESTINATION_KIND_EVM,
            bytes32(uint256(uint160(makeAddr("exchangeDeposit")))), 500e18
        ));
    }

    function testBorrowingDisabledLeavesExitsOpen() public {
        // the switch stops exactly one thing - new debt; every exit stays open on the sunset
        // pool: composed withdrawal (the 70 FXRP = 1400 RLUSD left cover the 1.5 x 50 the gate
        // wants), repayment, and recovery of the surplus
        address subaccount = _borrowedSubaccount(50e18);
        vm.prank(governance);
        IIMorphoLoanMarketsFacet(address(controller)).disableLoanBorrowing(
            SUBACCOUNT_TYPE_MORPHO_LOAN
        );

        _deliverWithValue(subaccount, 2, 0, _withdrawPayload(bytes32("op-w"), 30e6), 0.01 ether);
        (, , uint128 collateral) = morpho.position(_marketId(), subaccount);
        assertEq(collateral, 70e6);

        rlusd.mint(subaccount, 100e18);
        assertEq(IMorphoLoanSubaccountRemote(subaccount).repay(), 50e18);
        // the surplus left with the same call
        assertEq(rlusd.balanceOf(parentPersonalAccount), 50e18);
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
        IMorphoLoanMarketsFacet.Market memory marketB = _defaultMarket();
        marketB.marketParams.lltv = 0.5e18;
        morpho.createMarket(marketB.marketParams);
        vm.startPrank(governance);
        controller.setSubaccountImplementation(typeB, address(loanChainImpl));
        IIMorphoLoanMarketsFacet(address(controller)).registerLoanMarket(
            typeB, marketB
        );
        _setDefaultFeeTerms(address(controller), typeB);
        IIMorphoLoanMarketsFacet(address(controller)).disableLoanBorrowing(
            SUBACCOUNT_TYPE_MORPHO_LOAN
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
            IMorphoLoanSubaccountRemote.BorrowingDisabled.selector
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

    function testLzComposeRevertHardChecksOnEveryAction() public {
        // each action carries its own copy of the hard checks, so each copy needs its own
        // negative delivery (the deposit carries no id, so only its zero amount is checked)
        address subaccount = _createConfiguredSubaccount();
        fxrp.mint(subaccount, 100e6);

        _deliverExpectRevert(
            subaccount, 1,
            _borrowPayload(bytes32(0), DESTINATION_KIND_EVM, bytes32(uint256(1)), 500e18),
            IComposeReceiverAccountBase.InvalidOperationId.selector
        );
        _deliverExpectRevert(
            subaccount, 1, _withdrawPayload(bytes32("op-1"), 0),
            IMorphoLoanSubaccountRemote.ZeroAmount.selector
        );
        _deliverExpectRevert(
            subaccount, 1, _withdrawPayload(bytes32(0), 50e6),
            IComposeReceiverAccountBase.InvalidOperationId.selector
        );
    }

    function testLzComposeDepositSuppliesTheWholeIdleBalance() public {
        // the accepted race, made a no-op: the permissionless rail deposits the credit before
        // the deposit compose executes; the compose then supplies what is idle - nothing
        // here - and reports the amount it actually supplied
        address subaccount = _createConfiguredSubaccount();
        fxrp.mint(subaccount, 100e6);
        IMorphoLoanSubaccountRemote(subaccount).depositIdleFxrp();

        vm.expectEmit();
        emit IMorphoLoanSubaccountRemote.CollateralDeposited(
            parentPersonalAccount, 0, _guidFor(1)
        );
        _deliver(subaccount, 1, 100e6, _depositPayload());
        (, , uint128 collateral) = morpho.position(_marketId(), subaccount);
        assertEq(collateral, 100e6);

        // whatever is idle goes in, less or more than the packet's own amount: 40 idle against
        // a 100 packet supplies 40
        fxrp.mint(subaccount, 40e6);
        vm.expectEmit();
        emit IMorphoLoanSubaccountRemote.CollateralDeposited(
            parentPersonalAccount, 40e6, _guidFor(2)
        );
        _deliver(subaccount, 2, 100e6, _depositPayload());
        (, , collateral) = morpho.position(_marketId(), subaccount);
        assertEq(collateral, 140e6);
        assertEq(fxrp.balanceOf(subaccount), 0);

        // and residue rides along: 150 idle (a direct send on top of the credit) against a 100
        // packet supplies all 150 - no separate rail call needed
        fxrp.mint(subaccount, 150e6);
        vm.expectEmit();
        emit IMorphoLoanSubaccountRemote.CollateralDeposited(
            parentPersonalAccount, 150e6, _guidFor(3)
        );
        _deliver(subaccount, 3, 100e6, _depositPayload());
        (, , collateral) = morpho.position(_marketId(), subaccount);
        assertEq(collateral, 290e6);
        assertEq(fxrp.balanceOf(subaccount), 0);
    }

    function testLzComposePreemptedBorrowStillBorrowsAsSigned() public {
        // the same race on a borrow: the credit already sits in the position, so the compose
        // supplies nothing and borrows exactly the signed amount against it, to the signed
        // destination
        address subaccount = _createConfiguredSubaccount();
        fxrp.mint(subaccount, 100e6);
        IMorphoLoanSubaccountRemote(subaccount).depositIdleFxrp();
        address destination = makeAddr("exchangeDeposit");

        vm.expectEmit();
        emit IMorphoLoanSubaccountRemote.LoanOpened(
            parentPersonalAccount, bytes32("op-1"), 0, 300e18, DESTINATION_KIND_EVM,
            bytes32(uint256(uint160(destination))), _guidFor(1)
        );
        _deliver(subaccount, 1, 100e6, _borrowPayload(
            bytes32("op-1"), DESTINATION_KIND_EVM, bytes32(uint256(uint160(destination))), 300e18
        ));
        (, uint128 borrowShares, uint128 collateral) = morpho.position(_marketId(), subaccount);
        assertEq(collateral, 100e6);
        assertEq(borrowShares, 300e18 * 1e6);
        assertEq(rlusd.balanceOf(destination), 300e18);
    }
    function testLzComposePreemptedBorrowExecutesAgainstThePositionAsItStands() public {
        // the interleaving the aggregate semantics allow: the credit is deposited by the rail,
        // the user's own signed withdraw then takes part of the position out, and the delayed
        // borrow still executes - supplying nothing, borrowing the signed amount against what
        // is left, under Morpho's health check (enabled here) and within its deadline
        morpho.setHealthCheckDisabled(false);
        address subaccount = _createConfiguredSubaccount();
        fxrp.mint(subaccount, 100e6);
        IMorphoLoanSubaccountRemote(subaccount).depositIdleFxrp();
        _deliverWithValue(subaccount, 2, 0, _withdrawPayload(bytes32("op-w"), 30e6), RETURN_MIN_VALUE);
        (, , uint128 collateral) = morpho.position(_marketId(), subaccount);
        assertEq(collateral, 70e6);

        // 70 FXRP = 1400 RLUSD carry the signed 100 at Morpho (1078 allowed) and at the cover gate
        // (150 needed): it executes
        address destination = makeAddr("exchangeDeposit");
        vm.expectEmit();
        emit IMorphoLoanSubaccountRemote.LoanOpened(
            parentPersonalAccount, bytes32("op-1"), 0, 100e18, DESTINATION_KIND_EVM,
            bytes32(uint256(uint160(destination))), _guidFor(1)
        );
        _deliver(subaccount, 1, 100e6, _borrowPayload(
            bytes32("op-1"), DESTINATION_KIND_EVM, bytes32(uint256(uint160(destination))), 100e18
        ));
        (, uint128 borrowShares, uint128 collateralAfter) = morpho.position(_marketId(), subaccount);
        assertEq(collateralAfter, 70e6);
        assertEq(borrowShares, 100e18 * 1e6);
        assertEq(rlusd.balanceOf(destination), 100e18);
    }
    function testCreateSubaccountWithoutPersonalAccount() public {
        // the generic creation route works on this chain: no Personal Account exists or
        // ever will, the parent falls back to its computed address
        string memory xrplOwner = "rLoanChainOnlyOwner";
        address predicted = controller.getSubaccount(xrplOwner, SUBACCOUNT_TYPE_MORPHO_LOAN);
        assertEq(predicted.code.length, 0);

        address created = controller.createSubaccount(xrplOwner, SUBACCOUNT_TYPE_MORPHO_LOAN);
        assertEq(created, predicted);
        assertNotEq(created.code.length, 0);

        // idempotent
        address again = controller.createSubaccount(xrplOwner, SUBACCOUNT_TYPE_MORPHO_LOAN);
        assertEq(again, created);
    }

    function testCreateSubaccountRevertWhenPaused() public {
        _pauseController();
        vm.expectRevert(IPauseFacet.IsPaused.selector);
        controller.createSubaccount("rOwner", SUBACCOUNT_TYPE_MORPHO_LOAN);
    }

    //
    // step 4: repayment, deposits, the return leg and recovery
    //

    function testSecondTypeBindsItsOwnMarket() public {
        // a new pool is a new subaccount type: same implementation, own write-once market,
        // own deterministic CREATE2 address for the same owner - positions on different
        // pools never share an account
        _configureSettings();
        uint256 typeB = 2;
        IMorphoLoanMarketsFacet.Market memory marketB = _defaultMarket();
        marketB.marketParams.lltv = 0.5e18;
        morpho.createMarket(marketB.marketParams);
        vm.startPrank(governance);
        controller.setSubaccountImplementation(typeB, address(loanChainImpl));
        IIMorphoLoanMarketsFacet(address(controller)).registerLoanMarket(
            typeB, marketB
        );
        _setDefaultFeeTerms(address(controller), typeB);
        vm.stopPrank();

        // both accounts materialize through the production CREATE2 route, one per type
        string memory xrplOwner = "rTwoPoolsOwner";
        address subaccountA = controller.createSubaccount(xrplOwner, SUBACCOUNT_TYPE_MORPHO_LOAN);
        address subaccountB = controller.createSubaccount(xrplOwner, typeB);
        assertEq(subaccountA, controller.getSubaccount(xrplOwner, SUBACCOUNT_TYPE_MORPHO_LOAN));
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

    function testUnregisteredTypeRevertsBorrowDepositAndRail() public {
        // mis-sync fail-safe: a type with no market yet cannot execute composed actions
        // (retriable reverts, the operation id stays unconsumed). A borrow stops first at the
        // activation gate - fee terms follow registration, so an unregistered type has none -
        // while the deposit compose and the deposit rail stop at the registration itself; the
        // credit waits idle, its one route being into the position
        _configureSettings();
        uint256 typeB = 2;
        vm.prank(governance);
        controller.setSubaccountImplementation(typeB, address(loanChainImpl));
        SubaccountProxy proxyB = new SubaccountProxy(
            address(controller), parentPersonalAccount, typeB
        );
        address subaccountB = address(proxyB);
        fxrp.mint(subaccountB, 100e6);
        bytes memory notRegistered =
            abi.encodeWithSelector(IMorphoLoanMarketsFacet.MarketNotRegistered.selector, typeB);

        _deliverExpectRevert(
            subaccountB, 1,
            _borrowPayload(
                bytes32("op-borrow"), DESTINATION_KIND_EVM,
                bytes32(uint256(uint160(makeAddr("dest")))), 50e18
            ),
            IMorphoLoanSubaccountRemote.FeeTermsNotConfigured.selector
        );
        // the revert rolled the whole delivery back: the packet stays retriable, the id unconsumed
        assertFalse(IMorphoLoanSubaccountRemote(subaccountB).usedOperations(bytes32("op-borrow")));
        _deliverExpectRevert(subaccountB, 2, _depositPayload(), notRegistered);

        vm.expectRevert(notRegistered);
        IMorphoLoanSubaccountRemote(subaccountB).depositIdleFxrp();
        assertEq(fxrp.balanceOf(subaccountB), 100e6);
    }

    function testBorrowRetriesAfterMarketRegistration() public {
        // the mis-sync revert is retriable: the borrow stops at the activation gate while the
        // type has no market (and so no fee terms); once governance registers the market and
        // sets the terms, the exact same packet delivers - supplying the idle credit, opening
        // the debt, disbursing, and consuming the id
        _configureSettings();
        uint256 typeB = 2;
        vm.prank(governance);
        controller.setSubaccountImplementation(typeB, address(loanChainImpl));
        address subaccountB = address(new SubaccountProxy(
            address(controller), parentPersonalAccount, typeB
        ));
        fxrp.mint(subaccountB, 100e6);
        address dest = makeAddr("dest");
        bytes memory payload = _borrowPayload(
            bytes32("op-borrow"), DESTINATION_KIND_EVM, bytes32(uint256(uint160(dest))), 50e18
        );
        _deliverExpectRevert(
            subaccountB, 1, payload, IMorphoLoanSubaccountRemote.FeeTermsNotConfigured.selector
        );

        IMorphoLoanMarketsFacet.Market memory marketB = _defaultMarket();
        marketB.marketParams.lltv = 0.5e18;
        morpho.createMarket(marketB.marketParams);
        vm.startPrank(governance);
        IIMorphoLoanMarketsFacet(address(controller)).registerLoanMarket(typeB, marketB);
        _setDefaultFeeTerms(address(controller), typeB);
        vm.stopPrank();

        _deliver(subaccountB, 1, 100e6, payload);
        (, uint128 borrowShares, uint128 collateral) =
            morpho.position(keccak256(abi.encode(marketB.marketParams)), subaccountB);
        assertEq(collateral, 100e6);
        assertGt(borrowShares, 0);
        assertEq(rlusd.balanceOf(dest), 50e18);
        assertTrue(IMorphoLoanSubaccountRemote(subaccountB).usedOperations(bytes32("op-borrow")));
    }

    function testRepayPartialByAssets() public {
        address subaccount = _borrowedSubaccount(500e18);
        rlusd.mint(subaccount, 200e18);

        vm.expectEmit();
        emit IMorphoLoanSubaccountRemote.LoanRepaid(parentPersonalAccount, 200e18);
        uint256 assets = IMorphoLoanSubaccountRemote(subaccount).repay();

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
        emit IMorphoLoanSubaccountRemote.LoanRepaid(parentPersonalAccount, 500e18);
        vm.expectEmit();
        emit IMorphoLoanSubaccountRemote.LoanSurplusRecovered(parentPersonalAccount, 100e18);
        uint256 assets = IMorphoLoanSubaccountRemote(subaccount).repay();

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

        uint256 assets = IMorphoLoanSubaccountRemote(subaccount).repay();

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
        vm.expectRevert(IMorphoLoanSubaccountRemote.NothingToRepay.selector);
        IMorphoLoanSubaccountRemote(subaccount).repay();
    }

    function testRepayWithoutDebtRecoversWholeBalance() public {
        // loan tokens on a debt-free account (sent by mistake, or arriving after the close)
        // are surplus: repay is their exit, with nothing repaid
        address subaccount = _createConfiguredSubaccount();
        rlusd.mint(subaccount, 100e18);
        assertEq(IMorphoLoanSubaccountRemote(subaccount).repay(), 0);
        assertEq(rlusd.balanceOf(parentPersonalAccount), 100e18);
        assertEq(rlusd.balanceOf(subaccount), 0);
    }

    function testRepayKeepsBalanceWhileDebtRemains() public {
        // while the position has debt, the loan-token balance is repayment material: a
        // partial repay consumes it and nothing leaves to the parent
        address subaccount = _borrowedSubaccount(500e18);
        rlusd.mint(subaccount, 100e18);
        assertEq(IMorphoLoanSubaccountRemote(subaccount).repay(), 100e18);
        assertEq(rlusd.balanceOf(parentPersonalAccount), 0);
        assertEq(rlusd.balanceOf(subaccount), 0);
    }

    function testRepayRevertMarketNotRegistered() public {
        // an unconfigured type has no market to repay into
        address subaccount = address(_deploySubaccount());
        rlusd.mint(subaccount, 100e18);

        vm.expectRevert(
            abi.encodeWithSelector(
                IMorphoLoanMarketsFacet.MarketNotRegistered.selector, SUBACCOUNT_TYPE_MORPHO_LOAN
            )
        );
        IMorphoLoanSubaccountRemote(subaccount).repay();
    }

    function testRepayWorksWhilePaused() public {
        // repaying moves the position toward safety and stays available during incidents
        address subaccount = _borrowedSubaccount(500e18);
        rlusd.mint(subaccount, 200e18);
        _pauseController();

        uint256 assets = IMorphoLoanSubaccountRemote(subaccount).repay();
        assertEq(assets, 200e18);
    }

    function testRepayWorksWithClearedTransport() public {
        // clearing the transport kills composed actions (the return leg included), never
        // repayment
        address subaccount = _borrowedSubaccount(500e18);
        vm.prank(governance);
        IIComposeTransportFacet(address(controller)).clearComposeTransport();

        rlusd.mint(subaccount, 600e18);
        uint256 assets = IMorphoLoanSubaccountRemote(subaccount).repay();
        assertEq(assets, 500e18);
        // nor does the surplus push
        assertEq(rlusd.balanceOf(parentPersonalAccount), 100e18);

        // the defensive idle deposit needs no transport either
        fxrp.mint(subaccount, 10e6);
        IMorphoLoanSubaccountRemote(subaccount).depositIdleFxrp();
        (, , uint128 collateral) = morpho.position(_marketId(), subaccount);
        assertEq(collateral, 110e6);
    }

    function testTransportClearRetainsBorrowSwitchAndRecovery() public {
        // the nuclear lever zeroes only the LayerZero surface: the per-type borrow switch
        // survives the clear, and recovery to the parent needs no transport at all
        address subaccount = _createConfiguredSubaccount();
        vm.startPrank(governance);
        IIMorphoLoanMarketsFacet(address(controller)).disableLoanBorrowing(
            SUBACCOUNT_TYPE_MORPHO_LOAN
        );
        IIComposeTransportFacet(address(controller)).clearComposeTransport();
        vm.stopPrank();

        assertTrue(
            IMorphoLoanMarketsFacet(address(controller))
                .isLoanBorrowingDisabled(SUBACCOUNT_TYPE_MORPHO_LOAN)
        );
        rlusd.mint(subaccount, 1e18);
        assertEq(IMorphoLoanSubaccountRemote(subaccount).repay(), 0);
        assertEq(rlusd.balanceOf(parentPersonalAccount), 1e18);
    }

    function testDepositIdleFxrp() public {
        address subaccount = _createConfiguredSubaccount();
        fxrp.mint(subaccount, 70e6);

        vm.expectEmit();
        emit IMorphoLoanSubaccountRemote.IdleFxrpDeposited(parentPersonalAccount, 70e6);
        uint256 amount = IMorphoLoanSubaccountRemote(subaccount).depositIdleFxrp();

        assertEq(amount, 70e6);
        (, , uint128 collateral) = morpho.position(_marketId(), subaccount);
        assertEq(collateral, 70e6);
        assertEq(fxrp.balanceOf(subaccount), 0);
    }

    function testDepositIdleFxrpReverts() public {
        address subaccount = _createConfiguredSubaccount();

        // nothing idle
        vm.expectRevert(IMorphoLoanSubaccountRemote.NothingToDeposit.selector);
        IMorphoLoanSubaccountRemote(subaccount).depositIdleFxrp();

        // new exposure is pause-gated
        fxrp.mint(subaccount, 70e6);
        _pauseController();
        vm.expectRevert(IPauseFacet.IsPaused.selector);
        IMorphoLoanSubaccountRemote(subaccount).depositIdleFxrp();
    }

    function testUnknownActionIsUnsupported() public {
        // an action this receiver does not know fails closed, whatever it carries - here the
        // Flare side's own redeem-home, which the loan chain sends and never executes
        address subaccount = _createConfiguredSubaccount();
        fxrp.mint(subaccount, 100e6);
        _deliverExpectRevert(
            subaccount, 1, abi.encode(PAYLOAD_VERSION_1, ACTION_REDEEM_HOME, bytes("")),
            abi.encodeWithSelector(
                IComposeReceiverAccountBase.UnsupportedAction.selector, ACTION_REDEEM_HOME
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
        assertEq(IMorphoLoanSubaccountRemote(subaccount).repay(), 0);
        assertEq(rlusd.balanceOf(parentPersonalAccount), 1e18);
    }

    function testWithdrawWithAttachedCreditLeavesItIdle() public {
        // a message-only action delivered with tokens attached executes normally; the credit
        // simply stays idle on the account for the fixed rails
        address subaccount = _createConfiguredSubaccount();
        fxrp.mint(subaccount, 100e6);
        _deliver(subaccount, 1, 100e6, _depositPayload());

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
        IMorphoLoanMarketsFacet.Market memory market = _defaultMarket();
        market.marketParams.loanToken = makeAddr("codelessToken");
        morpho.createMarket(market.marketParams);
        _registerMarketExpectRevert(
            market, IMorphoLoanMarketsFacet.InvalidMarketParams.selector
        );
    }

    function testRegisterLoanMarketRevertCodelessCollateralToken() public {
        // the symmetric case: a codeless collateral token must be rejected too
        _configureTransport();
        IMorphoLoanMarketsFacet.Market memory market = _defaultMarket();
        market.marketParams.collateralToken = makeAddr("codelessCollateral");
        morpho.createMarket(market.marketParams);
        _registerMarketExpectRevert(
            market, IMorphoLoanMarketsFacet.InvalidMarketParams.selector
        );
    }

    function testRegisterLoanMarketRevertCodelessOracle() public {
        // the oracle too: Morpho's createMarket accepts a codeless oracle, and the exit gate's
        // try/catch around price() cannot catch one - the call succeeds with empty return data
        // and decoding it reverts outside the catch - so the whole withdraw would revert raw
        // instead of the gate refusing; registration is the place to close it
        _configureTransport();
        IMorphoLoanMarketsFacet.Market memory market = _defaultMarket();
        market.marketParams.oracle = makeAddr("codelessOracle");
        morpho.createMarket(market.marketParams);
        _registerMarketExpectRevert(
            market, IMorphoLoanMarketsFacet.InvalidMarketParams.selector
        );
    }

    function testRegisterLoanMarketRevertNonexistentMarket() public {
        // the market must actually exist on the Morpho contract, or every credited compose
        // action against it would revert
        _configureTransport();
        _registerMarketExpectRevert(
            _defaultMarket(), IMorphoLoanMarketsFacet.InvalidMarketParams.selector
        );
    }

    function testRepaySurplusPushFailureDoesNotRevertRepayment() public {
        // an RLUSD-like freeze on the parent: the surplus push fails, but the repayment that
        // just closed the debt stands - the surplus stays here and any later repay retries it
        _configureSettings();
        uint256 typeB = 2;
        MockFreezableToken frozenRlusd = new MockFreezableToken("Frozen RLUSD", "RLUSD", 18);
        IMorphoLoanMarketsFacet.Market memory marketB = _defaultMarket();
        marketB.marketParams.loanToken = address(frozenRlusd);
        morpho.createMarket(marketB.marketParams);
        vm.startPrank(governance);
        controller.setSubaccountImplementation(typeB, address(loanChainImpl));
        IIMorphoLoanMarketsFacet(address(controller)).registerLoanMarket(
            typeB, marketB
        );
        _setDefaultFeeTerms(address(controller), typeB);
        vm.stopPrank();

        address subaccount = controller.createSubaccount("rFrozenParentOwner", typeB);
        address parent = MorphoLoanSubaccountRemote(payable(subaccount)).parentPersonalAccount();
        fxrp.mint(subaccount, 100e6);
        _deliver(subaccount, 1, 100e6, _borrowPayload(
            bytes32("op-frz"), DESTINATION_KIND_EVM,
            bytes32(uint256(uint160(makeAddr("destFrz")))), 300e18
        ));

        frozenRlusd.mint(subaccount, 400e18);
        frozenRlusd.setFrozen(parent, true);

        vm.expectEmit();
        emit IMorphoLoanSubaccountRemote.LoanRepaid(parent, 300e18);
        vm.expectEmit();
        emit IMorphoLoanSubaccountRemote.LoanSurplusRetained(parent, 100e18);
        uint256 assets = IMorphoLoanSubaccountRemote(subaccount).repay();

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
        emit IMorphoLoanSubaccountRemote.LoanSurplusRecovered(parent, 100e18);
        assertEq(IMorphoLoanSubaccountRemote(subaccount).repay(), 0);
        assertEq(frozenRlusd.balanceOf(parent), 100e18);
        assertEq(frozenRlusd.balanceOf(subaccount), 0);
    }

    function testDebtFreeSurplusRecoveryNeedsNoAccrual() public {
        // the debt-free path reads only the position: a reverting IRM (broken or hostile)
        // cannot trap recoverable loan tokens
        address subaccount = _createConfiguredSubaccount();
        rlusd.mint(subaccount, 100e18);
        morpho.setAccrueInterestReverts(true);

        assertEq(IMorphoLoanSubaccountRemote(subaccount).repay(), 0);
        assertEq(rlusd.balanceOf(parentPersonalAccount), 100e18);

        // with live debt, repayment still needs accrual - the guard is scoped to debt-free
        morpho.setAccrueInterestReverts(false);
        address indebted = controller.createSubaccount("rIndebtedAccrualOwner", SUBACCOUNT_TYPE_MORPHO_LOAN);
        fxrp.mint(indebted, 100e6);
        _deliver(indebted, 1, 100e6, _borrowPayload(
            bytes32("op-acc"), DESTINATION_KIND_EVM,
            bytes32(uint256(uint160(makeAddr("destAcc")))), 300e18
        ));
        morpho.setAccrueInterestReverts(true);
        rlusd.mint(indebted, 100e18);
        vm.expectRevert(bytes("IRM reverted"));
        IMorphoLoanSubaccountRemote(indebted).repay();
    }

    function testStrayTokenHasNoExit() public {
        // no generic recovery rail: a stray token strands until a beacon upgrade adds one -
        // accepted on both subaccounts. Every token the protocol routes here has its own rail
        // (FXRP: depositIdleFxrp, then the signed withdraw; the loan token: repay)
        address subaccount = _createConfiguredSubaccount();
        MintableERC20 stray = new MintableERC20("Stray", "STR", 18);
        stray.mint(subaccount, 42e18);
        assertEq(stray.balanceOf(subaccount), 42e18);
    }

    function testFlareSendersProduceThePayloadsTheLoanChainDecodes() public {
        // end-to-end codec check: capture the payloads the Flare senders hand to the OFT's
        // send, wrap them with the canonical compose codec exactly as lzReceive ->
        // sendCompose does, and execute them on the remote receivers at the same address. No
        // hand-built payload in between
        address subaccount = _createConfiguredSubaccount();
        address sender = _flareSenderOnThisDiamond();
        uint64 deadline = uint64(vm.getBlockTimestamp() + 1 hours);
        vm.deal(parentPersonalAccount, 1 ether);

        // borrow: the sender bridges 100e6 with the typed payload; the receiver supplies the
        // credited amount and disburses the loan to the parent (the parent's address)
        fxrp.mint(sender, 100e6);
        vm.prank(parentPersonalAccount);
        ILoanSubaccount(sender).borrow{value: 0.01 ether}(
            100e6, 50e18, DESTINATION_KIND_EVM, bytes32(uint256(uint160(parentPersonalAccount))), 0,
            bytes32("op-b"), deadline, ""
        );
        (uint256 amountLD, bytes memory payload) = _lastSentCompose();
        assertEq(amountLD, 100e6);
        fxrp.mint(subaccount, amountLD); // the OFT's credit on the receiving side
        _deliver(subaccount, 1, amountLD, payload);
        (, , uint128 collateral) = morpho.position(_marketId(), subaccount);
        assertEq(collateral, 100e6);
        assertEq(rlusd.balanceOf(parentPersonalAccount), 50e18);

        // withdraw: message-only out, atomic on arrival - the receiver withdraws the
        // collateral and bridges it home in the same execution, under the signed return
        // options, paid by the delivered compose value (the 60 FXRP = 1200 RLUSD left cover the
        // 1.5 x 50 the cover gate wants)
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

        // the withdraw's return leg is a real bridge-back: the payload it carries is the action
        // and nothing else, which is all the Flare twin decodes before redeeming whatever it
        // holds (the redemption itself needs a Personal Account with code, and is the Flare
        // suite's to cover)
        (amountLD, payload) = _lastSentCompose();
        assertEq(amountLD, 40e6);
        assertEq(payload, abi.encode(PAYLOAD_VERSION_1, ACTION_REDEEM_HOME, bytes("")));

        // the signed deposit: exactly the signed amount travels; the loan chain supplies it (with
        // any idle residue - none here), no debt
        fxrp.mint(sender, 30e6);
        vm.prank(parentPersonalAccount);
        ILoanSubaccount(sender).depositCollateral{value: 0.01 ether}(30e6, "");
        (amountLD, payload) = _lastSentCompose();
        assertEq(amountLD, 30e6);
        fxrp.mint(subaccount, amountLD);
        _deliver(subaccount, 4, amountLD, payload);
        (, , collateral) = morpho.position(_marketId(), subaccount);
        assertEq(collateral, 90e6);


        // the cancellation: message-only, and on arrival the id it names is consumed, so a
        // borrow carrying that id can never execute afterwards
        vm.prank(parentPersonalAccount);
        ILoanSubaccount(sender).cancel{value: 0.01 ether}(bytes32("op-c"), "");
        (amountLD, payload) = _lastSentCompose();
        assertEq(amountLD, 0);
        _deliver(subaccount, 7, 0, payload);
        assertTrue(IMorphoLoanSubaccountRemote(subaccount).usedOperations(bytes32("op-c")));

        // the Personal Account's transfer: sent by a Flare PersonalAccount through
        // executeUserOp, decoded by a parent created behind the same beacon
        address destination = makeAddr("userChosen");
        _sendTransferFromFlarePersonalAccount(destination, deadline);
        (amountLD, payload) = _lastSentCompose();
        assertEq(amountLD, 0);
        address parent = _remotePaOnThisDiamond("rRemotePaOwner");
        rlusd.mint(parent, 500e18);
        _deliverToRemotePa(parent, 5, payload);
        assertEq(rlusd.balanceOf(destination), 500e18);
        assertEq(rlusd.balanceOf(parent), 0);
        assertTrue(IPersonalAccountRemote(parent).usedOperations(bytes32("op-t")));
    }

    function testMinimalLoanChainDiamondTopology() public {
        // the intended loan-chain cut: the generic subaccount surface, the PA beacon
        // surface, the compose transport and the loan markets - never the Flare-only
        // BridgeRoutesFacet. The full-suite diamond could hide an accidental
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
            address(new MorphoLoanMarketsFacet()), "MorphoLoanMarketsFacet", IDiamond.FacetCutAction.Add
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
        minimalController.setSubaccountImplementation(SUBACCOUNT_TYPE_MORPHO_LOAN, address(loanChainImpl));
        IIComposeTransportFacet(address(minimal)).setComposeTransport(_defaultTransport());
        IIMorphoLoanMarketsFacet(address(minimal)).registerLoanMarket(
            SUBACCOUNT_TYPE_MORPHO_LOAN, _defaultMarket()
        );
        _setDefaultFeeTerms(address(minimal), SUBACCOUNT_TYPE_MORPHO_LOAN);
        vm.stopPrank();
        string memory xrplOwner = "rMinimalTopologyOwner";
        address subaccount = minimalController.createSubaccount(xrplOwner, SUBACCOUNT_TYPE_MORPHO_LOAN);
        assertGt(subaccount.code.length, 0);

        // created before its parent, the subaccount is bound to the computed - still
        // codeless - parent address, and the surplus push parks the tokens there; creating
        // the parent later puts code and the registry entry at that same address, with the
        // parked balance now under the user's signature
        address parent = MorphoLoanSubaccountRemote(payable(subaccount)).parentPersonalAccount();
        assertEq(parent.code.length, 0);
        rlusd.mint(subaccount, 5e18);
        assertEq(IMorphoLoanSubaccountRemote(subaccount).repay(), 0);
        assertEq(rlusd.balanceOf(parent), 5e18);

        // the parent Personal Account also materializes on the minimal topology, behind the
        // PA beacon, through the generic creation route on the PersonalAccountsFacet - but
        // only once the implementation is registered: the frozen BeaconProxy asks the beacon
        // at construction, and an unset beacon fails the creation closed
        vm.expectRevert(
            abi.encodeWithSelector(
                IPersonalAccountsFacet.PersonalAccountNotSuccessfullyDeployed.selector, parent
            )
        );
        minimalController.createPersonalAccount(xrplOwner);
        PersonalAccountRemote remotePaImpl = new PersonalAccountRemote();
        vm.prank(initialOwner);
        minimalController.setPersonalAccountImplementation(address(remotePaImpl));
        address remotePa = minimalController.createPersonalAccount(xrplOwner);
        assertGt(remotePa.code.length, 0);
        assertEq(minimalController.getPersonalAccount(xrplOwner), remotePa);
        assertEq(remotePa, parent);
        assertEq(rlusd.balanceOf(remotePa), 5e18);

        // the Flare-only bridge routes are not routable on this diamond
        vm.expectRevert(
            abi.encodeWithSelector(FunctionNotFound.selector, IBridgeRoutesFacet.getFxrpOft.selector)
        );
        IBridgeRoutesFacet(address(minimal)).getFxrpOft();
    }

    function testLzComposeCancelConsumesTheIdAndStopsTheBorrowItNames() public {
        address subaccount = _createConfiguredSubaccount();
        fxrp.mint(subaccount, 100e6);

        vm.expectEmit(true, false, false, true, subaccount);
        emit IMorphoLoanSubaccountRemote.LoanActionCancelled(
            parentPersonalAccount, bytes32("op-1"), _guidFor(1)
        );
        _deliver(subaccount, 1, 0, _cancelPayload(bytes32("op-1")));
        assertTrue(IMorphoLoanSubaccountRemote(subaccount).usedOperations(bytes32("op-1")));

        // the borrow that id authorized is now a duplicate: it finalizes without executing
        _deliver(
            subaccount, 2, 0,
            _borrowPayload(bytes32("op-1"), DESTINATION_KIND_EVM, _borrowDestination(), 50e18)
        );
        (, uint128 shares, uint128 collateral) = morpho.position(_marketId(), subaccount);
        assertEq(shares, 0, "no debt was taken");
        assertEq(collateral, 0, "and no collateral was supplied");
        assertEq(fxrp.balanceOf(subaccount), 100e6, "the credit stays idle for the fixed rails");
    }

    function testLzComposeCancelAfterTheOriginalExecutedChangesNothing() public {
        // the race the front end is warned about: the borrow lands first, so the cancellation
        // finds the id consumed and finalizes quietly - no revert, no event, nothing moved
        address subaccount = _createConfiguredSubaccount();
        fxrp.mint(subaccount, 100e6);
        _deliver(
            subaccount, 1, 100e6,
            _borrowPayload(bytes32("op-1"), DESTINATION_KIND_EVM, _borrowDestination(), 50e18)
        );
        (, uint128 sharesBefore, uint128 collateralBefore) = morpho.position(_marketId(), subaccount);

        vm.recordLogs();
        _deliver(subaccount, 2, 0, _cancelPayload(bytes32("op-1")));
        assertEq(vm.getRecordedLogs().length, 0, "a lost race says nothing");

        (, uint128 shares, uint128 collateral) = morpho.position(_marketId(), subaccount);
        assertEq(shares, sharesBefore);
        assertEq(collateral, collateralBefore);
        assertTrue(IMorphoLoanSubaccountRemote(subaccount).usedOperations(bytes32("op-1")));
    }

    function testLzComposeCancelIsIdempotentAndNotPauseGated() public {
        // revoking an authority is not new exposure, so a pause does not hold it back; and a
        // second delivery of the same cancellation is quiet rather than reverting
        address subaccount = _createConfiguredSubaccount();
        _pauseController();
        _deliver(subaccount, 1, 0, _cancelPayload(bytes32("op-1")));
        assertTrue(IMorphoLoanSubaccountRemote(subaccount).usedOperations(bytes32("op-1")));

        vm.recordLogs();
        _deliver(subaccount, 2, 0, _cancelPayload(bytes32("op-1")));
        assertEq(vm.getRecordedLogs().length, 0, "the second one says nothing");
    }

    function testLzComposeCancelRejectsZeroIdAndComposeValue() public {
        address subaccount = _createConfiguredSubaccount();
        _deliverExpectRevert(
            subaccount, 1, _cancelPayload(bytes32(0)),
            abi.encodePacked(IComposeReceiverAccountBase.InvalidOperationId.selector)
        );
        // it moves nothing and forwards nothing, so it takes no compose value either
        (bytes memory message, bytes32 guid) =
            _composeMessage(subaccount, 2, 0, _cancelPayload(bytes32("op-1")));
        vm.deal(lzEndpoint, 1 ether);
        vm.prank(lzEndpoint);
        vm.expectRevert(IComposeReceiverAccountBase.NonZeroComposeValue.selector);
        IMorphoLoanSubaccountRemote(subaccount).lzCompose{value: 1 ether}(
            address(fxrpOft), guid, message, executor, ""
        );
        assertFalse(IMorphoLoanSubaccountRemote(subaccount).usedOperations(bytes32("op-1")));
    }

    function testLzComposeCancelNeedsNoMarketAndNoTerms() public {
        // the cancellation reads no market and no fee terms, so it executes on a type with
        // neither registered nor activated - and the borrow it stops still duplicate-skips
        // there, since the terminal gates run before the market lookup
        _configureTransport();
        address subaccount = address(_deploySubaccount());
        fxrp.mint(subaccount, 100e6);

        _deliver(subaccount, 1, 0, _cancelPayload(bytes32("op-1")));
        assertTrue(IMorphoLoanSubaccountRemote(subaccount).usedOperations(bytes32("op-1")));

        _deliver(
            subaccount, 2, 100e6,
            _borrowPayload(bytes32("op-1"), DESTINATION_KIND_EVM, _borrowDestination(), 50e18)
        );
        assertEq(fxrp.balanceOf(subaccount), 100e6, "finalized as a duplicate, nothing supplied");
        assertEq(rlusd.balanceOf(parentPersonalAccount), 0, "nothing borrowed");
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
        returns (IMorphoLoanMarketsFacet.Market memory)
    {
        return IMorphoLoanMarketsFacet.Market({
            morpho: address(morpho),
            marketParams: IMorpho.MarketParams({
                loanToken: address(rlusd),
                collateralToken: address(fxrp),
                oracle: address(oracle),
                irm: address(irm),
                lltv: 0.77e18
            })
        });
    }

    /// Configures the meeting-example fee terms (floor 7%, spread 1% annually, a fixed
    /// collector) for `_subaccountType` - the one call that activates the type. The caller
    /// must already be pranked as the diamond's owner.
    function _setDefaultFeeTerms(address _diamond, uint256 _subaccountType) private {
        IIMorphoLoanMarketsFacet(_diamond).setLoanFeeTerms(
            _subaccountType, _feeTerms(0.07e18, 0.01e18, makeAddr("feeCollector"))
        );
    }

    /// Changes the loan type's rates on this diamond, keeping the default collector. The
    /// caller must already be pranked as the diamond's owner.
    function _setFeeRates(uint64 _feeFloor, uint64 _feeSpread) private {
        IIMorphoLoanMarketsFacet(address(controller)).setLoanFeeTerms(
            SUBACCOUNT_TYPE_MORPHO_LOAN, _feeTerms(_feeFloor, _feeSpread, makeAddr("feeCollector"))
        );
    }

    /// A third-party liquidator repays `_shares` of the subaccount's borrow shares (0 = all)
    /// with its own loan tokens and seizes the collateral - entirely outside the account's
    /// rails, which is what real Morpho liquidation does.
    function _liquidate(address _subaccount, uint128 _shares) private {
        address liquidator = makeAddr("liquidator");
        rlusd.mint(liquidator, 1_000e18);
        vm.startPrank(liquidator);
        rlusd.approve(address(morpho), type(uint256).max);
        if (_shares == 0) {
            morpho.simulateLiquidation(_defaultMarket().marketParams, _subaccount);
        } else {
            morpho.simulatePartialLiquidation(
                _defaultMarket().marketParams, _subaccount, _shares
            );
        }
        vm.stopPrank();
    }

    /// A third party repays `_assets` of the subaccount's debt directly on Morpho - outside
    /// the rails, unobserved by the account (the donation path).
    function _externalRepay(address _subaccount, uint256 _assets) private {
        _externalRepayWith(rlusd, _defaultMarket(), _subaccount, _assets);
    }

    function _externalRepayWith(
        MintableERC20 _loanToken,
        IMorphoLoanMarketsFacet.Market memory _market,
        address _subaccount,
        uint256 _assets
    )
        private
    {
        address donor = makeAddr("donor");
        _loanToken.mint(donor, _assets);
        vm.startPrank(donor);
        _loanToken.approve(address(morpho), _assets);
        morpho.repay(_market.marketParams, _assets, 0, _subaccount, "");
        vm.stopPrank();
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
        IIMorphoLoanMarketsFacet(address(controller)).registerLoanMarket(
            SUBACCOUNT_TYPE_MORPHO_LOAN, _defaultMarket()
        );
        _setDefaultFeeTerms(address(controller), SUBACCOUNT_TYPE_MORPHO_LOAN);
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
        IMorphoLoanMarketsFacet.Market memory _market,
        bytes4 _selector
    )
        private
    {
        vm.prank(governance);
        vm.expectRevert(_selector);
        IIMorphoLoanMarketsFacet(address(controller)).registerLoanMarket(
            SUBACCOUNT_TYPE_MORPHO_LOAN, _market
        );
    }

    /// A Flare-side LoanSubaccount sender wired on this diamond as a second type, with the
    /// Flare bridge route pointing at this chain and the FAssets registry it reads FXRP from.
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
        vm.startPrank(governance);
        controller.setFxrpOft(address(fxrpOft));
        controller.setBridgeRoute(dstEid, peer);
        controller.setSubaccountTypeRoute(senderType, dstEid);
        vm.stopPrank();
    }

    /// A Flare PersonalAccount behind this diamond's beacon (the Flare implementation is the
    /// one registered in setUp) sends a one-call transfer batch for the parent through
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
                IPersonalAccount.sendCrossChainUserOp, (dstEid, batch, bytes32("op-t"), _deadline, "")
            )
        });
        vm.prank(address(controller));
        IPersonalAccount(flarePa).executeUserOp(calls);
    }

    /// The loan-chain parent for `_xrplOwner`, after switching the PA beacon to the parent
    /// implementation (Flare Personal Accounts created earlier on this diamond are not touched
    /// again).
    function _remotePaOnThisDiamond(string memory _xrplOwner) private returns (address) {
        vm.prank(governance);
        controller.setPersonalAccountImplementation(address(new PersonalAccountRemote()));
        return controller.createPersonalAccount(_xrplOwner);
    }

    /// A production-identity pair on this diamond: the compose-driven parent and its derived
    /// loan subaccount, created through the production derivation.
    function _parentAndSubaccount(
        string memory _owner
    )
        private
        returns (address _parent, address _subaccount)
    {
        _parent = _remotePaOnThisDiamond(_owner);
        _subaccount = controller.createSubaccount(_owner, SUBACCOUNT_TYPE_MORPHO_LOAN);
    }

    /// The pair above with 100e6 FXRP collateral, 1000e18 debt, and one year of accrued fee
    /// (70e18 at the default 7% floor with no market interest).
    function _borrowedPairWithFee(
        string memory _owner
    )
        private
        returns (address _parent, address _subaccount)
    {
        (_parent, _subaccount) = _parentAndSubaccount(_owner);
        fxrp.mint(_subaccount, 100e6);
        _deliver(_subaccount, 1, 100e6, _borrowPayload(
            bytes32("op-borrow"), DESTINATION_KIND_EVM,
            bytes32(uint256(uint160(makeAddr("dest")))), 1000e18
        ));
        vm.warp(vm.getBlockTimestamp() + 365 days);
    }

    /// Delivers a loan-chain-built compose to a Flare-side receiver on this diamond: srcEid is
    /// this (loan) chain, the pinned peer is the bridge route's one (this OFT), the guid the
    /// endpoint here would compute.
    function _deliverToRemotePa(address _parent, uint64 _nonce, bytes memory _payload) private {
        (bytes memory message, bytes32 guid) = _composeMessage(_parent, _nonce, 0, _payload);
        vm.prank(lzEndpoint);
        IPersonalAccountRemote(_parent).lzCompose(address(fxrpOft), guid, message, executor, "");
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
            ? _depositPayload()
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
        IMorphoLoanSubaccountRemote(_subaccount).lzCompose{value: _value}(
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
        IMorphoLoanSubaccountRemote(_subaccount).lzCompose(
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
        IMorphoLoanSubaccountRemote(_subaccount).lzCompose(
            address(fxrpOft), guid, message, executor, ""
        );
    }

    /// An hour out - the deadline the payload builders use.
    function _soon() private returns (uint64) {
        return uint64(vm.getBlockTimestamp() + 1 hours);
    }

    /// The stock disbursement destination for the payload-shape tests.
    function _dest() private returns (bytes32) {
        return bytes32(uint256(uint160(makeAddr("dest"))));
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
        return _borrowPayloadAt(
            _operationId, uint64(vm.getBlockTimestamp() + 1 hours), _destinationKind,
            _destination, _borrowAmount
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
                _operationId, uint64(vm.getBlockTimestamp() + 1 hours), _amount, _minComposeValue,
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

    function _deploySubaccount() private returns (MorphoLoanSubaccountRemote) {
        SubaccountProxy proxy = new SubaccountProxy(
            address(controller),
            parentPersonalAccount,
            SUBACCOUNT_TYPE_MORPHO_LOAN
        );
        return MorphoLoanSubaccountRemote(payable(address(proxy)));
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

    /// The loan-token value of `_fxrp` at the mock oracle's current price.
    function _valueOf(
        uint256 _fxrp
    )
        private view
        returns (uint256)
    {
        return Math.mulDiv(_fxrp, oracle.storedPrice(), 1e36);
    }

    function _borrowDestination() private view returns (bytes32) {
        return bytes32(uint256(uint160(parentPersonalAccount)));
    }

    function _cancelPayload(
        bytes32 _operationId
    )
        private
        pure
        returns (bytes memory)
    {
        return abi.encode(PAYLOAD_VERSION_1, ACTION_CANCEL, abi.encode(_operationId));
    }

    function _depositPayload()
        private
        pure
        returns (bytes memory)
    {
        return abi.encode(PAYLOAD_VERSION_1, ACTION_DEPOSIT_COLLATERAL, bytes(""));
    }

    function _feeTerms(
        uint64 _feeFloor,
        uint64 _feeSpread,
        address _feeRecipient
    )
        private pure
        returns (IMorphoLoanMarketsFacet.FeeTerms memory)
    {
        return IMorphoLoanMarketsFacet.FeeTerms({
            feeFloor: _feeFloor, feeSpread: _feeSpread, feeRecipient: _feeRecipient
        });
    }

    function _borrowPayloadAt(
        bytes32 _operationId,
        uint64 _deadline,
        uint8 _destinationKind,
        bytes32 _destination,
        uint256 _borrowAmount
    )
        private pure
        returns (bytes memory)
    {
        return abi.encode(
            PAYLOAD_VERSION_1,
            ACTION_BORROW,
            abi.encode(
                _operationId, _deadline, _destinationKind, _destination, _borrowAmount, uint256(0)
            )
        );
    }

    /// A borrow payload naming a delivery-value floor - which no kind V1 supports may do.
    function _borrowPayloadWithFloor(
        bytes32 _operationId,
        uint64 _deadline,
        uint8 _destinationKind,
        bytes32 _destination,
        uint256 _minComposeValue
    )
        private pure
        returns (bytes memory)
    {
        return abi.encode(
            PAYLOAD_VERSION_1,
            ACTION_BORROW,
            abi.encode(
                _operationId, _deadline, _destinationKind, _destination, uint256(500e18),
                _minComposeValue
            )
        );
    }

    /// A five-word borrow payload, for the pin that the decoder rejects it.
    function _borrowPayloadFiveWords(
        bytes32 _operationId,
        uint64 _deadline,
        bytes32 _destination
    )
        private pure
        returns (bytes memory)
    {
        return abi.encode(
            PAYLOAD_VERSION_1,
            ACTION_BORROW,
            abi.encode(_operationId, _deadline, DESTINATION_KIND_EVM, _destination, uint256(500e18))
        );
    }

    /// The exit gate's required cover on the default market (LLTV 77%) - the spec's formula,
    /// computed here: `(D + 2F) x 1.155 / 0.77`, rounded up.
    function _requiredCover(
        uint256 _debt,
        uint256 _collectible
    )
        private pure
        returns (uint256)
    {
        return Math.mulDiv(_debt + 2 * _collectible, 1.155e18, 0.77e18, Math.Rounding.Ceil);
    }

    /// The gate's refusal, as the delivery reverts with it.
    function _uncovered(
        uint256 _required,
        uint256 _remaining
    )
        private pure
        returns (bytes memory)
    {
        return abi.encodeWithSelector(
            IMorphoLoanSubaccountRemote.InsufficientRemainingCollateral.selector, _required, _remaining
        );
    }
}
