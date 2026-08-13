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
    address private morpho;
    uint32 private originEid;
    bytes32 private originPeer;

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
        // the settings validate that these are contracts; their behavior is not needed yet
        lzEndpoint = makeAddr("lzEndpoint");
        vm.etch(lzEndpoint, hex"00");
        fxrpOft.setEndpoint(lzEndpoint);
        morpho = makeAddr("morpho");
        vm.etch(morpho, hex"00");
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
        assertEq(stored.morpho, morpho);
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
            morpho: morpho,
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
}
