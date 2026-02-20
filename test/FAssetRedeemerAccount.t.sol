// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {FAssetRedeemerAccount} from "../contracts/composer/implementation/FAssetRedeemerAccount.sol";
import {FAssetRedeemerAccountProxy} from "../contracts/composer/proxy/FAssetRedeemerAccountProxy.sol";
import {IFAssetRedeemerAccount} from "../contracts/userInterfaces/IFAssetRedeemerAccount.sol";
import {IAssetManager} from "flare-periphery/src/flare/IAssetManager.sol";
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

    function testRedeemFAsset() public {
        uint256 amountLD = 1000;
        string memory redeemerUnderlying = "rExample";
        address payable executor = payable(makeAddr("executor"));
        uint256 executorFee = 1 ether;

        _mockAssetManagerLotSize(1);
        _mockAssetManagerRedeem(amountLD);

        // Fund composer (beacon) to pay executor fee
        vm.deal(address(beacon), executorFee);

        vm.prank(address(beacon));
        uint256 redeemed = account.redeemFAsset{value: executorFee}(
            IAssetManager(assetManager),
            amountLD,
            redeemerUnderlying,
            executor,
            executorFee
        );

        assertEq(redeemed, amountLD);
    }

    function testRedeemFAssetRevertComposerOnly() public {
        vm.expectRevert(IFAssetRedeemerAccount.ComposerOnly.selector);
        account.redeemFAsset(
            IAssetManager(assetManager),
            1000,
            "rExample",
            payable(address(0)),
            0
        );
    }

    function testRedeemFAssetRevertExecutorFeeNotCovered() public {
        uint256 amountLD = 1000;
        string memory redeemerUnderlying = "rExample";
        address payable executor = payable(makeAddr("executor"));
        uint256 executorFee = 1 ether;
        uint256 sentValue = 0.5 ether;

        // No need to mock asset manager as it reverts before call

        vm.deal(address(beacon), executorFee);
        vm.prank(address(beacon));

        vm.expectRevert(
            abi.encodeWithSelector(
                IFAssetRedeemerAccount.ExecutorFeeNotCovered.selector,
                sentValue,
                executorFee
            )
        );

        account.redeemFAsset{value: sentValue}(
            IAssetManager(assetManager),
            amountLD,
            redeemerUnderlying,
            executor,
            executorFee
        );
    }

    // Helpers

    function _mockForceApprove(address _token) private {
        vm.mockCall(
            _token,
            abi.encodeWithSelector(IERC20.approve.selector),
            abi.encode(true)
        );
    }

    function _mockAssetManagerLotSize(uint256 _size) private {
        vm.mockCall(
            assetManager,
            abi.encodeWithSelector(IAssetManager.lotSize.selector),
            abi.encode(_size)
        );
    }

    function _mockAssetManagerRedeem(uint256 _result) private {
        vm.mockCall(
            assetManager,
            abi.encodeWithSelector(IAssetManager.redeem.selector),
            abi.encode(_result)
        );
    }
}
