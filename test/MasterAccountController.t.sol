// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import {Test,console2} from "forge-std/Test.sol";
import {MasterAccountController} from "../contracts/smartAccounts/implementation/MasterAccountController.sol";
import {IMasterAccountController} from "../contracts/userInterfaces/IMasterAccountController.sol";
import {IIMasterAccountController} from "../contracts/smartAccounts/interface/IIMasterAccountController.sol";
import {IPayment} from "flare-periphery/src/flare/IPayment.sol";
import {IGovernanceSettings} from "flare-periphery/src/flare/IGovernanceSettings.sol";
import {IPaymentVerification} from "flare-periphery/src/flare/IPaymentVerification.sol";
import {IFlareContractRegistry} from "flare-periphery/src/flare/IFlareContractRegistry.sol";
import {IAssetManager} from "flare-periphery/src/flare/IAssetManager.sol";
import {AgentInfo} from "flare-periphery/src/flare/data/AvailableAgentInfo.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {PersonalAccount} from "../contracts/smartAccounts/implementation/PersonalAccount.sol";
import {IPersonalAccount} from "../contracts/userInterfaces/IPersonalAccount.sol";
import {PersonalAccountProxy} from "../contracts/smartAccounts/proxy/PersonalAccountProxy.sol";
import {MintableERC20} from "../contracts/mock/MintableERC20.sol";
import {MyERC4626, IERC20} from "../contracts/mock/MyERC4626.sol";
import {MockSingletonFactory} from "../contracts/mock/MockSingletonFactory.sol";
import {MockSingletonFactoryNoDeploy} from "../contracts/mock/MockSingletonFactoryNoDeploy.sol";
import {IISingletonFactory} from "../contracts/smartAccounts/interface/IISingletonFactory.sol";
import {CollateralReservationInfo} from "flare-periphery/src/flare/data/CollateralReservationInfo.sol";
import {DateUtils} from "../contracts/mock/DateUtils.sol";
import {IDiamond} from "../contracts/diamond/interfaces/IDiamond.sol";
import {FacetsDeploy} from "./utils/FacetsDeploy.t.sol";
import {DiamondArgs} from "../contracts/diamond/implementation/Diamond.sol";
import {NotContractOwner} from "../contracts/diamond/libraries/LibDiamond.sol";
import {MasterAccountControllerInit} from "../contracts/smartAccounts/facets/MasterAccountControllerInit.sol";
import {IInstructionsFacet} from "../contracts/userInterfaces/facets/IInstructionsFacet.sol";
import {IAgentVaultsFacet} from "../contracts/userInterfaces/facets/IAgentVaultsFacet.sol";
import {IPaymentProofsFacet} from "../contracts/userInterfaces/facets/IPaymentProofsFacet.sol";
import {IExecutorsFacet} from "../contracts/userInterfaces/facets/IExecutorsFacet.sol";
import {IInstructionFeesFacet} from "../contracts/userInterfaces/facets/IInstructionFeesFacet.sol";
import {IXrplProviderWalletsFacet} from "../contracts/userInterfaces/facets/IXrplProviderWalletsFacet.sol";
import {IAgentVaultsFacet} from "../contracts/userInterfaces/facets/IAgentVaultsFacet.sol";
import {IVaultsFacet} from "../contracts/userInterfaces/facets/IVaultsFacet.sol";
import {IPersonalAccountsFacet} from "../contracts/userInterfaces/facets/IPersonalAccountsFacet.sol";
import {ISwapFacet} from "../contracts/userInterfaces/facets/ISwapFacet.sol";

// solhint-disable-next-line max-states-count
contract MasterAccountControllerTest is Test, FacetsDeploy {
    address private constant SINGLETON_FACTORY = 0xce0042B868300000d44A59004Da54A005ffdcf9f;

    IIMasterAccountController private masterAccountController;
    PersonalAccount private personalAccountImpl;
    PersonalAccountProxy private personalAccountProxy;
    IPersonalAccount private personalAccount1;
    IPersonalAccount private personalAccount2;

    MockSingletonFactory private mockFactory;

    address private governance;
    address private initialOwner;
    address private executor;
    uint256 private executorFee;
    MyERC4626 private depositVault;
    MintableERC20 private fxrp;
    string private xrplProviderWallet;
    bytes32 private xrplProviderWalletHash;
    uint256 private paymentProofValidityDurationSeconds;
    uint256 private defaultInstructionFee;
    address private uniswapV3Router;
    address private usdt0;
    uint24 private wNatUsdt0PoolFeeTierPPM;
    uint24 private usdt0FXrpPoolFeeTierPPM;
    uint24 private maxSlippagePPM;
    address private personalAccountImplementation;
    string private xrplAddress1;
    string private xrplAddress2;
    address private assetManagerFxrpMock;
    address private agent;
    AgentInfo.Info private agentInfo;

    address private contractRegistryMock;
    address private fdcVerificationMock;
    address private wNatMock;

    function setUp() public {
        mockFactory = new MockSingletonFactory();
        vm.etch(SINGLETON_FACTORY, address(mockFactory).code);

        governance = makeAddr("governance");
        initialOwner = makeAddr("initialOwner");
        executor = makeAddr("executor");
        fxrp = new MintableERC20("F-XRPL", "fXRP");
        depositVault = new MyERC4626(
            IERC20(address(fxrp)),
            "Deposit Vault",
            "DV"
        );
        depositVault.setLagDuration(1 days);
        xrplProviderWallet = "rXrplProviderWallet";
        xrplProviderWalletHash = keccak256(bytes(xrplProviderWallet));
        contractRegistryMock = 0xaD67FE66660Fb8dFE9d6b1b4240d8650e30F6019;
        fdcVerificationMock = makeAddr("FDCVerificationMock");
        wNatMock = makeAddr("W-NAT");
        executorFee = 100;
        paymentProofValidityDurationSeconds = 1 days;
        defaultInstructionFee = 1000000; // 1 XRP
        uniswapV3Router = makeAddr("UniswapV3Router");
        wNatUsdt0PoolFeeTierPPM = 3000; // 0.3%
        usdt0 = makeAddr("USDT0");
        usdt0FXrpPoolFeeTierPPM = 500; // 0.05%
        maxSlippagePPM = 20000; // 2%
        assetManagerFxrpMock = makeAddr("AssetManagerFXRP");
        agent = makeAddr("agent");
        agentInfo.status = AgentInfo.Status.NORMAL;

        // deploy the personal account implementation
        personalAccountImpl = new PersonalAccount();
        personalAccountImplementation = address(personalAccountImpl);

        // deploy facets
        IDiamond.FacetCut[] memory baseCuts = deployBaseFacets();
        DiamondArgs memory args = DiamondArgs({
            owner: initialOwner,
            initAddress: address(0),
            initCalldata: ""
        });
        bytes memory bytecode = abi.encodePacked(
        type(MasterAccountController).creationCode,
            abi.encode(baseCuts, args)
        );
        bytes32 salt = bytes32(0);
        address deployed = IISingletonFactory(SINGLETON_FACTORY).deploy(bytecode, salt);
        masterAccountController = IIMasterAccountController(deployed);

        IDiamond.FacetCut[] memory smartAccountsCuts = deploySmartAccountsFacets();
        MasterAccountControllerInit masterAccountControllerInit = new MasterAccountControllerInit();
        vm.prank(initialOwner);
        masterAccountController.diamondCut(
            smartAccountsCuts,
            address(masterAccountControllerInit),
            abi.encodeWithSelector(
                MasterAccountControllerInit.init.selector,
                payable(executor),
                executorFee,
                paymentProofValidityDurationSeconds,
                defaultInstructionFee,
                personalAccountImplementation
            )
        );

        // set swap parameters
        vm.prank(initialOwner);
        masterAccountController.setSwapParams(
            uniswapV3Router,
            usdt0,
            wNatUsdt0PoolFeeTierPPM,
            usdt0FXrpPoolFeeTierPPM,
            maxSlippagePPM
        );

        // transfer ownership to governance
        vm.prank(initialOwner);
        masterAccountController.transferOwnership(governance);

        _mockGetContractAddressByHash("FdcVerification", fdcVerificationMock);
        _mockGetContractAddressByHash("AssetManagerFXRP", assetManagerFxrpMock);
        _mockGetAgentInfo(agent, agentInfo);
        _mockGetFAsset();

        // add xrpl provider wallets
        string[] memory xrplProviderWallets = new string[](1);
        xrplProviderWallets[0] = xrplProviderWallet;
        vm.prank(governance);
        masterAccountController.addXrplProviderWallets(xrplProviderWallets);

        // add agent vault
        uint256[] memory agentVaultIds = new uint256[](1);
        address[] memory agentVaultAddresses = new address[](1);
        agentVaultIds[0] = 0;
        agentVaultAddresses[0] = agent;
        vm.prank(governance);
        masterAccountController.addAgentVaults(
            agentVaultIds,
            agentVaultAddresses
        );
        // add vaults
        uint256[] memory vaultIds = new uint256[](2);
        address[] memory vaultAddresses = new address[](2);
        uint8[] memory vaultTypes = new uint8[](2);
        vaultIds[0] = 0;
        vaultIds[1] = 3;
        vaultAddresses[0] = address(depositVault);
        vaultAddresses[1] = address(depositVault);
        vaultTypes[0] = 1;
        vaultTypes[1] = 2;
        vm.prank(governance);
        masterAccountController.addVaults(vaultIds, vaultAddresses, vaultTypes);

        xrplAddress1 = "xrplAddress1";
        xrplAddress2 = "xrplAddress2";
    }

    function testUpgrades() public {
        IPayment.Proof memory proof;
        proof.data.responseBody.receivingAddressHash = xrplProviderWalletHash;
        proof.data.responseBody.sourceAddressHash = keccak256(bytes(xrplAddress1));
        proof.data.requestBody.transactionId = bytes32("tx1");
        proof.data.responseBody.receivedAmount = 1000000;
        proof.data.responseBody.standardPaymentReference = _encodeFirelightPaymentReference(1, 0, 12345, 0, 0);
        _mockVerifyPayment(true);

        address predictedAddress1 = masterAccountController.getPersonalAccount(xrplAddress1);
        assertEq(
            predictedAddress1.code.length,
            0
        );
        fxrp.mint(predictedAddress1, 12345);

        vm.expectEmit();
        emit IPersonalAccount.Approved(
            address(fxrp),
            address(depositVault),
            12345
        );
        masterAccountController.executeInstruction(proof, xrplAddress1);

        // check that the personal account was created at the expected address
        assertNotEq(
            predictedAddress1.code.length,
            0
        );
        assertEq(
            masterAccountController.getPersonalAccount(xrplAddress1),
            predictedAddress1
        );
        personalAccount1 = IPersonalAccount(predictedAddress1);
        assertEq(
            personalAccount1.implementation(),
            address(personalAccountImpl)
        );
        assertEq(
            personalAccount1.xrplOwner(),
            xrplAddress1
        );
        assertEq(
            personalAccount1.controllerAddress(),
            address(masterAccountController)
        );

        // TODO change facet?
        // change implementation of MasterAccountController
        // assertEq(
        //     masterAccountController.controllerImplementation(),
        //     address(masterAccountControllerImpl)
        // );
        // MasterAccountController newMasterAccountControllerImpl = new MasterAccountController();
        // vm.prank(governance);
        // masterAccountController.upgradeToAndCall(
        //     address(newMasterAccountControllerImpl),
        //     bytes("")
        // );
        // assertEq(
        //     masterAccountController.controllerImplementation(),
        //     address(newMasterAccountControllerImpl)
        // );
        // assertEq(
        //     masterAccountController.getPersonalAccount(xrplAddress1),
        //     address(personalAccount1)
        // );
        // assertEq(
        //     personalAccount1.controllerAddress(),
        //     address(masterAccountController)
        // );

        // deploy a new PersonalAccount implementation
        PersonalAccount newPersonalAccountImpl = new PersonalAccount();

        // compute address of personal account for xrplAddress2 before implementation change
        address predictedAddress2 = masterAccountController.getPersonalAccount(xrplAddress2);

        // update PersonalAccount implementation on MasterAccountController
        vm.prank(governance);
        masterAccountController.setPersonalAccountImplementation(address(newPersonalAccountImpl));
        assertEq(
            masterAccountController.implementation(),
            address(newPersonalAccountImpl)
        );
        assertEq(
            masterAccountController.implementation(), // beacon implementation
            address(newPersonalAccountImpl)
        );
        assertEq(
            masterAccountController.getPersonalAccount(xrplAddress1),
            address(personalAccount1)
        );
        assertEq(
            personalAccount1.implementation(),
            address(newPersonalAccountImpl)
        );
        assertEq(
            personalAccount1.xrplOwner(),
            xrplAddress1
        );
        assertEq(
            personalAccount1.controllerAddress(),
            address(masterAccountController)
        );

        // execute transaction for xrplAddress2; new personal account should be created with new implementation
        // and at the expected address
        assertEq(
            predictedAddress2.code.length,
            0
        );
        proof.data.requestBody.transactionId = bytes32("tx2");
        proof.data.responseBody.sourceAddressHash = keccak256(bytes(xrplAddress2));
        fxrp.mint(predictedAddress2, 12345);
        masterAccountController.executeInstruction(proof, xrplAddress2);
        personalAccount2 = IPersonalAccount(masterAccountController.getPersonalAccount(xrplAddress2));
        // check that the personal account was created at the expected address
        assertEq(
            address(personalAccount2),
            predictedAddress2
        );
        assertNotEq(
            predictedAddress2.code.length,
            0
        );
        // check implementation of the new personal account
        assertEq(
            personalAccount2.implementation(),
            address(newPersonalAccountImpl)
        );
        assertEq(
            personalAccount2.xrplOwner(),
            xrplAddress2
        );
        assertEq(
            personalAccount2.controllerAddress(),
            address(masterAccountController)
        );
    }

    // reserveCollateral tests
    function testReserveCollateralRevertInvalidInstruction() public {
        bytes32 paymentReference = _encodeFxrpPaymentReference(9, 0, 1000, 0);
        bytes32 transactionId = bytes32("tx1");
        vm.expectRevert(
            abi.encodeWithSelector(
                IInstructionsFacet.InvalidInstruction.selector,
                0,
                9
            )
        );
        masterAccountController.reserveCollateral(
            xrplAddress1,
            paymentReference,
            transactionId
        );
    }

    function testReserveCollateralRevertInvalidTransactionId() public {
        bytes32 paymentReference = _encodeFxrpPaymentReference(0, 0, 1000, 0);
        bytes32 transactionId = bytes32(0);
        vm.expectRevert(IInstructionsFacet.InvalidTransactionId.selector);
        masterAccountController.reserveCollateral(
            xrplAddress1,
            paymentReference,
            transactionId
        );
    }

    function testReserveCollateralRevertInvalidAgentVault() public {
        bytes32 paymentReference = _encodeFxrpPaymentReference(0, 0, 1000, 1); // agent vault 1 does not exist
        bytes32 transactionId = bytes32("tx1");
        vm.expectRevert(
            abi.encodeWithSelector(
                IAgentVaultsFacet.InvalidAgentVault.selector,
                1
            )
        );
        masterAccountController.reserveCollateral(
            xrplAddress1,
            paymentReference,
            transactionId
        );
    }

    function testReserveCollateralRevertValueZero() public {
        bytes32 paymentReference = _encodeFxrpPaymentReference(0, 0, 0, 0); // value 0
        bytes32 transactionId = bytes32("tx1");
        vm.expectRevert(IInstructionsFacet.ValueZero.selector);
        masterAccountController.reserveCollateral(
            xrplAddress1,
            paymentReference,
            transactionId
        );
    }

    function testReserveCollateral() public {
        uint16 lots = 2;
        bytes32 paymentReference = _encodeFxrpPaymentReference(0, 0, lots, 0);
        bytes32 transactionId = bytes32("tx1");

        _mockCollateralReservationFee(lots, 123);
        _mockReserveCollateral(22);

        address predictedAddress1 = masterAccountController.getPersonalAccount(xrplAddress1);
        assertEq(predictedAddress1.code.length, 0);

        vm.expectEmit();
        emit IInstructionsFacet.CollateralReserved(
            predictedAddress1,
            transactionId,
            paymentReference,
            xrplAddress1,
            22,
            agent,
            lots,
            executor,
            executorFee
        );
        uint256 collateralReservationId = masterAccountController.reserveCollateral{value: 123 + executorFee}(
            xrplAddress1,
            paymentReference,
            transactionId
        );
        assertEq(collateralReservationId, 22);

        // check that the personal account was created at the expected address
        assertNotEq(
            predictedAddress1.code.length,
            0
        );
        assertEq(
            masterAccountController.getPersonalAccount(xrplAddress1),
            predictedAddress1
        );

        assertEq(
            masterAccountController.getTransactionIdForCollateralReservation(collateralReservationId),
            transactionId
        );
    }

    function testExecuteDepositAfterMintingRevertInvalidInstruction() public {
        bytes32 paymentReference = _encodeFxrpPaymentReference(9, 0, 1000, 0);
        IPayment.Proof memory proof;
        proof.data.responseBody.standardPaymentReference = paymentReference;

        vm.expectRevert(
            abi.encodeWithSelector(
                IInstructionsFacet.InvalidInstruction.selector,
                0,
                9
            )
        );
        masterAccountController.executeDepositAfterMinting(0, proof, xrplAddress1);
    }

    function testExecuteDepositAfterMintingRevertUnknownCollateralReservationId() public {
        bytes32 paymentReference = _encodeFirelightPaymentReference(0, 0, 1000, 0, 0);
        IPayment.Proof memory proof;
        proof.data.responseBody.standardPaymentReference = paymentReference;

        vm.expectRevert(
            abi.encodeWithSelector(
                IInstructionsFacet.UnknownCollateralReservationId.selector,
                0
            )
        );
        masterAccountController.executeDepositAfterMinting(1, proof, xrplAddress1);
    }

    function testExecuteDepositAfterMintingRevertMintingNotCompleted() public {
        bytes32 paymentReference = _encodeFirelightPaymentReference(0, 0, 2, 0, 0);
        address predictedAddress1 = masterAccountController.getPersonalAccount(xrplAddress1);
        _mockCollateralReservationInfo(CollateralReservationInfo.Status.ACTIVE, predictedAddress1, 0);
        bytes32 transactionId = bytes32("tx1");
        testReserveCollateral();
        IPayment.Proof memory proof;
        proof.data.responseBody.standardPaymentReference = paymentReference;
        proof.data.requestBody.transactionId = transactionId;

        vm.expectRevert(IInstructionsFacet.MintingNotCompleted.selector);
        masterAccountController.executeDepositAfterMinting(22, proof, xrplAddress1);
    }

    function testExecuteDepositAfterMintingRevertInvalidMinter() public {
        bytes32 paymentReference = _encodeFirelightPaymentReference(0, 0, 2, 0, 0);
        _mockCollateralReservationInfo(CollateralReservationInfo.Status.SUCCESSFUL, makeAddr("wrongMinter"), 0);
        bytes32 transactionId = bytes32("tx1");
        testReserveCollateral();
        IPayment.Proof memory proof;
        proof.data.responseBody.standardPaymentReference = paymentReference;
        proof.data.requestBody.transactionId = transactionId;
        proof.data.responseBody.sourceAddressHash = keccak256(bytes(xrplAddress1));
        proof.data.responseBody.receivingAddressHash = xrplProviderWalletHash;
        proof.data.requestBody.transactionId = transactionId;
        _mockVerifyPayment(true);
        vm.expectRevert(IInstructionsFacet.InvalidMinter.selector);
        masterAccountController.executeDepositAfterMinting(22, proof, xrplAddress1);
    }

    function testExecuteDepositAfterMintingRevertInvalidAmount() public {
        bytes32 paymentReference = _encodeFirelightPaymentReference(0, 0, 2, 0, 0);
        address predictedAddress1 = masterAccountController.getPersonalAccount(xrplAddress1);
        _mockCollateralReservationInfo(CollateralReservationInfo.Status.SUCCESSFUL, predictedAddress1, 0);
        bytes32 transactionId = bytes32("tx1");
        testReserveCollateral();
        IPayment.Proof memory proof;
        proof.data.responseBody.standardPaymentReference = paymentReference;
        proof.data.requestBody.transactionId = transactionId;
        proof.data.responseBody.sourceAddressHash = keccak256(bytes(xrplAddress1));
        proof.data.responseBody.receivingAddressHash = xrplProviderWalletHash;
        proof.data.requestBody.transactionId = transactionId;
        _mockVerifyPayment(true);
        _mockLotSize(100);
        vm.expectRevert(IInstructionsFacet.InvalidAmount.selector);
        masterAccountController.executeDepositAfterMinting(22, proof, xrplAddress1);
    }

    function testExecuteDepositAfterMinting() public {
        uint16 lots = 2;
        uint256 lotSize = 100;
        bytes32 paymentReference = _encodeFirelightPaymentReference(0, 0, lots, 0, 0);
        address predictedAddress1 = masterAccountController.getPersonalAccount(xrplAddress1);
        _mockCollateralReservationInfo(
            CollateralReservationInfo.Status.SUCCESSFUL,
            predictedAddress1,
            lots * lotSize
        );
        bytes32 transactionId = bytes32("tx1");
        testReserveCollateral();
        IPayment.Proof memory proof;
        proof.data.responseBody.standardPaymentReference = paymentReference;
        proof.data.responseBody.sourceAddressHash = keccak256(bytes(xrplAddress1));
        proof.data.responseBody.receivingAddressHash = xrplProviderWalletHash;
        proof.data.requestBody.transactionId = transactionId;
        _mockVerifyPayment(true);
        _mockLotSize(lotSize);

        // mint what will be deposited
        fxrp.mint(predictedAddress1, lots * lotSize);

        vm.expectEmit();
        emit IInstructionsFacet.Deposited(
            predictedAddress1,
            address(depositVault),
            lots * lotSize,
            lots * lotSize // assuming 1:1 initial share:asset for simplicity
        );
        vm.expectEmit();
        emit IInstructionsFacet.InstructionExecuted(
            predictedAddress1,
            paymentReference,
            transactionId,
            xrplAddress1,
            _getInstructionId(1, 0)
        );
        masterAccountController.executeDepositAfterMinting(22, proof, xrplAddress1);
    }

    function testExecuteInstructionRevertInvalidPaymentAmount() public {
        bytes32 paymentReference = _encodeFxrpPaymentReference(0, 0, 2, 0);
        IPayment.Proof memory proof;
        proof.data.responseBody.standardPaymentReference = paymentReference;
        proof.data.responseBody.receivedAmount = -1;

        vm.expectRevert(
            abi.encodeWithSelector(
                IInstructionsFacet.InvalidPaymentAmount.selector,
                defaultInstructionFee
            )
        );
        masterAccountController.executeInstruction(proof, xrplAddress1);

        proof.data.responseBody.receivedAmount = int256(defaultInstructionFee) - 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                IInstructionsFacet.InvalidPaymentAmount.selector,
                defaultInstructionFee
            )
        );
        masterAccountController.executeInstruction(proof, xrplAddress1);
    }

    function testExecuteInstructionRevertInvalidTransactionStatus() public {
        bytes32 paymentReference = _encodeFxrpPaymentReference(0, 0, 2, 0);
        IPayment.Proof memory proof;
        proof.data.responseBody.standardPaymentReference = paymentReference;
        proof.data.responseBody.receivedAmount = int256(2 * defaultInstructionFee);
        proof.data.responseBody.status = 1;

        vm.expectRevert(IPaymentProofsFacet.InvalidTransactionStatus.selector);
        masterAccountController.executeInstruction(proof, xrplAddress1);
    }

    function testExecuteInstructionRevertPaymentProofExpired() public {
        bytes32 paymentReference = _encodeFxrpPaymentReference(0, 0, 2, 0);
        IPayment.Proof memory proof;
        proof.data.responseBody.standardPaymentReference = paymentReference;
        proof.data.responseBody.receivedAmount = int256(2 * defaultInstructionFee);
        proof.data.responseBody.status = 0;
        proof.data.responseBody.blockTimestamp = 1234;
        vm.warp(1234 + paymentProofValidityDurationSeconds + 1);

        vm.expectRevert(IPaymentProofsFacet.PaymentProofExpired.selector);
        masterAccountController.executeInstruction(proof, xrplAddress1);
    }

    function testExecuteInstructionRevertMismatchingSourceAndXrplAddr() public {
        bytes32 paymentReference = _encodeFxrpPaymentReference(0, 0, 2, 0);
        IPayment.Proof memory proof;
        proof.data.responseBody.standardPaymentReference = paymentReference;
        proof.data.responseBody.receivedAmount = int256(2 * defaultInstructionFee);
        proof.data.responseBody.status = 0;
        proof.data.responseBody.blockTimestamp = uint64(block.timestamp);
        proof.data.responseBody.sourceAddressHash = keccak256(bytes("differentXrplAddress"));

        vm.expectRevert(IPaymentProofsFacet.MismatchingSourceAndXrplAddr.selector);
        masterAccountController.executeInstruction(proof, xrplAddress1);
    }

    function testExecuteInstructionInvalidReceivingAddressHash() public {
        bytes32 paymentReference = _encodeFxrpPaymentReference(0, 0, 2, 0);
        IPayment.Proof memory proof;
        proof.data.responseBody.standardPaymentReference = paymentReference;
        proof.data.responseBody.receivedAmount = int256(2 * defaultInstructionFee);
        proof.data.responseBody.status = 0;
        proof.data.responseBody.blockTimestamp = uint64(block.timestamp);
        proof.data.responseBody.sourceAddressHash = keccak256(bytes(xrplAddress1));
        proof.data.responseBody.receivingAddressHash = keccak256(bytes("invalidReceivingAddress"));

        vm.expectRevert(IPaymentProofsFacet.InvalidReceivingAddressHash.selector);
        masterAccountController.executeInstruction(proof, xrplAddress1);
    }

    function testExecuteInstructionRevertTransactionAlreadyExecuted() public {
        bytes32 paymentReference = _encodeFirelightPaymentReference(1, 0, 2, 0, 0);
        IPayment.Proof memory proof;
        proof.data.responseBody.standardPaymentReference = paymentReference;
        proof.data.responseBody.receivedAmount = int256(2 * defaultInstructionFee);
        proof.data.responseBody.status = 0;
        proof.data.responseBody.blockTimestamp = uint64(block.timestamp);
        proof.data.responseBody.sourceAddressHash = keccak256(bytes(xrplAddress1));
        proof.data.responseBody.receivingAddressHash = xrplProviderWalletHash;
        _mockVerifyPayment(true);
        // mint some fXRP to the personal account to cover the deposit
        address predictedAddress1 = masterAccountController.getPersonalAccount(xrplAddress1);
        fxrp.mint(predictedAddress1, 2 * defaultInstructionFee);
        masterAccountController.executeInstruction(proof, xrplAddress1);

        vm.expectRevert(IInstructionsFacet.TransactionAlreadyExecuted.selector);
        masterAccountController.executeInstruction(proof, xrplAddress1);
    }

    function testExecuteInstructionRevertInvalidTransactionProof() public {
        bytes32 paymentReference = _encodeFirelightPaymentReference(1, 0, 2, 0, 0);
        IPayment.Proof memory proof;
        proof.data.responseBody.standardPaymentReference = paymentReference;
        proof.data.responseBody.receivedAmount = int256(2 * defaultInstructionFee);
        proof.data.responseBody.status = 0;
        proof.data.responseBody.blockTimestamp = uint64(block.timestamp);
        proof.data.responseBody.sourceAddressHash = keccak256(bytes(xrplAddress1));
        proof.data.responseBody.receivingAddressHash = xrplProviderWalletHash;
        _mockVerifyPayment(false);

        vm.expectRevert(IPaymentProofsFacet.InvalidTransactionProof.selector);
        masterAccountController.executeInstruction(proof, xrplAddress1);
    }

    function testExecuteInstructionDeposit() public {
        // mint some fXRP to the personal account to cover the deposit
        address personalAccountAddr = masterAccountController.getPersonalAccount(xrplAddress1);
        fxrp.mint(personalAccountAddr, 123);
        assertEq(fxrp.balanceOf(personalAccountAddr), 123);
        bytes32 paymentReference = _encodeFirelightPaymentReference(1, 0, 123, 0, 0);
        IPayment.Proof memory proof;
        proof.data.responseBody.standardPaymentReference = paymentReference;
        proof.data.responseBody.receivedAmount = int256(2 * defaultInstructionFee);
        proof.data.responseBody.status = 0;
        proof.data.responseBody.blockTimestamp = uint64(block.timestamp);
        proof.data.responseBody.sourceAddressHash = keccak256(bytes(xrplAddress1));
        proof.data.responseBody.receivingAddressHash = xrplProviderWalletHash;
        proof.data.requestBody.transactionId = bytes32("tx1");
        _mockVerifyPayment(true);

        vm.expectEmit();
        emit IInstructionsFacet.Deposited(
            personalAccountAddr,
            address(depositVault),
            123,
            123 // assuming 1:1 initial share:asset
        );
        vm.expectEmit();
        emit IInstructionsFacet.InstructionExecuted(
            personalAccountAddr,
            proof.data.requestBody.transactionId,
            paymentReference,
            xrplAddress1,
            _getInstructionId(1, 1)
        );
        masterAccountController.executeInstruction(proof, xrplAddress1);
        // check that fxrp were deposited into the deposit vault
        assertEq(
            depositVault.balanceOf(personalAccountAddr),
            123
        );
        assertEq(
            fxrp.balanceOf(address(depositVault)),
            123
        );
        assertEq(
            fxrp.balanceOf(personalAccountAddr),
            0
        );
    }

    function testExecuteInstructionDeposit2() public {
        // mint some fXRP to the personal account to cover the deposit
        address personalAccountAddr = masterAccountController.getPersonalAccount(xrplAddress1);
        fxrp.mint(personalAccountAddr, 123);
        assertEq(fxrp.balanceOf(personalAccountAddr), 123);
        bytes32 paymentReference = _encodeUpshiftPaymentReference(1, 0, 123, 0, 3);
        IPayment.Proof memory proof;
        proof.data.responseBody.standardPaymentReference = paymentReference;
        proof.data.responseBody.receivedAmount = int256(2 * defaultInstructionFee);
        proof.data.responseBody.status = 0;
        proof.data.responseBody.blockTimestamp = uint64(block.timestamp);
        proof.data.responseBody.sourceAddressHash = keccak256(bytes(xrplAddress1));
        proof.data.responseBody.receivingAddressHash = xrplProviderWalletHash;
        proof.data.requestBody.transactionId = bytes32("tx1");
        _mockVerifyPayment(true);

        vm.expectEmit();
        emit IInstructionsFacet.Deposited(
            personalAccountAddr,
            address(depositVault),
            123,
            123 // assuming 1:1 initial share:asset
        );
        vm.expectEmit();
        emit IInstructionsFacet.InstructionExecuted(
            personalAccountAddr,
            proof.data.requestBody.transactionId,
            paymentReference,
            xrplAddress1,
            _getInstructionId(2, 1)
        );
        masterAccountController.executeInstruction(proof, xrplAddress1);
        // check that fxrp were deposited into the deposit vault
        assertEq(
            depositVault.balanceOf(personalAccountAddr),
            123
        );
        assertEq(
            fxrp.balanceOf(address(depositVault)),
            123
        );
        assertEq(
            fxrp.balanceOf(personalAccountAddr),
            0
        );
    }

    function testExecuteInstructionTransfer() public {
        // mint some fXRP to the personal account
        address personalAccountAddr = masterAccountController.getPersonalAccount(xrplAddress1);
        fxrp.mint(personalAccountAddr, 123);
        address recipient = makeAddr("recipient");
        bytes32 paymentReference = _encodeFxrpTransferPaymentReference(0, 123, recipient);
        IPayment.Proof memory proof;
        proof.data.responseBody.standardPaymentReference = paymentReference;
        proof.data.responseBody.receivedAmount = int256(defaultInstructionFee);
        proof.data.responseBody.status = 0;
        proof.data.responseBody.blockTimestamp = uint64(block.timestamp);
        proof.data.responseBody.sourceAddressHash = keccak256(bytes(xrplAddress1));
        proof.data.responseBody.receivingAddressHash = xrplProviderWalletHash;
        proof.data.requestBody.transactionId = bytes32("tx1");
        _mockVerifyPayment(true);

        assertEq(
            fxrp.balanceOf(personalAccountAddr),
            123
        );
        assertEq(
            fxrp.balanceOf(recipient),
            0
        );

        vm.expectEmit();
        emit IInstructionsFacet.FXrpTransferred(
            personalAccountAddr,
            recipient,
            123
        );
        vm.expectEmit();
        emit IInstructionsFacet.InstructionExecuted(
            personalAccountAddr,
            proof.data.requestBody.transactionId,
            paymentReference,
            xrplAddress1,
            _getInstructionId(0, 1)
        );
        masterAccountController.executeInstruction(proof, xrplAddress1);

        assertEq(
            fxrp.balanceOf(personalAccountAddr),
            0
        );
        assertEq(
            fxrp.balanceOf(recipient),
            123
        );
    }

    function testExecuteInstructionTransferRevertAddressZero() public {
        // mint some fXRP to the personal account
        address personalAccountAddr = masterAccountController.getPersonalAccount(xrplAddress1);
        fxrp.mint(personalAccountAddr, 123);
        bytes32 paymentReference = _encodeFxrpTransferPaymentReference(0, 123, address(0));
        IPayment.Proof memory proof;
        proof.data.responseBody.standardPaymentReference = paymentReference;
        proof.data.responseBody.receivedAmount = int256(defaultInstructionFee);
        proof.data.responseBody.status = 0;
        proof.data.responseBody.blockTimestamp = uint64(block.timestamp);
        proof.data.responseBody.sourceAddressHash = keccak256(bytes(xrplAddress1));
        proof.data.responseBody.receivingAddressHash = xrplProviderWalletHash;
        proof.data.requestBody.transactionId = bytes32("tx1");
        _mockVerifyPayment(true);

        vm.expectRevert(IInstructionsFacet.AddressZero.selector);
        masterAccountController.executeInstruction(proof, xrplAddress1);
    }

    function testExecuteInstructionRedeemFxrp() public {
        bytes32 paymentReference = _encodeFxrpPaymentReference(2, 0, 3, 0);
        uint256 lotSize = 100;
        address personalAccountAddr = masterAccountController.getPersonalAccount(xrplAddress1);
        IPayment.Proof memory proof;
        proof.data.responseBody.standardPaymentReference = paymentReference;
        proof.data.responseBody.receivedAmount = int256(defaultInstructionFee);
        proof.data.responseBody.status = 0;
        proof.data.responseBody.blockTimestamp = uint64(block.timestamp);
        proof.data.responseBody.sourceAddressHash = keccak256(bytes(xrplAddress1));
        proof.data.responseBody.receivingAddressHash = xrplProviderWalletHash;
        proof.data.requestBody.transactionId = bytes32("tx1");
        _mockVerifyPayment(true);
        _mockRedeem(3 * lotSize);

        vm.expectEmit();
        emit IInstructionsFacet.FXrpRedeemed(
            personalAccountAddr,
            3,
            3 * lotSize,
            executor,
            executorFee
        );
        vm.expectEmit();
        emit IInstructionsFacet.InstructionExecuted(
            personalAccountAddr,
            proof.data.requestBody.transactionId,
            paymentReference,
            xrplAddress1,
            _getInstructionId(0, 2)
        );
        masterAccountController.executeInstruction{value: executorFee} (proof, xrplAddress1);

        assertEq(
            fxrp.balanceOf(personalAccountAddr),
            0
        );
    }

    function testExecuteInstructionRedeem() public {
        // deposit 123 fXRP to the personal account
        testExecuteInstructionDeposit();
        address personalAccountAddr = masterAccountController.getPersonalAccount(xrplAddress1);
        assertEq(
            depositVault.balanceOf(personalAccountAddr),
            123
        );
        assertEq(
            fxrp.balanceOf(personalAccountAddr),
            0
        );
        bytes32 paymentReference = _encodeFirelightPaymentReference(2, 0, 100, 0, 0);
        IPayment.Proof memory proof;
        proof.data.responseBody.standardPaymentReference = paymentReference;
        proof.data.responseBody.receivedAmount = int256(defaultInstructionFee);
        proof.data.responseBody.status = 0;
        proof.data.responseBody.blockTimestamp = uint64(block.timestamp);
        proof.data.responseBody.sourceAddressHash = keccak256(bytes(xrplAddress1));
        proof.data.responseBody.receivingAddressHash = xrplProviderWalletHash;
        proof.data.requestBody.transactionId = bytes32("tx2");
        _mockVerifyPayment(true);

        vm.expectEmit();
        emit IInstructionsFacet.Redeemed(
            personalAccountAddr,
            address(depositVault),
            100,
            100 // assuming 1:1 share:asset for simplicity
        );
        vm.expectEmit();
        emit IInstructionsFacet.InstructionExecuted(
            personalAccountAddr,
            proof.data.requestBody.transactionId,
            paymentReference,
            xrplAddress1,
            _getInstructionId(1, 2)
        );
        masterAccountController.executeInstruction(proof, xrplAddress1);

        assertEq(
            depositVault.balanceOf(personalAccountAddr),
            23 // 123 - 100 redeemed
        );
        assertEq(
            depositVault.pendingWithdrawAssets(personalAccountAddr, 1),
            100
        );
    }

    function testExecuteInstructionClaimWithdraw() public {
        uint16 period = 1;
        address personalAccountAddr = masterAccountController.getPersonalAccount(xrplAddress1);
        testExecuteInstructionRedeem();
        assertEq(
            depositVault.pendingWithdrawAssets(personalAccountAddr, period),
            100
        );
        assertEq(
            fxrp.balanceOf(personalAccountAddr),
            0
        );

        // move to the claimable period (to period 3)
        vm.warp(block.timestamp + 2 days);

        bytes32 paymentReference = _encodeFirelightPaymentReference(3, 0, period, 0, 0);
        IPayment.Proof memory proof;
        proof.data.responseBody.standardPaymentReference = paymentReference;
        proof.data.responseBody.receivedAmount = int256(defaultInstructionFee);
        proof.data.responseBody.status = 0;
        proof.data.responseBody.blockTimestamp = uint64(block.timestamp);
        proof.data.responseBody.sourceAddressHash = keccak256(bytes(xrplAddress1));
        proof.data.responseBody.receivingAddressHash = xrplProviderWalletHash;
        proof.data.requestBody.transactionId = bytes32("tx3");
        _mockVerifyPayment(true);

        vm.expectEmit();
        emit IInstructionsFacet.WithdrawalClaimed(
            personalAccountAddr,
            address(depositVault),
            period,
            100
        );
        vm.expectEmit();
        emit IInstructionsFacet.InstructionExecuted(
            personalAccountAddr,
            proof.data.requestBody.transactionId,
            paymentReference,
            xrplAddress1,
            _getInstructionId(1, 3)
        );
        masterAccountController.executeInstruction(proof, xrplAddress1);

        assertEq(
            depositVault.pendingWithdrawAssets(personalAccountAddr, period),
            0
        );
        assertEq(
            fxrp.balanceOf(personalAccountAddr),
            100
        );
    }

    function testExecuteInstructionClaimWithdrawAndRedeem() public {
        uint16 period = 1;
        address personalAccountAddr = masterAccountController.getPersonalAccount(xrplAddress1);
        testExecuteInstructionRedeem();
        assertEq(
            depositVault.pendingWithdrawAssets(personalAccountAddr, period),
            100
        );
        assertEq(
            fxrp.balanceOf(personalAccountAddr),
            0
        );

        // move to the claimable period (to period 3)
        vm.warp(block.timestamp + 2 days);

        bytes32 paymentReference = _encodeFirelightPaymentReference(4, 0, period, 0, 0);
        IPayment.Proof memory proof;
        proof.data.responseBody.standardPaymentReference = paymentReference;
        proof.data.responseBody.receivedAmount = int256(defaultInstructionFee);
        proof.data.responseBody.status = 0;
        proof.data.responseBody.blockTimestamp = uint64(block.timestamp);
        proof.data.responseBody.sourceAddressHash = keccak256(bytes(xrplAddress1));
        proof.data.responseBody.receivingAddressHash = xrplProviderWalletHash;
        proof.data.requestBody.transactionId = bytes32("tx3");
        _mockVerifyPayment(true);
        _mockLotSize(100);
        _mockRedeem(100);

        vm.expectEmit();
        emit IInstructionsFacet.WithdrawalClaimed(
            personalAccountAddr,
            address(depositVault),
            period,
            100
        );
        vm.expectEmit();
        emit IInstructionsFacet.FXrpRedeemed(
            personalAccountAddr,
            1,
            100,
            executor,
            executorFee
        );
        vm.expectEmit();
        emit IInstructionsFacet.InstructionExecuted(
            personalAccountAddr,
            proof.data.requestBody.transactionId,
            paymentReference,
            xrplAddress1,
            _getInstructionId(1, 4)
        );
        masterAccountController.executeInstruction{value: defaultInstructionFee}(proof, xrplAddress1);
        assertEq(
            depositVault.pendingWithdrawAssets(personalAccountAddr, period),
            0
        );
    }

    function testExecuteInstructionClaimWithdrawAndRedeemRevert() public {
        // if amount < 1 lot, it will revert on FAssets side
        address personalAccountAddr = masterAccountController.getPersonalAccount(xrplAddress1);
        testExecuteInstructionRedeem();
        assertEq(
            depositVault.pendingWithdrawAssets(personalAccountAddr, 1),
            100
        );
        assertEq(
            fxrp.balanceOf(personalAccountAddr),
            0
        );

        // move to the claimable period (to period 3)
        vm.warp(block.timestamp + 2 days);

        uint16 period = 1;
        bytes32 paymentReference = _encodeFirelightPaymentReference(4, 0, period, 0, 0);
        IPayment.Proof memory proof;
        proof.data.responseBody.standardPaymentReference = paymentReference;
        proof.data.responseBody.receivedAmount = int256(defaultInstructionFee);
        proof.data.responseBody.status = 0;
        proof.data.responseBody.blockTimestamp = uint64(block.timestamp);
        proof.data.responseBody.sourceAddressHash = keccak256(bytes(xrplAddress1));
        proof.data.responseBody.receivingAddressHash = xrplProviderWalletHash;
        proof.data.requestBody.transactionId = bytes32("tx3");
        _mockVerifyPayment(true);
        _mockLotSize(101);

        bytes4 errorSelector = bytes4(keccak256("RedeemZeroLots()"));
        vm.mockCallRevert(
            assetManagerFxrpMock,
            abi.encodeWithSelector(IAssetManager.redeem.selector),
            abi.encodePacked(errorSelector)
        );

        vm.expectRevert(errorSelector);
        masterAccountController.executeInstruction{value: defaultInstructionFee}(proof, xrplAddress1);
    }

    function testExecuteInstructionRequestRedeem() public {
        // deposit 123 fXRP to the personal account
        testExecuteInstructionDeposit2();
        address personalAccountAddr = masterAccountController.getPersonalAccount(xrplAddress1);
        assertEq(
            depositVault.balanceOf(personalAccountAddr),
            123
        );
        assertEq(
            fxrp.balanceOf(personalAccountAddr),
            0
        );
        bytes32 paymentReference = _encodeUpshiftPaymentReference(2, 0, 100, 0, 3);
        IPayment.Proof memory proof;
        proof.data.responseBody.standardPaymentReference = paymentReference;
        proof.data.responseBody.receivedAmount = int256(defaultInstructionFee);
        proof.data.responseBody.status = 0;
        proof.data.responseBody.blockTimestamp = uint64(block.timestamp);
        proof.data.responseBody.sourceAddressHash = keccak256(bytes(xrplAddress1));
        proof.data.responseBody.receivingAddressHash = xrplProviderWalletHash;
        proof.data.requestBody.transactionId = bytes32("tx2");
        _mockVerifyPayment(true);

        (uint256 year, uint256 month, uint256 day) =
            DateUtils.timestampToDate(block.timestamp + depositVault.lagDuration());
        uint256 claimableEpoch = DateUtils.timestampFromDateTime(year, month, day, 0, 0, 0);
        uint256 period = DateUtils.timestampFromDateTime(year, month, day, 0, 0, 0) / 1 days;
        vm.expectEmit();
        emit IInstructionsFacet.RedeemRequested(
            personalAccountAddr,
            address(depositVault),
            100,
            100,
            claimableEpoch
        );
        vm.expectEmit();
        emit IInstructionsFacet.InstructionExecuted(
            personalAccountAddr,
            proof.data.requestBody.transactionId,
            paymentReference,
            xrplAddress1,
            _getInstructionId(2, 2)
        );
        masterAccountController.executeInstruction(proof, xrplAddress1);

        assertEq(
            depositVault.balanceOf(personalAccountAddr),
            23 // 123 - 100 redeemed
        );
        assertEq(
            depositVault.pendingWithdrawAssets(personalAccountAddr, period),
            100
        );
    }

    function testExecuteInstructionClaim() public {
        address personalAccountAddr = masterAccountController.getPersonalAccount(xrplAddress1);
        testExecuteInstructionRequestRedeem();
        vm.warp(block.timestamp + 1 days); // move to next epoch
        uint256 claimableEpoch = 1;
        assertEq(
            depositVault.pendingWithdrawAssets(personalAccountAddr, claimableEpoch),
            100
        );
        assertEq(
            fxrp.balanceOf(personalAccountAddr),
            0
        );

        bytes32 paymentReference = _encodeUpshiftPaymentReference(3, 0, 19700102, 0, 3);
        IPayment.Proof memory proof;
        proof.data.responseBody.standardPaymentReference = paymentReference;
        proof.data.responseBody.receivedAmount = int256(defaultInstructionFee);
        proof.data.responseBody.status = 0;
        proof.data.responseBody.blockTimestamp = uint64(block.timestamp);
        proof.data.responseBody.sourceAddressHash = keccak256(bytes(xrplAddress1));
        proof.data.responseBody.receivingAddressHash = xrplProviderWalletHash;
        proof.data.requestBody.transactionId = bytes32("tx3");
        _mockVerifyPayment(true);

        vm.expectEmit();
        emit IInstructionsFacet.Claimed(
            personalAccountAddr,
            address(depositVault),
            1970,
            1,
            2,
            100,
            100
        );
        vm.expectEmit();
        emit IInstructionsFacet.InstructionExecuted(
            personalAccountAddr,
            proof.data.requestBody.transactionId,
            paymentReference,
            xrplAddress1,
            _getInstructionId(2, 3)
        );
        masterAccountController.executeInstruction(proof, xrplAddress1);

        assertEq(
            depositVault.pendingWithdrawAssets(personalAccountAddr, claimableEpoch),
            0
        );
        assertEq(
            fxrp.balanceOf(personalAccountAddr),
            100
        );
    }

    function testExecuteInstructionClaimAndRedeem() public {
        testExecuteInstructionRequestRedeem();
        uint256 claimableEpoch = 1;
        vm.warp(block.timestamp + 1 days); // move to next epoch
        address personalAccountAddr = masterAccountController.getPersonalAccount(xrplAddress1);
        assertEq(
            depositVault.pendingWithdrawAssets(personalAccountAddr, claimableEpoch),
            100
        );

        bytes32 paymentReference = _encodeUpshiftPaymentReference(4, 0, 19700102, 0, 3);
        IPayment.Proof memory proof;
        proof.data.responseBody.standardPaymentReference = paymentReference;
        proof.data.responseBody.receivedAmount = int256(defaultInstructionFee);
        proof.data.responseBody.status = 0;
        proof.data.responseBody.blockTimestamp = uint64(block.timestamp);
        proof.data.responseBody.sourceAddressHash = keccak256(bytes(xrplAddress1));
        proof.data.responseBody.receivingAddressHash = xrplProviderWalletHash;
        proof.data.requestBody.transactionId = bytes32("tx3");
        _mockVerifyPayment(true);
        _mockLotSize(100);
        _mockRedeem(100);

        // vm.expectEmit();
        emit IInstructionsFacet.Claimed(
            personalAccountAddr,
            address(depositVault),
            1970,
            1,
            2,
            100,
            100
        );
        vm.expectEmit();
        emit IInstructionsFacet.FXrpRedeemed(
            personalAccountAddr,
            1,
            100,
            executor,
            executorFee
        );
        vm.expectEmit();
        emit IInstructionsFacet.InstructionExecuted(
            personalAccountAddr,
            proof.data.requestBody.transactionId,
            paymentReference,
            xrplAddress1,
            _getInstructionId(2, 4)
        );
        masterAccountController.executeInstruction{value: defaultInstructionFee}(proof, xrplAddress1);
        assertEq(
            depositVault.pendingWithdrawAssets(personalAccountAddr, claimableEpoch),
            0
        );
    }

    function testExecuteInstructionRevertInvalidInstruction() public {
        bytes32 paymentReference = _encodeUpshiftPaymentReference(9, 0, 20250913, 0, 3);
        IPayment.Proof memory proof;
        proof.data.responseBody.standardPaymentReference = paymentReference;
        proof.data.responseBody.receivedAmount = int256(defaultInstructionFee);
        proof.data.responseBody.status = 0;
        proof.data.responseBody.blockTimestamp = uint64(block.timestamp);
        proof.data.responseBody.sourceAddressHash = keccak256(bytes(xrplAddress1));
        proof.data.responseBody.receivingAddressHash = xrplProviderWalletHash;
        proof.data.requestBody.transactionId = bytes32("tx3");
        _mockVerifyPayment(true);

        vm.expectRevert(
            abi.encodeWithSelector(
                IInstructionsFacet.InvalidInstruction.selector,
                2,
                9
            )
        );
        masterAccountController.executeInstruction(proof, xrplAddress1);
    }

    function testSetExecutor(address _executor) public {
        (address returnedExecutor,) = masterAccountController.getExecutorInfo();
        assertEq(returnedExecutor, executor);
        vm.assume(_executor != address(0));
        vm.prank(governance);
        masterAccountController.setExecutor(payable(_executor));
        (address newExecutor,) = masterAccountController.getExecutorInfo();
        assertEq(newExecutor, _executor);
    }

    function testSetExecutorRevertOnlyOwner() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                NotContractOwner.selector,
                address(this),
                governance
            )
        );
        masterAccountController.setExecutor(payable(makeAddr("newExecutor")));
    }

    function testSetExecutorRevertAddressZero() public {
        vm.expectRevert(IExecutorsFacet.InvalidExecutor.selector);
        vm.prank(governance);
        masterAccountController.setExecutor(payable(address(0)));
    }

    function testSetExecutorFee(uint256 _fee) public {
        vm.assume(_fee > 0);
        (, uint256 returnedFee) = masterAccountController.getExecutorInfo();
        assertEq(returnedFee, executorFee);
        vm.prank(governance);
        vm.expectEmit();
        emit IExecutorsFacet.ExecutorFeeSet(_fee);
        masterAccountController.setExecutorFee(_fee);
        (, uint256 newFee) = masterAccountController.getExecutorInfo();
        assertEq(newFee, _fee);
    }

    function testSetExecutorFeeRevertOnlyOwner() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                NotContractOwner.selector,
                address(this),
                governance
            )
        );
        masterAccountController.setExecutorFee(5000);
    }

    function testSetExecutorFeeRevertInvalidFee() public {
        vm.expectRevert(IExecutorsFacet.InvalidExecutorFee.selector);
        vm.prank(governance);
        masterAccountController.setExecutorFee(0);
    }

    function testSetPaymentProofValidityDuration(uint256 _duration) public {
        assertEq(
            masterAccountController.getPaymentProofValidityDurationSeconds(),
            paymentProofValidityDurationSeconds
        );
        vm.prank(governance);
        vm.assume(_duration > 0);
        vm.expectEmit();
        emit IPaymentProofsFacet.PaymentProofValidityDurationSecondsSet(_duration);
        masterAccountController.setPaymentProofValidityDuration(_duration);
        assertEq(
            masterAccountController.getPaymentProofValidityDurationSeconds(),
            _duration
        );
    }

    function testSetPaymentProofValidityDurationRevertOnlyOwner() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                NotContractOwner.selector,
                address(this),
                governance
            )
        );
        masterAccountController.setPaymentProofValidityDuration(1000);
    }

    function testSetPaymentProofValidityDurationRevertInvalidDuration() public {
        vm.expectRevert(IPaymentProofsFacet.InvalidPaymentProofValidityDuration.selector);
        vm.prank(governance);
        masterAccountController.setPaymentProofValidityDuration(0);
    }

    function testSetDefaultInstructionFee(uint128 _fee) public {
        assertEq(
            masterAccountController.getDefaultInstructionFee(),
            defaultInstructionFee
        );
        vm.prank(governance);
        vm.assume(_fee > 0);
        vm.expectEmit();
        emit IInstructionFeesFacet.DefaultInstructionFeeSet(_fee);
        masterAccountController.setDefaultInstructionFee(_fee);
        assertEq(
            masterAccountController.getDefaultInstructionFee(),
            _fee
        );
    }

    function testSetDefaultInstructionFeeRevertOnlyOwner(uint128 _fee) public {
        vm.expectRevert(
            abi.encodeWithSelector(
                NotContractOwner.selector,
                address(this),
                governance
            )
        );
        masterAccountController.setDefaultInstructionFee(_fee);
    }

    function testSetInstructorFees() public {
        assertEq(
            masterAccountController.getInstructionFee(_getInstructionId(1, 1)),
            defaultInstructionFee
        );
        address personalAccountAddr = masterAccountController.getPersonalAccount(xrplAddress1);
        fxrp.mint(personalAccountAddr, 123);
        assertEq(fxrp.balanceOf(personalAccountAddr), 123);
        bytes32 paymentReference = _encodeFirelightPaymentReference(1, 0, 10, 0, 0);
        IPayment.Proof memory proof;
        proof.data.responseBody.standardPaymentReference = paymentReference;
        proof.data.responseBody.receivedAmount = int256(defaultInstructionFee); // default fee
        proof.data.responseBody.status = 0;
        proof.data.responseBody.blockTimestamp = uint64(block.timestamp);
        proof.data.responseBody.sourceAddressHash = keccak256(bytes(xrplAddress1));
        proof.data.responseBody.receivingAddressHash = xrplProviderWalletHash;
        proof.data.requestBody.transactionId = bytes32("tx1");
        _mockVerifyPayment(true);
        masterAccountController.executeInstruction(proof, xrplAddress1);
        assertEq(
            fxrp.balanceOf(personalAccountAddr),
            113
        );

        // change fees
        uint256[] memory instructionIds = new uint256[](2);
        instructionIds[0] = _getInstructionId(1, 1);
        instructionIds[1] = _getInstructionId(1, 2);
        uint256[] memory newFees = new uint256[](2);
        uint256 newFee = 2 * 1e6; // 2 FXRP
        newFees[0] = newFee;
        newFees[1] = 2 * newFee;
        vm.prank(governance);
        vm.expectEmit();
        emit IInstructionFeesFacet.InstructionFeeSet(instructionIds[0], newFees[0]);
        vm.expectEmit();
        emit IInstructionFeesFacet.InstructionFeeSet(instructionIds[1], newFees[1]);
        masterAccountController.setInstructionFees(instructionIds, newFees);
        assertEq(
            masterAccountController.getInstructionFee(_getInstructionId(1, 1)),
            2 * 1e6
        );

        // send tx with old fee - should revert
        proof.data.requestBody.transactionId = bytes32("tx2");
        vm.expectRevert(
            abi.encodeWithSelector(
                IInstructionsFacet.InvalidPaymentAmount.selector,
                newFee
            )
        );
        masterAccountController.executeInstruction(proof, xrplAddress1);

        // send tx with new fee - should pass
        proof.data.requestBody.transactionId = bytes32("tx3");
        proof.data.responseBody.receivedAmount = int256(newFee);
        masterAccountController.executeInstruction(proof, xrplAddress1);
        assertEq(fxrp.balanceOf(personalAccountAddr), 103);
    }

    function testSetInstructionFeesRevertOnlyOwner() public {
        uint256[] memory instructionIds = new uint256[](1);
        instructionIds[0] = 11;
        uint256[] memory newFees = new uint256[](1);
        newFees[0] = 2 * 1e6;
        vm.expectRevert(
            abi.encodeWithSelector(
                NotContractOwner.selector,
                address(this),
                governance
            )
        );
        masterAccountController.setInstructionFees(instructionIds, newFees);
    }

    function testSetInstructionFeesRevertLengthsMismatch() public {
        uint256[] memory instructionIds = new uint256[](2);
        instructionIds[0] = 11;
        instructionIds[1] = 12;
        uint256[] memory newFees = new uint256[](1);
        newFees[0] = 2 * 1e6;
        vm.prank(governance);
        vm.expectRevert(IInstructionFeesFacet.InstructionFeesLengthsMismatch.selector);
        masterAccountController.setInstructionFees(instructionIds, newFees);
    }

    function testRemoveInstructionFees() public {
        assertEq(
            masterAccountController.getInstructionFee(11),
            defaultInstructionFee
        );
        // set custom fee
        uint256[] memory instructionIds = new uint256[](1);
        instructionIds[0] = 11;
        uint256[] memory newFees = new uint256[](1);
        uint256 newFee = 2 * 1e6; // 2 FXRP
        newFees[0] = newFee;
        vm.prank(governance);
        masterAccountController.setInstructionFees(instructionIds, newFees);
        assertEq(
            masterAccountController.getInstructionFee(11),
            newFee
        );

        // remove custom fee
        vm.prank(governance);
        masterAccountController.removeInstructionFees(instructionIds);
        assertEq(
            masterAccountController.getInstructionFee(11),
            defaultInstructionFee
        );
    }

    function testRemoveInstructionFeesRevertOnlyOwner() public {
        uint256[] memory instructionIds = new uint256[](1);
        instructionIds[0] = 11;
        vm.expectRevert(
            abi.encodeWithSelector(
                NotContractOwner.selector,
                address(this),
                governance
            )
        );
        masterAccountController.removeInstructionFees(instructionIds);
    }

    function testAddXrplProviderWallets() public {
        string memory newWalet = "newXrplWallet";
        assertEq(
            masterAccountController.getXrplProviderWallets().length,
            1
        );
        address personalAccountAddr = masterAccountController.getPersonalAccount(xrplAddress1);
        fxrp.mint(personalAccountAddr, 123);
        // make tx with new wallet as receiving address - should revert
        bytes32 paymentReference = _encodeFirelightPaymentReference(1, 0, 123, 0, 0);
        IPayment.Proof memory proof;
        proof.data.responseBody.standardPaymentReference = paymentReference;
        proof.data.responseBody.receivedAmount = int256(defaultInstructionFee);
        proof.data.responseBody.status = 0;
        proof.data.responseBody.blockTimestamp = uint64(block.timestamp);
        proof.data.responseBody.sourceAddressHash = keccak256(bytes(xrplAddress1));
        proof.data.responseBody.receivingAddressHash = keccak256(bytes(newWalet));
        proof.data.requestBody.transactionId = bytes32("tx1");
        _mockVerifyPayment(true);

        vm.expectRevert(IPaymentProofsFacet.InvalidReceivingAddressHash.selector);
        masterAccountController.executeInstruction(proof, xrplAddress1);

        // add new wallet
        string[] memory newWallets = new string[](2);
        newWallets[0] = newWalet;
        newWallets[1] = "newWallet2";
        vm.prank(governance);
        vm.expectEmit();
        emit IXrplProviderWalletsFacet.XrplProviderWalletAdded(newWallets[0]);
        vm.expectEmit();
        emit IXrplProviderWalletsFacet.XrplProviderWalletAdded(newWallets[1]);
        masterAccountController.addXrplProviderWallets(newWallets);
        assertEq(
            masterAccountController.getXrplProviderWallets().length,
            3
        );

        // try the tx again - should pass now
        proof.data.requestBody.transactionId = bytes32("tx2");
        masterAccountController.executeInstruction(proof, xrplAddress1);
    }

    function testAddXrplProviderWalletsRevertOnlyOwner() public {
        string[] memory newWallets = new string[](1);
        newWallets[0] = "newXrplWallet";
        vm.expectRevert(
            abi.encodeWithSelector(
                NotContractOwner.selector,
                address(this),
                governance
            )
        );
        masterAccountController.addXrplProviderWallets(newWallets);
    }

    function testAddXrplProviderWalletsRevertInvalidXrplProviderWallet() public {
        string[] memory newWallets = new string[](2);
        newWallets[1] = ""; // invalid
        newWallets[0] = "newWallet2";
        vm.prank(governance);
        vm.expectRevert(
            abi.encodeWithSelector(
                IXrplProviderWalletsFacet.InvalidXrplProviderWallet.selector,
                newWallets[1]
            )
        );
        masterAccountController.addXrplProviderWallets(newWallets);
    }

    function testAddXrplProviderWalletsRevertXrplProviderWalletAlreadyExists() public {
        string[] memory newWallets = new string[](1);
        newWallets[0] = xrplProviderWallet; // already exists
        vm.prank(governance);
        vm.expectRevert(
            abi.encodeWithSelector(
                IXrplProviderWalletsFacet.XrplProviderWalletAlreadyExists.selector,
                newWallets[0]
            )
        );
        masterAccountController.addXrplProviderWallets(newWallets);
    }

    function testRemoveXrplProviderWallets() public {
        assertEq(
            masterAccountController.getXrplProviderWallets().length,
            1
        );
        // remove existing wallet
        string[] memory walletsToRemove = new string[](1);
        walletsToRemove[0] = xrplProviderWallet;
        vm.prank(governance);
        vm.expectEmit();
        emit IXrplProviderWalletsFacet.XrplProviderWalletRemoved(walletsToRemove[0]);
        masterAccountController.removeXrplProviderWallets(walletsToRemove);
        assertEq(
            masterAccountController.getXrplProviderWallets().length,
            0
        );
    }

    // remove non-last wallet
    function testRemoveXrplProviderWallets2() public {
        testAddXrplProviderWallets();

        // remove first wallet
        string[] memory walletsToRemove = new string[](1);
        walletsToRemove[0] = xrplProviderWallet;
        vm.prank(governance);
        vm.expectEmit();
        emit IXrplProviderWalletsFacet.XrplProviderWalletRemoved(walletsToRemove[0]);
        masterAccountController.removeXrplProviderWallets(walletsToRemove);
        assertEq(
            masterAccountController.getXrplProviderWallets().length,
            2
        );
    }

    function testAddAgentVaults() public {
        uint256[] memory ids = new uint256[](2);
        address[] memory addresses = new address[](2);
        ids[0] = 1;
        addresses[0] = makeAddr("agentVault1");
        ids[1] = 2;
        addresses[1] = makeAddr("agentVault2");

        agentInfo.status = AgentInfo.Status.NORMAL;
        _mockGetAgentInfo(addresses[0], agentInfo);
        _mockGetAgentInfo(addresses[1], agentInfo);

        vm.prank(governance);
        vm.expectEmit();
        emit IAgentVaultsFacet.AgentVaultAdded(1, addresses[0]);
        vm.expectEmit();
        emit IAgentVaultsFacet.AgentVaultAdded(2, addresses[1]);
        masterAccountController.addAgentVaults(ids, addresses);

        (uint256[] memory returnedIds, address[] memory addrs) = masterAccountController.getAgentVaults();
        assertEq(returnedIds.length, 3);
        assertEq(returnedIds[0], 0);
        assertEq(returnedIds[1], 1);
        assertEq(returnedIds[2], 2);
        assertEq(addrs[0], agent);
        assertEq(addrs[1], addresses[0]);
        assertEq(addrs[2], addresses[1]);
    }

    function testAddAgentVaultsRevertOnlyOwner() public {
        uint256[] memory ids = new uint256[](1);
        address[] memory addresses = new address[](1);
        ids[0] = 1;
        addresses[0] = makeAddr("agentVault1");

        vm.expectRevert(
            abi.encodeWithSelector(
                NotContractOwner.selector,
                address(this),
                governance
            )
        );
        masterAccountController.addAgentVaults(ids, addresses);
    }

    function testAddAgentVaultsRevertLengthsMismatch() public {
        uint256[] memory ids = new uint256[](2);
        address[] memory addresses = new address[](1);
        ids[0] = 1;
        ids[1] = 2;
        addresses[0] = makeAddr("agentVault1");

        vm.prank(governance);
        vm.expectRevert(IAgentVaultsFacet.AgentsVaultsLengthsMismatch.selector);
        masterAccountController.addAgentVaults(ids, addresses);
    }

    function testAddAgentVaultsRevertAgentVaultIdAlreadyUsed() public {
        uint256[] memory ids = new uint256[](1);
        address[] memory addresses = new address[](1);
        ids[0] = 1;
        addresses[0] = makeAddr("agentVault1");

        agentInfo.status = AgentInfo.Status.NORMAL;
        _mockGetAgentInfo(addresses[0], agentInfo);
        vm.prank(governance);
        masterAccountController.addAgentVaults(ids, addresses);

        // try to add again
        vm.prank(governance);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAgentVaultsFacet.AgentVaultIdAlreadyUsed.selector,
                1
            )
        );
        masterAccountController.addAgentVaults(ids, addresses);
    }

    function testAddAgentVaultsRevertInvalidAgentVault() public {
        uint256[] memory ids = new uint256[](2);
        address[] memory addresses = new address[](2);
        ids[1] = 1;
        addresses[1] = address(0); // invalid
        ids[0] = 2;
        addresses[0] = makeAddr("agentVault2");

        agentInfo.status = AgentInfo.Status.NORMAL;
        _mockGetAgentInfo(addresses[0], agentInfo);

        vm.prank(governance);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAgentVaultsFacet.InvalidAgentVault.selector,
                1
            )
        );
        masterAccountController.addAgentVaults(ids, addresses);
    }

    function testAddAgentVaultsRevertAgentNotAvailable() public {
        uint256[] memory ids = new uint256[](2);
        address[] memory addresses = new address[](2);
        ids[1] = 1;
        addresses[1] = makeAddr("agentVault1");
        ids[0] = 2;
        addresses[0] = makeAddr("agentVault2");

        agentInfo.status = AgentInfo.Status.LIQUIDATION;
        _mockGetAgentInfo(addresses[1], agentInfo);
        agentInfo.status = AgentInfo.Status.NORMAL;
        _mockGetAgentInfo(addresses[0], agentInfo);

        vm.prank(governance);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAgentVaultsFacet.AgentNotAvailable.selector,
                addresses[1]
            )
        );
        masterAccountController.addAgentVaults(ids, addresses);
    }

    function testRemoveAgentVaults() public {
        testAddAgentVaults();
        (uint256[] memory returnedIds, address[] memory addrs) = masterAccountController.getAgentVaults();
        assertEq(returnedIds.length, 3);

        // remove first added agent vault
        uint256[] memory idsToRemove = new uint256[](1);
        idsToRemove[0] = 0;
        vm.prank(governance);
        vm.expectEmit();
        emit IAgentVaultsFacet.AgentVaultRemoved(0, agent);
        masterAccountController.removeAgentVaults(idsToRemove);

        (returnedIds, addrs) = masterAccountController.getAgentVaults();
        assertEq(returnedIds.length, 2);
        assertEq(returnedIds[0], 2);
        assertEq(returnedIds[1], 1);
        assertEq(addrs[0], makeAddr("agentVault2"));
        assertEq(addrs[1], makeAddr("agentVault1"));
    }

    function testRemoveAgentVaultsRevertOnlyOwner() public {
        uint256[] memory idsToRemove = new uint256[](1);
        idsToRemove[0] = 0;
        vm.expectRevert(
            abi.encodeWithSelector(
                NotContractOwner.selector,
                address(this),
                governance
            )
        );
        masterAccountController.removeAgentVaults(idsToRemove);
    }

    function testRemoveAgentVaultsRevertInvalidAgentVault() public {
        uint256[] memory idsToRemove = new uint256[](1);
        idsToRemove[0] = 1;
        vm.prank(governance);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAgentVaultsFacet.InvalidAgentVault.selector,
                1
            )
        );
        masterAccountController.removeAgentVaults(idsToRemove);
    }

    function testAddVaults() public {
        uint256[] memory vaultIds = new uint256[](2);
        address[] memory vaultAddresses = new address[](2);
        uint8[] memory vaultTypes = new uint8[](2);
        vaultIds[0] = 1;
        vaultIds[1] = 2;
        vaultAddresses[0] = makeAddr("vault1");
        vaultAddresses[1] = makeAddr("vault2");
        vaultTypes[0] = 1;
        vaultTypes[1] = 2;

        vm.expectEmit();
        emit IVaultsFacet.VaultAdded(vaultIds[0], vaultAddresses[0], vaultTypes[0]);
        vm.expectEmit();
        emit IVaultsFacet.VaultAdded(vaultIds[1], vaultAddresses[1], vaultTypes[1]);
        vm.prank(governance);
        masterAccountController.addVaults(vaultIds, vaultAddresses, vaultTypes);

        (uint256[] memory returnedIds, address[] memory addrs, uint8[] memory types) =
            masterAccountController.getVaults();
        assertEq(returnedIds.length, 4);
        assertEq(returnedIds[0], 0);
        assertEq(returnedIds[1], 3);
        assertEq(returnedIds[2], 1);
        assertEq(returnedIds[3], 2);
        assertEq(addrs[0], address(depositVault));
        assertEq(addrs[1], address(depositVault));
        assertEq(addrs[2], vaultAddresses[0]);
        assertEq(addrs[3], vaultAddresses[1]);
        assertEq(types[0], 1);
        assertEq(types[1], 2);
        assertEq(types[2], vaultTypes[0]);
        assertEq(types[3], vaultTypes[1]);
    }

    function testAddVaultsRevertOnlyOwner() public {
        uint256[] memory vaultIds = new uint256[](1);
        address[] memory vaultAddresses = new address[](1);
        uint8[] memory vaultTypes = new uint8[](1);
        vaultIds[0] = 1;
        vaultAddresses[0] = makeAddr("vault1");
        vaultTypes[0] = 1;

        vm.expectRevert(
            abi.encodeWithSelector(
                NotContractOwner.selector,
                address(this),
                governance
            )
        );
        masterAccountController.addVaults(vaultIds, vaultAddresses, vaultTypes);
    }

    function testAddVaultsRevertInvalidVaultId() public {
        uint256[] memory vaultIds = new uint256[](1);
        address[] memory vaultAddresses = new address[](1);
        uint8[] memory vaultTypes = new uint8[](1);
        vaultIds[0] = 1;
        vaultAddresses[0] = address(0); // invalid
        vaultTypes[0] = 1;

        vm.prank(governance);
        vm.expectRevert(
            abi.encodeWithSelector(
                IVaultsFacet.InvalidVaultId.selector,
                1
            )
        );
        masterAccountController.addVaults(vaultIds, vaultAddresses, vaultTypes);
    }

    function testAddVaultsRevertInvalidVaultType() public {
        uint256[] memory vaultIds = new uint256[](1);
        address[] memory vaultAddresses = new address[](1);
        uint8[] memory vaultTypes = new uint8[](1);
        vaultIds[0] = 1;
        vaultAddresses[0] = makeAddr("vault1");
        vaultTypes[0] = 0; // invalid

        vm.prank(governance);
        vm.expectRevert(
            abi.encodeWithSelector(
                IVaultsFacet.InvalidVaultType.selector,
                0
            )
        );
        masterAccountController.addVaults(vaultIds, vaultAddresses, vaultTypes);
    }

    function testAddVaultsRevertLengthsMismatch() public {
        uint256[] memory vaultIds = new uint256[](1);
        address[] memory vaultAddresses = new address[](2);
        uint8[] memory vaultTypes = new uint8[](1);
        vaultIds[0] = 1;
        vaultAddresses[0] = makeAddr("vault1");
        vaultAddresses[1] = makeAddr("vault2");
        vaultTypes[0] = 1;

        vm.prank(governance);
        vm.expectRevert(IVaultsFacet.VaultsLengthsMismatch.selector);
        masterAccountController.addVaults(vaultIds, vaultAddresses, vaultTypes);
    }

    function testAddVaultsRevertLengthsMismatch2() public {
        uint256[] memory vaultIds = new uint256[](1);
        address[] memory vaultAddresses = new address[](1);
        uint8[] memory vaultTypes = new uint8[](2);
        vaultIds[0] = 1;
        vaultAddresses[0] = makeAddr("vault1");
        vaultTypes[0] = 1;
        vaultTypes[1] = 2;

        vm.prank(governance);
        vm.expectRevert(IVaultsFacet.VaultsLengthsMismatch.selector);
        masterAccountController.addVaults(vaultIds, vaultAddresses, vaultTypes);
    }

    function testAddVaultsRevertVaultIdAlreadyUsed() public {
        uint256[] memory vaultIds = new uint256[](1);
        address[] memory vaultAddresses = new address[](1);
        uint8[] memory vaultTypes = new uint8[](1);
        vaultIds[0] = 0; // already used
        vaultAddresses[0] = makeAddr("vault1");
        vaultTypes[0] = 1;

        vm.prank(governance);
        vm.expectRevert(
            abi.encodeWithSelector(
                IVaultsFacet.VaultIdAlreadyUsed.selector,
                0
            )
        );
        masterAccountController.addVaults(vaultIds, vaultAddresses, vaultTypes);
    }

    function testSetPersonalAccountImplementation(address _newImplementation) public {
        assertEq(masterAccountController.implementation(), personalAccountImplementation);
        vm.prank(governance);
        vm.assume(_newImplementation != address(0));
        vm.expectEmit();
        emit IPersonalAccountsFacet.PersonalAccountImplementationSet(_newImplementation);
        masterAccountController.setPersonalAccountImplementation(_newImplementation);
        assertEq(masterAccountController.implementation(), _newImplementation);
    }

    function testSetPersonalAccountImplementationRevertOnlyOwner() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                NotContractOwner.selector,
                address(this),
                governance
            )
        );
        masterAccountController.setPersonalAccountImplementation(makeAddr("newImplementation"));
    }

    function testSetPersonalAccountImplementationRevertInvalidPersonalAccountImplementation() public {
        vm.expectRevert(IPersonalAccountsFacet.InvalidPersonalAccountImplementation.selector);
        vm.prank(governance);
        masterAccountController.setPersonalAccountImplementation(address(0));
    }

    function testSetSwapParams() public {
        address router = makeAddr("router");
        address newUsdt0 = makeAddr("newUsdt0");
        uint24 wnatusdtFee = 500;
        uint24 usdt0fxrpFee = 3000;
        uint24 maxSlippageBps = 100;
        vm.prank(governance);
        vm.expectEmit();
        emit ISwapFacet.SwapParamsSet(
            router,
            newUsdt0,
            wnatusdtFee,
            usdt0fxrpFee,
            maxSlippageBps
        );
        masterAccountController.setSwapParams(
            router,
            newUsdt0,
            wnatusdtFee,
            usdt0fxrpFee,
            maxSlippageBps
        );
        (
            address returnedRouter,
            address returnedUsdt0,
            uint24 returnedWnatusdtFee,
            uint24 returnedUsdt0fxrpFee,
            uint24 returnedMaxSlippageBps
        ) = masterAccountController.getSwapParams();
        assertEq(returnedRouter, router);
        assertEq(returnedUsdt0, newUsdt0);
        assertEq(returnedWnatusdtFee, wnatusdtFee);
        assertEq(returnedUsdt0fxrpFee, usdt0fxrpFee);
        assertEq(returnedMaxSlippageBps, maxSlippageBps);
    }

    function testSetSwapParamsRevertOnlyOwner() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                NotContractOwner.selector,
                address(this),
                governance
            )
        );
        masterAccountController.setSwapParams(
            makeAddr("router"),
            makeAddr("usdt0"),
            500,
            3000,
            100
        );
    }

    function testSwapParamsRevertInvalidUniswapV3Router() public {
        vm.expectRevert(ISwapFacet.InvalidUniswapV3Router.selector);
        vm.prank(governance);
        masterAccountController.setSwapParams(
            address(0),
            makeAddr("usdt0"),
            500,
            3000,
            100
        );
    }

    function testSwapParamsRevertInvalidPoolFeeTierPPM1() public {
        vm.expectRevert(ISwapFacet.InvalidPoolFeeTierPPM.selector);
        vm.prank(governance);
        masterAccountController.setSwapParams(
            makeAddr("router"),
            makeAddr("usdt0"),
            200,
            3000,
            100
        );
    }

    function testSwapParamsRevertInvalidPoolFeeTierPPM2() public {
        vm.expectRevert(ISwapFacet.InvalidPoolFeeTierPPM.selector);
        vm.prank(governance);
        masterAccountController.setSwapParams(
            makeAddr("router"),
            makeAddr("usdt0"),
            500,
            7000,
            100
        );
    }

    function testSwapParamsRevertInvalidUsdt0() public {
        vm.expectRevert(ISwapFacet.InvalidUsdt0.selector);
        vm.prank(governance);
        masterAccountController.setSwapParams(
            makeAddr("router"),
            address(0),
            500,
            3000,
            100
        );
    }

    function testCreatePersonalAccountRevertPersonalAccountNotSuccessfullyDeployed() public {
        MockSingletonFactoryNoDeploy mockFactoryNoDeploy = new MockSingletonFactoryNoDeploy();
        vm.etch(SINGLETON_FACTORY, address(mockFactoryNoDeploy).code);

        address personalAccountAddr = masterAccountController.getPersonalAccount(xrplAddress1);
        fxrp.mint(personalAccountAddr, 123);
        assertEq(fxrp.balanceOf(personalAccountAddr), 123);
        bytes32 paymentReference = _encodeFirelightPaymentReference(1, 0, 123, 0, 1);
        IPayment.Proof memory proof;
        proof.data.responseBody.standardPaymentReference = paymentReference;
        proof.data.responseBody.receivedAmount = int256(2 * defaultInstructionFee);
        proof.data.responseBody.status = 0;
        proof.data.responseBody.blockTimestamp = uint64(block.timestamp);
        proof.data.responseBody.sourceAddressHash = keccak256(bytes(xrplAddress1));
        proof.data.responseBody.receivingAddressHash = xrplProviderWalletHash;
        proof.data.requestBody.transactionId = bytes32("tx1");
        _mockVerifyPayment(true);

        vm.expectRevert(
            abi.encodeWithSelector(
                IPersonalAccountsFacet.PersonalAccountNotSuccessfullyDeployed.selector,
                personalAccountAddr
            )
        );
        masterAccountController.executeInstruction(proof, xrplAddress1);
    }

    function testGetVaultAddressRevertInvalidVaultId() public {
        address personalAccountAddr = masterAccountController.getPersonalAccount(xrplAddress1);
        fxrp.mint(personalAccountAddr, 123);
        assertEq(fxrp.balanceOf(personalAccountAddr), 123);
        bytes32 paymentReference = _encodeFirelightPaymentReference(1, 0, 123, 0, 1);
        IPayment.Proof memory proof;
        proof.data.responseBody.standardPaymentReference = paymentReference;
        proof.data.responseBody.receivedAmount = int256(2 * defaultInstructionFee);
        proof.data.responseBody.status = 0;
        proof.data.responseBody.blockTimestamp = uint64(block.timestamp);
        proof.data.responseBody.sourceAddressHash = keccak256(bytes(xrplAddress1));
        proof.data.responseBody.receivingAddressHash = xrplProviderWalletHash;
        proof.data.requestBody.transactionId = bytes32("tx1");
        _mockVerifyPayment(true);

        vm.expectRevert(
            abi.encodeWithSelector(
                IVaultsFacet.InvalidVaultId.selector,
                1
            )
        );
        masterAccountController.executeInstruction(proof, xrplAddress1);
    }

    function testExecuteWithdrawalFirelight() public {
        uint16 period = 1;
        address personalAccountAddr = masterAccountController.getPersonalAccount(xrplAddress1);
        testExecuteInstructionRedeem();
        assertEq(
            depositVault.pendingWithdrawAssets(personalAccountAddr, period),
            100
        );
        assertEq(
            fxrp.balanceOf(personalAccountAddr),
            0
        );

        // move to the claimable period (to period 3)
        vm.warp(block.timestamp + 2 days);

        vm.expectEmit();
        emit IInstructionsFacet.WithdrawalClaimed(
            personalAccountAddr,
            address(depositVault),
            period,
            100
        );
        vm.expectEmit();
        emit IInstructionsFacet.WithdrawalExecuted(
            personalAccountAddr,
            address(depositVault),
            xrplAddress1,
            period
        );
        masterAccountController.executeWithdrawal(xrplAddress1, 0, period);

        assertEq(
            depositVault.pendingWithdrawAssets(personalAccountAddr, period),
            0
        );
        assertEq(
            fxrp.balanceOf(personalAccountAddr),
            100
        );
    }

    function testExecuteWithdrawalUpshift() public {
        address personalAccountAddr = masterAccountController.getPersonalAccount(xrplAddress1);
        testExecuteInstructionRequestRedeem();
        vm.warp(block.timestamp + 1 days); // move to next epoch
        uint256 claimableEpoch = 1;
        uint256 date = 19700102;
        assertEq(
            depositVault.pendingWithdrawAssets(personalAccountAddr, claimableEpoch),
            100
        );
        assertEq(
            fxrp.balanceOf(personalAccountAddr),
            0
        );

        vm.expectEmit();
        emit IInstructionsFacet.Claimed(
            personalAccountAddr,
            address(depositVault),
            1970,
            1,
            2,
            100,
            100
        );
        vm.expectEmit();
        emit IInstructionsFacet.WithdrawalExecuted(
            personalAccountAddr,
            address(depositVault),
            xrplAddress1,
            date
        );
        masterAccountController.executeWithdrawal(xrplAddress1, 3, date);

        assertEq(
            depositVault.pendingWithdrawAssets(personalAccountAddr, claimableEpoch),
            0
        );
        assertEq(
            fxrp.balanceOf(personalAccountAddr),
            100
        );
    }

    function testExecuteWithdrawalRevertInvalidInvalidVaultId() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IVaultsFacet.InvalidVaultId.selector,
                5
            )
        );
        masterAccountController.executeWithdrawal(xrplAddress1, 5, 0);
    }

    function testExecuteInstructionRevertInvalidInstructionType() public {
        // use upshift vault for firelight instruction type
        bytes32 paymentReference = _encodeFirelightPaymentReference(1, 0, 123, 0, 3);
        IPayment.Proof memory proof;
        proof.data.responseBody.standardPaymentReference = paymentReference;
        proof.data.responseBody.receivedAmount = int256(2 * defaultInstructionFee);
        proof.data.responseBody.status = 0;
        proof.data.responseBody.blockTimestamp = uint64(block.timestamp);
        proof.data.responseBody.sourceAddressHash = keccak256(bytes(xrplAddress1));
        proof.data.responseBody.receivingAddressHash = xrplProviderWalletHash;
        proof.data.requestBody.transactionId = bytes32("tx1");
        _mockVerifyPayment(true);

        vm.expectRevert(
            abi.encodeWithSelector(
                IInstructionsFacet.InvalidInstructionType.selector,
                1
            )
        );
        masterAccountController.executeInstruction(proof, xrplAddress1);
    }



    // function testSwapWNatForUsdt0() public {
    //     _mockGetContractAddressByHash("WNat", wNatMock);
    //     masterAccountController.swapWNatForUsdt0(xrplAddress1);
    // }

    //// helper functions ////
    function _mockGetAgentInfo(
        address agentAddress,
        AgentInfo.Info memory info
    )
        private
    {
        vm.mockCall(
            assetManagerFxrpMock,
            abi.encodeWithSelector(
                IAssetManager.getAgentInfo.selector,
                agentAddress
            ),
            abi.encode(info)
        );
    }

    function _mockGetFAsset()
        private
    {
        vm.mockCall(
            assetManagerFxrpMock,
            abi.encodeWithSelector(
                IAssetManager.fAsset.selector
            ),
            abi.encode(fxrp)
        );
    }

    function _mockGetContractAddressByHash(
        string memory name,
        address addr
    )
        private
    {
        vm.mockCall(
            contractRegistryMock,
            abi.encodeWithSelector(
                IFlareContractRegistry.getContractAddressByHash.selector,
                keccak256(abi.encode(name))
            ),
            abi.encode(addr)
        );
    }

    function _mockVerifyPayment(bool _result) private {
        vm.mockCall(
            fdcVerificationMock,
            abi.encodeWithSelector(IPaymentVerification.verifyPayment.selector),
            abi.encode(_result)
        );
    }

    function _mockReserveCollateral(uint256 _reservationId) private {
        vm.mockCall(
            assetManagerFxrpMock,
            abi.encodeWithSelector(
                IAssetManager.reserveCollateral.selector
            ),
            abi.encode(_reservationId)
        );
    }

    function _mockCollateralReservationFee(uint256 _lots, uint256 _fee) private {
        vm.mockCall(
            assetManagerFxrpMock,
            abi.encodeWithSelector(
                IAssetManager.collateralReservationFee.selector,
                _lots
            ),
            abi.encode(_fee)
        );
    }

    function _mockCollateralReservationInfo(
        CollateralReservationInfo.Status _status,
        address _minter,
        uint256 _valueUBA
    )
        private
    {
        CollateralReservationInfo.Data memory info;
        info.status = _status;
        info.minter = _minter;
        info.valueUBA = _valueUBA;
        vm.mockCall(
            assetManagerFxrpMock,
            abi.encodeWithSelector(
                IAssetManager.collateralReservationInfo.selector
            ),
            abi.encode(info)
        );
    }

    function _mockLotSize(uint256 _lotSize) private {
        vm.mockCall(
            assetManagerFxrpMock,
            abi.encodeWithSelector(
                IAssetManager.lotSize.selector
            ),
            abi.encode(_lotSize)
        );
    }

    function _mockRedeem(uint256 _amount) private {
        vm.mockCall(
            assetManagerFxrpMock,
            abi.encodeWithSelector(
                IAssetManager.redeem.selector
            ),
            abi.encode(_amount)
        );
    }

    // FXRP payment reference (32 bytes)
    function _encodeFxrpPaymentReference(
        uint8 _instructionCommand,
        uint8 _walletId,
        uint128 _value,
        uint16 _agentVaultId
    ) private pure returns (bytes32) {
        return
            (bytes32(uint256(_instructionCommand)) << 248) |
            (bytes32(uint256(_walletId)) << 240) |
            (bytes32(uint256(_value)) << 160) |
            (bytes32(uint256(_agentVaultId)) << 144);
        // bytes 14-31 are zero (future use)
    }

    function _encodeFxrpTransferPaymentReference(
        uint8 _walletId,
        uint128 _value,
        address _recipient
    ) private pure returns (bytes32) {
        return
            (bytes32(uint256(1)) << 248) |
            (bytes32(uint256(_walletId)) << 240) |
            (bytes32(uint256(_value)) << 160) |
            (bytes32(uint256(uint160(_recipient))));
        // bytes 12-31: recipient address (20 bytes)
    }

    // Firelight vaults payment reference (32 bytes)
    function _encodeFirelightPaymentReference(
        uint8 _instructionCommand,
        uint8 _walletId,
        uint128 _value,
        uint16 _agentVaultId,
        uint16 _vaultId
    ) private pure returns (bytes32) {
        return
            (bytes32(uint256(1)) << 252) |
            (bytes32(uint256(_instructionCommand)) << 248) |
            (bytes32(uint256(_walletId)) << 240) |
            (bytes32(uint256(_value)) << 160) |
            (bytes32(uint256(_agentVaultId)) << 144) |
            (bytes32(uint256(_vaultId)) << 128);
        // bytes 16-31 are zero (future use)
    }

    // Upshift vaults payment reference (32 bytes)
    function _encodeUpshiftPaymentReference(
        uint8 _instructionCommand,
        uint8 _walletId,
        uint128 _value,
        uint16 _agentVaultId,
        uint16 _vaultId
    ) private pure returns (bytes32) {
        return
            (bytes32(uint256(2)) << 252) |
            (bytes32(uint256(_instructionCommand)) << 248) |
            (bytes32(uint256(_walletId)) << 240) |
            (bytes32(uint256(_value)) << 160) |
            (bytes32(uint256(_agentVaultId)) << 144) |
            (bytes32(uint256(_vaultId)) << 128);
        // bytes 16-31 are zero (future use)
    }

    function _getInstructionId(
        uint256 _instructionType,
        uint256 _instructionCommand
    ) private pure returns (uint256) {
        return (_instructionType << 4) | _instructionCommand;
    }
}
