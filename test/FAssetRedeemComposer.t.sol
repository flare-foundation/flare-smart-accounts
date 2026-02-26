// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {FAssetRedeemComposer} from "../contracts/composer/implementation/FAssetRedeemComposer.sol";
import {FAssetRedeemerAccount} from "../contracts/composer/implementation/FAssetRedeemerAccount.sol";
import {FAssetRedeemComposerProxy} from "../contracts/composer/proxy/FAssetRedeemComposerProxy.sol";
import {IFAssetRedeemComposer} from "../contracts/userInterfaces/IFAssetRedeemComposer.sol";
import {IAssetManager} from "flare-periphery/src/flare/IAssetManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {RevertingReceiver} from "./utils/RevertingReceiver.sol";

contract FAssetRedeemComposerTest is Test {
    FAssetRedeemComposer private composerImpl;
    FAssetRedeemComposerProxy private composerProxy;
    FAssetRedeemComposer private composer;

    address private owner;
    address private endpoint;
    address private trustedSourceOApp;
    address private assetManager;
    address private stableCoin;
    address private wNat;
    address private composerFeeRecipient;
    uint256 private defaultComposerFeePPM;
    address private redeemerAccountImplementation;
    address private fAsset;

    function setUp() public {
        owner = makeAddr("owner");
        endpoint = makeAddr("endpoint");
        trustedSourceOApp = makeAddr("trustedSourceOApp");
        assetManager = makeAddr("assetManager");
        stableCoin = makeAddr("stableCoin");
        wNat = makeAddr("wNat");
        composerFeeRecipient = makeAddr("composerFeeRecipient");
        defaultComposerFeePPM = 1000; // 0.1%
        fAsset = makeAddr("fAsset");

        // Mock fAsset
        _mockFAssetCode();
        _mockAssetManagerFAsset();

        // Mock token code existence
        vm.etch(stableCoin, bytes("code"));
        vm.etch(wNat, bytes("code"));

        redeemerAccountImplementation = address(new FAssetRedeemerAccount());

        composerImpl = new FAssetRedeemComposer();

        composerProxy = new FAssetRedeemComposerProxy(
            address(composerImpl),
            owner,
            endpoint,
            trustedSourceOApp,
            assetManager,
            stableCoin,
            wNat,
            composerFeeRecipient,
            defaultComposerFeePPM,
            redeemerAccountImplementation
        );

        composer = FAssetRedeemComposer(address(composerProxy));
    }

    // --- initialize ---

    function testInitialize() public {
        assertEq(composer.owner(), owner);
        assertEq(composer.endpoint(), endpoint);
        assertEq(composer.trustedSourceOApp(), trustedSourceOApp);
        assertEq(address(composer.assetManager()), assetManager);
        assertEq(address(composer.stableCoin()), stableCoin);
        assertEq(address(composer.wNat()), wNat);
        assertEq(composer.composerFeeRecipient(), composerFeeRecipient);
        assertEq(composer.defaultComposerFeePPM(), defaultComposerFeePPM);
        assertEq(composer.redeemerAccountImplementation(), redeemerAccountImplementation);
    }

    function testInitializeRevertInvalidOwner() public {
        vm.expectRevert(IFAssetRedeemComposer.InvalidAddress.selector);
        new FAssetRedeemComposerProxy(
            address(composerImpl),
            address(0),
            endpoint,
            trustedSourceOApp,
            assetManager,
            stableCoin,
            wNat,
            composerFeeRecipient,
            defaultComposerFeePPM,
            redeemerAccountImplementation
        );
    }

    function testInitializeRevertInvalidEndpoint() public {
        vm.expectRevert(IFAssetRedeemComposer.InvalidAddress.selector);
        new FAssetRedeemComposerProxy(
            address(composerImpl),
            owner,
            address(0),
            trustedSourceOApp,
            assetManager,
            stableCoin,
            wNat,
            composerFeeRecipient,
            defaultComposerFeePPM,
            redeemerAccountImplementation
        );
    }

    function testInitializeRevertInvalidTrustedSource() public {
        vm.expectRevert(IFAssetRedeemComposer.InvalidAddress.selector);
        new FAssetRedeemComposerProxy(
            address(composerImpl),
            owner,
            endpoint,
            address(0),
            assetManager,
            stableCoin,
            wNat,
            composerFeeRecipient,
            defaultComposerFeePPM,
            redeemerAccountImplementation
        );
    }

    function testInitializeRevertInvalidAssetManager() public {
        vm.expectRevert(IFAssetRedeemComposer.InvalidAddress.selector);
        new FAssetRedeemComposerProxy(
            address(composerImpl),
            owner,
            endpoint,
            trustedSourceOApp,
            address(0), // empty address (no code)
            stableCoin,
            wNat,
            composerFeeRecipient,
            defaultComposerFeePPM,
            redeemerAccountImplementation
        );
    }

    function testInitializeRevertInvalidStableCoin() public {
        vm.expectRevert(IFAssetRedeemComposer.InvalidAddress.selector);
        new FAssetRedeemComposerProxy(
            address(composerImpl),
            owner,
            endpoint,
            trustedSourceOApp,
            assetManager,
            address(0), // empty address (no code)
            wNat,
            composerFeeRecipient,
            defaultComposerFeePPM,
            redeemerAccountImplementation
        );
    }

    function testInitializeRevertInvalidWNat() public {
        vm.expectRevert(IFAssetRedeemComposer.InvalidAddress.selector);
        new FAssetRedeemComposerProxy(
            address(composerImpl),
            owner,
            endpoint,
            trustedSourceOApp,
            assetManager,
            stableCoin,
            address(0), // empty address (no code)
            composerFeeRecipient,
            defaultComposerFeePPM,
            redeemerAccountImplementation
        );
    }

    function testInitializeRevertInvalidFAsset() public {
        // Setup a scenario where fAsset has no code
        address invalidFAsset = makeAddr("invalidFAsset");
        // Ensure no code at this address (default for makeAddr, but explicit is good)
        // vm.etch not called

        // Mock asset manager to return this invalid fAsset
        vm.mockCall(
            assetManager,
            abi.encodeWithSelector(IAssetManager.fAsset.selector),
            abi.encode(invalidFAsset)
        );

        vm.expectRevert(IFAssetRedeemComposer.InvalidAddress.selector);
        new FAssetRedeemComposerProxy(
            address(composerImpl),
            owner,
            endpoint,
            trustedSourceOApp,
            assetManager,
            stableCoin,
            wNat,
            composerFeeRecipient,
            defaultComposerFeePPM,
            redeemerAccountImplementation
        );
    }

    function testInitializeRevertInvalidComposerFeeRecipient() public {
        vm.expectRevert(IFAssetRedeemComposer.InvalidAddress.selector);
        new FAssetRedeemComposerProxy(
            address(composerImpl),
            owner,
            endpoint,
            trustedSourceOApp,
            assetManager,
            stableCoin,
            wNat,
            address(0),
            defaultComposerFeePPM,
            redeemerAccountImplementation
        );
    }

    function testInitializeRevertInvalidComposerFeePPM() public {
        vm.expectRevert(IFAssetRedeemComposer.InvalidComposerFeePPM.selector);
        new FAssetRedeemComposerProxy(
            address(composerImpl),
            owner,
            endpoint,
            trustedSourceOApp,
            assetManager,
            stableCoin,
            wNat,
            composerFeeRecipient,
            1_000_000,
            redeemerAccountImplementation
        );
    }

    function testInitializeRevertInvalidRedeemerAccountImplementationNoCode() public {
        address noCodeImpl = makeAddr("noCodeImpl");
        vm.expectRevert(IFAssetRedeemComposer.InvalidRedeemerAccountImplementation.selector);
        new FAssetRedeemComposerProxy(
            address(composerImpl),
            owner,
            endpoint,
            trustedSourceOApp,
            assetManager,
            stableCoin,
            wNat,
            composerFeeRecipient,
            defaultComposerFeePPM,
            noCodeImpl
        );
    }

    // --- setDefaultComposerFee ---

    function testSetDefaultComposerFee() public {
        uint256 newFee = 2000;
        vm.prank(owner);
        vm.expectEmit();
        emit IFAssetRedeemComposer.DefaultComposerFeeSet(newFee);
        composer.setDefaultComposerFee(newFee);
        assertEq(composer.defaultComposerFeePPM(), newFee);
        assertEq(composer.getComposerFeePPM(1), newFee); // default applies to all srcEids without specific fee
    }

    function testSetDefaultComposerFeeRevertInvalid() public {
        uint256 newFee = 1_000_000;
        vm.prank(owner);
        vm.expectRevert(IFAssetRedeemComposer.InvalidComposerFeePPM.selector);
        composer.setDefaultComposerFee(newFee);
    }

    function testSetDefaultComposerFeeRevertOnlyOwner() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                address(this)
            )
        );
        composer.setDefaultComposerFee(2000);
    }

    // --- setComposerFees ---

    function testSetComposerFees() public {
        uint32[] memory srcEids = new uint32[](2);
        srcEids[0] = 1;
        srcEids[1] = 2;
        uint256[] memory fees = new uint256[](2);
        fees[0] = 500;
        fees[1] = 0;

        vm.prank(owner);
        vm.expectEmit();
        emit IFAssetRedeemComposer.ComposerFeeSet(1, 500);
        vm.expectEmit();
        emit IFAssetRedeemComposer.ComposerFeeSet(2, 0);
        composer.setComposerFees(srcEids, fees);

        assertEq(composer.getComposerFeePPM(1), 500);
        assertEq(composer.getComposerFeePPM(2), 0);
        assertEq(composer.getComposerFeePPM(3), defaultComposerFeePPM); // default
    }

    function testSetComposerFeesRevertLengthMismatch() public {
        uint32[] memory srcEids = new uint32[](1);
        uint256[] memory fees = new uint256[](2);
        vm.prank(owner);
        vm.expectRevert(IFAssetRedeemComposer.LengthMismatch.selector);
        composer.setComposerFees(srcEids, fees);
    }

    function testSetComposerFeesRevertInvalidFee() public {
        uint32[] memory srcEids = new uint32[](1);
        uint256[] memory fees = new uint256[](1);
        fees[0] = 1_000_000;
        vm.prank(owner);
        vm.expectRevert(IFAssetRedeemComposer.InvalidComposerFeePPM.selector);
        composer.setComposerFees(srcEids, fees);
    }

    function testSetComposerFeesRevertOnlyOwner() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                address(this)
            )
        );
        composer.setComposerFees(new uint32[](0), new uint256[](0));
    }

    // --- removeComposerFees ---

    function testRemoveComposerFeesRevertNotSet() public {
        uint32[] memory srcEids = new uint32[](1);
        srcEids[0] = 1;
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(IFAssetRedeemComposer.ComposerFeeNotSet.selector, 1)
        );
        composer.removeComposerFees(srcEids);
    }

    function testRemoveComposerFees() public {
        uint32[] memory srcEids = new uint32[](1);
        srcEids[0] = 1;
        uint256[] memory fees = new uint256[](1);
        fees[0] = 500;

        // First set fee
        vm.prank(owner);
        composer.setComposerFees(srcEids, fees);
        assertEq(composer.getComposerFeePPM(1), 500);

        // Then remove fee
        vm.prank(owner);
        vm.expectEmit();
        emit IFAssetRedeemComposer.ComposerFeeRemoved(1);
        composer.removeComposerFees(srcEids);
        assertEq(composer.getComposerFeePPM(1), defaultComposerFeePPM); // back to default
    }

    function testRemoveComposerFeesRevertOnlyOwner() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                address(this)
            )
        );
        composer.removeComposerFees(new uint32[](0));
    }

    // --- setComposerFeeRecipient ---

    function testSetComposerFeeRecipient() public {
        address newRecipient = makeAddr("newRecipient");
        vm.prank(owner);
        vm.expectEmit();
        emit IFAssetRedeemComposer.ComposerFeeRecipientSet(newRecipient);
        composer.setComposerFeeRecipient(newRecipient);
        assertEq(composer.composerFeeRecipient(), newRecipient);
    }

    function testSetComposerFeeRecipientRevertInvalid() public {
        vm.prank(owner);
        vm.expectRevert(IFAssetRedeemComposer.InvalidComposerFeeRecipient.selector);
        composer.setComposerFeeRecipient(address(0));
    }

    function testSetComposerFeeRecipientRevertOnlyOwner() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                address(this)
            )
        );
        composer.setComposerFeeRecipient(makeAddr("recipient"));
    }

    // --- setRedeemerAccountImplementation ---

    function testSetRedeemerAccountImplementation() public {
        FAssetRedeemerAccount newImpl = new FAssetRedeemerAccount();
        address newImplAddress = address(newImpl);

        vm.prank(owner);
        vm.expectEmit();
        emit IFAssetRedeemComposer.RedeemerAccountImplementationSet(newImplAddress);
        composer.setRedeemerAccountImplementation(newImplAddress);
        assertEq(composer.redeemerAccountImplementation(), newImplAddress);
    }

    function testSetRedeemerAccountImplementationRevertInvalid() public {
        vm.prank(owner);
        vm.expectRevert(IFAssetRedeemComposer.InvalidRedeemerAccountImplementation.selector);
        composer.setRedeemerAccountImplementation(address(0));
    }

    function testSetRedeemerAccountImplementationRevertOnlyOwner() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                address(this)
            )
        );
        composer.setRedeemerAccountImplementation(makeAddr("impl"));
    }

    // --- setExecutorData ---

    function testSetExecutorData() public returns (address, uint256) {
        address payable executor = payable(makeAddr("executor"));
        uint256 fee = 100;

        vm.prank(owner);
        vm.expectEmit();
        emit IFAssetRedeemComposer.ExecutorDataSet(executor, fee);
        composer.setExecutorData(executor, fee);

        (address payable resExecutor, uint256 resFee) = composer.getExecutorData();
        assertEq(resExecutor, executor);
        assertEq(resFee, fee);
        return (resExecutor, resFee);
    }

    function testSetExecutorDataZeroAddress() public {
        testSetExecutorData();
        vm.prank(owner);
        composer.setExecutorData(payable(address(0)), 0);
        (address payable resExecutor, uint256 resFee) = composer.getExecutorData();
        assertEq(resExecutor, payable(address(0)));
        assertEq(resFee, 0);
    }

    function testSetExecutorDataRevertInvalid() public {
        vm.prank(owner);
        vm.expectRevert(IFAssetRedeemComposer.InvalidExecutorData.selector);
        composer.setExecutorData(payable(address(0)), 100);
    }

    function testSetExecutorDataRevertOnlyOwner() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                address(this)
            )
        );
        composer.setExecutorData(payable(makeAddr("executor")), 100);
    }

    // --- transferFAsset ---

    function testTransferFAsset() public {
        uint256 amount = 100;
        address to = makeAddr("to");

        _mockSafeTransfer(fAsset, to, amount);

        vm.prank(owner);
        vm.expectEmit();
        emit IFAssetRedeemComposer.FAssetTransferred(to, amount);
        composer.transferFAsset(to, amount);
    }

    function testTransferFAssetRevertInvalidAddress() public {
        vm.prank(owner);
        vm.expectRevert(IFAssetRedeemComposer.InvalidAddress.selector);
        composer.transferFAsset(address(0), 100);
    }

    function testTransferFAssetRevertOnlyOwner() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                address(this)
            )
        );
        composer.transferFAsset(makeAddr("to"), 100);
    }

    // --- transferNative ---

    function testRecoverNative() public {
        uint256 amount = 1 ether;
        address to = makeAddr("to");
        vm.deal(address(composer), amount);

        vm.prank(owner);
        vm.expectEmit();
        emit IFAssetRedeemComposer.NativeTransferred(to, amount);
        composer.transferNative(to, amount);

        assertEq(to.balance, amount);
    }

    function testTransferNativeRevertInvalidAddress() public {
        vm.prank(owner);
        vm.expectRevert(IFAssetRedeemComposer.InvalidAddress.selector);
        composer.transferNative(address(0), 100);
    }

    function testTransferNativeRevertFailed() public {
        vm.deal(address(composer), 1 ether);
        RevertingReceiver receiver = new RevertingReceiver();

        vm.prank(owner);
        vm.expectRevert(IFAssetRedeemComposer.NativeTransferFailed.selector);
        composer.transferNative(address(receiver), 1 ether);
    }

    function testTransferNativeRevertOnlyOwner() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                address(this)
            )
        );
        composer.transferNative(makeAddr("to"), 100);
    }

    // --- lzCompose ---

    function testLzComposeSuccess() public {
        address redeemer = makeAddr("redeemer");
        string memory redeemerUnderlying = "rExample";
        uint32 srcEid = 1;
        uint256 amountLD = 1000;
        uint256 composerFee = amountLD * defaultComposerFeePPM / 1_000_000;
        uint256 amountToRedeem = amountLD - composerFee;

        (bytes memory message, bytes32 guid) = _encodeMessage(redeemer, redeemerUnderlying, srcEid, amountLD);

        address redeemerAccount = composer.getRedeemerAccountAddress(redeemer);

        // Mock token transfers
        _mockSafeTransfer(fAsset, composerFeeRecipient, composerFee);
        _mockSafeTransfer(fAsset, redeemerAccount, amountToRedeem);

        // Mock approvals for setMaxAllowances (called during deployment)
        _mockForceApprove(fAsset, true);
        _mockForceApprove(stableCoin, true);
        _mockForceApprove(wNat, true);

        // Mock AssetManager redeem call
        vm.mockCall(
            assetManager,
            abi.encodeWithSelector(IAssetManager.redeem.selector),
            abi.encode(amountToRedeem) // returns redeemedAmountUBA
        );

        (address executor, uint256 executorFee) = testSetExecutorData(); // set executor data

        // fund sender
        vm.deal(endpoint, executorFee);

        vm.prank(endpoint);

        vm.expectEmit();
        emit IFAssetRedeemComposer.ComposerFeeCollected(
            guid,
            srcEid,
            composerFeeRecipient,
            composerFee
        );

        vm.expectEmit();
        emit IFAssetRedeemComposer.FAssetTransferred(
            redeemerAccount,
            amountToRedeem
        );

        vm.expectEmit();
        emit IFAssetRedeemComposer.FAssetRedeemed(
            guid,
            srcEid,
            redeemer,
            redeemerAccount,
            amountToRedeem,
            redeemerUnderlying,
            executor,
            executorFee,
            amountToRedeem // result
        );

        composer.lzCompose{value: executorFee}(
            trustedSourceOApp,
            guid,
            message,
            address(0),
            ""
        );
    }

    function testLzComposeSuccessNotDefaultFee() public {
        // set specific fee for srcEid 2
        uint32 srcEid = 2;
        uint256 feePPM = 2000; // 0.2%
        uint32[] memory srcEids = new uint32[](1);
        srcEids[0] = srcEid;
        uint256[] memory fees = new uint256[](1);
        fees[0] = feePPM;
        vm.prank(owner);
        composer.setComposerFees(srcEids, fees);

        address redeemer = makeAddr("redeemer");
        string memory redeemerUnderlying = "rExample";
        uint256 amountLD = 1000;
        uint256 composerFee = amountLD * feePPM / 1_000_000;
        uint256 amountToRedeem = amountLD - composerFee;

        (bytes memory message, bytes32 guid) = _encodeMessage(redeemer, redeemerUnderlying, srcEid, amountLD);

        address redeemerAccount = composer.getRedeemerAccountAddress(redeemer);

        // Mock token transfers
        _mockSafeTransfer(fAsset, composerFeeRecipient, composerFee);
        _mockSafeTransfer(fAsset, redeemerAccount, amountToRedeem);

        // Mock approvals for setMaxAllowances (called during deployment)
        _mockForceApprove(fAsset, true);
        _mockForceApprove(stableCoin, true);
        _mockForceApprove(wNat, true);

        // Mock AssetManager redeem call
        vm.mockCall(
            assetManager,
            abi.encodeWithSelector(IAssetManager.redeem.selector),
            abi.encode(amountToRedeem) // returns redeemedAmountUBA
        );

        (address executor, uint256 executorFee) = testSetExecutorData(); // set executor data

        // fund sender
        vm.deal(endpoint, executorFee);

        vm.prank(endpoint);

        vm.expectEmit();
        emit IFAssetRedeemComposer.ComposerFeeCollected(
            guid,
            srcEid,
            composerFeeRecipient,
            composerFee
        );

        vm.expectEmit();
        emit IFAssetRedeemComposer.FAssetTransferred(
            redeemerAccount,
            amountToRedeem
        );

        vm.expectEmit();
        emit IFAssetRedeemComposer.FAssetRedeemed(
            guid,
            srcEid,
            redeemer,
            redeemerAccount,
            amountToRedeem,
            redeemerUnderlying,
            executor,
            executorFee,
            amountToRedeem // result
        );

        composer.lzCompose{value: executorFee}(
            trustedSourceOApp,
            guid,
            message,
            address(0),
            ""
        );
    }

    function testLzComposeSuccessZeroFee() public {
        // Set fee to 0
        vm.prank(owner);
        composer.setDefaultComposerFee(0);

        address redeemer = makeAddr("redeemer");
        string memory redeemerUnderlying = "rExample";
        uint32 srcEid = 1;
        uint256 amountLD = 1000;
        uint256 amountToRedeem = amountLD;

        (bytes memory message, bytes32 guid) = _encodeMessage(redeemer, redeemerUnderlying, srcEid, amountLD);

        address redeemerAccount = composer.getRedeemerAccountAddress(redeemer);

        // Mock token transfers - NO fee transfer
        _mockSafeTransfer(fAsset, redeemerAccount, amountToRedeem);

        // Mock approvals for setMaxAllowances (called during deployment)
        _mockForceApprove(fAsset, true);
        _mockForceApprove(stableCoin, true);
        _mockForceApprove(wNat, true);

        // Mock AssetManager redeem call
        vm.mockCall(
            assetManager,
            abi.encodeWithSelector(IAssetManager.redeem.selector),
            abi.encode(amountToRedeem)
        );

        vm.prank(endpoint);
        vm.expectEmit();
        emit IFAssetRedeemComposer.FAssetRedeemed(
            guid,
            srcEid,
            redeemer,
            redeemerAccount,
            amountToRedeem,
            redeemerUnderlying,
            address(0),
            0,
            amountToRedeem
        );

        composer.lzCompose(
            trustedSourceOApp,
            guid,
            message,
            address(0),
            ""
        );
    }

    function testLzComposeIdempotencyAndCachedAddress() public {
        address redeemer = makeAddr("redeemer");
        string memory redeemerUnderlying = "rExample";
        uint32 srcEid = 1;
        uint256 amountLD = 1000;

        (bytes memory message, bytes32 guid) = _encodeMessage(redeemer, redeemerUnderlying, srcEid, amountLD);

        // 1. First call - creates account

        // Setup mocks for first call
        address redeemerAccount = composer.getRedeemerAccountAddress(redeemer);
        uint256 fee = amountLD * defaultComposerFeePPM / 1_000_000;
        uint256 amountToRedeem = amountLD - fee;

        _mockSafeTransfer(fAsset, composerFeeRecipient, fee);
        _mockSafeTransfer(fAsset, redeemerAccount, amountToRedeem);
        _mockForceApprove(fAsset, true);
        _mockForceApprove(stableCoin, true);
        _mockForceApprove(wNat, true);
        vm.mockCall(
            assetManager,
            abi.encodeWithSelector(IAssetManager.redeem.selector),
            abi.encode(amountToRedeem)
        );

        vm.prank(endpoint);
        vm.expectEmit();
        emit IFAssetRedeemComposer.RedeemerAccountCreated(
            redeemer,
            redeemerAccount
        );

        composer.lzCompose(trustedSourceOApp, guid, message, address(0), "");

        // 2. Check if address is cached in mapping by calling getRedeemerAccountAddress
        assertEq(composer.getRedeemerAccountAddress(redeemer), redeemerAccount);

        // 3. Second call - should reuse account (no new creation events/logic)

        bytes32 guid2 = keccak256("guid2");

        vm.recordLogs();
        vm.prank(endpoint);

        composer.lzCompose(trustedSourceOApp, guid2, message, address(0), "");

        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 redeemerAccountCreatedSig = keccak256("RedeemerAccountCreated(address,address)");
        bytes32 fAssetRedeemedSig = keccak256(
            "FAssetRedeemed(bytes32,uint32,address,address,uint256,string,address,uint256,uint256)"
        );

        bool foundCreatedEvent = false;
        bool foundRedeemedEvent = false;

        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].topics[0] == redeemerAccountCreatedSig) {
                foundCreatedEvent = true;
            }
            if (entries[i].topics[0] == fAssetRedeemedSig) {
                foundRedeemedEvent = true;
            }
        }

        assertFalse(foundCreatedEvent, "Should not emit RedeemerAccountCreated on second call");
        assertTrue(foundRedeemedEvent, "Should emit FAssetRedeemed on second call");
    }

    function testLzComposeFailed() public {
        address redeemer = makeAddr("redeemer");
        string memory redeemerUnderlying = "rExample";
        uint32 srcEid = 1;
        uint256 amountLD = 1000;
        uint256 fee = amountLD * defaultComposerFeePPM / 1_000_000;
        uint256 amountToRedeem = amountLD - fee;

        (bytes memory message, bytes32 guid) = _encodeMessage(redeemer, redeemerUnderlying, srcEid, amountLD);

        address redeemerAccount = composer.getRedeemerAccountAddress(redeemer);

        _mockSafeTransfer(fAsset, composerFeeRecipient, fee);
        _mockSafeTransfer(fAsset, redeemerAccount, amountToRedeem);

        // Mock approvals for setMaxAllowances (called during deployment)
        _mockForceApprove(fAsset, true);
        _mockForceApprove(stableCoin, true);
        _mockForceApprove(wNat, true);

        // Make AssetManager.redeem revert
        vm.mockCallRevert(
            assetManager,
            abi.encodeWithSelector(IAssetManager.redeem.selector),
            "Redeem failed"
        );

        vm.prank(endpoint);
        vm.expectEmit();
        emit IFAssetRedeemComposer.RedeemerAccountCreated(
            redeemer,
            redeemerAccount
        );
        vm.expectEmit();
        emit IFAssetRedeemComposer.FAssetRedeemFailed(
            guid,
            srcEid,
            redeemer,
            redeemerAccount,
            amountToRedeem
        );

        composer.lzCompose(
            trustedSourceOApp,
            guid,
            message,
            address(0),
            ""
        );
    }

    function testLzComposeRevertOnlyEndpoint() public {
        vm.expectRevert(IFAssetRedeemComposer.OnlyEndpoint.selector);
        composer.lzCompose(
            trustedSourceOApp,
            bytes32(0),
            "",
            address(0),
            ""
        );
    }

    function testLzComposeRevertInvalidSource() public {
        vm.prank(endpoint);
        vm.expectRevert(
            abi.encodeWithSelector(IFAssetRedeemComposer.InvalidSourceOApp.selector, address(this))
        );
        composer.lzCompose(
            address(this),
            bytes32(0),
            "",
            address(0),
            ""
        );
    }

    function testLzComposeRevertInvalidRedeemer() public {
        uint32 srcEid = 1;
        uint256 amountLD = 1000;

        (bytes memory message, ) = _encodeMessage(address(0), "rExample", srcEid, amountLD);

        vm.prank(endpoint);
        vm.expectRevert(IFAssetRedeemComposer.InvalidAddress.selector);
        composer.lzCompose(
            trustedSourceOApp,
            bytes32(0),
            message,
            address(0),
            ""
        );
    }

    function testLzComposeFailedExecutorFeeNotCovered() public {
        address redeemer = makeAddr("redeemer");
        string memory redeemerUnderlying = "rExample";
        uint32 srcEid = 1;
        uint256 amountLD = 1000;
        uint256 fee = amountLD * defaultComposerFeePPM / 1_000_000;
        uint256 amountToRedeem = amountLD - fee;

        (bytes memory message, bytes32 guid) = _encodeMessage(redeemer, redeemerUnderlying, srcEid, amountLD);

        address redeemerAccount = composer.getRedeemerAccountAddress(redeemer);

        _mockSafeTransfer(fAsset, composerFeeRecipient, fee);
        _mockSafeTransfer(fAsset, redeemerAccount, amountToRedeem);

        // Mock approvals for setMaxAllowances (called during deployment)
        _mockForceApprove(fAsset, true);
        _mockForceApprove(stableCoin, true);
        _mockForceApprove(wNat, true);

        // set executor fee
        (, uint256 executorFee) = testSetExecutorData();
        vm.deal(endpoint, executorFee);

        // We expect the catch block to emit FAssetRedeemFailed
        // because the underlying call fails with ExecutorFeeNotCovered
        vm.prank(endpoint);
        vm.expectEmit();
        emit IFAssetRedeemComposer.FAssetRedeemFailed(
            guid,
            srcEid,
            redeemer,
            redeemerAccount,
            amountToRedeem
        );

        composer.lzCompose{value: executorFee - 1}(
            trustedSourceOApp,
            guid,
            message,
            address(0),
            ""
        );
    }


    // --- upgradeToAndCall ---

    function testUpgrade() public {
        // Deploy new implementation
        FAssetRedeemComposer newImpl = new FAssetRedeemComposer();

        vm.prank(owner);
        composer.upgradeToAndCall(address(newImpl), "");

        // Verify implementation slot (ERC1967 standard slot)
        bytes32 implementationSlot = bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);
        address implementation = address(uint160(uint256(vm.load(address(composer), implementationSlot))));

        assertEq(implementation, address(newImpl));
    }

    function testUpgradeWithData() public {
        // Deploy new implementation
        FAssetRedeemComposer newImpl = new FAssetRedeemComposer();

        // Prepare some data to call on the new implementation after upgrade
        bytes memory data = abi.encodeWithSelector(
            FAssetRedeemComposer.setDefaultComposerFee.selector,
            1234
        );

        vm.prank(owner);
        composer.upgradeToAndCall(address(newImpl), data);

        // Verify implementation slot (ERC1967 standard slot)
        bytes32 implementationSlot = bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);
        address implementation = address(uint160(uint256(vm.load(address(composer), implementationSlot))));
        assertEq(implementation, address(newImpl));

        // Verify the call data was executed (fee was updated)
        assertEq(composer.defaultComposerFeePPM(), 1234);
    }

    function testUpgradeRevertOnlyOwner() public {
        FAssetRedeemComposer newImpl = new FAssetRedeemComposer();
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                address(this)
            )
        );
        composer.upgradeToAndCall(address(newImpl), "");
    }

    // --- Helpers ---

    function _mockAssetManagerFAsset() private {
        vm.mockCall(
            assetManager,
            abi.encodeWithSelector(IAssetManager.fAsset.selector),
            abi.encode(fAsset)
        );
        vm.mockCall(
            assetManager,
            abi.encodeWithSelector(IAssetManager.lotSize.selector),
            abi.encode(1) // lot size 1 for simplicity
        );
    }

    function _mockFAssetCode() private {
        vm.etch(fAsset, bytes("code"));
    }

    function _mockSafeTransfer(address _token, address _to, uint256 _amount) private {
        vm.mockCall(
            _token,
            abi.encodeWithSelector(IERC20.transfer.selector, _to, _amount),
            abi.encode(true)
        );
    }

    function _mockForceApprove(address _token, bool _success) private {
        vm.mockCall(
            _token,
            abi.encodeWithSelector(IERC20.approve.selector),
            abi.encode(_success)
        );
    }

    function _encodeMessage(
        address _redeemer,
        string memory _redeemerUnderlying,
        uint32 _srcEid,
        uint256 _amountLD
    ) private pure returns (bytes memory, bytes32) {
        bytes memory composeMsg = abi.encode(_redeemer, _redeemerUnderlying);
        bytes memory message = abi.encodePacked(
            uint64(0), // nonce
            _srcEid,
            _amountLD,
            bytes32(0), // composeFrom
            composeMsg
        );
        return (message, keccak256("guid"));
    }

}
