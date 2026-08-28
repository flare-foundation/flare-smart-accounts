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
import {
    LoanChainSettingsFacet
} from "../contracts/smartAccounts/facets/LoanChainSettingsFacet.sol";
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
import {IPersonalAccountRemote} from "../contracts/userInterfaces/IPersonalAccountRemote.sol";
import {IFlareContractRegistry} from "flare-periphery/src/flare/IFlareContractRegistry.sol";
import {
    ILoanChainSettingsFacet
} from "../contracts/userInterfaces/facets/ILoanChainSettingsFacet.sol";
import {
    IILoanChainSettingsFacet
} from "../contracts/smartAccounts/interface/IILoanChainSettingsFacet.sol";
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
import {MockLzEndpoint} from "../contracts/mock/MockLzEndpoint.sol";
import {OFTComposeMsgCodec} from "@layerzerolabs/oft-evm/contracts/libs/OFTComposeMsgCodec.sol";
import {GUID} from "@layerzerolabs/lz-evm-protocol-v2/contracts/libs/GUID.sol";
import {IPauseFacet} from "../contracts/userInterfaces/facets/IPauseFacet.sol";
import {
    ACTION_BORROW,
    ACTION_WITHDRAW,
    ACTION_DEPOSIT_COLLATERAL,
    ACTION_DEPOSIT_SWEEP,
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

        // the loan-chain diamond additionally carries the loan settings facet
        IDiamond.FacetCut[] memory settingsCut = new IDiamond.FacetCut[](1);
        settingsCut[0] = _buildFacetCut(
            address(new LoanChainSettingsFacet()),
            "LoanChainSettingsFacet",
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
        // nothing in the protocol ever pushes native at the account (bridge rails refund
        // their caller, compose value is rejected), so it has no receive() and no native exit:
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

    function testSetLoanChainTransportAndRegisterMarket() public {
        _configureSettings();

        ILoanChainSettingsFacet.Transport memory transport =
            ILoanChainSettingsFacet(address(controller)).getLoanChainTransport();
        assertEq(transport.lzEndpoint, lzEndpoint);
        assertEq(transport.fxrpOft, address(fxrpOft));
        assertEq(transport.originEid, originEid);
        assertEq(transport.originPeer, originPeer);

        ILoanChainSettingsFacet.Market memory market =
            ILoanChainSettingsFacet(address(controller)).getLoanChainMarket(
                SUBACCOUNT_TYPE_LOAN
            );
        assertEq(market.morpho, address(morpho));
        assertEq(market.marketParams.loanToken, address(rlusd));
        assertEq(market.marketParams.collateralToken, address(fxrp));
        assertEq(market.marketParams.lltv, 0.77e18);
        assertFalse(
            ILoanChainSettingsFacet(address(controller)).isLoanChainBorrowingDisabled(
                SUBACCOUNT_TYPE_LOAN
            )
        );
    }

    function testLoanChainSettingsRevertNotOwner() public {
        address notOwner = makeAddr("notOwner");
        vm.startPrank(notOwner);
        vm.expectRevert(
            abi.encodeWithSelector(NotContractOwner.selector, notOwner, governance)
        );
        IILoanChainSettingsFacet(address(controller)).setLoanChainTransport(
            _defaultTransport()
        );
        vm.expectRevert(
            abi.encodeWithSelector(NotContractOwner.selector, notOwner, governance)
        );
        IILoanChainSettingsFacet(address(controller)).registerLoanChainMarket(
            SUBACCOUNT_TYPE_LOAN, _defaultMarket()
        );
        vm.expectRevert(
            abi.encodeWithSelector(NotContractOwner.selector, notOwner, governance)
        );
        IILoanChainSettingsFacet(address(controller)).disableLoanChainBorrowing(
            SUBACCOUNT_TYPE_LOAN
        );
        vm.expectRevert(
            abi.encodeWithSelector(NotContractOwner.selector, notOwner, governance)
        );
        IILoanChainSettingsFacet(address(controller)).enableLoanChainBorrowing(
            SUBACCOUNT_TYPE_LOAN
        );
        vm.stopPrank();
    }

    function testSetLoanChainTransportRevertInvalidValues() public {
        fxrpOft.setPeer(originEid, originPeer);
        ILoanChainSettingsFacet.Transport memory transport;

        // the endpoint and the OFT must be contracts
        transport = _defaultTransport();
        transport.lzEndpoint = makeAddr("noCode");
        _setTransportExpectRevert(transport, ILoanChainSettingsFacet.InvalidLzEndpoint.selector);

        transport = _defaultTransport();
        transport.fxrpOft = makeAddr("noCode");
        _setTransportExpectRevert(transport, ILoanBridgeSettingsFacet.InvalidFxrpOft.selector);

        transport = _defaultTransport();
        transport.originEid = 0;
        _setTransportExpectRevert(transport, ILoanChainSettingsFacet.InvalidOriginEid.selector);

        transport = _defaultTransport();
        transport.originPeer = bytes32(0);
        _setTransportExpectRevert(transport, ILoanChainSettingsFacet.InvalidOriginPeer.selector);
    }

    function testRegisterLoanChainMarketRevertInvalidValues() public {
        _configureTransport();
        ILoanChainSettingsFacet.Market memory market;

        // Morpho must be a contract
        market = _defaultMarket();
        market.morpho = makeAddr("noCode");
        _registerMarketExpectRevert(market, ILoanChainSettingsFacet.InvalidMorpho.selector);

        // the market must name both tokens and a non-zero LLTV
        market = _defaultMarket();
        market.marketParams.loanToken = address(0);
        _registerMarketExpectRevert(
            market, ILoanChainSettingsFacet.InvalidMarketParams.selector
        );

        market = _defaultMarket();
        market.marketParams.collateralToken = address(0);
        _registerMarketExpectRevert(
            market, ILoanChainSettingsFacet.InvalidMarketParams.selector
        );

        market = _defaultMarket();
        market.marketParams.lltv = 0;
        _registerMarketExpectRevert(
            market, ILoanChainSettingsFacet.InvalidMarketParams.selector
        );

        // the reserved type 0 can never be bound
        vm.prank(governance);
        vm.expectRevert(ISubaccountsFacet.InvalidSubaccountType.selector);
        IILoanChainSettingsFacet(address(controller)).registerLoanChainMarket(
            0, _defaultMarket()
        );
    }

    function testRegisterLoanChainMarketRevertWithoutTransport() public {
        // the transport pins FXRP's identity, which the market's collateral must match:
        // markets cannot be registered before the transport is configured
        morpho.createMarket(_defaultMarket().marketParams);
        _registerMarketExpectRevert(
            _defaultMarket(),
            ILoanChainSettingsFacet.LoanChainTransportNotConfigured.selector
        );
    }

    function testRegisterLoanChainMarketRevertWrongCollateral() public {
        // the market's collateral token must be exactly the OFT's own token
        _configureTransport();
        MintableERC20 otherToken = new MintableERC20("Other", "OTH", 6);
        ILoanChainSettingsFacet.Market memory market = _defaultMarket();
        market.marketParams.collateralToken = address(otherToken);
        morpho.createMarket(market.marketParams);
        _registerMarketExpectRevert(market, ILoanBridgeSettingsFacet.InvalidFxrpOft.selector);
    }

    function testSetLoanChainTransportRevertWrongSharedDecimals() public {
        // the bridge-back sweep sends with minAmountLD == amountLD, so shared-decimal dust
        // would make it revert; such an OFT must be rejected up front
        fxrpOft.setPeer(originEid, originPeer);
        fxrpOft.setSharedDecimals(4);
        _setTransportExpectRevert(
            _defaultTransport(), ILoanBridgeSettingsFacet.InvalidFxrpOft.selector
        );
    }

    function testSetLoanChainTransportRevertWrongOftVersion() public {
        // the compose authentication depends on the canonical composeFrom encoding, so only
        // the canonical interface id and message-codec version 1 are accepted
        fxrpOft.setPeer(originEid, originPeer);

        fxrpOft.setOftVersion(0x02e49c2c, 2);
        _setTransportExpectRevert(
            _defaultTransport(), ILoanBridgeSettingsFacet.InvalidFxrpOft.selector
        );

        fxrpOft.setOftVersion(0xdeadbeef, 1);
        _setTransportExpectRevert(
            _defaultTransport(), ILoanBridgeSettingsFacet.InvalidFxrpOft.selector
        );

        fxrpOft.setOftVersion(0x02e49c2c, 1);
        vm.prank(governance);
        IILoanChainSettingsFacet(address(controller)).setLoanChainTransport(
            _defaultTransport()
        );
    }

    function testSetLoanChainTransportRevertPeerMismatch() public {
        // the live peer for the origin endpoint must be exactly the pinned remote OApp
        fxrpOft.setPeer(originEid, bytes32(uint256(0xbad)));
        _setTransportExpectRevert(
            _defaultTransport(), ILoanChainSettingsFacet.InvalidOriginPeer.selector
        );
    }

    function testSetLoanChainTransportRevertWrongEndpointAssociation() public {
        // the OFT must be wired to the same endpoint that delivers lzCompose calls; a wrong
        // (or malicious) endpoint could fabricate every callback parameter
        fxrpOft.setPeer(originEid, originPeer);
        address otherEndpoint = makeAddr("otherEndpoint");
        vm.etch(otherEndpoint, hex"00");

        ILoanChainSettingsFacet.Transport memory transport = _defaultTransport();
        transport.lzEndpoint = otherEndpoint;
        _setTransportExpectRevert(transport, ILoanChainSettingsFacet.InvalidLzEndpoint.selector);
    }

    function testSetLoanChainTransportRevertDirtyOriginPeer() public {
        // the origin peer is an EVM address and must be cleanly zero-padded
        bytes32 dirtyPeer = bytes32(uint256(originPeer) | (uint256(1) << 200));
        fxrpOft.setPeer(originEid, dirtyPeer);

        ILoanChainSettingsFacet.Transport memory transport = _defaultTransport();
        transport.originPeer = dirtyPeer;
        _setTransportExpectRevert(transport, ILoanChainSettingsFacet.InvalidOriginPeer.selector);
    }

    function testClearLoanChainTransportRevertPartialZero() public {
        _configureSettings();

        // a struct with only some fields zeroed is not a clear: it falls through to
        // validation and reverts, so a malformed clear cannot silently wipe the transport
        ILoanChainSettingsFacet.Transport memory partialZero;
        partialZero.originEid = 5;
        vm.prank(governance);
        vm.expectRevert(ILoanChainSettingsFacet.InvalidLzEndpoint.selector);
        IILoanChainSettingsFacet(address(controller)).setLoanChainTransport(partialZero);

        // the configured transport is untouched
        assertEq(
            ILoanChainSettingsFacet(address(controller))
                .getLoanChainTransport().lzEndpoint,
            lzEndpoint
        );
    }

    function testClearLoanChainTransport() public {
        _configureSettings();

        // clearing with an all-zero transport disables the transport-dependent surface until
        // reconfigured; the registered market and repayment persist
        ILoanChainSettingsFacet.Transport memory cleared;
        vm.prank(governance);
        IILoanChainSettingsFacet(address(controller)).setLoanChainTransport(cleared);

        ILoanChainSettingsFacet.Transport memory stored =
            ILoanChainSettingsFacet(address(controller)).getLoanChainTransport();
        assertEq(stored.lzEndpoint, address(0));
        assertEq(stored.fxrpOft, address(0));
        assertEq(stored.originEid, 0);
        assertEq(stored.originPeer, bytes32(0));

        // the write-once market binding is not part of the transport and survives
        assertEq(
            ILoanChainSettingsFacet(address(controller))
                .getLoanChainMarket(SUBACCOUNT_TYPE_LOAN).morpho,
            address(morpho)
        );
    }

    function testRegisterLoanChainMarketIsWriteOnce() public {
        _configureSettings();

        // the binding is permanent: a different market means a new subaccount type
        ILoanChainSettingsFacet.Market memory other = _defaultMarket();
        other.marketParams.lltv = 0.5e18;
        morpho.createMarket(other.marketParams);
        vm.prank(governance);
        vm.expectRevert(
            abi.encodeWithSelector(
                ILoanChainSettingsFacet.MarketAlreadyRegistered.selector,
                SUBACCOUNT_TYPE_LOAN
            )
        );
        IILoanChainSettingsFacet(address(controller)).registerLoanChainMarket(
            SUBACCOUNT_TYPE_LOAN, other
        );
    }

    function testBorrowSwitchRequiresRegisteredMarket() public {
        vm.startPrank(governance);
        vm.expectRevert(
            abi.encodeWithSelector(
                ILoanChainSettingsFacet.MarketNotRegistered.selector, SUBACCOUNT_TYPE_LOAN
            )
        );
        IILoanChainSettingsFacet(address(controller)).disableLoanChainBorrowing(
            SUBACCOUNT_TYPE_LOAN
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                ILoanChainSettingsFacet.MarketNotRegistered.selector, SUBACCOUNT_TYPE_LOAN
            )
        );
        IILoanChainSettingsFacet(address(controller)).enableLoanChainBorrowing(
            SUBACCOUNT_TYPE_LOAN
        );
        vm.stopPrank();
    }

    function testSetLoanChainTransportRevertDifferentTokenAfterMarket() public {
        // once a market is bound, the collateral token is pinned: a replacement transport
        // wrapping a different token would strand the permanent binding and is rejected
        _configureSettings();
        MintableERC20 otherToken = new MintableERC20("Other", "OTH", 6);
        ILoanChainSettingsFacet.Transport memory transport = _defaultTransport();
        transport.fxrpOft = address(_wiredOft(otherToken));
        _setTransportExpectRevert(transport, ILoanBridgeSettingsFacet.InvalidFxrpOft.selector);
    }

    function testSetLoanChainTransportAllowsAdapterRotation() public {
        // the pin freezes the token, not the adapter: a new OFT wrapping the same token passes
        _configureSettings();
        ILoanChainSettingsFacet.Transport memory transport = _defaultTransport();
        transport.fxrpOft = address(_wiredOft(fxrp));
        vm.prank(governance);
        IILoanChainSettingsFacet(address(controller)).setLoanChainTransport(transport);
        assertEq(
            ILoanChainSettingsFacet(address(controller)).getLoanChainTransport().fxrpOft,
            transport.fxrpOft
        );
    }

    function testTransportClearAndRestoreKeepsCollateralPin() public {
        // the pin is not transport state: it survives a clear, still rejects a wrong-token
        // transport, and the original same-token transport restores cleanly
        _configureSettings();
        ILoanChainSettingsFacet.Transport memory cleared;
        vm.prank(governance);
        IILoanChainSettingsFacet(address(controller)).setLoanChainTransport(cleared);

        MintableERC20 otherToken = new MintableERC20("Other", "OTH", 6);
        ILoanChainSettingsFacet.Transport memory wrongToken = _defaultTransport();
        wrongToken.fxrpOft = address(_wiredOft(otherToken));
        _setTransportExpectRevert(wrongToken, ILoanBridgeSettingsFacet.InvalidFxrpOft.selector);

        vm.prank(governance);
        IILoanChainSettingsFacet(address(controller)).setLoanChainTransport(
            _defaultTransport()
        );
        assertEq(
            ILoanChainSettingsFacet(address(controller)).getLoanChainTransport().fxrpOft,
            address(fxrpOft)
        );
    }

    function testRegisterSecondTypeRequiresPinnedCollateral() public {
        // with the pin set by the first registration, a second type cannot bind a market on
        // a different collateral token (rejected against the pinned transport's OFT)
        _configureSettings();
        MintableERC20 otherToken = new MintableERC20("Other", "OTH", 6);
        ILoanChainSettingsFacet.Market memory market = _defaultMarket();
        market.marketParams.collateralToken = address(otherToken);
        morpho.createMarket(market.marketParams);
        vm.prank(governance);
        vm.expectRevert(ILoanBridgeSettingsFacet.InvalidFxrpOft.selector);
        IILoanChainSettingsFacet(address(controller)).registerLoanChainMarket(2, market);
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

    function testLzComposeSweepDepositSuppliesBridgedAmount() public {
        // the permissionless forward sweep's compose: argument-free, deposits exactly what
        // arrived, no debt, no id - a second packet simply deposits again
        address subaccount = _createConfiguredSubaccount();
        fxrp.mint(subaccount, 100e6);
        vm.expectEmit();
        emit ILoanSubaccountRemote.SweptFxrpDeposited(parentPersonalAccount, 100e6, _guidFor(1));
        _deliver(subaccount, 1, 100e6, _sweepDepositPayload());

        (, uint128 borrowShares, uint128 collateral) = morpho.position(_marketId(), subaccount);
        assertEq(collateral, 100e6);
        assertEq(borrowShares, 0);

        fxrp.mint(subaccount, 25e6);
        _deliver(subaccount, 2, 25e6, _sweepDepositPayload());
        (, , collateral) = morpho.position(_marketId(), subaccount);
        assertEq(collateral, 125e6);

        // a sweep that brings nothing is malformed
        _deliverExpectRevertZeroAmount(
            subaccount, 3, _sweepDepositPayload(), ILoanSubaccountRemote.ZeroAmount.selector
        );
    }

    function testLzComposeSweepDepositWhilePausedRequiresLiveDebt() public {
        // the deposit rule: defending an indebted position survives a pause, a debt-free
        // deposit is new exposure and waits (a revert, retriable, not a skip)
        address indebted = _borrowedSubaccount(500e18);
        address debtFree = controller.createSubaccount("rDebtFreeOwner", SUBACCOUNT_TYPE_LOAN);
        fxrp.mint(indebted, 50e6);
        fxrp.mint(debtFree, 100e6);
        _pauseController();

        _deliverExpectRevert(debtFree, 1, _sweepDepositPayload(), IPauseFacet.IsPaused.selector);
        _deliver(indebted, 2, 50e6, _sweepDepositPayload());
        (, , uint128 collateral) = morpho.position(_marketId(), indebted);
        assertEq(collateral, 150e6);
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

    function testLzComposeWithdrawReturnsCollateralToTheAccount() public {
        address subaccount = _createConfiguredSubaccount();
        fxrp.mint(subaccount, 100e6);
        _deliver(subaccount, 1, 100e6, _depositPayload(bytes32("op-1")));

        bytes32 operationId = bytes32("op-2");
        vm.expectEmit();
        emit ILoanSubaccountRemote.CollateralWithdrawn(
            parentPersonalAccount, operationId, 30e6, _guidFor(2)
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

    function testExternalLiquidationImmediatelyUnblocksRecovery() public {
        // debt is read live from Morpho on every check - nothing is cached, so an external
        // liquidation is visible to the very next call with no synchronization step
        address subaccount = _borrowedSubaccount(500e18);
        rlusd.mint(subaccount, 100e18);

        vm.expectRevert(ILoanSubaccountRemote.OutstandingDebt.selector);
        ILoanSubaccountRemote(subaccount).recoverToken(address(rlusd));

        morpho.simulateLiquidation(_marketId(), subaccount);

        uint256 amount = ILoanSubaccountRemote(subaccount).recoverToken(address(rlusd));
        assertEq(amount, 100e18);
        assertEq(rlusd.balanceOf(parentPersonalAccount), 100e18);
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

        ILoanChainSettingsFacet.Transport memory cleared;
        vm.prank(governance);
        IILoanChainSettingsFacet(address(controller)).setLoanChainTransport(cleared);

        vm.prank(lzEndpoint);
        vm.expectRevert(
            ILoanChainSettingsFacet.LoanChainTransportNotConfigured.selector
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
        _deliver(subaccount, 2, 0, _withdrawPayload(operationId, 30e6));
        (, , uint128 collateral) = morpho.position(_marketId(), subaccount);
        assertEq(collateral, 100e6);
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
            abi.encode(bytes32("op-w"), uint64(block.timestamp), uint256(40e6))
        );
        _deliver(subaccount, 2, 0, payload);
        (, , uint128 collateral) = morpho.position(_marketId(), subaccount);
        assertEq(collateral, 60e6);
        assertEq(fxrp.balanceOf(subaccount), 40e6);
        assertTrue(ILoanSubaccountRemote(subaccount).usedOperations(bytes32("op-w")));
    }

    function testLzComposeBorrowRevertBorrowingDisabled() public {
        // the borrow switch sunsets a pool: a debt increase reverts (retriable - a reversible
        // policy must not consume the packet); deposits, repayment and withdrawals still work
        address subaccount = _borrowedSubaccount(500e18);
        vm.prank(governance);
        vm.expectEmit();
        emit ILoanChainSettingsFacet.LoanChainBorrowingDisabled(SUBACCOUNT_TYPE_LOAN);
        IILoanChainSettingsFacet(address(controller)).disableLoanChainBorrowing(
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
        emit ILoanChainSettingsFacet.LoanChainBorrowingEnabled(SUBACCOUNT_TYPE_LOAN);
        IILoanChainSettingsFacet(address(controller)).enableLoanChainBorrowing(
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
        IILoanChainSettingsFacet(address(controller)).disableLoanChainBorrowing(
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
        IILoanChainSettingsFacet(address(controller)).disableLoanChainBorrowing(
            SUBACCOUNT_TYPE_LOAN
        );

        _deliver(subaccount, 2, 0, _withdrawPayload(bytes32("op-w"), 30e6));
        (, , uint128 collateral) = morpho.position(_marketId(), subaccount);
        assertEq(collateral, 70e6);

        rlusd.mint(subaccount, 600e18);
        assertEq(ILoanSubaccountRemote(subaccount).repay(), 500e18);

        assertEq(ILoanSubaccountRemote(subaccount).recoverToken(address(rlusd)), 100e18);
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
        ILoanChainSettingsFacet.Market memory marketB = _defaultMarket();
        marketB.marketParams.lltv = 0.5e18;
        morpho.createMarket(marketB.marketParams);
        vm.startPrank(governance);
        controller.setSubaccountImplementation(typeB, address(loanChainImpl));
        IILoanChainSettingsFacet(address(controller)).registerLoanChainMarket(
            typeB, marketB
        );
        IILoanChainSettingsFacet(address(controller)).disableLoanChainBorrowing(
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
        ILoanChainSettingsFacet.Market memory marketB = _defaultMarket();
        marketB.marketParams.lltv = 0.5e18;
        morpho.createMarket(marketB.marketParams);
        vm.startPrank(governance);
        controller.setSubaccountImplementation(typeB, address(loanChainImpl));
        IILoanChainSettingsFacet(address(controller)).registerLoanChainMarket(
            typeB, marketB
        );
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
                ILoanChainSettingsFacet.MarketNotRegistered.selector, typeB
            )
        );
        // the revert rolled the whole delivery back: the id stays unconsumed for a retry
        assertFalse(ILoanSubaccountRemote(subaccountB).usedOperations(bytes32("op-1")));

        // the stranded credit exits over the transport without needing a market
        uint256 messagingFee = 0.01 ether;
        vm.deal(address(this), messagingFee);
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
                ILoanChainSettingsFacet.MarketNotRegistered.selector, typeB
            )
        );
        assertFalse(ILoanSubaccountRemote(subaccountB).usedOperations(bytes32("op-1")));

        ILoanChainSettingsFacet.Market memory marketB = _defaultMarket();
        marketB.marketParams.lltv = 0.5e18;
        morpho.createMarket(marketB.marketParams);
        vm.prank(governance);
        IILoanChainSettingsFacet(address(controller)).registerLoanChainMarket(
            typeB, marketB
        );

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

    function testRepayFullClosesByShares() public {
        // the balance covers the debt: repaid by exact borrow shares, the surplus stays
        address subaccount = _borrowedSubaccount(500e18);
        rlusd.mint(subaccount, 600e18);

        uint256 assets = ILoanSubaccountRemote(subaccount).repay();

        assertEq(assets, 500e18);
        (, uint128 borrowShares, ) = morpho.position(_marketId(), subaccount);
        assertEq(borrowShares, 0);
        // the over-funded remainder is surplus on the account, recoverToken's material
        assertEq(rlusd.balanceOf(subaccount), 100e18);
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
    }

    function testRepayRevertNothingToRepay() public {
        address subaccount = _createConfiguredSubaccount();

        // no idle balance
        vm.expectRevert(ILoanSubaccountRemote.NothingToRepay.selector);
        ILoanSubaccountRemote(subaccount).repay();

        // balance but no debt
        rlusd.mint(subaccount, 100e18);
        vm.expectRevert(ILoanSubaccountRemote.NothingToRepay.selector);
        ILoanSubaccountRemote(subaccount).repay();
    }

    function testRepayRevertMarketNotRegistered() public {
        // an unconfigured type has no market to repay into
        address subaccount = address(_deploySubaccount());
        rlusd.mint(subaccount, 100e18);

        vm.expectRevert(
            abi.encodeWithSelector(
                ILoanChainSettingsFacet.MarketNotRegistered.selector, SUBACCOUNT_TYPE_LOAN
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
        ILoanChainSettingsFacet.Transport memory cleared;
        vm.prank(governance);
        IILoanChainSettingsFacet(address(controller)).setLoanChainTransport(cleared);

        rlusd.mint(subaccount, 600e18);
        uint256 assets = ILoanSubaccountRemote(subaccount).repay();
        assertEq(assets, 500e18);

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
        IILoanChainSettingsFacet(address(controller)).disableLoanChainBorrowing(
            SUBACCOUNT_TYPE_LOAN
        );
        ILoanChainSettingsFacet.Transport memory cleared;
        IILoanChainSettingsFacet(address(controller)).setLoanChainTransport(cleared);
        vm.stopPrank();

        assertTrue(
            ILoanChainSettingsFacet(address(controller))
                .isLoanChainBorrowingDisabled(SUBACCOUNT_TYPE_LOAN)
        );
        MintableERC20 stray = new MintableERC20("Stray", "STR", 18);
        stray.mint(subaccount, 1e18);
        assertEq(ILoanSubaccountRemote(subaccount).recoverToken(address(stray)), 1e18);
        assertEq(stray.balanceOf(parentPersonalAccount), 1e18);
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

        address caller = makeAddr("keeper");
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
        vm.deal(address(this), 0.01 ether);
        ILoanSubaccountRemote(subaccount).sweepToOrigin{value: 0.01 ether}(options);
        (,,,, bytes memory sentOptions,,) = fxrpOft.lastSendParam();
        assertEq(sentOptions, options);
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
        ILoanSubaccountRemote(subaccount).sweepToOrigin{value: messagingFee}("");

        assertEq(subaccount.balance, 5 ether);
        assertEq(caller.balance, 0);
    }

    function testSweepToOriginReverts() public {
        address subaccount = _createConfiguredSubaccount();
        uint256 messagingFee = 0.01 ether;
        vm.deal(address(this), 1 ether);

        // nothing to sweep
        vm.expectRevert(ILoanSubaccountRemote.NothingToSweep.selector);
        ILoanSubaccountRemote(subaccount).sweepToOrigin{value: messagingFee}("");

        fxrp.mint(subaccount, 100e6);

        // insufficient fee
        vm.expectRevert(
            abi.encodeWithSelector(
                ILoanSubaccountRemote.InsufficientFundsForSweep.selector, messagingFee
            )
        );
        ILoanSubaccountRemote(subaccount).sweepToOrigin{value: messagingFee - 1}("");

        // a peer mutation fails closed
        fxrpOft.setPeer(originEid, bytes32(uint256(0xbad)));
        vm.expectRevert(ILoanSubaccountRemote.WrongOriginPeer.selector);
        ILoanSubaccountRemote(subaccount).sweepToOrigin{value: messagingFee}("");
        fxrpOft.setPeer(originEid, originPeer);

        // every exit from this chain rides the OFT: the pause stops it
        _pauseController();
        vm.expectRevert(IPauseFacet.IsPaused.selector);
        ILoanSubaccountRemote(subaccount).sweepToOrigin{value: messagingFee}("");
    }

    function testRecoveryWorksWhilePaused() public {
        // recovery is inward consolidation to the account's own parent, not an exit, so the
        // pause does not gate it; the parent's signed user operations are what the pause stops
        address subaccount = _createConfiguredSubaccount();
        _pauseController();

        MintableERC20 stray = new MintableERC20("Stray", "STR", 18);
        stray.mint(subaccount, 1e18);
        assertEq(ILoanSubaccountRemote(subaccount).recoverToken(address(stray)), 1e18);
        assertEq(stray.balanceOf(parentPersonalAccount), 1e18);
    }

    function testWithdrawWithAttachedCreditLeavesItIdle() public {
        // a message-only action delivered with tokens attached executes normally; the credit
        // simply stays idle on the account for the fixed rails
        address subaccount = _createConfiguredSubaccount();
        fxrp.mint(subaccount, 100e6);
        _deliver(subaccount, 1, 100e6, _depositPayload(bytes32("op-1")));

        fxrp.mint(subaccount, 5e6);
        _deliver(subaccount, 2, 5e6, _withdrawPayload(bytes32("op-2"), 30e6));

        (, , uint128 collateral) = morpho.position(_marketId(), subaccount);
        assertEq(collateral, 70e6);
        assertEq(fxrp.balanceOf(subaccount), 35e6);
    }

    function testRegisterLoanChainMarketRevertCodelessToken() public {
        // the binding is permanent, and a Morpho market can exist for an address with no
        // code - so both tokens must be contracts
        _configureTransport();
        ILoanChainSettingsFacet.Market memory market = _defaultMarket();
        market.marketParams.loanToken = makeAddr("codelessToken");
        morpho.createMarket(market.marketParams);
        _registerMarketExpectRevert(
            market, ILoanChainSettingsFacet.InvalidMarketParams.selector
        );
    }

    function testRegisterLoanChainMarketRevertCodelessCollateralToken() public {
        // the symmetric case: a codeless collateral token must be rejected too
        _configureTransport();
        ILoanChainSettingsFacet.Market memory market = _defaultMarket();
        market.marketParams.collateralToken = makeAddr("codelessCollateral");
        morpho.createMarket(market.marketParams);
        _registerMarketExpectRevert(
            market, ILoanChainSettingsFacet.InvalidMarketParams.selector
        );
    }

    function testRegisterLoanChainMarketRevertNonexistentMarket() public {
        // the market must actually exist on the Morpho contract, or every credited compose
        // action against it would revert
        _configureTransport();
        _registerMarketExpectRevert(
            _defaultMarket(), ILoanChainSettingsFacet.InvalidMarketParams.selector
        );
    }

    function testRecoverTokenToParent() public {
        // the fixed recovery destination is the parent Personal Account - the user's own
        // compose-driven account on this chain - with nothing to configure first
        address subaccount = _createConfiguredSubaccount();
        MintableERC20 stray = new MintableERC20("Stray", "STR", 18);
        stray.mint(subaccount, 42e18);

        vm.expectEmit();
        emit ILoanSubaccountRemote.TokenRecovered(parentPersonalAccount, address(stray), 42e18);
        uint256 amount = ILoanSubaccountRemote(subaccount).recoverToken(address(stray));
        assertEq(amount, 42e18);
        assertEq(stray.balanceOf(parentPersonalAccount), 42e18);
    }

    function testRecoverTokenGuards() public {
        address subaccount = _createConfiguredSubaccount();

        // collateral never leaves through recovery: it has its own rails
        fxrp.mint(subaccount, 1e6);
        vm.expectRevert(
            abi.encodeWithSelector(ILoanSubaccountRemote.ProtectedToken.selector, address(fxrp))
        );
        ILoanSubaccountRemote(subaccount).recoverToken(address(fxrp));

        // the loan token is recoverable while the position carries no debt
        rlusd.mint(subaccount, 5e18);
        assertEq(ILoanSubaccountRemote(subaccount).recoverToken(address(rlusd)), 5e18);
        assertEq(rlusd.balanceOf(parentPersonalAccount), 5e18);

        // nothing to recover
        MintableERC20 empty = new MintableERC20("Empty", "EMP", 18);
        vm.expectRevert(ILoanSubaccountRemote.NothingToRecover.selector);
        ILoanSubaccountRemote(subaccount).recoverToken(address(empty));
    }

    function testRecoverLoanTokenSurplusAfterFullRepayment() public {
        address subaccount = _borrowedSubaccount(500e18);
        rlusd.mint(subaccount, 600e18);

        // while debt is outstanding, the balance is repayment material
        vm.expectRevert(ILoanSubaccountRemote.OutstandingDebt.selector);
        ILoanSubaccountRemote(subaccount).recoverToken(address(rlusd));

        ILoanSubaccountRemote(subaccount).repay();
        uint256 amount = ILoanSubaccountRemote(subaccount).recoverToken(address(rlusd));
        assertEq(amount, 100e18);
        assertEq(rlusd.balanceOf(parentPersonalAccount), 100e18);
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

        // withdraw: message-only; the receiver returns collateral to the account
        vm.prank(parentPersonalAccount);
        ILoanSubaccount(sender).withdraw{value: 0.01 ether}(40e6, bytes32("op-w"), deadline, "");
        (amountLD, payload) = _lastSentCompose();
        assertEq(amountLD, 0);
        _deliver(subaccount, 2, 0, payload);
        (, , collateral) = morpho.position(_marketId(), subaccount);
        assertEq(collateral, 60e6);
        assertEq(fxrp.balanceOf(subaccount), 40e6);

        // the permissionless forward sweep: whatever idles on the Flare side bridges with the
        // argument-free deposit compose and becomes collateral on arrival
        fxrp.mint(sender, 40e6);
        ILoanSubaccount(sender).sweepToLoan{value: 0.01 ether}("");
        (amountLD, payload) = _lastSentCompose();
        assertEq(amountLD, 40e6);
        fxrp.mint(subaccount, amountLD);
        _deliver(subaccount, 3, amountLD, payload);
        (, , collateral) = morpho.position(_marketId(), subaccount);
        assertEq(collateral, 100e6);

        // the signed deposit: exactly the signed amount travels and is supplied, no debt
        fxrp.mint(sender, 30e6);
        vm.prank(parentPersonalAccount);
        ILoanSubaccount(sender).depositCollateral{value: 0.01 ether}(30e6, bytes32("op-d"), deadline, "");
        (amountLD, payload) = _lastSentCompose();
        assertEq(amountLD, 30e6);
        fxrp.mint(subaccount, amountLD);
        _deliver(subaccount, 4, amountLD, payload);
        (, , collateral) = morpho.position(_marketId(), subaccount);
        assertEq(collateral, 130e6);
        assertTrue(ILoanSubaccountRemote(subaccount).usedOperations(bytes32("op-d")));

        // the bridge-back: the loan-chain side's idle FXRP (what the withdraw returned) goes
        // home with the redeem-home compose (a deadline, nothing else); the Flare twin authenticates it against
        // the bridge settings and runs the sweep-redeem logic on arrival - here its dust branch,
        // since the parent has no code on this diamond (the redemption itself is covered in the
        // Flare suite with a real Personal Account)
        vm.deal(address(this), 0.01 ether);
        ILoanSubaccountRemote(subaccount).sweepToOrigin{value: 0.01 ether}("");
        (amountLD, payload) = _lastSentCompose();
        assertEq(amountLD, 40e6);
        flareAssetManager.setMinimumRedeemAmountUBA(1_000e6);
        fxrp.mint(sender, amountLD);
        _deliverToFlareReceiver(sender, 6, amountLD, payload);
        assertEq(fxrp.balanceOf(sender), 0);
        assertEq(fxrp.balanceOf(parentPersonalAccount), 40e6);

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
        // surface, and the loan-chain settings facet - never the Flare-only
        // LoanBridgeSettingsFacet. The full-suite diamond could hide an accidental
        // dependency; this minimal one proves there is none (base facets reused from
        // setUp - their fixed CREATE2 salts would collide again)
        DiamondArgs memory args = DiamondArgs({
            owner: initialOwner,
            initAddress: address(0),
            initCalldata: ""
        });
        MasterAccountController minimal = new MasterAccountController(baseCuts, args);

        IDiamond.FacetCut[] memory cuts = new IDiamond.FacetCut[](5);
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
            address(new LoanChainSettingsFacet()),
            "LoanChainSettingsFacet",
            IDiamond.FacetCutAction.Add
        );
        cuts[4] = _buildFacetCut(
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
        IILoanChainSettingsFacet(address(minimal)).setLoanChainTransport(
            _defaultTransport()
        );
        IILoanChainSettingsFacet(address(minimal)).registerLoanChainMarket(
            SUBACCOUNT_TYPE_LOAN, _defaultMarket()
        );
        vm.stopPrank();
        string memory xrplOwner = "rMinimalTopologyOwner";
        address subaccount = minimalController.createSubaccount(xrplOwner, SUBACCOUNT_TYPE_LOAN);
        assertGt(subaccount.code.length, 0);

        // created before its mirror, the subaccount is bound to the computed - still
        // codeless - mirror address, and a recovery parks the tokens there; creating the
        // mirror later puts code and the registry entry at that same address, with the
        // parked balance now under the user's signature
        address parent = LoanSubaccountRemote(payable(subaccount)).parentPersonalAccount();
        assertEq(parent.code.length, 0);
        MintableERC20 stray = new MintableERC20("Stray", "STRAY", 18);
        stray.mint(subaccount, 5e18);
        ILoanSubaccountRemote(subaccount).recoverToken(address(stray));
        assertEq(stray.balanceOf(parent), 5e18);

        // the mirror Personal Account also materializes on the minimal topology, behind the
        // PA beacon, through the explicit loan-chain creation route - but only once the
        // implementation is registered: the frozen BeaconProxy asks the beacon at
        // construction, and an unset beacon fails the creation closed
        vm.expectRevert();
        ILoanChainSettingsFacet(address(minimal)).createPersonalAccountRemote(xrplOwner);
        PersonalAccountRemote mirrorImpl = new PersonalAccountRemote();
        vm.prank(initialOwner);
        minimalController.setPersonalAccountImplementation(address(mirrorImpl));
        address mirror = ILoanChainSettingsFacet(address(minimal))
            .createPersonalAccountRemote(xrplOwner);
        assertGt(mirror.code.length, 0);
        assertEq(minimalController.getPersonalAccount(xrplOwner), mirror);
        assertEq(mirror, parent);
        assertEq(stray.balanceOf(mirror), 5e18);

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
        returns (ILoanChainSettingsFacet.Transport memory)
    {
        return ILoanChainSettingsFacet.Transport({
            lzEndpoint: lzEndpoint,
            fxrpOft: address(fxrpOft),
            originEid: originEid,
            originPeer: originPeer
        });
    }

    function _defaultMarket()
        private
        returns (ILoanChainSettingsFacet.Market memory)
    {
        return ILoanChainSettingsFacet.Market({
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

    /// A valid alternate OFT adapter wrapping `_token`, wired like the default one.
    function _wiredOft(MintableERC20 _token) private returns (MockOft _oft) {
        _oft = new MockOft(_token, 0.01 ether);
        _oft.setEndpoint(lzEndpoint);
        _oft.setPeer(originEid, originPeer);
    }

    function _configureTransport() private {
        fxrpOft.setPeer(originEid, originPeer);
        vm.prank(governance);
        IILoanChainSettingsFacet(address(controller)).setLoanChainTransport(
            _defaultTransport()
        );
    }

    function _configureSettings() private {
        _configureTransport();
        morpho.createMarket(_defaultMarket().marketParams);
        vm.prank(governance);
        IILoanChainSettingsFacet(address(controller)).registerLoanChainMarket(
            SUBACCOUNT_TYPE_LOAN, _defaultMarket()
        );
    }

    function _setTransportExpectRevert(
        ILoanChainSettingsFacet.Transport memory _transport,
        bytes4 _selector
    )
        private
    {
        vm.prank(governance);
        vm.expectRevert(_selector);
        IILoanChainSettingsFacet(address(controller)).setLoanChainTransport(_transport);
    }

    function _registerMarketExpectRevert(
        ILoanChainSettingsFacet.Market memory _market,
        bytes4 _selector
    )
        private
    {
        vm.prank(governance);
        vm.expectRevert(_selector);
        IILoanChainSettingsFacet(address(controller)).registerLoanChainMarket(
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
        return ILoanChainSettingsFacet(address(controller)).createPersonalAccountRemote(_xrplOwner);
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
        (bytes memory message, bytes32 guid) =
            _composeMessage(_subaccount, _nonce, _amountLD, _payload);
        vm.prank(lzEndpoint);
        ILoanSubaccountRemote(_subaccount).lzCompose(
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
        return abi.encode(
            PAYLOAD_VERSION_1,
            ACTION_WITHDRAW,
            abi.encode(_operationId, uint64(block.timestamp + 1 hours), _amount)
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

    function _sweepDepositPayload() private pure returns (bytes memory) {
        return abi.encode(PAYLOAD_VERSION_1, ACTION_DEPOSIT_SWEEP, bytes(""));
    }
}
