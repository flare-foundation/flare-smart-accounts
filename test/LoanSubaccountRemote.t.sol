// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {IControlledAccount} from "../contracts/userInterfaces/IControlledAccount.sol";
import {ISubaccount} from "../contracts/userInterfaces/ISubaccount.sol";
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
import {MockNativeRejectingParent} from "../contracts/mock/MockNativeRejectingParent.sol";
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
import {ILoanSubaccount} from "../contracts/userInterfaces/ILoanSubaccount.sol";
import {ACTION_REDEEM_HOME, REDEEM_HOME_TTL} from "../contracts/userInterfaces/IBridgingSubaccount.sol";
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
    SUBACCOUNT_TYPE_LOAN,
    SUBACCOUNT_TYPE_NONE
} from "../contracts/userInterfaces/facets/ISubaccountsFacet.sol";
import {IBridgeRoutesFacet} from "../contracts/userInterfaces/facets/IBridgeRoutesFacet.sol";
import {NotContractOwner} from "../contracts/diamond/libraries/LibDiamond.sol";
import {MintableERC20} from "../contracts/mock/MintableERC20.sol";
import {MockReentrantToken} from "../contracts/mock/MockReentrantToken.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockOft} from "../contracts/mock/MockOft.sol";
import {MockAssetManager} from "../contracts/mock/MockAssetManager.sol";
import {MockMorpho} from "../contracts/mock/MockMorpho.sol";
import {MockOracle} from "../contracts/mock/MockOracle.sol";
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
 * @notice The loan-chain-side subaccount (Ethereum, at launch): the same frozen proxy
 * resolves a per-chain implementation through the controller-as-beacon, so the account keeps
 * its cross-chain CREATE2 address while behaving differently per chain. Covers creation and
 * implementation resolution, the authenticated compose actions, the Morpho rails, the Flare
 * fee accounting and gates, and cross-chain payload integration.
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
    MockOracle private oracle;
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
        // the fee and gate tests exercise the account's arithmetic under leverage a real
        // market would not allow; the canonical-Morpho tests switch the health check back on
        morpho.setHealthCheckDisabled(true);
        // Morpho oracle convention: 1 FXRP (6 decimals) = 2 RLUSD (18 decimals)
        oracle = new MockOracle(2e48);
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
        vm.expectEmit();
        emit ISubaccount.SubaccountInitialized(
            address(controller), parentPersonalAccount, SUBACCOUNT_TYPE_LOAN
        );
        LoanSubaccountRemote subaccount = _deploySubaccount();

        assertEq(subaccount.controllerAddress(), address(controller));
        assertEq(subaccount.parentPersonalAccount(), parentPersonalAccount);
        assertEq(subaccount.subaccountType(), SUBACCOUNT_TYPE_LOAN);
        assertEq(subaccount.implementation(), address(loanChainImpl));
    }

    function testInitializeRevertAlreadyInitialized() public {
        LoanSubaccountRemote subaccount = _deploySubaccount();

        vm.expectRevert(IControlledAccount.AlreadyInitialized.selector);
        subaccount.initialize(
            address(controller),
            parentPersonalAccount,
            SUBACCOUNT_TYPE_LOAN
        );
    }

    function testImplementationInitializeRevertAlreadyInitialized() public {
        // the implementation contract locks itself in its own constructor
        vm.expectRevert(IControlledAccount.AlreadyInitialized.selector);
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

        // the one activating set opens borrowing: the same packet now delivers
        vm.startPrank(governance);
        _setFeeRates(0.07e18, 0.01e18);
        vm.stopPrank();
        terms = ILoanMarketsFacet(address(controller)).getLoanFeeTerms(SUBACCOUNT_TYPE_LOAN);
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
        IILoanMarketsFacet(address(controller)).registerLoanMarket(
            SUBACCOUNT_TYPE_LOAN, _defaultMarket()
        );
        _setFeeRates(0, 0);
        vm.stopPrank();
        ILoanMarketsFacet.FeeTerms memory terms =
            ILoanMarketsFacet(address(controller)).getLoanFeeTerms(SUBACCOUNT_TYPE_LOAN);
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
        ILoanSubaccountRemote(subaccount).checkpointFee();
        (, uint256 feeDebtX18, , , , ) = ILoanSubaccountRemote(subaccount).getLoanFeeState();
        assertEq(feeDebtX18, 0);
    }

    function testSetLoanFeeTermsZeroRatesIsDeliberateFeeOff() public {
        // explicit zero floor and spread are legal - with the recipient set, the type is
        // configured and "fee off" is a deliberate state, distinct from unconfigured
        _configureSettings();
        vm.startPrank(governance);
        _setFeeRates(0, 0);
        vm.stopPrank();
        ILoanMarketsFacet.FeeTerms memory stored =
            ILoanMarketsFacet(address(controller)).getLoanFeeTerms(SUBACCOUNT_TYPE_LOAN);
        assertEq(stored.feeFloor, 0);
        assertEq(stored.feeSpread, 0);
        assertEq(stored.feeRecipient, makeAddr("feeCollector"));
    }

    function testSetLoanFeeTerms() public {
        _configureSettings();
        vm.startPrank(governance);

        // a rate change restates the collector; the caps are inclusive
        vm.expectEmit();
        emit ILoanMarketsFacet.LoanFeeTermsSet(
            SUBACCOUNT_TYPE_LOAN, MAX_FEE_RATE, MAX_FEE_RATE, makeAddr("feeCollector")
        );
        _setFeeRates(MAX_FEE_RATE, MAX_FEE_RATE);
        ILoanMarketsFacet.FeeTerms memory terms =
            ILoanMarketsFacet(address(controller)).getLoanFeeTerms(SUBACCOUNT_TYPE_LOAN);
        assertEq(terms.feeFloor, MAX_FEE_RATE);
        assertEq(terms.feeSpread, MAX_FEE_RATE);
        assertEq(terms.feeRecipient, makeAddr("feeCollector"));

        // a collector rotation restates the rates
        address newCollector = makeAddr("newCollector");
        vm.expectEmit();
        emit ILoanMarketsFacet.LoanFeeTermsSet(
            SUBACCOUNT_TYPE_LOAN, MAX_FEE_RATE, MAX_FEE_RATE, newCollector
        );
        IILoanMarketsFacet(address(controller)).setLoanFeeTerms(
            SUBACCOUNT_TYPE_LOAN, _feeTerms(MAX_FEE_RATE, MAX_FEE_RATE, newCollector)
        );
        terms = ILoanMarketsFacet(address(controller)).getLoanFeeTerms(SUBACCOUNT_TYPE_LOAN);
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
            abi.encodeWithSelector(ILoanMarketsFacet.MarketNotRegistered.selector, 9)
        );
        IILoanMarketsFacet(address(controller)).setLoanFeeTerms(9, _feeTerms(0, 0, collector));

        vm.expectRevert(ILoanMarketsFacet.InvalidFeeTerms.selector);
        IILoanMarketsFacet(address(controller)).setLoanFeeTerms(
            SUBACCOUNT_TYPE_LOAN, _feeTerms(MAX_FEE_RATE + 1, 0, collector)
        );
        vm.expectRevert(ILoanMarketsFacet.InvalidFeeTerms.selector);
        IILoanMarketsFacet(address(controller)).setLoanFeeTerms(
            SUBACCOUNT_TYPE_LOAN, _feeTerms(0, MAX_FEE_RATE + 1, collector)
        );
        vm.expectRevert(ILoanMarketsFacet.InvalidFeeRecipient.selector);
        IILoanMarketsFacet(address(controller)).setLoanFeeTerms(
            SUBACCOUNT_TYPE_LOAN, _feeTerms(0, 0, address(0))
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
                ILoanSubaccountRemote.InsufficientFundsForBridgeHome.selector, 0.01 ether
            )
        );
        ILoanSubaccountRemote(subaccount).lzCompose{value: 0.001 ether}(
            address(fxrpOft), guid, message, executor, ""
        );
        (, , uint128 collateral) = morpho.position(_marketId(), subaccount);
        assertEq(collateral, 100e6);
        assertFalse(ILoanSubaccountRemote(subaccount).usedOperations(operationId));
    }

    function testLzComposeWithdrawForwardsExcessToTheParent() public {
        // the operator quotes the return leg generously and signs the whole prepayment as the
        // floor: a delivery covering only the live quote still reverts on the floor, and the
        // full delivery's excess lands on the parent (the user's own account) - never on this
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
        _liquidate(subaccount, 0);
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
        _deliver(subaccount, 1, 100e6, _depositPayload(bytes32("op-1")));

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
            ILoanSubaccountRemote(subaccount).getLoanFeeState();
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
        emit ILoanSubaccountRemote.LoanFeeCheckpointed(
            parentPersonalAccount, 1060e18, 10e18 * 1e18
        );
        ILoanSubaccountRemote(subaccount).checkpointFee();
        (uint256 principal, , uint256 collectible, , , ) =
            ILoanSubaccountRemote(subaccount).getLoanFeeState();
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

        ILoanSubaccountRemote(subaccount).checkpointFee();
        // owed = max(5% * 1000, 100 + 3% * 1000) = 130; the fee is 130 - 100 = 30
        (uint256 principal, , uint256 collectible, , , ) =
            ILoanSubaccountRemote(subaccount).getLoanFeeState();
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

        ILoanSubaccountRemote(subaccount).checkpointFee();
        (uint256 principal, uint256 feeDebtX18, , , , ) =
            ILoanSubaccountRemote(subaccount).getLoanFeeState();
        assertApproxEqAbs(principal, 100e18, 1);
        assertEq(feeDebtX18, 70e18 * 1e18);

        // the shrunken base is what the next period is priced on
        vm.warp(vm.getBlockTimestamp() + 365 days);
        ILoanSubaccountRemote(subaccount).checkpointFee();
        (, feeDebtX18, , , , ) = ILoanSubaccountRemote(subaccount).getLoanFeeState();
        assertApproxEqAbs(feeDebtX18, 77e18 * 1e18, 1e18);
    }

    function testLiquidationKeepsFloorAccruingUntilPing() public {
        // a liquidation extinguishes debt with no event the account can see: the floor keeps
        // accruing on the stale principal until someone pings - prospectively only - and the
        // accrued claim is never auto-written-off
        address subaccount = _borrowedSubaccount(1000e18);
        vm.warp(vm.getBlockTimestamp() + 365 days);
        _liquidate(subaccount, 0);

        ILoanSubaccountRemote(subaccount).checkpointFee();
        (uint256 principal, uint256 feeDebtX18, , , , ) =
            ILoanSubaccountRemote(subaccount).getLoanFeeState();
        assertEq(principal, 0);
        assertEq(feeDebtX18, 70e18 * 1e18);

        // zero principal accrues nothing further; the claim simply stays outstanding
        vm.warp(vm.getBlockTimestamp() + 365 days);
        ILoanSubaccountRemote(subaccount).checkpointFee();
        (, feeDebtX18, , , , ) = ILoanSubaccountRemote(subaccount).getLoanFeeState();
        assertEq(feeDebtX18, 70e18 * 1e18);
    }

    function testCheckpointIsSharesFirstAndMorphoIndependentWhenDebtFree() public {
        // no Morpho liveness where none is needed: zero principal makes no Morpho call at
        // all, and zero live shares settle at zero debt without touching the IRM
        address borrowed = _borrowedSubaccount(1000e18);
        address subaccount = address(_deploySubaccount());
        morpho.setAccrueInterestReverts(true);
        ILoanSubaccountRemote(subaccount).checkpointFee();
        morpho.setAccrueInterestReverts(false);
        vm.warp(vm.getBlockTimestamp() + 365 days);
        _liquidate(borrowed, 0);
        morpho.setAccrueInterestReverts(true);
        // principal is stale-positive but the position has no shares: the checkpoint settles
        // at zero debt, charges the floor, and never invokes the IRM
        ILoanSubaccountRemote(borrowed).checkpointFee();
        (uint256 principal, uint256 feeDebtX18, , , , ) =
            ILoanSubaccountRemote(borrowed).getLoanFeeState();
        assertEq(principal, 0);
        assertEq(feeDebtX18, 70e18 * 1e18);
    }

    function testSameBlockCheckpointResyncsPrincipal() public {
        // the front-run regression: checkpoint at t, external repayment, checkpoint in the
        // same block - the zero-time checkpoint skips the fee math but must still re-read the
        // debt, or the next period would be charged on the stale pre-repayment base
        address subaccount = _borrowedSubaccount(1000e18);
        vm.warp(vm.getBlockTimestamp() + 365 days);
        ILoanSubaccountRemote(subaccount).checkpointFee();
        _externalRepay(subaccount, 900e18);
        ILoanSubaccountRemote(subaccount).checkpointFee();
        (uint256 principal, uint256 feeDebtX18, , , , ) =
            ILoanSubaccountRemote(subaccount).getLoanFeeState();
        assertApproxEqAbs(principal, 100e18, 1);
        assertEq(feeDebtX18, 70e18 * 1e18);

        vm.warp(vm.getBlockTimestamp() + 365 days);
        ILoanSubaccountRemote(subaccount).checkpointFee();
        (, feeDebtX18, , , , ) = ILoanSubaccountRemote(subaccount).getLoanFeeState();
        // the second year is priced on ~100, not the stale 1000
        assertApproxEqAbs(feeDebtX18, 77e18 * 1e18, 1e18);
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
        ILoanSubaccountRemote(subaccount).checkpointFee();
        (, uint256 feeDebtX18, , , uint64 fl, ) =
            ILoanSubaccountRemote(subaccount).getLoanFeeState();
        assertEq(feeDebtX18, 70e18 * 1e18);
        assertEq(fl, 0.14e18);

        // the next year is the new 14%
        vm.warp(vm.getBlockTimestamp() + 365 days);
        ILoanSubaccountRemote(subaccount).checkpointFee();
        (, feeDebtX18, , , , ) = ILoanSubaccountRemote(subaccount).getLoanFeeState();
        assertEq(feeDebtX18, 210e18 * 1e18);

        // the decrease direction: a dormant account keeps paying its snapshotted higher rate
        // until someone pings - the cut is never retroactive either
        vm.startPrank(governance);
        _setFeeRates(0.035e18, 0.005e18);
        vm.stopPrank();
        vm.warp(vm.getBlockTimestamp() + 365 days);
        ILoanSubaccountRemote(subaccount).checkpointFee();
        (, feeDebtX18, , , , ) = ILoanSubaccountRemote(subaccount).getLoanFeeState();
        assertEq(feeDebtX18, 350e18 * 1e18);

        vm.warp(vm.getBlockTimestamp() + 365 days);
        ILoanSubaccountRemote(subaccount).checkpointFee();
        (, feeDebtX18, , , , ) = ILoanSubaccountRemote(subaccount).getLoanFeeState();
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
            ILoanSubaccountRemote(subaccount).checkpointFee();
        }
        (, uint256 partitioned, , , , ) = ILoanSubaccountRemote(subaccount).getLoanFeeState();
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
        ILoanSubaccountRemote(subaccount).repay();
        (uint256 principal, uint256 feeDebtX18, , , , ) =
            ILoanSubaccountRemote(subaccount).getLoanFeeState();
        assertEq(principal, 0);
        assertEq(feeDebtX18, 0);

        // a year idle, then borrow again - only the new period accrues, at the current rates
        vm.warp(vm.getBlockTimestamp() + 365 days);
        vm.startPrank(governance);
        _setFeeRates(0.14e18, 0.02e18);
        vm.stopPrank();
        vm.expectEmit();
        emit ILoanSubaccountRemote.LoanFeePrincipalSynced(parentPersonalAccount, 500e18);
        _deliver(subaccount, 2, 0, _borrowPayload(
            bytes32("op-2"), DESTINATION_KIND_EVM,
            bytes32(uint256(uint160(makeAddr("dest")))), 500e18
        ));
        vm.warp(vm.getBlockTimestamp() + 365 days);
        ILoanSubaccountRemote(subaccount).checkpointFee();
        (principal, feeDebtX18, , , , ) = ILoanSubaccountRemote(subaccount).getLoanFeeState();
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
            controller.createSubaccount("rSecondBorrowerOwner", SUBACCOUNT_TYPE_LOAN);
        fxrp.mint(subaccountB, 100e6);
        _deliver(subaccountB, 1, 100e6, _borrowPayload(
            bytes32("op-b"), DESTINATION_KIND_EVM,
            bytes32(uint256(uint160(makeAddr("dest")))), 1000e18
        ));
        morpho.addPendingInterest(_marketId(), 100e18);

        // A's external repayment of 500 converts at the ACCRUED rate (total 2100, not 2000)
        _externalRepay(subaccountA, 500e18);
        vm.warp(vm.getBlockTimestamp() + 1);
        ILoanSubaccountRemote(subaccountB).checkpointFee();
        (uint256 principalB, , , , , ) = ILoanSubaccountRemote(subaccountB).getLoanFeeState();
        // B's share of the interest is exactly half: 1000 + 50; a stale-rate conversion
        // would have shifted this to ~1066
        assertApproxEqAbs(principalB, 1050e18, 1);
    }

    function testCheckpointPartitionPreservesTheFloorTotal() public {
        // two half-year checkpoints charge exactly the full-year floor; the
        // indivisible-partition test covers the sub-X18 truncation bound
        address subaccount = _borrowedSubaccount(1000e18);
        vm.warp(vm.getBlockTimestamp() + 365 days / 2);
        ILoanSubaccountRemote(subaccount).checkpointFee();
        (, uint256 halfYear, , , , ) = ILoanSubaccountRemote(subaccount).getLoanFeeState();
        assertEq(halfYear, 35e18 * 1e18);

        vm.warp(vm.getBlockTimestamp() + 365 days / 2);
        ILoanSubaccountRemote(subaccount).checkpointFee();
        (, uint256 fullYear, , , , ) = ILoanSubaccountRemote(subaccount).getLoanFeeState();
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

        ILoanSubaccountRemote(subaccount).checkpointFee();
        (, uint256 feeDebtX18, , , , ) = ILoanSubaccountRemote(subaccount).getLoanFeeState();
        assertEq(feeDebtX18, 0);
    }

    function testSecondBorrowSettlesTheElapsedPeriodFirst() public {
        // the worked example's second year opening: the new borrow's pre-checkpoint prices
        // the elapsed period on the old base, and the post-sync capitalizes to the canonical
        // new debt - the borrowed amount is never classified as market interest
        address subaccount = _borrowedSubaccount(1000e18);
        vm.warp(vm.getBlockTimestamp() + 365 days);
        morpho.addPendingInterest(_marketId(), 60e18);

        _deliver(subaccount, 2, 0, _borrowPayload(
            bytes32("op-2"), DESTINATION_KIND_EVM,
            bytes32(uint256(uint160(makeAddr("dest")))), 1000e18
        ));
        (uint256 principal, , uint256 collectible, uint64 last, , ) =
            ILoanSubaccountRemote(subaccount).getLoanFeeState();
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
            abi.encodeWithSelector(ILoanMarketsFacet.MarketNotRegistered.selector, typeB)
        );
        ILoanSubaccountRemote(subaccountB).checkpointFee();
    }

    function testRepayCollectsFeeThenPushesOnlyTheSurplus() public {
        // the pinned order: Morpho first, then the fee from the remainder, then the surplus -
        // closing through the rails costs the live debt plus the collectible, in one call
        address subaccount = _borrowedSubaccount(1000e18);
        vm.warp(vm.getBlockTimestamp() + 365 days);
        rlusd.mint(subaccount, 1100e18);

        vm.expectEmit();
        emit ILoanSubaccountRemote.LoanFeeCollected(makeAddr("feeCollector"), 70e18);
        vm.expectEmit();
        emit ILoanSubaccountRemote.LoanSurplusRecovered(parentPersonalAccount, 30e18);
        assertEq(ILoanSubaccountRemote(subaccount).repay(), 1000e18);
        assertEq(rlusd.balanceOf(makeAddr("feeCollector")), 70e18);
        assertEq(rlusd.balanceOf(parentPersonalAccount), 30e18);
        assertEq(rlusd.balanceOf(subaccount), 0);
        (, uint256 feeDebtX18, , , , ) = ILoanSubaccountRemote(subaccount).getLoanFeeState();
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
        emit ILoanSubaccountRemote.LoanFeeCollected(makeAddr("feeCollector"), feeShare);
        vm.expectEmit();
        emit ILoanSubaccountRemote.LoanRepaid(parentPersonalAccount, 1050e18 - feeShare);
        assertEq(ILoanSubaccountRemote(subaccount).repay(), 1050e18 - feeShare);
        assertEq(rlusd.balanceOf(makeAddr("feeCollector")), feeShare);
        assertEq(rlusd.balanceOf(subaccount), 0);
        (uint256 principal, uint256 feeDebtX18, , , , ) =
            ILoanSubaccountRemote(subaccount).getLoanFeeState();
        assertEq(feeDebtX18, (70e18 - feeShare) * 1e18);
        assertApproxEqAbs(principal, 1000e18 - (1050e18 - feeShare), 1);
        // the proportion survives the split: 1000:70 before, the same after (within the
        // share's round-down and the debt's share-conversion wei, scaled)
        assertApproxEqAbs(principal * 70, (70e18 - feeShare) * 1000, 2000);

        rlusd.mint(subaccount, 30e18);
        ILoanSubaccountRemote(subaccount).repay();
        assertEq(rlusd.balanceOf(makeAddr("feeCollector")), 70e18);
        assertApproxEqAbs(rlusd.balanceOf(parentPersonalAccount), 10e18, 2);
        (, feeDebtX18, , , , ) = ILoanSubaccountRemote(subaccount).getLoanFeeState();
        assertEq(feeDebtX18, 0);
        (, uint128 borrowShares, ) = morpho.position(_marketId(), subaccount);
        assertEq(borrowShares, 0);
    }

    function testRepayFeeLegHoldsWhilePausedAndReserves() public {
        // while paused the fee leg holds entirely: the Morpho repayment and the checkpoint
        // still run, tokens covering the fee stay RESERVED here (never pushed as surplus),
        // and a later repay collects them without another top-up
        address subaccount = _borrowedSubaccount(1000e18);
        vm.warp(vm.getBlockTimestamp() + 365 days);
        rlusd.mint(subaccount, 1100e18);
        _pauseController();

        vm.expectEmit();
        emit ILoanSubaccountRemote.LoanFeeReserved(makeAddr("feeCollector"), 70e18);
        assertEq(ILoanSubaccountRemote(subaccount).repay(), 1000e18);
        assertEq(rlusd.balanceOf(makeAddr("feeCollector")), 0);
        assertEq(rlusd.balanceOf(parentPersonalAccount), 30e18);
        assertEq(rlusd.balanceOf(subaccount), 70e18);

        _unpauseController();
        ILoanSubaccountRemote(subaccount).repay();
        assertEq(rlusd.balanceOf(makeAddr("feeCollector")), 70e18);
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

        assertEq(ILoanSubaccountRemote(subaccount).repay(), 1000e18 - feeShare);
        assertEq(rlusd.balanceOf(makeAddr("feeCollector")), feeShare);
        (uint256 principal, uint256 feeDebtX18, , , , ) =
            ILoanSubaccountRemote(subaccount).getLoanFeeState();
        assertEq(feeDebtX18, (70e18 - feeShare) * 1e18);
        assertApproxEqAbs(principal, feeShare, 1);
        (, uint128 borrowShares, ) = morpho.position(_marketId(), subaccount);
        assertGt(borrowShares, 0);
    }

    function testRepayProRataFeeShareHeldWhilePausedRepaysDebtInstead() public {
        // a partial payment while paused: the fee's share cannot leave, so it repays debt
        // with the rest (LoanFeeDeferred) - nothing is reserved on the account, the fee stays
        // owed in full, and the paused route is debt-first for its duration
        address subaccount = _borrowedSubaccount(1000e18);
        vm.warp(vm.getBlockTimestamp() + 365 days);
        rlusd.mint(subaccount, 100e18);
        _pauseController();

        vm.expectEmit();
        emit ILoanSubaccountRemote.LoanFeeDeferred(
            makeAddr("feeCollector"), uint256(100e18) * 70e18 / 1070e18
        );
        vm.expectEmit();
        emit ILoanSubaccountRemote.LoanRepaid(parentPersonalAccount, 100e18);
        assertEq(ILoanSubaccountRemote(subaccount).repay(), 100e18);
        assertEq(rlusd.balanceOf(makeAddr("feeCollector")), 0);
        assertEq(rlusd.balanceOf(subaccount), 0);
        (uint256 principal, uint256 feeDebtX18, , , , ) =
            ILoanSubaccountRemote(subaccount).getLoanFeeState();
        assertEq(feeDebtX18, 70e18 * 1e18);
        assertApproxEqAbs(principal, 900e18, 1);

        // unpaused, the next payment is split at the now higher fee-to-debt ratio: 70 of 970
        _unpauseController();
        rlusd.mint(subaccount, 97e18);
        ILoanSubaccountRemote(subaccount).repay();
        assertApproxEqAbs(rlusd.balanceOf(makeAddr("feeCollector")), 7e18, 1);
    }

    function testRepayProRataRoundsTheFeeShareDown() public {
        // the fee's share is rounded down and the remainder goes to the debt: one wei against
        // debt 1000 and fee 70 pays no fee at all
        address subaccount = _borrowedSubaccount(1000e18);
        vm.warp(vm.getBlockTimestamp() + 365 days);
        rlusd.mint(subaccount, 1);

        assertEq(ILoanSubaccountRemote(subaccount).repay(), 1);
        assertEq(rlusd.balanceOf(makeAddr("feeCollector")), 0);
        (, uint256 feeDebtX18, , , , ) = ILoanSubaccountRemote(subaccount).getLoanFeeState();
        assertEq(feeDebtX18, 70e18 * 1e18);
    }

    function testRepayProRataRoundingRemainderCanCompleteTheDebt() public {
        // one wei short of debt plus fee: the fee's share rounds down to the fee less one
        // wei, the remainder is exactly the debt, and the debt closes by shares - the split
        // reaches the close only when its round-down leaves Morpho exactly the debt (an edge
        // one wei wide here, F/D wide in general - see the next test)
        address subaccount = _borrowedSubaccount(1000e18);
        vm.warp(vm.getBlockTimestamp() + 365 days);
        ILoanSubaccountRemote(subaccount).checkpointFee();
        (uint256 principal, , uint256 collectible, , , ) =
            ILoanSubaccountRemote(subaccount).getLoanFeeState();
        rlusd.mint(subaccount, principal + collectible - 1);

        vm.expectEmit();
        emit ILoanSubaccountRemote.LoanFeeCollected(makeAddr("feeCollector"), collectible - 1);
        assertEq(ILoanSubaccountRemote(subaccount).repay(), principal);
        assertEq(rlusd.balanceOf(makeAddr("feeCollector")), collectible - 1);
        assertEq(rlusd.balanceOf(subaccount), 0);
        (, uint128 borrowShares, ) = morpho.position(_marketId(), subaccount);
        assertEq(borrowShares, 0);
        // the one wei stays owed: a whole base unit is never forgiven
        (, uint256 feeDebtX18, , , , ) = ILoanSubaccountRemote(subaccount).getLoanFeeState();
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
        ILoanSubaccountRemote(subaccount).checkpointFee();
        (uint256 principal, , uint256 collectible, , , ) =
            ILoanSubaccountRemote(subaccount).getLoanFeeState();
        assertApproxEqAbs(principal, 2e18, 1);
        assertEq(collectible, 7e18);
        uint256 payment = principal + collectible - 4;
        uint256 feeShare = payment * collectible / (principal + collectible);
        assertEq(payment - feeShare, principal);
        rlusd.mint(subaccount, payment);

        vm.expectEmit();
        emit ILoanSubaccountRemote.LoanFeeCollected(makeAddr("feeCollector"), feeShare);
        assertEq(ILoanSubaccountRemote(subaccount).repay(), principal);
        (, uint128 borrowShares, ) = morpho.position(_marketId(), subaccount);
        assertEq(borrowShares, 0);
        assertEq(rlusd.balanceOf(subaccount), 0);
        (, uint256 feeDebtX18, , , , ) = ILoanSubaccountRemote(subaccount).getLoanFeeState();
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
        ILoanSubaccountRemote(subaccount).repay();
        (, uint256 dustX18, uint256 collectible, , , ) =
            ILoanSubaccountRemote(subaccount).getLoanFeeState();
        assertEq(collectible, 0);
        assertGt(dustX18, 0);

        vm.expectEmit();
        emit ILoanSubaccountRemote.LoanFeeRemainderForgiven(dustX18);
        _deliverWithValue(
            subaccount, 2, 0,
            _withdrawPayload(bytes32("op-w"), 100e6),
            RETURN_MIN_VALUE
        );
        (, dustX18, , , , ) = ILoanSubaccountRemote(subaccount).getLoanFeeState();
        assertEq(dustX18, 0);
    }

    function testWithdrawSecuredFeeRidesUncollected() public {
        // the secured-claim rule: while the remaining collateral is worth at least 3x the
        // collectible fee, a withdrawal collects nothing - the position IS the security
        _configureSettings();
        (, address subaccount) = _parentAndSubaccount("rSecuredOwner");
        fxrp.mint(subaccount, 100e6);
        _deliver(subaccount, 1, 100e6, _borrowPayload(
            bytes32("op-borrow"), DESTINATION_KIND_EVM,
            bytes32(uint256(uint160(makeAddr("dest")))), 1000e18
        ));
        vm.warp(vm.getBlockTimestamp() + 30 days);
        ILoanSubaccountRemote(subaccount).checkpointFee();
        (, uint256 feeBefore, uint256 collectible, , , ) =
            ILoanSubaccountRemote(subaccount).getLoanFeeState();
        assertGt(collectible, 0);

        // remaining 90 FXRP is worth 180 RLUSD >= 3x the ~5.75 fee: no caps, no collection
        _deliverWithValue(
            subaccount, 2, 0,
            _withdrawPayload(bytes32("op-w"), 10e6),
            RETURN_MIN_VALUE
        );
        assertEq(rlusd.balanceOf(makeAddr("feeCollector")), 0);
        assertEq(fxrp.balanceOf(makeAddr("feeCollector")), 0);
        (, uint256 feeAfter, , , , ) = ILoanSubaccountRemote(subaccount).getLoanFeeState();
        assertEq(feeAfter, feeBefore);
        (, , uint256 amountLD, , , , ) = fxrpOft.lastSendParam();
        assertEq(amountLD, 10e6);
    }

    function testWithdrawStrippingSecurityIsBlockedUntilTheFeeIsPaid() public {
        // the exit that would leave the fee under-secured is refused - nothing is taken from
        // the collateral; the fee is paid in loan tokens through repay, then the same packet
        // passes
        _configureSettings();
        (, address subaccount) = _parentAndSubaccount("rStrippingOwner");
        fxrp.mint(subaccount, 100e6);
        _deliver(subaccount, 1, 100e6, _borrowPayload(
            bytes32("op-borrow"), DESTINATION_KIND_EVM,
            bytes32(uint256(uint160(makeAddr("dest")))), 1000e18
        ));
        vm.warp(vm.getBlockTimestamp() + 30 days);
        ILoanSubaccountRemote(subaccount).checkpointFee();
        (, , uint256 collectible, , , ) =
            ILoanSubaccountRemote(subaccount).getLoanFeeState();

        // remaining 2 FXRP (4 RLUSD) cannot secure the fee: refused, id unconsumed
        bytes memory payload = _withdrawPayload(bytes32("op-w"), 98e6);
        (bytes memory message, bytes32 guid) = _composeMessage(subaccount, 2, 0, payload);
        vm.deal(lzEndpoint, RETURN_MIN_VALUE);
        vm.prank(lzEndpoint);
        vm.expectRevert(
            abi.encodeWithSelector(ILoanSubaccountRemote.OutstandingLoanFee.selector, collectible)
        );
        ILoanSubaccountRemote(subaccount).lzCompose{value: RETURN_MIN_VALUE}(
            address(fxrpOft), guid, message, executor, ""
        );
        assertFalse(ILoanSubaccountRemote(subaccount).usedOperations(bytes32("op-w")));
        assertEq(fxrp.balanceOf(makeAddr("feeCollector")), 0);

        // loan tokens to the account, repay closes the debt and pays the fee, the packet passes
        rlusd.mint(subaccount, 1100e18);
        ILoanSubaccountRemote(subaccount).repay();
        assertEq(rlusd.balanceOf(makeAddr("feeCollector")), collectible);
        _deliverWithValue(subaccount, 2, 0, payload, RETURN_MIN_VALUE);
        assertTrue(ILoanSubaccountRemote(subaccount).usedOperations(bytes32("op-w")));
        (, , uint256 amountLD, , , , ) = fxrpOft.lastSendParam();
        assertEq(amountLD, 98e6);
    }

    function testWithdrawDeadOracleParksAndRepayIsTheEscape() public {
        // a reverting oracle values the security at nothing, so the gate refuses the exit:
        // the escape is repay - settle debt and fee through the subaccount, then the same
        // packet passes with nothing collectible, oracle-free
        _configureSettings();
        (, address subaccount) = _parentAndSubaccount("rDeadOracleGateOwner");
        fxrp.mint(subaccount, 100e6);
        _deliver(subaccount, 1, 100e6, _borrowPayload(
            bytes32("op-borrow"), DESTINATION_KIND_EVM,
            bytes32(uint256(uint160(makeAddr("dest")))), 1000e18
        ));
        vm.warp(vm.getBlockTimestamp() + 30 days);
        ILoanSubaccountRemote(subaccount).checkpointFee();
        (, , uint256 collectible, , , ) =
            ILoanSubaccountRemote(subaccount).getLoanFeeState();
        oracle.setPriceReverts(true);

        bytes memory payload = _withdrawPayload(bytes32("op-w"), 10e6);
        (bytes memory message, bytes32 guid) = _composeMessage(subaccount, 2, 0, payload);
        vm.deal(lzEndpoint, RETURN_MIN_VALUE);
        vm.prank(lzEndpoint);
        vm.expectRevert(
            abi.encodeWithSelector(ILoanSubaccountRemote.OutstandingLoanFee.selector, collectible)
        );
        ILoanSubaccountRemote(subaccount).lzCompose{value: RETURN_MIN_VALUE}(
            address(fxrpOft), guid, message, executor, ""
        );

        rlusd.mint(subaccount, 1100e18);
        ILoanSubaccountRemote(subaccount).repay();
        _deliverWithValue(subaccount, 2, 0, payload, RETURN_MIN_VALUE);
        assertTrue(ILoanSubaccountRemote(subaccount).usedOperations(bytes32("op-w")));
    }

    function testWithdrawZeroPricedOracleRefusesAndRepayIsTheEscape() public {
        // a zero price (answering, not reverting) also values the security at nothing: the
        // same refusal with the id unconsumed, and the same escape - once nothing is
        // collectible the retried packet passes without ever reading the still-zero oracle
        _configureSettings();
        (, address subaccount) = _parentAndSubaccount("rZeroPriceGateOwner");
        fxrp.mint(subaccount, 100e6);
        _deliver(subaccount, 1, 100e6, _borrowPayload(
            bytes32("op-borrow"), DESTINATION_KIND_EVM,
            bytes32(uint256(uint160(makeAddr("dest")))), 1000e18
        ));
        vm.warp(vm.getBlockTimestamp() + 30 days);
        ILoanSubaccountRemote(subaccount).checkpointFee();
        (, , uint256 collectible, , , ) =
            ILoanSubaccountRemote(subaccount).getLoanFeeState();
        oracle.setPrice(0);

        bytes memory payload = _withdrawPayload(bytes32("op-w"), 10e6);
        (bytes memory message, bytes32 guid) = _composeMessage(subaccount, 2, 0, payload);
        vm.deal(lzEndpoint, RETURN_MIN_VALUE);
        vm.prank(lzEndpoint);
        vm.expectRevert(
            abi.encodeWithSelector(ILoanSubaccountRemote.OutstandingLoanFee.selector, collectible)
        );
        ILoanSubaccountRemote(subaccount).lzCompose{value: RETURN_MIN_VALUE}(
            address(fxrpOft), guid, message, executor, ""
        );
        assertFalse(ILoanSubaccountRemote(subaccount).usedOperations(bytes32("op-w")));

        rlusd.mint(subaccount, 1100e18);
        ILoanSubaccountRemote(subaccount).repay();
        assertEq(rlusd.balanceOf(makeAddr("feeCollector")), collectible);
        _deliverWithValue(subaccount, 2, 0, payload, RETURN_MIN_VALUE);
        assertTrue(ILoanSubaccountRemote(subaccount).usedOperations(bytes32("op-w")));
        assertEq(oracle.storedPrice(), 0);
    }

    function testMorphoBlocksLiveDebtWithdrawUnderDeadOracleBeforeTheGate() public {
        // the premise the exit gate leans on, modelled by the mock: with live borrow shares
        // canonical Morpho reads the oracle in withdrawCollateral, so a dead oracle blocks a
        // live-debt withdrawal at Morpho itself - here with nothing collectible, where the
        // gate is oracle-free and Morpho is the only thing in the way. The escape is the
        // spec's: settle through repay (no shares, no health check), then the packet passes
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
        vm.expectRevert(bytes("oracle reverted"));
        ILoanSubaccountRemote(subaccount).lzCompose{value: RETURN_MIN_VALUE}(
            address(fxrpOft), guid, message, executor, ""
        );
        assertFalse(ILoanSubaccountRemote(subaccount).usedOperations(bytes32("op-w")));

        rlusd.mint(subaccount, 501e18);
        ILoanSubaccountRemote(subaccount).repay();
        _deliverWithValue(subaccount, 2, 0, payload, RETURN_MIN_VALUE);
        assertTrue(ILoanSubaccountRemote(subaccount).usedOperations(bytes32("op-w")));
    }

    function testMorphoEnforcesPositionHealthOnWithdraw() public {
        // "Morpho enforces position health": a withdrawal the fee gate passes still reverts
        // at Morpho when it would leave the position under its LLTV - retriable, id unconsumed
        morpho.setHealthCheckDisabled(false);
        _configureSettings();
        (, address subaccount) = _parentAndSubaccount("rMorphoHealthOwner");
        fxrp.mint(subaccount, 1000e6);
        _deliver(subaccount, 1, 1000e6, _borrowPayload(
            bytes32("op-borrow"), DESTINATION_KIND_EVM,
            bytes32(uint256(uint160(makeAddr("dest")))), 1000e18
        ));

        // 600 FXRP left = 1200 RLUSD x 77% = 924 < the 1000 owed
        bytes memory tooMuch = _withdrawPayload(bytes32("op-w"), 400e6);
        (bytes memory message, bytes32 guid) = _composeMessage(subaccount, 2, 0, tooMuch);
        vm.deal(lzEndpoint, RETURN_MIN_VALUE);
        vm.prank(lzEndpoint);
        vm.expectRevert(bytes("insufficient collateral"));
        ILoanSubaccountRemote(subaccount).lzCompose{value: RETURN_MIN_VALUE}(
            address(fxrpOft), guid, message, executor, ""
        );
        assertFalse(ILoanSubaccountRemote(subaccount).usedOperations(bytes32("op-w")));

        // 700 FXRP left = 1400 RLUSD x 77% = 1078 >= 1000: Morpho lets it through
        _deliverWithValue(
            subaccount, 2, 0, _withdrawPayload(bytes32("op-w"), 300e6), RETURN_MIN_VALUE
        );
        assertTrue(ILoanSubaccountRemote(subaccount).usedOperations(bytes32("op-w")));
    }

    function testOverlapTopUpOnTheSubaccountPaysTheFeeProRata() public {
        // the accepted overlap of the two exit limits: once the fee outgrows ~43% of the live
        // debt (here after a debt-only external repayment), a remainder Morpho's health check
        // accepts (debt <= 77% of it) can still fail the factor-3 gate. Subaccount RLUSD pays
        // the fee pro rata with the debt, so a top-up shrinks both - here enough for the gate
        // to pass with the loan still open; payLoanFee stays the fee-only way through
        morpho.setHealthCheckDisabled(false);
        _configureSettings();
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

        // the gate wants 3 x 7 = 21 against the 16 left - refused, id unconsumed
        bytes memory payload = _withdrawPayload(bytes32("op-w"), 92e6);
        (bytes memory message, bytes32 guid) = _composeMessage(subaccount, 2, 0, payload);
        vm.deal(lzEndpoint, RETURN_MIN_VALUE);
        vm.prank(lzEndpoint);
        vm.expectRevert(
            abi.encodeWithSelector(ILoanSubaccountRemote.OutstandingLoanFee.selector, 7e18)
        );
        ILoanSubaccountRemote(subaccount).lzCompose{value: RETURN_MIN_VALUE}(
            address(fxrpOft), guid, message, executor, ""
        );
        assertFalse(ILoanSubaccountRemote(subaccount).usedOperations(bytes32("op-w")));

        // a fee-sized top-up is split 7 x 7 / 17 to the fee and 7 x 10 / 17 to the debt: the
        // fee falls to 70 / 17 = 4.12 and the debt to 100 / 17 = 5.88, still 10:7
        rlusd.mint(subaccount, 7e18);
        uint256 feeShare = uint256(7e18) * 7e18 / 17e18;
        ILoanSubaccountRemote(subaccount).repay();
        assertEq(rlusd.balanceOf(makeAddr("feeCollector")), feeShare);
        (uint256 principal, , uint256 collectible, , , ) =
            ILoanSubaccountRemote(subaccount).getLoanFeeState();
        assertEq(collectible, 7e18 - feeShare);
        assertApproxEqAbs(principal, 10e18 - (7e18 - feeShare), 1);

        // 16 >= 3 x 4.12: the same packet now passes, the debt still open
        _deliverWithValue(subaccount, 2, 0, payload, RETURN_MIN_VALUE);
        assertTrue(ILoanSubaccountRemote(subaccount).usedOperations(bytes32("op-w")));
        (, , uint256 amountLD, , , , ) = fxrpOft.lastSendParam();
        assertEq(amountLD, 92e6);
        (, uint128 borrowShares, ) = morpho.position(_marketId(), subaccount);
        assertGt(borrowShares, 0);
    }

    function testMorphoEnforcesPositionHealthOnBorrow() public {
        // 100 FXRP = 200 RLUSD of collateral carries at most 154 RLUSD at LLTV 77%: a borrow
        // beyond it reverts at Morpho (retriable, id unconsumed), one within it executes
        morpho.setHealthCheckDisabled(false);
        address subaccount = _createConfiguredSubaccount();
        fxrp.mint(subaccount, 100e6);
        bytes32 dest = bytes32(uint256(uint160(makeAddr("dest"))));

        _deliverExpectRevert(
            subaccount, 1, _borrowPayload(bytes32("op-1"), DESTINATION_KIND_EVM, dest, 1000e18),
            bytes("insufficient collateral")
        );
        assertFalse(ILoanSubaccountRemote(subaccount).usedOperations(bytes32("op-1")));

        _deliver(
            subaccount, 1, 100e6,
            _borrowPayload(bytes32("op-1"), DESTINATION_KIND_EVM, dest, 150e18)
        );
        assertTrue(ILoanSubaccountRemote(subaccount).usedOperations(bytes32("op-1")));
    }

    function testWithdrawBeyondCollateralRevertsAtMorpho() public {
        // the account passes the signed amount through; Morpho's own bound (an underflow in
        // canonical Morpho, a require in the mock) rejects more than the position holds
        _configureSettings();
        (, address subaccount) = _parentAndSubaccount("rOverdrawOwner");
        fxrp.mint(subaccount, 100e6);
        _deliver(subaccount, 1, 100e6, _depositPayload(bytes32("op-dep")));

        bytes memory payload = _withdrawPayload(bytes32("op-w"), 101e6);
        (bytes memory message, bytes32 guid) = _composeMessage(subaccount, 2, 0, payload);
        vm.deal(lzEndpoint, RETURN_MIN_VALUE);
        vm.prank(lzEndpoint);
        vm.expectRevert(bytes("withdraw exceeds collateral"));
        ILoanSubaccountRemote(subaccount).lzCompose{value: RETURN_MIN_VALUE}(
            address(fxrpOft), guid, message, executor, ""
        );
        assertFalse(ILoanSubaccountRemote(subaccount).usedOperations(bytes32("op-w")));
    }

    function testSecurityFactorBoundaryIsInclusive() public {
        // remaining value == 3x the collectible passes uncollected (>=); one whole FXRP less
        // in the remainder is refused - a >=/> regression flips exactly this pair
        _configureSettings();
        (, address subaccount) = _parentAndSubaccount("rExactSecurityOwner");
        fxrp.mint(subaccount, 200e6);
        _deliver(subaccount, 1, 200e6, _borrowPayload(
            bytes32("op-borrow"), DESTINATION_KIND_EVM,
            bytes32(uint256(uint160(makeAddr("dest")))), 1000e18
        ));
        vm.warp(vm.getBlockTimestamp() + 365 days);
        ILoanSubaccountRemote(subaccount).checkpointFee();

        // 96 out leaves 104 FXRP = 208 RLUSD < 210: under-secured, refused
        bytes memory underSecured = _withdrawPayload(bytes32("op-w1"), 96e6);
        (bytes memory message, bytes32 guid) = _composeMessage(subaccount, 2, 0, underSecured);
        vm.deal(lzEndpoint, RETURN_MIN_VALUE);
        vm.prank(lzEndpoint);
        vm.expectRevert(
            abi.encodeWithSelector(ILoanSubaccountRemote.OutstandingLoanFee.selector, 70e18)
        );
        ILoanSubaccountRemote(subaccount).lzCompose{value: RETURN_MIN_VALUE}(
            address(fxrpOft), guid, message, executor, ""
        );

        // 95 out leaves 105 FXRP = 210 RLUSD == 3 x 70: exactly secured, rides uncollected
        _deliverWithValue(
            subaccount, 3, 0, _withdrawPayload(bytes32("op-w2"), 95e6), RETURN_MIN_VALUE
        );
        (, uint256 feeDebtX18, , , , ) = ILoanSubaccountRemote(subaccount).getLoanFeeState();
        assertEq(feeDebtX18, 70e18 * 1e18);
    }

    function testPausedWithdrawTerminalSkipsFinalizeFreshOnesWait() public {
        // the pinned pause placement: duplicates finalize during a pause (value to the
        // parent), a fresh withdrawal reverts before consuming anything
        _configureSettings();
        (address parent, address subaccount) = _borrowedPairWithFee("rPausedGateOwner");
        // clear debt and fee first so the withdrawal itself is gate-free
        rlusd.mint(subaccount, 1100e18);
        ILoanSubaccountRemote(subaccount).repay();
        bytes memory executed = _withdrawPayload(bytes32("op-w"), 40e6);
        _deliverWithValue(subaccount, 2, 0, executed, RETURN_MIN_VALUE);
        _pauseController();

        // the duplicate finalizes even while paused, its value forwarded to the parent
        uint256 parentNativeBefore = parent.balance;
        vm.expectEmit();
        emit ILoanSubaccountRemote.LoanActionSkipped(
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
        ILoanSubaccountRemote(subaccount).lzCompose{value: RETURN_MIN_VALUE}(
            address(fxrpOft), guid, message, executor, ""
        );
        assertFalse(ILoanSubaccountRemote(subaccount).usedOperations(bytes32("op-w2")));
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

        bytes memory stripping = _withdrawPayload(bytes32("op-w"), 100e6);
        (bytes memory message, bytes32 guid) = _composeMessage(subaccount, 2, 0, stripping);
        vm.deal(lzEndpoint, RETURN_MIN_VALUE);
        vm.prank(lzEndpoint);
        vm.expectRevert(
            abi.encodeWithSelector(ILoanSubaccountRemote.OutstandingLoanFee.selector, 70e18)
        );
        ILoanSubaccountRemote(subaccount).lzCompose{value: RETURN_MIN_VALUE}(
            address(fxrpOft), guid, message, executor, ""
        );
        assertFalse(ILoanSubaccountRemote(subaccount).usedOperations(bytes32("op-w")));

        // the fee paid in loan tokens through repay (payLoanFee is the other way) - the whole
        // collateral goes home
        rlusd.mint(subaccount, 70e18);
        ILoanSubaccountRemote(subaccount).repay();
        assertEq(rlusd.balanceOf(makeAddr("feeCollector")), 70e18);
        _deliverWithValue(subaccount, 2, 0, stripping, RETURN_MIN_VALUE);
        (, , uint256 amountLD, , , , ) = fxrpOft.lastSendParam();
        assertEq(amountLD, 100e6);
        (, uint256 feeDebtX18, , , , ) = ILoanSubaccountRemote(subaccount).getLoanFeeState();
        assertEq(feeDebtX18, 0);
    }

    function testSelfLiquidationLeavesTheClaimStanding() public {
        // the accepted junior-claim risk, end to end: a (self-)liquidation strips the
        // position past the gates, but the claim is never auto-written-off - later assets
        // on the account still answer to it
        _configureSettings();
        (, address subaccount) = _borrowedPairWithFee("rSelfLiqOwner");
        _liquidate(subaccount, 0);
        ILoanSubaccountRemote(subaccount).checkpointFee();
        (, uint256 feeDebtX18, , , , ) = ILoanSubaccountRemote(subaccount).getLoanFeeState();
        assertEq(feeDebtX18, 70e18 * 1e18);

        // idle FXRP arriving later has one route home - into the position, then a signed
        // withdraw - and that withdraw cannot pass the now-unsecured claim
        fxrp.mint(subaccount, 5e6);
        ILoanSubaccountRemote(subaccount).depositIdleFxrp();
        bytes memory payload = _withdrawPayload(bytes32("op-w"), 5e6);
        (bytes memory message, bytes32 guid) = _composeMessage(subaccount, 2, 0, payload);
        vm.deal(lzEndpoint, RETURN_MIN_VALUE);
        vm.prank(lzEndpoint);
        vm.expectRevert(
            abi.encodeWithSelector(ILoanSubaccountRemote.OutstandingLoanFee.selector, 70e18)
        );
        ILoanSubaccountRemote(subaccount).lzCompose{value: RETURN_MIN_VALUE}(
            address(fxrpOft), guid, message, executor, ""
        );

        // paying the claim (the free direction + repay) reopens the exit
        rlusd.mint(subaccount, 70e18);
        ILoanSubaccountRemote(subaccount).repay();
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
        ILoanSubaccountRemote(subaccount).repay();
        (, uint128 sharesAfter, ) = morpho.position(_marketId(), subaccount);
        assertLt(sharesAfter, sharesBefore);
        assertEq(rlusd.balanceOf(subaccount), 0);
        // the fee is measured and paid pro rata - nothing was stolen, nothing collected
        // beyond the payment's share of it
        uint256 feeShare = uint256(100e18) * 70e18 / 1070e18;
        (, uint256 feeDebtX18, , , , ) = ILoanSubaccountRemote(subaccount).getLoanFeeState();
        assertEq(feeDebtX18, (70e18 - feeShare) * 1e18);
        assertEq(rlusd.balanceOf(makeAddr("feeCollector")), feeShare);
    }

    function testSequentialExitsWithPriceMovesKeepTheLedgerConsistent() public {
        // the stateful chain single tests cannot catch: secured exits, price moves, more
        // accrual, then a refused exit reopened by repay - the ledger must be exact throughout
        _configureSettings();
        (, address subaccount) = _parentAndSubaccount("rSequenceOwner");
        fxrp.mint(subaccount, 300e6);
        _deliver(subaccount, 1, 300e6, _borrowPayload(
            bytes32("op-borrow"), DESTINATION_KIND_EVM,
            bytes32(uint256(uint160(makeAddr("dest")))), 1000e18
        ));

        // half a year: fee 35; remaining 250 FXRP = 500 RLUSD >= 105 - secured, uncollected
        vm.warp(vm.getBlockTimestamp() + 365 days / 2);
        _deliverWithValue(
            subaccount, 2, 0,
            _withdrawPayload(bytes32("op-w1"), 50e6),
            RETURN_MIN_VALUE
        );
        (, uint256 feeDebtX18, , , , ) = ILoanSubaccountRemote(subaccount).getLoanFeeState();
        assertEq(feeDebtX18, 35e18 * 1e18);

        // price halves; remaining 200 FXRP = 200 RLUSD still >= 105 - still secured
        oracle.setPrice(1e48);
        _deliverWithValue(
            subaccount, 3, 0,
            _withdrawPayload(bytes32("op-w2"), 50e6),
            RETURN_MIN_VALUE
        );
        assertEq(fxrp.balanceOf(makeAddr("feeCollector")), 0);

        // another half year (fee 70) and another halving: 200 FXRP = 100 RLUSD < 210 -
        // the next exit is refused at the CURRENT price
        vm.warp(vm.getBlockTimestamp() + 365 days / 2);
        oracle.setPrice(0.5e48);
        bytes memory refused = _withdrawPayload(bytes32("op-w3"), 150e6);
        (bytes memory message, bytes32 guid) = _composeMessage(subaccount, 4, 0, refused);
        vm.deal(lzEndpoint, RETURN_MIN_VALUE);
        vm.prank(lzEndpoint);
        vm.expectRevert(
            abi.encodeWithSelector(ILoanSubaccountRemote.OutstandingLoanFee.selector, 70e18)
        );
        ILoanSubaccountRemote(subaccount).lzCompose{value: RETURN_MIN_VALUE}(
            address(fxrpOft), guid, message, executor, ""
        );

        // debt and fee paid in loan tokens through repay: the exit passes in full, and the
        // ledger is exact at every step
        rlusd.mint(subaccount, 1071e18);
        ILoanSubaccountRemote(subaccount).repay();
        assertEq(rlusd.balanceOf(makeAddr("feeCollector")), 70e18);
        _deliverWithValue(subaccount, 4, 0, refused, RETURN_MIN_VALUE);
        (, , uint256 amountLD, , , , ) = fxrpOft.lastSendParam();
        assertEq(amountLD, 150e6);
        (, feeDebtX18, , , , ) = ILoanSubaccountRemote(subaccount).getLoanFeeState();
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
            subaccounts[i] = controller.createSubaccount(owners[i], SUBACCOUNT_TYPE_LOAN);
            fxrp.mint(subaccounts[i], 100e6);
            _deliver(subaccounts[i], 1, 100e6, _borrowPayload(
                bytes32("op-borrow"), DESTINATION_KIND_EVM,
                bytes32(uint256(uint160(makeAddr("dest")))), 1000e18
            ));
        }
        vm.warp(vm.getBlockTimestamp() + 365 days);

        // step 1: pre-change pass (C missed); step 2: the change; step 3: post-change pass
        ILoanSubaccountRemote(subaccounts[0]).checkpointFee();
        ILoanSubaccountRemote(subaccounts[1]).checkpointFee();
        vm.startPrank(governance);
        _setFeeRates(0.14e18, 0.02e18);
        vm.stopPrank();
        ILoanSubaccountRemote(subaccounts[0]).checkpointFee();
        ILoanSubaccountRemote(subaccounts[1]).checkpointFee();

        vm.warp(vm.getBlockTimestamp() + 365 days);
        for (uint256 i = 0; i < 3; i++) {
            ILoanSubaccountRemote(subaccounts[i]).checkpointFee();
        }
        // A and B: year 1 at 7% (70) + year 2 at 14% (140)
        (, uint256 feeA, , , , ) = ILoanSubaccountRemote(subaccounts[0]).getLoanFeeState();
        (, uint256 feeB, , , , ) = ILoanSubaccountRemote(subaccounts[1]).getLoanFeeState();
        assertEq(feeA, 210e18 * 1e18);
        assertEq(feeB, 210e18 * 1e18);
        // C, missed by both passes: two years at the OLD 7% snapshot - late, in the user's
        // favor, never retroactive
        (, uint256 feeC, , , , ) = ILoanSubaccountRemote(subaccounts[2]).getLoanFeeState();
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
        emit ILoanSubaccountRemote.LoanActionSkipped(
            pairParent, bytes32("op-2"), SKIP_REASON_EXPIRED, _guidFor(2)
        );
        _deliver(subaccount, 2, 20e6, _borrowPayloadAt(
            bytes32("op-2"), uint64(vm.getBlockTimestamp() - 1), DESTINATION_KIND_EVM,
            bytes32(uint256(uint160(makeAddr("dest")))), 100e18
        ));

        // the elapsed year is priced at the 7% SNAPSHOT (fee 70): the under-secured exit is
        // refused and the idle 20 is untouched - it is not fee fuel
        bytes memory payload = _withdrawPayload(bytes32("op-w"), 40e6);
        (bytes memory message, bytes32 guid) = _composeMessage(subaccount, 3, 0, payload);
        vm.deal(lzEndpoint, RETURN_MIN_VALUE);
        vm.prank(lzEndpoint);
        vm.expectRevert(
            abi.encodeWithSelector(ILoanSubaccountRemote.OutstandingLoanFee.selector, 70e18)
        );
        ILoanSubaccountRemote(subaccount).lzCompose{value: RETURN_MIN_VALUE}(
            address(fxrpOft), guid, message, executor, ""
        );
        assertEq(fxrp.balanceOf(makeAddr("feeCollector")), 0);
        assertEq(fxrp.balanceOf(subaccount), 20e6);

        ILoanSubaccountRemote(subaccount).depositIdleFxrp();
        assertEq(fxrp.balanceOf(subaccount), 0);
        (, , uint128 collateral) = morpho.position(_marketId(), subaccount);
        assertEq(collateral, 120e6);
    }

    function testMixedInterestCheckpointPathDependenceIsThePromise() public {
        // the design's per-checkpoint promise, pinned: zero interest in the first half-year,
        // heavy interest in the second - the account checkpointed halfway owes ~40 (35 floor
        // + 5 spread), the untouched one owes ~10 (interest ate the whole-year floor). Both
        // are correct; the advertised measurement is per-checkpoint, not whole-period.
        _configureSettings();
        address pinged = controller.createSubaccount("rPingedOwner", SUBACCOUNT_TYPE_LOAN);
        address dormant = controller.createSubaccount("rDormantOwner", SUBACCOUNT_TYPE_LOAN);
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
        ILoanSubaccountRemote(pinged).checkpointFee();
        // the market's interest arrives entirely in the second half: 100 per position
        morpho.addPendingInterest(_marketId(), 200e18);
        vm.warp(vm.getBlockTimestamp() + 365 days / 2);
        ILoanSubaccountRemote(pinged).checkpointFee();
        ILoanSubaccountRemote(dormant).checkpointFee();

        (, uint256 feePinged, , , , ) = ILoanSubaccountRemote(pinged).getLoanFeeState();
        (, uint256 feeDormant, , , , ) = ILoanSubaccountRemote(dormant).getLoanFeeState();
        assertApproxEqAbs(feePinged, 40e18 * 1e18, 2e18);
        assertApproxEqAbs(feeDormant, 10e18 * 1e18, 2e18);
    }

    function testRepayFrozenFeeRecipientReservesAndRetries() public {
        // a recipient the token refuses must never roll back the repayment: the fee stays
        // owed and reserved, and a later repay retries the transfer
        _configureSettings();
        uint256 typeB = 2;
        MockFreezableToken frozenRlusd = new MockFreezableToken("Frozen RLUSD", "RLUSD", 18);
        ILoanMarketsFacet.Market memory marketB = _defaultMarket();
        marketB.marketParams.loanToken = address(frozenRlusd);
        morpho.createMarket(marketB.marketParams);
        vm.startPrank(governance);
        controller.setSubaccountImplementation(typeB, address(loanChainImpl));
        IILoanMarketsFacet(address(controller)).registerLoanMarket(typeB, marketB);
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
        emit ILoanSubaccountRemote.LoanFeeReserved(makeAddr("feeCollector"), 70e18);
        ILoanSubaccountRemote(subaccount).repay();
        assertEq(frozenRlusd.balanceOf(subaccount), 70e18);
        (, uint256 feeDebtX18, , , , ) = ILoanSubaccountRemote(subaccount).getLoanFeeState();
        assertEq(feeDebtX18, 70e18 * 1e18);

        frozenRlusd.setFrozen(makeAddr("feeCollector"), false);
        ILoanSubaccountRemote(subaccount).repay();
        assertEq(frozenRlusd.balanceOf(makeAddr("feeCollector")), 70e18);
        (, feeDebtX18, , , , ) = ILoanSubaccountRemote(subaccount).getLoanFeeState();
        assertEq(feeDebtX18, 0);
    }

    function testRepayProRataFeeShareRefusedByTheTokenRepaysDebtInstead() public {
        // a recipient the token refuses: the fee's share of a partial payment repays debt
        // instead (LoanFeeDeferred), the repayment stands and the fee stays owed; unfrozen,
        // the next payment pays its share normally
        _configureSettings();
        uint256 typeB = 2;
        MockFreezableToken frozenRlusd = new MockFreezableToken("Frozen RLUSD", "RLUSD", 18);
        ILoanMarketsFacet.Market memory marketB = _defaultMarket();
        marketB.marketParams.loanToken = address(frozenRlusd);
        morpho.createMarket(marketB.marketParams);
        vm.startPrank(governance);
        controller.setSubaccountImplementation(typeB, address(loanChainImpl));
        IILoanMarketsFacet(address(controller)).registerLoanMarket(typeB, marketB);
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
        emit ILoanSubaccountRemote.LoanFeeDeferred(makeAddr("feeCollector"), feeShare);
        assertEq(ILoanSubaccountRemote(subaccount).repay(), 100e18);
        assertEq(frozenRlusd.balanceOf(subaccount), 0);
        assertEq(frozenRlusd.balanceOf(makeAddr("feeCollector")), 0);
        (, uint256 feeDebtX18, , , , ) = ILoanSubaccountRemote(subaccount).getLoanFeeState();
        assertEq(feeDebtX18, 70e18 * 1e18);

        frozenRlusd.setFrozen(makeAddr("feeCollector"), false);
        frozenRlusd.mint(subaccount, 97e18);
        ILoanSubaccountRemote(subaccount).repay();
        assertApproxEqAbs(frozenRlusd.balanceOf(makeAddr("feeCollector")), 7e18, 1);
    }

    function testPayLoanFeeFromParentUnblocksTheOverlapWithoutClosingTheDebt() public {
        // the fee-only way through the overlap: the parent pays exactly the collectible from
        // its own RLUSD, nothing touches the debt, and the refused withdrawal passes with the
        // loan still open
        morpho.setHealthCheckDisabled(false);
        _configureSettings();
        (address parent, address subaccount) = _parentAndSubaccount("rPayFeeOverlapOwner");
        fxrp.mint(subaccount, 100e6);
        _deliver(subaccount, 1, 100e6, _borrowPayload(
            bytes32("op-borrow"), DESTINATION_KIND_EVM,
            bytes32(uint256(uint160(makeAddr("dest")))), 100e18
        ));
        vm.warp(vm.getBlockTimestamp() + 365 days);
        _externalRepay(subaccount, 90e18);

        bytes memory payload = _withdrawPayload(bytes32("op-w"), 92e6);
        (bytes memory message, bytes32 guid) = _composeMessage(subaccount, 2, 0, payload);
        vm.deal(lzEndpoint, RETURN_MIN_VALUE);
        vm.prank(lzEndpoint);
        vm.expectRevert(
            abi.encodeWithSelector(ILoanSubaccountRemote.OutstandingLoanFee.selector, 7e18)
        );
        ILoanSubaccountRemote(subaccount).lzCompose{value: RETURN_MIN_VALUE}(
            address(fxrpOft), guid, message, executor, ""
        );

        rlusd.mint(parent, 7e18);
        vm.startPrank(parent);
        rlusd.approve(subaccount, 7e18);
        vm.expectEmit();
        emit ILoanSubaccountRemote.LoanFeeCollected(makeAddr("feeCollector"), 7e18);
        uint256 paid = ILoanSubaccountRemote(subaccount).payLoanFee(7e18);
        vm.stopPrank();
        assertEq(paid, 7e18);
        assertEq(rlusd.balanceOf(makeAddr("feeCollector")), 7e18);
        assertEq(rlusd.balanceOf(parent), 0);
        assertEq(rlusd.balanceOf(subaccount), 0);
        (uint256 principal, uint256 feeDebtX18, , , , ) =
            ILoanSubaccountRemote(subaccount).getLoanFeeState();
        assertEq(feeDebtX18, 0);
        assertEq(principal, 10e18);

        _deliverWithValue(subaccount, 2, 0, payload, RETURN_MIN_VALUE);
        assertTrue(ILoanSubaccountRemote(subaccount).usedOperations(bytes32("op-w")));
        (, , uint256 amountLD, , , , ) = fxrpOft.lastSendParam();
        assertEq(amountLD, 92e6);
        (principal, , , , , ) = ILoanSubaccountRemote(subaccount).getLoanFeeState();
        assertEq(principal, 10e18);
    }

    function testPayLoanFeeClampsToTheCollectible() public {
        // the signed amount is a ceiling: more than owed pays exactly the collectible; the
        // leftover allowance cannot be spent by a second call once nothing is owed - and is why
        // the canonical batch ends with approve(0)
        _configureSettings();
        (address parent, address subaccount) = _borrowedPairWithFee("rPayFeeClampOwner");
        rlusd.mint(parent, 100e18);
        vm.startPrank(parent);
        rlusd.approve(subaccount, 100e18);
        uint256 paid = ILoanSubaccountRemote(subaccount).payLoanFee(100e18);
        assertEq(paid, 70e18);
        assertEq(rlusd.balanceOf(makeAddr("feeCollector")), 70e18);
        assertEq(rlusd.allowance(parent, subaccount), 30e18);
        (, uint256 feeDebtX18, , , , ) = ILoanSubaccountRemote(subaccount).getLoanFeeState();
        assertEq(feeDebtX18, 0);

        vm.expectRevert(ILoanSubaccountRemote.NothingCollectible.selector);
        ILoanSubaccountRemote(subaccount).payLoanFee(30e18);
        vm.stopPrank();
        assertEq(rlusd.balanceOf(parent), 30e18);
    }

    function testPayLoanFeePartialPaymentOnADebtFreeAccountKeepsTheRestOwed() public {
        // the cap below the collectible, on a debt-free position: exactly the cap is paid, the
        // whole-unit remainder stays owed (dust forgiveness is for sub-unit remainders only)
        // and keeps the exit refused until the rest is paid
        _configureSettings();
        (address parent, address subaccount) = _borrowedPairWithFee("rPartialPayFeeOwner");
        _externalRepay(subaccount, 1000e18);
        rlusd.mint(parent, 70e18);
        vm.startPrank(parent);
        rlusd.approve(subaccount, 70e18);
        assertEq(ILoanSubaccountRemote(subaccount).payLoanFee(1e18), 1e18);
        vm.stopPrank();
        assertEq(rlusd.balanceOf(makeAddr("feeCollector")), 1e18);
        (uint256 principal, uint256 feeDebtX18, uint256 collectible, , , ) =
            ILoanSubaccountRemote(subaccount).getLoanFeeState();
        assertEq(principal, 0);
        assertEq(feeDebtX18, 69e18 * 1e18);
        assertEq(collectible, 69e18);

        bytes memory stripping = _withdrawPayload(bytes32("op-w"), 100e6);
        (bytes memory message, bytes32 guid) = _composeMessage(subaccount, 2, 0, stripping);
        vm.deal(lzEndpoint, RETURN_MIN_VALUE);
        vm.prank(lzEndpoint);
        vm.expectRevert(
            abi.encodeWithSelector(ILoanSubaccountRemote.OutstandingLoanFee.selector, 69e18)
        );
        ILoanSubaccountRemote(subaccount).lzCompose{value: RETURN_MIN_VALUE}(
            address(fxrpOft), guid, message, executor, ""
        );

        vm.prank(parent);
        assertEq(ILoanSubaccountRemote(subaccount).payLoanFee(69e18), 69e18);
        assertEq(rlusd.balanceOf(makeAddr("feeCollector")), 70e18);
        _deliverWithValue(subaccount, 2, 0, stripping, RETURN_MIN_VALUE);
        (, , uint256 amountLD, , , , ) = fxrpOft.lastSendParam();
        assertEq(amountLD, 100e6);
    }

    function testPayLoanFeeForgivesOnlySubUnitRemainders() public {
        // the forgiveness boundary: one second past the year puts a sub-base-unit tail on
        // top of the fee. Paying down to exactly one base unit leaves it owed (the remainder
        // is >= 1e18 at WAD precision); paying that last unit leaves only the tail, which is
        // forgiven with its exact amount
        _configureSettings();
        (address parent, address subaccount) = _borrowedPairWithFee("rDustBoundaryOwner");
        vm.warp(vm.getBlockTimestamp() + 1);
        _externalRepay(subaccount, 1000e18);
        ILoanSubaccountRemote(subaccount).checkpointFee();
        (, uint256 feeDebtX18, uint256 collectible, , , ) =
            ILoanSubaccountRemote(subaccount).getLoanFeeState();
        uint256 tail = feeDebtX18 - collectible * 1e18;
        assertGt(tail, 0);
        assertLt(tail, 1e18);

        rlusd.mint(parent, collectible);
        vm.startPrank(parent);
        rlusd.approve(subaccount, collectible);
        assertEq(ILoanSubaccountRemote(subaccount).payLoanFee(collectible - 1), collectible - 1);
        (, feeDebtX18, , , , ) = ILoanSubaccountRemote(subaccount).getLoanFeeState();
        assertEq(feeDebtX18, 1e18 + tail);

        vm.expectEmit();
        emit ILoanSubaccountRemote.LoanFeeRemainderForgiven(tail);
        assertEq(ILoanSubaccountRemote(subaccount).payLoanFee(1), 1);
        vm.stopPrank();
        (, feeDebtX18, , , , ) = ILoanSubaccountRemote(subaccount).getLoanFeeState();
        assertEq(feeDebtX18, 0);
        assertEq(rlusd.balanceOf(makeAddr("feeCollector")), collectible);
    }

    function testPayLoanFeeGuards() public {
        // only the parent; a non-zero cap; held while paused; an unapproved parent reverts
        // whole and retriable with the fee untouched
        _configureSettings();
        (address parent, address subaccount) = _borrowedPairWithFee("rPayFeeGuardOwner");
        ILoanSubaccountRemote(subaccount).checkpointFee();
        rlusd.mint(parent, 70e18);

        vm.expectRevert(ISubaccount.OnlyParent.selector);
        ILoanSubaccountRemote(subaccount).payLoanFee(70e18);

        vm.prank(parent);
        vm.expectRevert(ILoanSubaccountRemote.ZeroAmount.selector);
        ILoanSubaccountRemote(subaccount).payLoanFee(0);

        vm.prank(parent);
        vm.expectRevert();
        ILoanSubaccountRemote(subaccount).payLoanFee(70e18);
        (, uint256 feeDebtX18, , , , ) = ILoanSubaccountRemote(subaccount).getLoanFeeState();
        assertEq(feeDebtX18, 70e18 * 1e18);

        _pauseController();
        vm.startPrank(parent);
        rlusd.approve(subaccount, 70e18);
        vm.expectRevert(IPauseFacet.IsPaused.selector);
        ILoanSubaccountRemote(subaccount).payLoanFee(70e18);
        vm.stopPrank();
        _unpauseController();

        vm.prank(parent);
        assertEq(ILoanSubaccountRemote(subaccount).payLoanFee(70e18), 70e18);
        assertEq(rlusd.balanceOf(makeAddr("feeCollector")), 70e18);
    }

    function testPayLoanFeeThroughTheParentBatch() public {
        // the shape the front end signs: one cross-chain user operation on the remote Personal
        // Account - approve, payLoanFee, approve(0) - all or nothing; then the parked exit passes
        _configureSettings();
        (address parent, address subaccount) = _borrowedPairWithFee("rPayFeeBatchOwner");
        _externalRepay(subaccount, 1000e18);
        rlusd.mint(parent, 80e18);

        bytes memory stripping = _withdrawPayload(bytes32("op-w"), 100e6);
        (bytes memory message, bytes32 guid) = _composeMessage(subaccount, 2, 0, stripping);
        vm.deal(lzEndpoint, RETURN_MIN_VALUE);
        vm.prank(lzEndpoint);
        vm.expectRevert(
            abi.encodeWithSelector(ILoanSubaccountRemote.OutstandingLoanFee.selector, 70e18)
        );
        ILoanSubaccountRemote(subaccount).lzCompose{value: RETURN_MIN_VALUE}(
            address(fxrpOft), guid, message, executor, ""
        );

        // approve a little above the quoted fee, pay (clamped to what is owed), revoke the rest
        IPersonalAccountRemote.Call[] memory calls = new IPersonalAccountRemote.Call[](3);
        calls[0] = IPersonalAccountRemote.Call({
            target: address(rlusd), value: 0,
            data: abi.encodeCall(IERC20.approve, (subaccount, 80e18))
        });
        calls[1] = IPersonalAccountRemote.Call({
            target: subaccount, value: 0,
            data: abi.encodeCall(ILoanSubaccountRemote.payLoanFee, (80e18))
        });
        calls[2] = IPersonalAccountRemote.Call({
            target: address(rlusd), value: 0,
            data: abi.encodeCall(IERC20.approve, (subaccount, 0))
        });
        bytes memory batch = abi.encode(
            PAYLOAD_VERSION_1,
            PA_ACTION_EXECUTE,
            abi.encode(bytes32("op-fee"), uint64(vm.getBlockTimestamp() + 1 hours), calls)
        );
        (bytes memory paMessage, bytes32 paGuid) = _composeMessage(parent, 3, 0, batch);
        vm.prank(lzEndpoint);
        IPersonalAccountRemote(parent).lzCompose(address(fxrpOft), paGuid, paMessage, executor, "");
        assertTrue(IPersonalAccountRemote(parent).usedOperations(bytes32("op-fee")));
        assertEq(rlusd.balanceOf(makeAddr("feeCollector")), 70e18);
        assertEq(rlusd.balanceOf(parent), 10e18);
        assertEq(rlusd.allowance(parent, subaccount), 0);

        _deliverWithValue(subaccount, 2, 0, stripping, RETURN_MIN_VALUE);
        (, , uint256 amountLD, , , , ) = fxrpOft.lastSendParam();
        assertEq(amountLD, 100e6);
    }

    function testFrozenSubaccountKeepsTheExitGatedUntilUnfrozen() public {
        // the repay path runs through this address: frozen, no loan tokens can reach it and
        // repay has nothing to work with, so an under-secured exit stays refused until
        // unfreezing, funding and repaying (payLoanFee is no way around it either - the token
        // checks the spender, see the next test)
        _configureSettings();
        uint256 typeB = 2;
        MockFreezableToken frozenRlusd = new MockFreezableToken("Frozen RLUSD", "RLUSD", 18);
        ILoanMarketsFacet.Market memory marketB = _defaultMarket();
        marketB.marketParams.loanToken = address(frozenRlusd);
        morpho.createMarket(marketB.marketParams);
        vm.startPrank(governance);
        controller.setSubaccountImplementation(typeB, address(loanChainImpl));
        IILoanMarketsFacet(address(controller)).registerLoanMarket(typeB, marketB);
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

        // 2 FXRP left = 4 RLUSD against a 70 fee: refused
        bytes memory payload = _withdrawPayload(bytes32("op-w"), 98e6);
        (bytes memory message, bytes32 guid) = _composeMessage(subaccount, 2, 0, payload);
        vm.deal(lzEndpoint, RETURN_MIN_VALUE);
        vm.prank(lzEndpoint);
        vm.expectRevert(
            abi.encodeWithSelector(ILoanSubaccountRemote.OutstandingLoanFee.selector, 70e18)
        );
        ILoanSubaccountRemote(subaccount).lzCompose{value: RETURN_MIN_VALUE}(
            address(fxrpOft), guid, message, executor, ""
        );
        assertFalse(ILoanSubaccountRemote(subaccount).usedOperations(bytes32("op-w")));

        // the settlement cannot even be funded while frozen
        vm.expectRevert(
            abi.encodeWithSelector(MockFreezableToken.FrozenAccount.selector, subaccount)
        );
        frozenRlusd.mint(subaccount, 1100e18);
        vm.expectRevert(ILoanSubaccountRemote.NothingToRepay.selector);
        ILoanSubaccountRemote(subaccount).repay();

        frozenRlusd.setFrozen(subaccount, false);
        frozenRlusd.mint(subaccount, 1100e18);
        ILoanSubaccountRemote(subaccount).repay();
        assertEq(frozenRlusd.balanceOf(makeAddr("feeCollector")), 70e18);
        _deliverWithValue(subaccount, 2, 0, payload, RETURN_MIN_VALUE);
        assertTrue(ILoanSubaccountRemote(subaccount).usedOperations(bytes32("op-w")));
        (, , uint256 amountLD, , , , ) = fxrpOft.lastSendParam();
        assertEq(amountLD, 98e6);
    }

    function testPayLoanFeeDoesNotWorkAroundAFrozenSubaccount() public {
        // RLUSD checks the spender as well as sender and receiver, and payLoanFee spends the
        // parent's allowance FROM the subaccount: with the subaccount frozen the approval to
        // it reverts, an allowance granted earlier cannot be spent, the fee stays owed and the
        // FXRP exit stays gated. A frozen subaccount has no fee rail - payLoanFee is not a
        // freeze escape (see the TODO's decision D on keeping it at all)
        _configureSettings();
        uint256 typeB = 2;
        MockFreezableToken frozenRlusd = new MockFreezableToken("Frozen RLUSD", "RLUSD", 18);
        ILoanMarketsFacet.Market memory marketB = _defaultMarket();
        marketB.marketParams.loanToken = address(frozenRlusd);
        morpho.createMarket(marketB.marketParams);
        vm.startPrank(governance);
        controller.setSubaccountImplementation(typeB, address(loanChainImpl));
        IILoanMarketsFacet(address(controller)).registerLoanMarket(typeB, marketB);
        _setDefaultFeeTerms(address(controller), typeB);
        vm.stopPrank();
        address parent = _remotePaOnThisDiamond("rFrozenPayFeeOwner");
        address subaccount = controller.createSubaccount("rFrozenPayFeeOwner", typeB);
        fxrp.mint(subaccount, 100e6);
        _deliver(subaccount, 1, 100e6, _borrowPayload(
            bytes32("op-frz"), DESTINATION_KIND_EVM,
            bytes32(uint256(uint160(makeAddr("dest")))), 1000e18
        ));
        vm.warp(vm.getBlockTimestamp() + 365 days);
        _externalRepayWith(frozenRlusd, marketB, subaccount, 1000e18);
        frozenRlusd.mint(parent, 70e18);
        // an allowance granted before the freeze, and one attempted after it
        vm.prank(parent);
        frozenRlusd.approve(subaccount, 10e18);
        frozenRlusd.setFrozen(subaccount, true);
        // the frozen address itself can neither approve nor send (the token's other checks)
        vm.startPrank(subaccount);
        vm.expectRevert(abi.encodeWithSelector(MockFreezableToken.FrozenAccount.selector, subaccount));
        frozenRlusd.approve(parent, 1);
        vm.expectRevert(abi.encodeWithSelector(MockFreezableToken.FrozenAccount.selector, subaccount));
        frozenRlusd.transfer(parent, 1);
        vm.stopPrank();

        vm.startPrank(parent);
        vm.expectRevert(abi.encodeWithSelector(MockFreezableToken.FrozenAccount.selector, subaccount));
        frozenRlusd.approve(subaccount, 70e18);
        vm.expectRevert(abi.encodeWithSelector(MockFreezableToken.FrozenAccount.selector, subaccount));
        ILoanSubaccountRemote(subaccount).payLoanFee(10e18);
        vm.stopPrank();
        assertEq(frozenRlusd.balanceOf(makeAddr("feeCollector")), 0);
        // both reverted calls rolled their checkpoints back; the bare ping moves no tokens
        ILoanSubaccountRemote(subaccount).checkpointFee();
        (, uint256 feeDebtX18, , , , ) = ILoanSubaccountRemote(subaccount).getLoanFeeState();
        assertEq(feeDebtX18, 70e18 * 1e18);

        bytes memory payload = _withdrawPayload(bytes32("op-w"), 100e6);
        (bytes memory message, bytes32 guid) = _composeMessage(subaccount, 2, 0, payload);
        vm.deal(lzEndpoint, RETURN_MIN_VALUE);
        vm.prank(lzEndpoint);
        vm.expectRevert(
            abi.encodeWithSelector(ILoanSubaccountRemote.OutstandingLoanFee.selector, 70e18)
        );
        ILoanSubaccountRemote(subaccount).lzCompose{value: RETURN_MIN_VALUE}(
            address(fxrpOft), guid, message, executor, ""
        );
    }

    function testPayLoanFeeCallbackCannotReenter() public {
        // a loan token whose transferFrom calls back into the account: the permissionless
        // repay meets the transient guard - asserted by the guard's own error, so the test
        // fails if the guard is ever removed - and payLoanFee itself refuses any non-parent
        // caller before that; the whole payment reverts and the fee stays owed
        _configureSettings();
        uint256 typeB = 2;
        MockReentrantToken evil = new MockReentrantToken();
        ILoanMarketsFacet.Market memory marketB = _defaultMarket();
        marketB.marketParams.loanToken = address(evil);
        morpho.createMarket(marketB.marketParams);
        vm.startPrank(governance);
        controller.setSubaccountImplementation(typeB, address(loanChainImpl));
        IILoanMarketsFacet(address(controller)).registerLoanMarket(typeB, marketB);
        _setDefaultFeeTerms(address(controller), typeB);
        vm.stopPrank();
        address parent = _remotePaOnThisDiamond("rEvilPayFeeOwner");
        address subaccount = controller.createSubaccount("rEvilPayFeeOwner", typeB);
        fxrp.mint(subaccount, 100e6);
        _deliver(subaccount, 1, 100e6, _borrowPayload(
            bytes32("op-evil"), DESTINATION_KIND_EVM,
            bytes32(uint256(uint160(makeAddr("dest")))), 1000e18
        ));
        vm.warp(vm.getBlockTimestamp() + 365 days);
        ILoanSubaccountRemote(subaccount).checkpointFee();

        evil.mint(parent, 70e18);
        evil.setCallback(subaccount, abi.encodeCall(ILoanSubaccountRemote.repay, ()));
        vm.startPrank(parent);
        evil.approve(subaccount, 70e18);
        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        ILoanSubaccountRemote(subaccount).payLoanFee(70e18);

        evil.setCallback(
            subaccount, abi.encodeCall(ILoanSubaccountRemote.payLoanFee, (70e18))
        );
        vm.expectRevert(ISubaccount.OnlyParent.selector);
        ILoanSubaccountRemote(subaccount).payLoanFee(70e18);
        vm.stopPrank();
        (, uint256 feeDebtX18, , , , ) = ILoanSubaccountRemote(subaccount).getLoanFeeState();
        assertEq(feeDebtX18, 70e18 * 1e18);
        assertEq(evil.balanceOf(makeAddr("feeCollector")), 0);
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
        ILoanMarketsFacet.Market memory marketB = _defaultMarket();
        marketB.marketParams.loanToken = address(evil);
        morpho.createMarket(marketB.marketParams);
        vm.startPrank(governance);
        controller.setSubaccountImplementation(typeB, address(loanChainImpl));
        IILoanMarketsFacet(address(controller)).registerLoanMarket(typeB, marketB);
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
        evil.setCallback(subaccount, abi.encodeCall(ILoanSubaccountRemote.repay, ()));
        evil.setSoftFailures(true);
        uint256 feeShare = uint256(100e18) * 70e18 / 1070e18;

        vm.expectEmit();
        emit ILoanSubaccountRemote.LoanFeeCollected(makeAddr("feeCollector"), feeShare);
        assertEq(ILoanSubaccountRemote(subaccount).repay(), 100e18 - feeShare);
        assertEq(evil.callbackFailures(), 2);
        assertEq(
            evil.lastCallbackRevert(),
            abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector)
        );
        assertEq(evil.balanceOf(makeAddr("feeCollector")), feeShare);
        (, uint256 feeDebtX18, , , , ) = ILoanSubaccountRemote(subaccount).getLoanFeeState();
        assertEq(feeDebtX18, (70e18 - feeShare) * 1e18);

        evil.setSoftFailures(false);
        evil.mint(subaccount, 100e18);
        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        ILoanSubaccountRemote(subaccount).repay();
    }

    function testInitializeValidatesItsArgumentsOnAClearedAccount() public {
        // defense in depth: the proxy always passes its own constructor arguments, and it
        // resolves the implementation through the controller first, so these guards cannot be
        // reached in production. Clearing the controller slot re-opens `initialize` on a live
        // account, which is the only way to exercise them.
        address subaccount = address(_deploySubaccount());
        vm.store(subaccount, bytes32(0), bytes32(0));

        vm.expectRevert(IControlledAccount.InvalidControllerAddress.selector);
        ISubaccount(subaccount).initialize(address(0), parentPersonalAccount, SUBACCOUNT_TYPE_LOAN);

        vm.expectRevert(ISubaccount.InvalidParentPersonalAccount.selector);
        ISubaccount(subaccount).initialize(address(controller), address(0), SUBACCOUNT_TYPE_LOAN);

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
            address(controller), address(rejectingParent), SUBACCOUNT_TYPE_LOAN
        ));
        fxrp.mint(subaccount, 5e6);
        ILoanSubaccountRemote(subaccount).depositIdleFxrp();
        vm.deal(subaccount, 5 ether);

        bytes memory payload = _withdrawPayload(bytes32("op-w"), 5e6);
        (bytes memory message, bytes32 guid) = _composeMessage(subaccount, 1, 0, payload);
        vm.deal(lzEndpoint, 0.02 ether);
        vm.prank(lzEndpoint);
        vm.expectRevert(ILoanSubaccountRemote.RefundFailed.selector);
        ILoanSubaccountRemote(subaccount).lzCompose{value: 0.02 ether}(
            address(fxrpOft), guid, message, executor, ""
        );
        assertFalse(ILoanSubaccountRemote(subaccount).usedOperations(bytes32("op-w")));
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
        _deliver(subaccount, 1, 100e6, _depositPayload(bytes32("op-1")));
        fxrpOft.setPeer(originEid, bytes32(uint256(0xbad)));

        bytes memory payload = _withdrawPayload(bytes32("op-2"), 30e6);
        (bytes memory message, bytes32 guid) = _composeMessage(subaccount, 2, 0, payload);
        vm.deal(lzEndpoint, RETURN_MIN_VALUE);
        vm.prank(lzEndpoint);
        vm.expectRevert(ILoanSubaccountRemote.WrongOriginPeer.selector);
        ILoanSubaccountRemote(subaccount).lzCompose{value: RETURN_MIN_VALUE}(
            address(fxrpOft), guid, message, executor, ""
        );
        assertFalse(ILoanSubaccountRemote(subaccount).usedOperations(bytes32("op-2")));
        (, , uint128 collateral) = morpho.position(_marketId(), subaccount);
        assertEq(collateral, 100e6);

        fxrpOft.setPeer(originEid, originPeer);
        _deliverWithValue(subaccount, 2, 0, payload, RETURN_MIN_VALUE);
        assertTrue(ILoanSubaccountRemote(subaccount).usedOperations(bytes32("op-2")));
    }

    function testSkippedWithdrawValueForwardFailureReverts() public {
        // a terminal skip forwards its delivered value to the parent, since the endpoint is no
        // refund target and this account has no native exit: a parent that cannot receive it
        // reverts the delivery, which keeps the value with the endpoint and the packet retriable
        _configureSettings();
        MockNativeRejectingParent rejectingParent = new MockNativeRejectingParent();
        address subaccount = address(new SubaccountProxy(
            address(controller), address(rejectingParent), SUBACCOUNT_TYPE_LOAN
        ));

        bytes memory payload = _withdrawPayload(bytes32("op-w"), 10e6);
        (bytes memory message, bytes32 guid) = _composeMessage(subaccount, 1, 0, payload);
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        vm.deal(lzEndpoint, RETURN_MIN_VALUE);
        vm.prank(lzEndpoint);
        vm.expectRevert(ILoanSubaccountRemote.RefundFailed.selector);
        ILoanSubaccountRemote(subaccount).lzCompose{value: RETURN_MIN_VALUE}(
            address(fxrpOft), guid, message, executor, ""
        );
        assertFalse(ILoanSubaccountRemote(subaccount).usedOperations(bytes32("op-w")));
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
        // the skipped delivery's value went to the parent, not stranding here
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

    function testLzComposeRevertHardChecksOnEveryAction() public {
        // each action carries its own copy of the hard checks, so each copy needs its own
        // negative delivery - the deposit test above cannot stand in for borrow or withdraw
        address subaccount = _createConfiguredSubaccount();
        fxrp.mint(subaccount, 100e6);

        _deliverExpectRevert(
            subaccount, 1,
            _borrowPayload(bytes32(0), DESTINATION_KIND_EVM, bytes32(uint256(1)), 500e18),
            IComposeReceiverAccountBase.InvalidOperationId.selector
        );
        _deliverExpectRevert(
            subaccount, 1, _withdrawPayload(bytes32("op-1"), 0),
            ILoanSubaccountRemote.ZeroAmount.selector
        );
        _deliverExpectRevert(
            subaccount, 1, _withdrawPayload(bytes32(0), 50e6),
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
    // step 4: repayment, deposits, the return leg and recovery
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
        // (retriable revert); the credit waits idle for the registration - its one route is
        // into the position, so the deposit rail waits the same way
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

        vm.expectRevert(
            abi.encodeWithSelector(ILoanMarketsFacet.MarketNotRegistered.selector, typeB)
        );
        ILoanSubaccountRemote(subaccountB).depositIdleFxrp();
        assertEq(fxrp.balanceOf(subaccountB), 100e6);
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
        // clearing the transport kills composed actions (the return leg included), never
        // repayment
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
        // this same diamond, which authenticates it against its bridge route and runs the
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

        // created before its parent, the subaccount is bound to the computed - still
        // codeless - parent address, and the surplus push parks the tokens there; creating
        // the parent later puts code and the registry entry at that same address, with the
        // parked balance now under the user's signature
        address parent = LoanSubaccountRemote(payable(subaccount)).parentPersonalAccount();
        assertEq(parent.code.length, 0);
        rlusd.mint(subaccount, 5e18);
        assertEq(ILoanSubaccountRemote(subaccount).repay(), 0);
        assertEq(rlusd.balanceOf(parent), 5e18);

        // the parent Personal Account also materializes on the minimal topology, behind the
        // PA beacon, through the generic creation route on the PersonalAccountsFacet - but
        // only once the implementation is registered: the frozen BeaconProxy asks the beacon
        // at construction, and an unset beacon fails the creation closed
        vm.expectRevert();
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
                oracle: address(oracle),
                irm: makeAddr("irm"),
                lltv: 0.77e18
            })
        });
    }

    /// Configures the meeting-example fee terms (floor 7%, spread 1% annually, a fixed
    /// collector) for `_subaccountType` - the one call that activates the type. The caller
    /// must already be pranked as the diamond's owner.
    function _setDefaultFeeTerms(address _diamond, uint256 _subaccountType) private {
        IILoanMarketsFacet(_diamond).setLoanFeeTerms(
            _subaccountType, _feeTerms(0.07e18, 0.01e18, makeAddr("feeCollector"))
        );
    }

    /// Changes the loan type's rates on this diamond, keeping the default collector. The
    /// caller must already be pranked as the diamond's owner.
    function _setFeeRates(uint64 _feeFloor, uint64 _feeSpread) private {
        IILoanMarketsFacet(address(controller)).setLoanFeeTerms(
            SUBACCOUNT_TYPE_LOAN, _feeTerms(_feeFloor, _feeSpread, makeAddr("feeCollector"))
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
        ILoanMarketsFacet.Market memory _market,
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
        _subaccount = controller.createSubaccount(_owner, SUBACCOUNT_TYPE_LOAN);
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
        return _borrowPayloadAt(
            _operationId, uint64(vm.getBlockTimestamp() + 1 hours), _destinationKind,
            _destination, _borrowAmount
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
            abi.encode(_operationId, uint64(vm.getBlockTimestamp() + 1 hours))
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

    function _feeTerms(
        uint64 _feeFloor,
        uint64 _feeSpread,
        address _feeRecipient
    )
        private pure
        returns (ILoanMarketsFacet.FeeTerms memory)
    {
        return ILoanMarketsFacet.FeeTerms({
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
            abi.encode(_operationId, _deadline, _destinationKind, _destination, _borrowAmount)
        );
    }
}
