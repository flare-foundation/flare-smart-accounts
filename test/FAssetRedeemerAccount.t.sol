// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {FAssetRedeemerAccount} from "../contracts/composer/implementation/FAssetRedeemerAccount.sol";
import {FAssetRedeemerAccountProxy} from "../contracts/composer/proxy/FAssetRedeemerAccountProxy.sol";
import {IFAssetRedeemerAccount} from "../contracts/userInterfaces/IFAssetRedeemerAccount.sol";
import {IAssetManager} from "flare-periphery/src/flare/IAssetManager.sol";
import {IRedeemExtended} from "flare-periphery/src/flare/IRedeemExtended.sol";
import {IReferencedPaymentNonexistence} from "flare-periphery/src/flare/IReferencedPaymentNonexistence.sol";
import {IXRPPaymentNonexistence} from "flare-periphery/src/flare/IXRPPaymentNonexistence.sol";
import {IFAssetRedeemComposer} from "../contracts/userInterfaces/IFAssetRedeemComposer.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockBeacon} from "./utils/MockBeacon.sol";
import {UninitializedProxy} from "./utils/UninitializedProxy.sol";

contract FAssetRedeemerAccountTest is Test {
    FAssetRedeemerAccount private accountImpl;
    FAssetRedeemerAccount private account;
    MockBeacon private beacon;

    address private owner;
    address private assetManager;
    address private fAsset;
    address private stableCoin;
    address private wNat;

    function setUp() public {
        owner = makeAddr("owner");
        assetManager = makeAddr("assetManager");
        fAsset = makeAddr("fAsset");
        stableCoin = makeAddr("stableCoin");
        wNat = makeAddr("wNat");

        accountImpl = new FAssetRedeemerAccount();
        beacon = new MockBeacon(address(accountImpl));

        // Deploy proxy using beacon as "composer"
        // This sets account.composer = address(beacon)
        // we cant use regular address for composer here because FAssetRedeemerAccountProxy initializes
        // BeaconProxy which calls IBeacon(newBeacon).implementation()
        // so we need a mock have the implementation address implemented.
        FAssetRedeemerAccountProxy proxy = new FAssetRedeemerAccountProxy(
            address(beacon),
            owner
        );
        account = FAssetRedeemerAccount(address(proxy));
    }

    function testInitialize() public {
        assertEq(account.composer(), address(beacon));
        assertEq(account.owner(), owner);
    }

    function testInitializeRevertAlreadyInitialized() public {
        vm.expectRevert(IFAssetRedeemerAccount.AlreadyInitialized.selector);
        account.initialize(address(beacon), owner);
    }

    function testInitializeRevertInvalidAddress() public {
        // UninitializedProxy delegates to the implementation without calling initialize,
        // giving us zeroed storage so we can test the address validation in initialize().
        UninitializedProxy uninitializedProxy = new UninitializedProxy(address(accountImpl));
        FAssetRedeemerAccount uninitializedAccount = FAssetRedeemerAccount(address(uninitializedProxy));

        vm.expectRevert(IFAssetRedeemerAccount.InvalidAddress.selector);
        uninitializedAccount.initialize(address(0), owner);

        vm.expectRevert(IFAssetRedeemerAccount.InvalidAddress.selector);
        uninitializedAccount.initialize(address(beacon), address(0));
    }

    function testSetMaxAllowances() public {
        _mockForceApprove(fAsset);
        _mockForceApprove(stableCoin);
        _mockForceApprove(wNat);

        vm.prank(address(beacon)); // Prank as composer
        vm.expectEmit();
        emit IFAssetRedeemerAccount.MaxAllowancesSet(
            owner,
            IERC20(fAsset),
            IERC20(stableCoin),
            IERC20(wNat)
        );
        account.setMaxAllowances(IERC20(fAsset), IERC20(stableCoin), IERC20(wNat));
    }

    function testSetMaxAllowancesRevertComposerOnly() public {
        vm.expectRevert(IFAssetRedeemerAccount.ComposerOnly.selector);
        account.setMaxAllowances(IERC20(fAsset), IERC20(stableCoin), IERC20(wNat));
    }

    function testRedeemFAssetWithRedeemAmount() public {
        uint256 amountLD = 1000;
        string memory redeemerUnderlying = "rExample";
        address payable executor = payable(makeAddr("executor"));
        uint256 nativeValue = 1 ether;

        _mockAssetManagerRedeemAmount(amountLD);

        vm.deal(address(beacon), nativeValue);

        vm.prank(address(beacon));
        vm.expectEmit();
        emit IFAssetRedeemerAccount.FAssetRedeemed(
            amountLD,
            redeemerUnderlying,
            false,
            0,
            executor,
            nativeValue,
            amountLD
        );
        uint256 redeemed = account.redeemFAsset{value: nativeValue}(
            IAssetManager(assetManager),
            amountLD,
            redeemerUnderlying,
            false,
            0,
            executor
        );

        assertEq(redeemed, amountLD);
    }

    function testRedeemFAssetWithRedeemAmountIgnoresTag() public {
        uint256 amountLD = 1000;
        string memory redeemerUnderlying = "rExample";
        address payable executor = payable(makeAddr("executor"));
        uint256 nativeValue = 1 ether;
        uint256 destinationTag = 99999;

        _mockAssetManagerRedeemAmount(amountLD);

        vm.deal(address(beacon), nativeValue);

        vm.prank(address(beacon));
        vm.expectEmit();
        emit IFAssetRedeemerAccount.FAssetRedeemed(
            amountLD,
            redeemerUnderlying,
            false,
            destinationTag,
            executor,
            nativeValue,
            amountLD
        );
        uint256 redeemed = account.redeemFAsset{value: nativeValue}(
            IAssetManager(assetManager),
            amountLD,
            redeemerUnderlying,
            false,
            destinationTag,
            executor
        );

        assertEq(redeemed, amountLD);
    }

    function testRedeemFAssetWithRedeemWithTag() public {
        uint256 amountLD = 1000;
        string memory redeemerUnderlying = "rExample";
        address payable executor = payable(makeAddr("executor"));
        uint256 nativeValue = 1 ether;
        uint256 destinationTag = 12345;

        _mockRedeemWithTagSupported(true);
        _mockAssetManagerRedeemWithTag(amountLD);

        vm.deal(address(beacon), nativeValue);

        vm.prank(address(beacon));
        vm.expectEmit();
        emit IFAssetRedeemerAccount.FAssetRedeemed(
            amountLD,
            redeemerUnderlying,
            true,
            destinationTag,
            executor,
            nativeValue,
            amountLD
        );
        uint256 redeemed = account.redeemFAsset{value: nativeValue}(
            IAssetManager(assetManager),
            amountLD,
            redeemerUnderlying,
            true,
            destinationTag,
            executor
        );

        assertEq(redeemed, amountLD);
    }

    function testRedeemFAssetRevertRedeemWithTagNotSupported() public {
        uint256 nativeValue = 1 ether;
        uint256 destinationTag = 12345;

        _mockRedeemWithTagSupported(false);

        vm.deal(address(beacon), nativeValue);
        vm.prank(address(beacon));

        vm.expectRevert(
            abi.encodeWithSelector(
                IFAssetRedeemerAccount.RedeemWithTagNotSupported.selector,
                destinationTag
            )
        );

        account.redeemFAsset{value: nativeValue}(
            IAssetManager(assetManager),
            1000,
            "rExample",
            true,
            destinationTag,
            payable(makeAddr("executor"))
        );
    }

    function testRedeemFAssetRevertComposerOnly() public {
        vm.expectRevert(IFAssetRedeemerAccount.ComposerOnly.selector);
        account.redeemFAsset(
            IAssetManager(assetManager),
            1000,
            "rExample",
            false,
            0,
            payable(address(0))
        );
    }

    // --- redemptionPaymentDefault ---

    function testRedemptionPaymentDefaultSuccess() public {
        uint256 requestId = 42;
        IReferencedPaymentNonexistence.Proof memory proof;

        _mockComposerAssetManager();
        vm.mockCall(
            assetManager,
            abi.encodeWithSelector(IAssetManager.redemptionPaymentDefault.selector, proof, requestId),
            ""
        );

        vm.prank(owner);
        vm.expectEmit();
        emit IFAssetRedeemerAccount.RedemptionPaymentDefaulted(requestId);
        account.redemptionPaymentDefault(proof, requestId);
    }

    function testRedemptionPaymentDefaultRevertOwnerOnly() public {
        IReferencedPaymentNonexistence.Proof memory proof;

        // composer is not owner
        vm.prank(address(beacon));
        vm.expectRevert(IFAssetRedeemerAccount.OwnerOnly.selector);
        account.redemptionPaymentDefault(proof, 1);

        // a random EOA is not owner
        vm.prank(makeAddr("intruder"));
        vm.expectRevert(IFAssetRedeemerAccount.OwnerOnly.selector);
        account.redemptionPaymentDefault(proof, 1);
    }

    function testRedemptionPaymentDefaultBubblesAssetManagerRevert() public {
        IReferencedPaymentNonexistence.Proof memory proof;

        _mockComposerAssetManager();
        vm.mockCallRevert(
            assetManager,
            abi.encodeWithSelector(IAssetManager.redemptionPaymentDefault.selector),
            "AM revert"
        );

        vm.prank(owner);
        vm.expectRevert("AM revert");
        account.redemptionPaymentDefault(proof, 1);
    }

    // --- xrpRedemptionPaymentDefault ---

    function testXrpRedemptionPaymentDefaultSuccess() public {
        uint256 requestId = 99;
        IXRPPaymentNonexistence.Proof memory proof;

        _mockComposerAssetManager();
        vm.mockCall(
            assetManager,
            abi.encodeWithSelector(IRedeemExtended.xrpRedemptionPaymentDefault.selector, proof, requestId),
            ""
        );

        vm.prank(owner);
        vm.expectEmit();
        emit IFAssetRedeemerAccount.XrpRedemptionPaymentDefaulted(requestId);
        account.xrpRedemptionPaymentDefault(proof, requestId);
    }

    function testXrpRedemptionPaymentDefaultRevertOwnerOnly() public {
        IXRPPaymentNonexistence.Proof memory proof;

        // composer is not owner
        vm.prank(address(beacon));
        vm.expectRevert(IFAssetRedeemerAccount.OwnerOnly.selector);
        account.xrpRedemptionPaymentDefault(proof, 1);

        // a random EOA is not owner
        vm.prank(makeAddr("intruder"));
        vm.expectRevert(IFAssetRedeemerAccount.OwnerOnly.selector);
        account.xrpRedemptionPaymentDefault(proof, 1);
    }

    function testXrpRedemptionPaymentDefaultBubblesAssetManagerRevert() public {
        IXRPPaymentNonexistence.Proof memory proof;

        _mockComposerAssetManager();
        vm.mockCallRevert(
            assetManager,
            abi.encodeWithSelector(IRedeemExtended.xrpRedemptionPaymentDefault.selector),
            "AM revert"
        );

        vm.prank(owner);
        vm.expectRevert("AM revert");
        account.xrpRedemptionPaymentDefault(proof, 1);
    }

    // Helpers

    function _mockForceApprove(address _token) private {
        vm.mockCall(
            _token,
            abi.encodeWithSelector(IERC20.approve.selector),
            abi.encode(true)
        );
    }

    function _mockAssetManagerRedeemAmount(uint256 _result) private {
        vm.mockCall(
            assetManager,
            abi.encodeWithSelector(IRedeemExtended.redeemAmount.selector),
            abi.encode(_result)
        );
    }

    function _mockAssetManagerRedeemWithTag(uint256 _result) private {
        vm.mockCall(
            assetManager,
            abi.encodeWithSelector(IRedeemExtended.redeemWithTag.selector),
            abi.encode(_result)
        );
    }

    function _mockComposerAssetManager() private {
        vm.mockCall(
            address(beacon),
            abi.encodeWithSelector(IFAssetRedeemComposer.assetManager.selector),
            abi.encode(assetManager)
        );
    }

    function _mockRedeemWithTagSupported(bool _supported) private {
        vm.mockCall(
            assetManager,
            abi.encodeWithSelector(IRedeemExtended.redeemWithTagSupported.selector),
            abi.encode(_supported)
        );
    }
}
