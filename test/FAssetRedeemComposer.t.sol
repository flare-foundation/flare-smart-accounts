// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {FAssetRedeemComposer} from "../contracts/composer/implementation/FAssetRedeemComposer.sol";
import {FAssetRedeemerAccount} from "../contracts/composer/implementation/FAssetRedeemerAccount.sol";
import {FAssetRedeemComposerProxy} from "../contracts/composer/proxy/FAssetRedeemComposerProxy.sol";
import {IFAssetRedeemComposer} from "../contracts/userInterfaces/IFAssetRedeemComposer.sol";
import {IOwnableWithTimelock} from "../contracts/userInterfaces/IOwnableWithTimelock.sol";
import {IAssetManager} from "flare-periphery/src/flare/IAssetManager.sol";
import {IRedeemExtended} from "flare-periphery/src/flare/IRedeemExtended.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

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
    address payable private defaultExecutor;

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
        defaultExecutor = payable(makeAddr("defaultExecutor"));

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
            defaultExecutor,
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
        assertEq(composer.defaultExecutor(), defaultExecutor);
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
            defaultExecutor,
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
            defaultExecutor,
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
            defaultExecutor,
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
            defaultExecutor,
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
            defaultExecutor,
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
            defaultExecutor,
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
            defaultExecutor,
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
            defaultExecutor,
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
            defaultExecutor,
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
            defaultExecutor,
            noCodeImpl
        );
    }

    function testInitializeRevertInvalidDefaultExecutor() public {
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
            payable(address(0)),
            redeemerAccountImplementation
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

    // --- setDefaultExecutor ---

    function testSetDefaultExecutor() public {
        address payable newExecutor = payable(makeAddr("newExecutor"));

        vm.prank(owner);
        vm.expectEmit();
        emit IFAssetRedeemComposer.DefaultExecutorSet(newExecutor);
        composer.setDefaultExecutor(newExecutor);

        assertEq(composer.defaultExecutor(), newExecutor);
    }

    function testSetDefaultExecutorRevertInvalidAddress() public {
        vm.prank(owner);
        vm.expectRevert(IFAssetRedeemComposer.InvalidAddress.selector);
        composer.setDefaultExecutor(payable(address(0)));
    }

    function testSetDefaultExecutorRevertOnlyOwner() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                address(this)
            )
        );
        composer.setDefaultExecutor(payable(makeAddr("executor")));
    }

    // --- lzCompose ---

    function testLzComposeSuccess() public {
        address redeemer = makeAddr("redeemer");
        string memory redeemerUnderlying = "rExample";
        uint32 srcEid = 1;
        uint256 amountLD = 1000;
        uint256 composerFee = amountLD * defaultComposerFeePPM / 1_000_000;
        uint256 amountToRedeem = amountLD - composerFee;
        uint256 nativeValue = 0.1 ether;

        (bytes memory message, bytes32 guid) = _encodeMessageFull(
            redeemer, redeemerUnderlying, false, 0, payable(address(0)), nativeValue, srcEid, amountLD
        );

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
            abi.encodeWithSelector(IRedeemExtended.redeemAmount.selector),
            abi.encode(amountToRedeem) // returns redeemedAmountUBA
        );

        // fund sender
        vm.deal(endpoint, nativeValue);

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
            false,
            0,
            defaultExecutor,
            nativeValue,
            amountToRedeem, // result
            0 // wrappedAmount (no excess)
        );

        composer.lzCompose{value: nativeValue}(
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
        uint256 nativeValue = 0.1 ether;

        (bytes memory message, bytes32 guid) = _encodeMessageFull(
            redeemer, redeemerUnderlying, false, 0, payable(address(0)), nativeValue, srcEid, amountLD
        );

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
            abi.encodeWithSelector(IRedeemExtended.redeemAmount.selector),
            abi.encode(amountToRedeem) // returns redeemedAmountUBA
        );

        // fund sender
        vm.deal(endpoint, nativeValue);

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
            false,
            0,
            defaultExecutor,
            nativeValue,
            amountToRedeem, // result
            0 // wrappedAmount (no excess)
        );

        composer.lzCompose{value: nativeValue}(
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
            abi.encodeWithSelector(IRedeemExtended.redeemAmount.selector),
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
            false,
            0,
            defaultExecutor,
            0,
            amountToRedeem,
            0 // wrappedAmount
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
            abi.encodeWithSelector(IRedeemExtended.redeemAmount.selector),
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
        bytes32 redeemerAccountCreatedSig = IFAssetRedeemComposer.RedeemerAccountCreated.selector;
        bytes32 fAssetRedeemedSig = IFAssetRedeemComposer.FAssetRedeemed.selector;

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
            abi.encodeWithSelector(IRedeemExtended.redeemAmount.selector),
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
            amountToRedeem,
            0
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

    function testLzComposeSuccessIgnoresTagWhenRedeemWithTagFalse() public {
        address redeemer = makeAddr("redeemer");
        string memory redeemerUnderlying = "rExample";
        uint32 srcEid = 1;
        uint256 amountLD = 1000;
        uint256 destinationTag = 99999;
        uint256 composerFee = amountLD * defaultComposerFeePPM / 1_000_000;
        uint256 amountToRedeem = amountLD - composerFee;
        uint256 nativeValue = 0.1 ether;

        // redeemWithTag = false, but destinationTag != 0
        (bytes memory message, bytes32 guid) = _encodeMessageFull(
            redeemer, redeemerUnderlying, false, destinationTag, payable(address(0)), nativeValue, srcEid, amountLD
        );

        address redeemerAccount = composer.getRedeemerAccountAddress(redeemer);

        _mockSafeTransfer(fAsset, composerFeeRecipient, composerFee);
        _mockSafeTransfer(fAsset, redeemerAccount, amountToRedeem);
        _mockForceApprove(fAsset, true);
        _mockForceApprove(stableCoin, true);
        _mockForceApprove(wNat, true);

        // Only mock redeemAmount (not redeemWithTag) to verify the tag path is not taken
        vm.mockCall(
            assetManager,
            abi.encodeWithSelector(IRedeemExtended.redeemAmount.selector),
            abi.encode(amountToRedeem)
        );

        vm.deal(endpoint, nativeValue);
        vm.prank(endpoint);

        vm.expectEmit();
        emit IFAssetRedeemComposer.FAssetRedeemed(
            guid,
            srcEid,
            redeemer,
            redeemerAccount,
            amountToRedeem,
            redeemerUnderlying,
            false,
            destinationTag,
            defaultExecutor,
            nativeValue,
            amountToRedeem,
            0 // wrappedAmount (no excess)
        );

        composer.lzCompose{value: nativeValue}(
            trustedSourceOApp,
            guid,
            message,
            address(0),
            ""
        );
    }

    // --- lzCompose with redeemWithTag ---

    function testLzComposeSuccessRedeemWithTag() public {
        address redeemer = makeAddr("redeemer");
        string memory redeemerUnderlying = "rExample";
        uint32 srcEid = 1;
        uint256 amountLD = 1000;
        uint256 destinationTag = 12345;
        uint256 composerFee = amountLD * defaultComposerFeePPM / 1_000_000;
        uint256 amountToRedeem = amountLD - composerFee;
        uint256 nativeValue = 0.1 ether;

        (bytes memory message, bytes32 guid) = _encodeMessageFull(
            redeemer, redeemerUnderlying, true, destinationTag, payable(address(0)), nativeValue, srcEid, amountLD
        );

        address redeemerAccount = composer.getRedeemerAccountAddress(redeemer);

        _mockSafeTransfer(fAsset, composerFeeRecipient, composerFee);
        _mockSafeTransfer(fAsset, redeemerAccount, amountToRedeem);
        _mockForceApprove(fAsset, true);
        _mockForceApprove(stableCoin, true);
        _mockForceApprove(wNat, true);

        // Mock redeemWithTagSupported and redeemWithTag
        vm.mockCall(
            assetManager,
            abi.encodeWithSelector(IRedeemExtended.redeemWithTagSupported.selector),
            abi.encode(true)
        );
        vm.mockCall(
            assetManager,
            abi.encodeWithSelector(IRedeemExtended.redeemWithTag.selector),
            abi.encode(amountToRedeem)
        );

        vm.deal(endpoint, nativeValue);
        vm.prank(endpoint);

        vm.expectEmit();
        emit IFAssetRedeemComposer.FAssetRedeemed(
            guid,
            srcEid,
            redeemer,
            redeemerAccount,
            amountToRedeem,
            redeemerUnderlying,
            true,
            destinationTag,
            defaultExecutor,
            nativeValue,
            amountToRedeem,
            0 // wrappedAmount (no excess)
        );

        composer.lzCompose{value: nativeValue}(
            trustedSourceOApp,
            guid,
            message,
            address(0),
            ""
        );
    }

    function testLzComposeFailedRedeemWithTagNotSupported() public {
        address redeemer = makeAddr("redeemer");
        string memory redeemerUnderlying = "rExample";
        uint32 srcEid = 1;
        uint256 amountLD = 1000;
        uint256 destinationTag = 12345;
        uint256 composerFee = amountLD * defaultComposerFeePPM / 1_000_000;
        uint256 amountToRedeem = amountLD - composerFee;

        (bytes memory message, bytes32 guid) = _encodeMessageFull(
            redeemer, redeemerUnderlying, true, destinationTag, payable(address(0)), 0, srcEid, amountLD
        );

        address redeemerAccount = composer.getRedeemerAccountAddress(redeemer);

        _mockSafeTransfer(fAsset, composerFeeRecipient, composerFee);
        _mockSafeTransfer(fAsset, redeemerAccount, amountToRedeem);
        _mockForceApprove(fAsset, true);
        _mockForceApprove(stableCoin, true);
        _mockForceApprove(wNat, true);

        // redeemWithTagSupported returns false -> revert caught by try-catch
        vm.mockCall(
            assetManager,
            abi.encodeWithSelector(IRedeemExtended.redeemWithTagSupported.selector),
            abi.encode(false)
        );

        vm.prank(endpoint);
        vm.expectEmit();
        emit IFAssetRedeemComposer.FAssetRedeemFailed(
            guid,
            srcEid,
            redeemer,
            redeemerAccount,
            amountToRedeem,
            0
        );

        composer.lzCompose(
            trustedSourceOApp,
            guid,
            message,
            address(0),
            ""
        );
    }

    // --- lzCompose with custom executor ---

    function testLzComposeSuccessCustomExecutor() public {
        address redeemer = makeAddr("redeemer");
        string memory redeemerUnderlying = "rExample";
        uint32 srcEid = 1;
        uint256 amountLD = 1000;
        address payable customExecutor = payable(makeAddr("customExecutor"));
        uint256 composerFee = amountLD * defaultComposerFeePPM / 1_000_000;
        uint256 amountToRedeem = amountLD - composerFee;
        uint256 customExecutorFee = 0.5 ether;

        (bytes memory message, bytes32 guid) = _encodeMessageFull(
            redeemer, redeemerUnderlying, false, 0, customExecutor, customExecutorFee, srcEid, amountLD
        );

        address redeemerAccount = composer.getRedeemerAccountAddress(redeemer);

        _mockSafeTransfer(fAsset, composerFeeRecipient, composerFee);
        _mockSafeTransfer(fAsset, redeemerAccount, amountToRedeem);
        _mockForceApprove(fAsset, true);
        _mockForceApprove(stableCoin, true);
        _mockForceApprove(wNat, true);

        vm.mockCall(
            assetManager,
            abi.encodeWithSelector(IRedeemExtended.redeemAmount.selector),
            abi.encode(amountToRedeem)
        );

        vm.deal(endpoint, customExecutorFee);
        vm.prank(endpoint);

        // When custom executor is provided in compose message, it overrides defaultExecutor
        vm.expectEmit();
        emit IFAssetRedeemComposer.FAssetRedeemed(
            guid,
            srcEid,
            redeemer,
            redeemerAccount,
            amountToRedeem,
            redeemerUnderlying,
            false,
            0,
            customExecutor,
            customExecutorFee,
            amountToRedeem,
            0 // wrappedAmount (no excess)
        );

        composer.lzCompose{value: customExecutorFee}(
            trustedSourceOApp,
            guid,
            message,
            address(0),
            ""
        );
    }

    // --- implementation ---

    function testImplementation() public {
        assertEq(composer.implementation(), redeemerAccountImplementation);
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

    function testUpgradeWithDataAndTimelockRevertOnlyOwner() public {
        // set timelock to 1 hour
        vm.prank(owner);
        composer.setTimelockDuration(1 hours);

        // Deploy new implementation
        FAssetRedeemComposer newImpl = new FAssetRedeemComposer();

        // Prepare some data to call on the new implementation after upgrade
        bytes memory data = abi.encodeWithSelector(
            FAssetRedeemComposer.setDefaultComposerFee.selector,
            1234
        );

        // Calculate encoded call data
        bytes memory encodedCall = abi.encodeWithSelector(
            UUPSUpgradeable.upgradeToAndCall.selector,
            address(newImpl),
            data
        );

        vm.prank(owner);
        vm.expectEmit();
        emit IOwnableWithTimelock.CallTimelocked(encodedCall, keccak256(encodedCall), block.timestamp + 1 hours);
        composer.upgradeToAndCall(address(newImpl), data);

        // Fast forward time by 1 hour to surpass timelock
        skip(1 hours);

        // Execute the upgrade after timelock
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                address(composer)
            )
        );
        composer.executeTimelockedCall(encodedCall);
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

    // --- OwnableWithTimelock: setTimelockDuration ---

    function testTimelockDurationInitiallyZero() public view {
        assertEq(composer.getTimelockDurationSeconds(), 0);
    }

    function testSetTimelockDurationDirectExecutionWhenZero() public {
        vm.prank(owner);
        vm.expectEmit();
        emit IOwnableWithTimelock.TimelockDurationSet(2 hours);
        composer.setTimelockDuration(2 hours);

        assertEq(composer.getTimelockDurationSeconds(), 2 hours);
    }

    function testSetTimelockDurationRevertTooLong() public {
        vm.prank(owner);
        vm.expectRevert(IOwnableWithTimelock.TimelockDurationTooLong.selector);
        composer.setTimelockDuration(7 days + 1);
    }

    function testSetTimelockDurationRevertNonOwner() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                address(this)
            )
        );
        composer.setTimelockDuration(1 hours);
    }

    function testSetTimelockDurationQueuedOnceActive() public {
        vm.prank(owner);
        composer.setTimelockDuration(1 hours);

        bytes memory encodedCall = abi.encodeWithSelector(
            IOwnableWithTimelock.setTimelockDuration.selector,
            30 minutes
        );

        vm.prank(owner);
        vm.expectEmit();
        emit IOwnableWithTimelock.CallTimelocked(
            encodedCall, keccak256(encodedCall), block.timestamp + 1 hours
        );
        composer.setTimelockDuration(30 minutes);

        assertEq(composer.getTimelockDurationSeconds(), 1 hours);
        assertEq(
            composer.getExecuteTimelockedCallTimestamp(encodedCall),
            block.timestamp + 1 hours
        );
    }

    // --- OwnableWithTimelock: cancelTimelockedCall ---

    function testCancelTimelockedCall() public {
        vm.prank(owner);
        composer.setTimelockDuration(1 hours);

        bytes memory encodedCall = abi.encodeWithSelector(
            FAssetRedeemComposer.setDefaultComposerFee.selector,
            2000
        );

        vm.prank(owner);
        composer.setDefaultComposerFee(2000);

        vm.prank(owner);
        vm.expectEmit();
        emit IOwnableWithTimelock.TimelockedCallCanceled(keccak256(encodedCall));
        composer.cancelTimelockedCall(encodedCall);

        vm.expectRevert(IOwnableWithTimelock.TimelockInvalidSelector.selector);
        composer.getExecuteTimelockedCallTimestamp(encodedCall);
    }

    function testCancelTimelockedCallRevertNonOwner() public {
        vm.prank(owner);
        composer.setTimelockDuration(1 hours);

        bytes memory encodedCall = abi.encodeWithSelector(
            FAssetRedeemComposer.setDefaultComposerFee.selector,
            2000
        );

        vm.prank(owner);
        composer.setDefaultComposerFee(2000);

        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                address(this)
            )
        );
        composer.cancelTimelockedCall(encodedCall);
    }

    function testCancelTimelockedCallRevertInvalidSelector() public {
        bytes memory encodedCall = abi.encodeWithSelector(
            FAssetRedeemComposer.setDefaultComposerFee.selector,
            2000
        );

        vm.prank(owner);
        vm.expectRevert(IOwnableWithTimelock.TimelockInvalidSelector.selector);
        composer.cancelTimelockedCall(encodedCall);
    }

    // --- OwnableWithTimelock: getExecuteTimelockedCallTimestamp ---

    function testGetExecuteTimelockedCallTimestampRevertInvalidSelector() public {
        bytes memory encodedCall = abi.encodeWithSelector(
            FAssetRedeemComposer.setDefaultComposerFee.selector,
            2000
        );

        vm.expectRevert(IOwnableWithTimelock.TimelockInvalidSelector.selector);
        composer.getExecuteTimelockedCallTimestamp(encodedCall);
    }

    // --- OwnableWithTimelock: executeTimelockedCall ---

    function testExecuteTimelockedCallRevertInvalidSelector() public {
        bytes memory encodedCall = abi.encodeWithSelector(
            FAssetRedeemComposer.setDefaultComposerFee.selector,
            2000
        );

        vm.expectRevert(IOwnableWithTimelock.TimelockInvalidSelector.selector);
        composer.executeTimelockedCall(encodedCall);
    }

    function testExecuteTimelockedCallRevertNotAllowedYet() public {
        vm.prank(owner);
        composer.setTimelockDuration(1 hours);

        bytes memory encodedCall = abi.encodeWithSelector(
            FAssetRedeemComposer.setDefaultComposerFee.selector,
            2000
        );

        vm.prank(owner);
        composer.setDefaultComposerFee(2000);

        vm.expectRevert(IOwnableWithTimelock.TimelockNotAllowedYet.selector);
        composer.executeTimelockedCall(encodedCall);
    }

    function testExecuteTimelockedCallSucceedsAfterDelay() public {
        vm.prank(owner);
        composer.setTimelockDuration(1 hours);

        bytes memory encodedCall = abi.encodeWithSelector(
            FAssetRedeemComposer.setDefaultComposerFee.selector,
            2000
        );

        vm.prank(owner);
        composer.setDefaultComposerFee(2000);

        skip(1 hours);

        vm.expectEmit();
        emit IFAssetRedeemComposer.DefaultComposerFeeSet(2000);
        vm.expectEmit();
        emit IOwnableWithTimelock.TimelockedCallExecuted(keccak256(encodedCall));
        composer.executeTimelockedCall(encodedCall);

        assertEq(composer.defaultComposerFeePPM(), 2000);

        vm.expectRevert(IOwnableWithTimelock.TimelockInvalidSelector.selector);
        composer.getExecuteTimelockedCallTimestamp(encodedCall);
    }

    function testExecuteTimelockedCallBubblesInnerRevert() public {
        vm.prank(owner);
        composer.setTimelockDuration(1 hours);

        uint256 invalidFee = 1_000_000;
        bytes memory encodedCall = abi.encodeWithSelector(
            FAssetRedeemComposer.setDefaultComposerFee.selector,
            invalidFee
        );

        vm.prank(owner);
        composer.setDefaultComposerFee(invalidFee);

        skip(1 hours);

        vm.expectRevert(IFAssetRedeemComposer.InvalidComposerFeePPM.selector);
        composer.executeTimelockedCall(encodedCall);
    }

    // --- lzCompose wraps native on failure ---

    function testLzComposeFailedWrapsNativeToRedeemerAccount() public {
        address redeemer = makeAddr("redeemer");
        string memory redeemerUnderlying = "rExample";
        uint32 srcEid = 1;
        uint256 amountLD = 1000;
        uint256 fee = amountLD * defaultComposerFeePPM / 1_000_000;
        uint256 amountToRedeem = amountLD - fee;
        uint256 nativeValue = 0.5 ether;

        (bytes memory message, bytes32 guid) = _encodeMessageFull(
            redeemer, redeemerUnderlying, false, 0, payable(address(0)), nativeValue, srcEid, amountLD
        );

        address redeemerAccount = composer.getRedeemerAccountAddress(redeemer);

        _mockSafeTransfer(fAsset, composerFeeRecipient, fee);
        _mockSafeTransfer(fAsset, redeemerAccount, amountToRedeem);
        _mockForceApprove(fAsset, true);
        _mockForceApprove(stableCoin, true);
        _mockForceApprove(wNat, true);

        // Make AssetManager.redeem revert
        vm.mockCallRevert(
            assetManager,
            abi.encodeWithSelector(IRedeemExtended.redeemAmount.selector),
            "Redeem failed"
        );

        // Mock wNat.depositTo to accept the executor fee on failure
        vm.mockCall(
            wNat,
            nativeValue,
            abi.encodeWithSignature("depositTo(address)", redeemerAccount),
            ""
        );

        vm.deal(endpoint, nativeValue);
        vm.prank(endpoint);
        vm.expectEmit();
        emit IFAssetRedeemComposer.FAssetRedeemFailed(
            guid,
            srcEid,
            redeemer,
            redeemerAccount,
            amountToRedeem,
            nativeValue
        );

        composer.lzCompose{value: nativeValue}(
            trustedSourceOApp,
            guid,
            message,
            address(0),
            ""
        );
    }

    function testLzComposeFailedNoNativeNoWrap() public {
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
        _mockForceApprove(fAsset, true);
        _mockForceApprove(stableCoin, true);
        _mockForceApprove(wNat, true);

        // Make AssetManager.redeem revert
        vm.mockCallRevert(
            assetManager,
            abi.encodeWithSelector(IRedeemExtended.redeemAmount.selector),
            "Redeem failed"
        );

        // No native value sent — depositTo should NOT be called
        vm.prank(endpoint);
        vm.expectEmit();
        emit IFAssetRedeemComposer.FAssetRedeemFailed(
            guid,
            srcEid,
            redeemer,
            redeemerAccount,
            amountToRedeem,
            0
        );

        composer.lzCompose(
            trustedSourceOApp,
            guid,
            message,
            address(0),
            ""
        );
    }

    // --- lzCompose executor fee validation ---

    function testLzComposeRevertInsufficientExecutorFee() public {
        address redeemer = makeAddr("redeemer");
        string memory redeemerUnderlying = "rExample";
        uint32 srcEid = 1;
        uint256 amountLD = 1000;
        uint256 executorFee = 0.5 ether;

        (bytes memory message, bytes32 guid) = _encodeMessageFull(
            redeemer, redeemerUnderlying, false, 0, payable(address(0)), executorFee, srcEid, amountLD
        );

        // Send less than executorFee
        uint256 insufficientValue = 0.1 ether;
        vm.deal(endpoint, insufficientValue);
        vm.prank(endpoint);
        vm.expectRevert(
            abi.encodeWithSelector(
                IFAssetRedeemComposer.InsufficientExecutorFee.selector,
                insufficientValue,
                executorFee
            )
        );
        composer.lzCompose{value: insufficientValue}(
            trustedSourceOApp,
            guid,
            message,
            address(0),
            ""
        );
    }

    function testLzComposeSuccessExcessNativeWrapped() public {
        address redeemer = makeAddr("redeemer");
        string memory redeemerUnderlying = "rExample";
        uint32 srcEid = 1;
        uint256 amountLD = 1000;
        uint256 composerFee = amountLD * defaultComposerFeePPM / 1_000_000;
        uint256 amountToRedeem = amountLD - composerFee;
        uint256 executorFee = 0.1 ether;
        uint256 nativeValue = 0.5 ether;
        uint256 excess = nativeValue - executorFee;

        (bytes memory message, bytes32 guid) = _encodeMessageFull(
            redeemer, redeemerUnderlying, false, 0, payable(address(0)), executorFee, srcEid, amountLD
        );

        address redeemerAccount = composer.getRedeemerAccountAddress(redeemer);

        _mockSafeTransfer(fAsset, composerFeeRecipient, composerFee);
        _mockSafeTransfer(fAsset, redeemerAccount, amountToRedeem);
        _mockForceApprove(fAsset, true);
        _mockForceApprove(stableCoin, true);
        _mockForceApprove(wNat, true);

        vm.mockCall(
            assetManager,
            abi.encodeWithSelector(IRedeemExtended.redeemAmount.selector),
            abi.encode(amountToRedeem)
        );

        // Mock wNat.depositTo for the excess amount
        vm.mockCall(
            wNat,
            excess,
            abi.encodeWithSignature("depositTo(address)", redeemerAccount),
            ""
        );

        vm.deal(endpoint, nativeValue);
        vm.prank(endpoint);

        vm.expectEmit();
        emit IFAssetRedeemComposer.FAssetRedeemed(
            guid,
            srcEid,
            redeemer,
            redeemerAccount,
            amountToRedeem,
            redeemerUnderlying,
            false,
            0,
            defaultExecutor,
            executorFee,
            amountToRedeem,
            excess // wrappedAmount
        );

        composer.lzCompose{value: nativeValue}(
            trustedSourceOApp,
            guid,
            message,
            address(0),
            ""
        );
    }

    function testLzComposeFailedExcessAndExecutorFeeWrapped() public {
        address redeemer = makeAddr("redeemer");
        string memory redeemerUnderlying = "rExample";
        uint32 srcEid = 1;
        uint256 amountLD = 1000;
        uint256 fee = amountLD * defaultComposerFeePPM / 1_000_000;
        uint256 amountToRedeem = amountLD - fee;
        uint256 executorFee = 0.2 ether;
        uint256 nativeValue = 0.5 ether;

        (bytes memory message, bytes32 guid) = _encodeMessageFull(
            redeemer, redeemerUnderlying, false, 0, payable(address(0)), executorFee, srcEid, amountLD
        );

        address redeemerAccount = composer.getRedeemerAccountAddress(redeemer);

        _mockSafeTransfer(fAsset, composerFeeRecipient, fee);
        _mockSafeTransfer(fAsset, redeemerAccount, amountToRedeem);
        _mockForceApprove(fAsset, true);
        _mockForceApprove(stableCoin, true);
        _mockForceApprove(wNat, true);

        vm.mockCallRevert(
            assetManager,
            abi.encodeWithSelector(IRedeemExtended.redeemAmount.selector),
            "Redeem failed"
        );

        // Mock wNat.depositTo for full msg.value wrapping (single call in catch)
        vm.mockCall(
            wNat,
            nativeValue,
            abi.encodeWithSignature("depositTo(address)", redeemerAccount),
            ""
        );

        vm.deal(endpoint, nativeValue);
        vm.prank(endpoint);

        vm.expectEmit();
        emit IFAssetRedeemComposer.FAssetRedeemFailed(
            guid,
            srcEid,
            redeemer,
            redeemerAccount,
            amountToRedeem,
            nativeValue // wrappedAmount is full msg.value on failure
        );

        composer.lzCompose{value: nativeValue}(
            trustedSourceOApp,
            guid,
            message,
            address(0),
            ""
        );
    }

    function testLzComposeSuccessZeroExecutorFeeNoExcessWrap() public {
        address redeemer = makeAddr("redeemer");
        string memory redeemerUnderlying = "rExample";
        uint32 srcEid = 1;
        uint256 amountLD = 1000;
        uint256 composerFee = amountLD * defaultComposerFeePPM / 1_000_000;
        uint256 amountToRedeem = amountLD - composerFee;

        // executorFee = 0, msg.value = 0 — no wrapping should occur
        (bytes memory message, bytes32 guid) = _encodeMessage(redeemer, redeemerUnderlying, srcEid, amountLD);

        address redeemerAccount = composer.getRedeemerAccountAddress(redeemer);

        _mockSafeTransfer(fAsset, composerFeeRecipient, composerFee);
        _mockSafeTransfer(fAsset, redeemerAccount, amountToRedeem);
        _mockForceApprove(fAsset, true);
        _mockForceApprove(stableCoin, true);
        _mockForceApprove(wNat, true);

        vm.mockCall(
            assetManager,
            abi.encodeWithSelector(IRedeemExtended.redeemAmount.selector),
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
            false,
            0,
            defaultExecutor,
            0,
            amountToRedeem,
            0 // wrappedAmount
        );

        composer.lzCompose(
            trustedSourceOApp,
            guid,
            message,
            address(0),
            ""
        );
    }

    // --- isRedeemerAccount ---

    function testIsRedeemerAccount() public {
        // First create a redeemer account via lzCompose
        address redeemer = makeAddr("redeemer");
        string memory redeemerUnderlying = "rExample";
        uint32 srcEid = 1;
        uint256 amountLD = 1000;
        uint256 fee = amountLD * defaultComposerFeePPM / 1_000_000;
        uint256 amountToRedeem = amountLD - fee;

        (bytes memory message, ) = _encodeMessage(redeemer, redeemerUnderlying, srcEid, amountLD);

        address redeemerAccount = composer.getRedeemerAccountAddress(redeemer);

        _mockSafeTransfer(fAsset, composerFeeRecipient, fee);
        _mockSafeTransfer(fAsset, redeemerAccount, amountToRedeem);
        _mockForceApprove(fAsset, true);
        _mockForceApprove(stableCoin, true);
        _mockForceApprove(wNat, true);
        vm.mockCall(
            assetManager,
            abi.encodeWithSelector(IRedeemExtended.redeemAmount.selector),
            abi.encode(amountToRedeem)
        );

        vm.prank(endpoint);
        composer.lzCompose(trustedSourceOApp, keccak256("guid"), message, address(0), "");

        // Now check isRedeemerAccount
        (bool isAccount, address accountOwner) = composer.isRedeemerAccount(redeemerAccount);
        assertTrue(isAccount);
        assertEq(accountOwner, redeemer);
    }

    function testIsRedeemerAccountFalseForEOA() public {
        (bool isAccount, address accountOwner) = composer.isRedeemerAccount(makeAddr("random"));
        assertFalse(isAccount);
        assertEq(accountOwner, address(0));
    }

    function testIsRedeemerAccountFalseForUnrelatedContract() public {
        (bool isAccount, address accountOwner) = composer.isRedeemerAccount(address(composerImpl));
        assertFalse(isAccount);
        assertEq(accountOwner, address(0));
    }

    // --- getBalances ---

    function testGetBalances() public {
        address account = makeAddr("account");
        uint256 fAssetBal = 100;
        uint256 stableCoinBal = 200;
        uint256 wNatBal = 300;

        vm.mockCall(
            fAsset,
            abi.encodeWithSelector(IERC20.balanceOf.selector, account),
            abi.encode(fAssetBal)
        );
        vm.mockCall(
            stableCoin,
            abi.encodeWithSelector(IERC20.balanceOf.selector, account),
            abi.encode(stableCoinBal)
        );
        vm.mockCall(
            wNat,
            abi.encodeWithSelector(IERC20.balanceOf.selector, account),
            abi.encode(wNatBal)
        );

        IFAssetRedeemComposer.AccountBalances memory balances = composer.getBalances(account);

        assertEq(balances.fAsset.token, fAsset);
        assertEq(balances.fAsset.balance, fAssetBal);
        assertEq(balances.stableCoin.token, stableCoin);
        assertEq(balances.stableCoin.balance, stableCoinBal);
        assertEq(balances.wNat.token, wNat);
        assertEq(balances.wNat.balance, wNatBal);
    }

    function testGetBalancesZero() public {
        address account = makeAddr("account");

        vm.mockCall(
            fAsset,
            abi.encodeWithSelector(IERC20.balanceOf.selector, account),
            abi.encode(uint256(0))
        );
        vm.mockCall(
            stableCoin,
            abi.encodeWithSelector(IERC20.balanceOf.selector, account),
            abi.encode(uint256(0))
        );
        vm.mockCall(
            wNat,
            abi.encodeWithSelector(IERC20.balanceOf.selector, account),
            abi.encode(uint256(0))
        );

        IFAssetRedeemComposer.AccountBalances memory balances = composer.getBalances(account);

        assertEq(balances.fAsset.balance, 0);
        assertEq(balances.stableCoin.balance, 0);
        assertEq(balances.wNat.balance, 0);
    }

    // --- Helpers ---

    function _mockAssetManagerFAsset() private {
        vm.mockCall(
            assetManager,
            abi.encodeWithSelector(IAssetManager.fAsset.selector),
            abi.encode(fAsset)
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
        return _encodeMessageFull(
            _redeemer, _redeemerUnderlying, false, 0, payable(address(0)), 0, _srcEid, _amountLD
        );
    }

    function _encodeMessageFull(
        address _redeemer,
        string memory _redeemerUnderlying,
        bool _redeemWithTag,
        uint256 _destinationTag,
        address payable _executor,
        uint256 _executorFee,
        uint32 _srcEid,
        uint256 _amountLD
    ) private pure returns (bytes memory, bytes32) {
        IFAssetRedeemComposer.RedeemComposeMessage memory redeemMsg = IFAssetRedeemComposer.RedeemComposeMessage({
            redeemer: _redeemer,
            redeemerUnderlyingAddress: _redeemerUnderlying,
            redeemWithTag: _redeemWithTag,
            destinationTag: _destinationTag,
            executor: _executor,
            executorFee: _executorFee
        });
        bytes memory composeMsg = abi.encode(redeemMsg);
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
