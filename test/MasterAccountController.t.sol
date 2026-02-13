// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {MasterAccountController} from "../contracts/smartAccounts/implementation/MasterAccountController.sol";
import {IIMasterAccountController} from "../contracts/smartAccounts/interface/IIMasterAccountController.sol";
import {IPayment} from "flare-periphery/src/flare/IPayment.sol";
import {IPaymentVerification} from "flare-periphery/src/flare/IPaymentVerification.sol";
import {IFlareContractRegistry} from "flare-periphery/src/flare/IFlareContractRegistry.sol";
import {IAssetManager} from "flare-periphery/src/flare/IAssetManager.sol";
import {AgentInfo} from "flare-periphery/src/flare/data/AvailableAgentInfo.sol";
import {FtsoV2Interface} from "flare-periphery/src/flare/FtsoV2Interface.sol";
import {PersonalAccount} from "../contracts/smartAccounts/implementation/PersonalAccount.sol";
import {IPersonalAccount} from "../contracts/userInterfaces/IPersonalAccount.sol";
import {PersonalAccountProxy} from "../contracts/smartAccounts/proxy/PersonalAccountProxy.sol";
import {MintableERC20} from "../contracts/mock/MintableERC20.sol";
import {MyERC4626, IERC20} from "../contracts/mock/MyERC4626.sol";
import {MockUniswapV3Router} from "../contracts/mock/MockUniswapV3Router.sol";
import {UniswapV3} from "../contracts/smartAccounts/library/UniswapV3.sol";
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
import {IVaultsFacet} from "../contracts/userInterfaces/facets/IVaultsFacet.sol";
import {IPersonalAccountsFacet} from "../contracts/userInterfaces/facets/IPersonalAccountsFacet.sol";
import {ISwapFacet} from "../contracts/userInterfaces/facets/ISwapFacet.sol";
import {SwapFacet} from "../contracts/smartAccounts/facets/SwapFacet.sol";
import {ITimelockFacet} from "../contracts/userInterfaces/facets/ITimelockFacet.sol";
import {IITimelockFacet} from "../contracts/smartAccounts/interface/IITimelockFacet.sol";
import {XrplProviderWalletsFacet} from "../contracts/smartAccounts/facets/XrplProviderWalletsFacet.sol";


// solhint-disable-next-line max-states-count
contract MasterAccountControllerTest is Test, FacetsDeploy {
    address private constant SINGLETON_FACTORY = 0xce0042B868300000d44A59004Da54A005ffdcf9f;
    bytes21 private constant FLR_USD_FEED_ID = 0x01464c522f55534400000000000000000000000000;
    bytes21 private constant USDT_USD_FEED_ID = 0x01555344542f555344000000000000000000000000;
    bytes21 private constant XRP_USD_FEED_ID = 0x015852502f55534400000000000000000000000000;

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
    MyERC4626 private firelightVault;
    MyERC4626 private upshiftVault;
    MintableERC20 private fxrp;
    string private xrplProviderWallet;
    bytes32 private xrplProviderWalletHash;
    bytes32 private sourceId;
    uint256 private paymentProofValidityDurationSeconds;
    uint256 private defaultInstructionFee;
    MockUniswapV3Router private uniswapV3Router;
    MintableERC20 private usdt0;
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
    MintableERC20 private wNatMock;
    address private ftsoV2Mock;

    function setUp() public {
        mockFactory = new MockSingletonFactory();
        vm.etch(SINGLETON_FACTORY, address(mockFactory).code);

        governance = makeAddr("governance");
        initialOwner = makeAddr("initialOwner");
        executor = makeAddr("executor");
        fxrp = new MintableERC20("F-XRPL", "fXRP", 6);
        firelightVault = new MyERC4626(
            IERC20(address(fxrp)),
            "Firelight Vault",
            "FV"
        );
        firelightVault.setLagDuration(1 days);
        upshiftVault = new MyERC4626(
            IERC20(address(fxrp)),
            "Upshift Vault",
            "UV"
        );
        upshiftVault.setLagDuration(1 days);
        xrplProviderWallet = "rXrplProviderWallet";
        xrplProviderWalletHash = keccak256(bytes(xrplProviderWallet));
        contractRegistryMock = 0xaD67FE66660Fb8dFE9d6b1b4240d8650e30F6019;
        fdcVerificationMock = makeAddr("FDCVerificationMock");
        wNatMock = new MintableERC20("WFLR", "WFLR", 18);
        ftsoV2Mock = makeAddr("FtsoV2Mock");
        executorFee = 100;
        sourceId = bytes32("testXRP");
        paymentProofValidityDurationSeconds = 1 days;
        defaultInstructionFee = 1000000; // 1 XRP
        uniswapV3Router = new MockUniswapV3Router();
        wNatUsdt0PoolFeeTierPPM = 3000; // 0.3%
        usdt0 = new MintableERC20("USDT0", "USDT0", 6);
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
                sourceId,
                paymentProofValidityDurationSeconds,
                defaultInstructionFee,
                personalAccountImplementation
            )
        );

        // transfer ownership to governance
        vm.prank(initialOwner);
        masterAccountController.transferOwnership(governance);

        _mockGetContractAddressByHash("FdcVerification", fdcVerificationMock);
        _mockGetContractAddressByHash("AssetManagerFXRP", assetManagerFxrpMock);
        _mockGetContractAddressByHash("WNat", address(wNatMock));
        _mockGetContractAddressByHash("FtsoV2", ftsoV2Mock);
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
        agentVaultIds[0] = 1;
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
        vaultIds[0] = 1;
        vaultIds[1] = 4;
        vaultAddresses[0] = address(firelightVault);
        vaultAddresses[1] = address(upshiftVault);
        vaultTypes[0] = 1;
        vaultTypes[1] = 2;
        vm.prank(governance);
        masterAccountController.addVaults(vaultIds, vaultAddresses, vaultTypes);

        xrplAddress1 = "xrplAddress1";
        xrplAddress2 = "xrplAddress2";
    }

    function testInitialization() public {
        assertEq(
            masterAccountController.owner(),
            governance
        );

        (address payable returnedExecutor, uint256 returnedExecutorFee) =
            masterAccountController.getExecutorInfo();
        assertEq(
            returnedExecutor,
            executor
        );
        assertEq(
            returnedExecutorFee,
            executorFee
        );
        assertEq(
            masterAccountController.getSourceId(),
            sourceId
        );
        assertEq(
            masterAccountController.getPaymentProofValidityDurationSeconds(),
            paymentProofValidityDurationSeconds
        );
        assertEq(
            masterAccountController.getDefaultInstructionFee(),
            defaultInstructionFee
        );
        assertEq(
            masterAccountController.implementation(),
            personalAccountImplementation
        );
    }

    function testInitializationRevertInvalidExecutor() public {
        MasterAccountControllerInit masterAccountControllerInit = new MasterAccountControllerInit();
        vm.prank(governance);
        vm.expectRevert(
            abi.encodeWithSelector(
                IExecutorsFacet.InvalidExecutor.selector
            )
        );
        masterAccountController.diamondCut(
            new IDiamond.FacetCut[](0),
            address(masterAccountControllerInit),
            abi.encodeWithSelector(
                MasterAccountControllerInit.init.selector,
                payable(address(0)),
                executorFee,
                sourceId,
                paymentProofValidityDurationSeconds,
                defaultInstructionFee,
                personalAccountImplementation
            )
        );
    }

    function testInitializationRevertInvalidExecutorFee() public {
        MasterAccountControllerInit masterAccountControllerInit = new MasterAccountControllerInit();
        vm.prank(governance);
        vm.expectRevert(
            abi.encodeWithSelector(
                IExecutorsFacet.InvalidExecutorFee.selector
            )
        );
        masterAccountController.diamondCut(
            new IDiamond.FacetCut[](0),
            address(masterAccountControllerInit),
            abi.encodeWithSelector(
                MasterAccountControllerInit.init.selector,
                payable(executor),
                0,
                sourceId,
                paymentProofValidityDurationSeconds,
                defaultInstructionFee,
                personalAccountImplementation
            )
        );
    }

    function testInitializationRevertInvalidPaymentProofValidityDuration() public {
        MasterAccountControllerInit masterAccountControllerInit = new MasterAccountControllerInit();
        vm.prank(governance);
        vm.expectRevert(
            abi.encodeWithSelector(
                IPaymentProofsFacet.InvalidPaymentProofValidityDuration.selector
            )
        );
        masterAccountController.diamondCut(
            new IDiamond.FacetCut[](0),
            address(masterAccountControllerInit),
            abi.encodeWithSelector(
                MasterAccountControllerInit.init.selector,
                payable(executor),
                executorFee,
                sourceId,
                0,
                defaultInstructionFee,
                personalAccountImplementation
            )
        );
    }

    function testInitializationRevertInvalidPersonalAccountImplementation(address _implementation) public {
        vm.assume(_implementation.code.length == 0);
        MasterAccountControllerInit masterAccountControllerInit = new MasterAccountControllerInit();
        vm.prank(governance);
        vm.expectRevert(
            abi.encodeWithSelector(
                IPersonalAccountsFacet.InvalidPersonalAccountImplementation.selector
            )
        );
        masterAccountController.diamondCut(
            new IDiamond.FacetCut[](0),
            address(masterAccountControllerInit),
            abi.encodeWithSelector(
                MasterAccountControllerInit.init.selector,
                payable(executor),
                executorFee,
                sourceId,
                paymentProofValidityDurationSeconds,
                defaultInstructionFee,
                _implementation
            )
        );
    }

    function testPersonalAccountUpgrades() public {
        IPayment.Proof memory proof;
        proof.data.sourceId = sourceId;
        proof.data.responseBody.receivingAddressHash = xrplProviderWalletHash;
        proof.data.responseBody.sourceAddressHash = keccak256(bytes(xrplAddress1));
        proof.data.requestBody.transactionId = bytes32("tx1");
        proof.data.responseBody.receivedAmount = 1000000;
        proof.data.responseBody.standardPaymentReference = _encodeFirelightPaymentReference(1, 0, 12345, 1, 1);
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
            address(firelightVault),
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

    function testRemoveCuts() public {
        // get current facet cuts
        address[] memory currentCuts = masterAccountController.facetAddresses();
        assertEq(
            currentCuts.length,
            3 + 10 // base facets + smart accounts facets
        );

        IDiamond.FacetCut[] memory removeCuts = new IDiamond.FacetCut[](2);
        removeCuts[0] = _buildFacetCut(address(0), "XrplProviderWalletsFacet", IDiamond.FacetCutAction.Remove);
        removeCuts[1] = _buildFacetCut(address(0), "SwapFacet", IDiamond.FacetCutAction.Remove);
        vm.prank(governance);
        masterAccountController.diamondCut(
            removeCuts,
            address(0),
            ""
        );
        // check facets were removed
        address[] memory updatedCuts = masterAccountController.facetAddresses();
        assertEq(
            updatedCuts.length,
            currentCuts.length - 2
        );
        for (uint256 i = 0; i < updatedCuts.length; i++) {
            assertNotEq(
                updatedCuts[i],
                currentCuts[9] // SwapFacet
            );
            assertNotEq(
                updatedCuts[i],
                currentCuts[12] // XrplProviderWalletsFacet
            );
        }
    }

    function testReplaceCuts() public {
        // get current facet cuts
        address[] memory currentCuts = masterAccountController.facetAddresses();
        assertEq(
            currentCuts.length,
            3 + 10 // base facets + smart accounts facets
        );

        // replace facets
        IDiamond.FacetCut[] memory updateCuts = new IDiamond.FacetCut[](2);
        address newSwapFacetAddress = address(new SwapFacet());
        updateCuts[0] = _buildFacetCut(
            newSwapFacetAddress, "SwapFacet", IDiamond.FacetCutAction.Replace
        );
        address newXrplProviderWalletsFacetAddress = address(new XrplProviderWalletsFacet());
        updateCuts[1] = _buildFacetCut(
            newXrplProviderWalletsFacetAddress, "XrplProviderWalletsFacet", IDiamond.FacetCutAction.Replace
        );
        vm.prank(governance);
        masterAccountController.diamondCut(
            updateCuts,
            address(0),
            ""
        );
        // check facets were replaced
        address[] memory finalCuts = masterAccountController.facetAddresses();
        assertEq(
            finalCuts.length,
            currentCuts.length
        );
        assertEq(
            finalCuts[9], // SwapFacet
            newSwapFacetAddress
        );
        assertEq(
            finalCuts[12], // XrplProviderWalletsFacet
            newXrplProviderWalletsFacetAddress
        );
    }

    function testDiamondOnlyOwner() public {
        address notOwner = makeAddr("notOwner");
        IDiamond.FacetCut[] memory removeCuts = new IDiamond.FacetCut[](1);
        removeCuts[0] = _buildFacetCut(address(0), "XrplProviderWalletsFacet", IDiamond.FacetCutAction.Remove);
        vm.prank(notOwner);
        vm.expectRevert(
            abi.encodeWithSelector(
                NotContractOwner.selector,
                notOwner,
                governance
            )
        );
        masterAccountController.diamondCut(
            removeCuts,
            address(0),
            ""
        );
    }

    function testDiamondTransferOwnership() public {
        assertEq(
            masterAccountController.owner(),
            governance
        );
        address newOwner = makeAddr("newOwner");
        vm.prank(governance);
        masterAccountController.transferOwnership(newOwner);
        assertEq(
            masterAccountController.owner(),
            newOwner
        );

        // old owner can no longer perform owner actions
        IDiamond.FacetCut[] memory removeCuts = new IDiamond.FacetCut[](1);
        removeCuts[0] = _buildFacetCut(address(0), "XrplProviderWalletsFacet", IDiamond.FacetCutAction.Remove);
        vm.prank(governance);
        vm.expectRevert(
            abi.encodeWithSelector(
                NotContractOwner.selector,
                governance,
                newOwner
            )
        );
        masterAccountController.diamondCut(
            removeCuts,
            address(0),
            ""
        );

        // new owner can perform owner actions
        vm.prank(newOwner);
        masterAccountController.diamondCut(
            removeCuts,
            address(0),
            ""
        );
    }

    // reserveCollateral tests
    function testReserveCollateralRevertInvalidInstruction() public {
        bytes32 paymentReference = _encodeFxrpPaymentReference(9, 0, 1000, 1);
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
        bytes32 paymentReference = _encodeFxrpPaymentReference(0, 0, 1000, 1);
        bytes32 transactionId = bytes32(0);
        vm.expectRevert(IInstructionsFacet.InvalidTransactionId.selector);
        masterAccountController.reserveCollateral(
            xrplAddress1,
            paymentReference,
            transactionId
        );
    }

    function testReserveCollateralRevertInvalidAgentVault() public {
        bytes32 paymentReference = _encodeFxrpPaymentReference(0, 0, 1000, 2); // agent vault 2 does not exist
        bytes32 transactionId = bytes32("tx1");
        vm.expectRevert(
            abi.encodeWithSelector(
                IAgentVaultsFacet.InvalidAgentVault.selector,
                2
            )
        );
        masterAccountController.reserveCollateral(
            xrplAddress1,
            paymentReference,
            transactionId
        );
    }

    function testReserveCollateralRevertValueZero() public {
        bytes32 paymentReference = _encodeFxrpPaymentReference(0, 0, 0, 1); // value 0
        bytes32 transactionId = bytes32("tx1");
        vm.expectRevert(IInstructionsFacet.ValueZero.selector);
        masterAccountController.reserveCollateral(
            xrplAddress1,
            paymentReference,
            transactionId
        );
    }

    function testReserveCollateralRevertAgentVaultIdZero() public {
        bytes32 paymentReference = _encodeFxrpPaymentReference(0, 0, 1000, 0);
        bytes32 transactionId = bytes32("tx1");
        vm.expectRevert(
            abi.encodeWithSelector(
                IAgentVaultsFacet.InvalidAgentVault.selector,
                0
            )
        );
        masterAccountController.reserveCollateral(
            xrplAddress1,
            paymentReference,
            transactionId
        );
    }

    function testReserveCollateral() public {
        uint16 lots = 2;
        bytes32 paymentReference = _encodeFxrpPaymentReference(0, 0, lots, 1);
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
        bytes32 paymentReference = _encodeFxrpPaymentReference(9, 0, 1000, 1);
        IPayment.Proof memory proof;
        proof.data.sourceId = sourceId;
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
        bytes32 paymentReference = _encodeFirelightPaymentReference(0, 0, 1000, 1, 1);
        IPayment.Proof memory proof;
        proof.data.sourceId = sourceId;
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
        bytes32 paymentReference = _encodeFirelightPaymentReference(0, 0, 2, 1, 1);
        address predictedAddress1 = masterAccountController.getPersonalAccount(xrplAddress1);
        _mockCollateralReservationInfo(CollateralReservationInfo.Status.ACTIVE, predictedAddress1, 0);
        bytes32 transactionId = bytes32("tx1");
        testReserveCollateral();
        IPayment.Proof memory proof;
        proof.data.sourceId = sourceId;
        proof.data.responseBody.standardPaymentReference = paymentReference;
        proof.data.requestBody.transactionId = transactionId;

        vm.expectRevert(IInstructionsFacet.MintingNotCompleted.selector);
        masterAccountController.executeDepositAfterMinting(22, proof, xrplAddress1);
    }

    function testExecuteDepositAfterMintingRevertInvalidMinter() public {
        bytes32 paymentReference = _encodeFirelightPaymentReference(0, 0, 2, 1, 1);
        _mockCollateralReservationInfo(CollateralReservationInfo.Status.SUCCESSFUL, makeAddr("wrongMinter"), 0);
        bytes32 transactionId = bytes32("tx1");
        testReserveCollateral();
        IPayment.Proof memory proof;
        proof.data.sourceId = sourceId;
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
        bytes32 paymentReference = _encodeFirelightPaymentReference(0, 0, 2, 1, 1);
        address predictedAddress1 = masterAccountController.getPersonalAccount(xrplAddress1);
        _mockCollateralReservationInfo(CollateralReservationInfo.Status.SUCCESSFUL, predictedAddress1, 0);
        bytes32 transactionId = bytes32("tx1");
        testReserveCollateral();
        IPayment.Proof memory proof;
        proof.data.sourceId = sourceId;
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

    function testExecuteDepositAfterMintingRevertVaultIdZero() public {
        uint16 lots = 2;
        uint256 lotSize = 100;
        bytes32 paymentReference = _encodeFirelightPaymentReference(0, 0, lots, 1, 0);
        address predictedAddress1 = masterAccountController.getPersonalAccount(xrplAddress1);
        _mockCollateralReservationInfo(CollateralReservationInfo.Status.SUCCESSFUL, predictedAddress1, lots * lotSize);
        bytes32 transactionId = bytes32("tx1");
        testReserveCollateral();
        IPayment.Proof memory proof;
        proof.data.sourceId = sourceId;
        proof.data.responseBody.standardPaymentReference = paymentReference;
        proof.data.requestBody.transactionId = transactionId;
        proof.data.responseBody.sourceAddressHash = keccak256(bytes(xrplAddress1));
        proof.data.responseBody.receivingAddressHash = xrplProviderWalletHash;
        proof.data.requestBody.transactionId = transactionId;
        _mockVerifyPayment(true);
        _mockLotSize(lotSize);

        vm.expectRevert(
            abi.encodeWithSelector(
                IVaultsFacet.InvalidVaultId.selector,
                0
            )
        );
        masterAccountController.executeDepositAfterMinting(22, proof, xrplAddress1);
    }

    function testExecuteDepositAfterMinting() public {
        uint16 lots = 2;
        uint256 lotSize = 100;
        bytes32 paymentReference = _encodeFirelightPaymentReference(0, 0, lots, 1, 1);
        address predictedAddress1 = masterAccountController.getPersonalAccount(xrplAddress1);
        _mockCollateralReservationInfo(
            CollateralReservationInfo.Status.SUCCESSFUL,
            predictedAddress1,
            lots * lotSize
        );
        bytes32 transactionId = bytes32("tx1");
        testReserveCollateral();
        IPayment.Proof memory proof;
        proof.data.sourceId = sourceId;
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
            address(firelightVault),
            lots * lotSize,
            lots * lotSize // assuming 1:1 initial share:asset for simplicity
        );
        vm.expectEmit();
        emit IInstructionsFacet.InstructionExecuted(
            predictedAddress1,
            transactionId,
            paymentReference,
            xrplAddress1,
            _getInstructionId(1, 0)
        );
        masterAccountController.executeDepositAfterMinting(22, proof, xrplAddress1);

         // check that fxrp were deposited into the vault
        assertEq(
            firelightVault.balanceOf(predictedAddress1),
            lots * lotSize
        );
        assertEq(
            fxrp.balanceOf(address(firelightVault)),
            lots * lotSize
        );
        assertEq(
            fxrp.balanceOf(predictedAddress1),
            0
        );
        assertEq(
            masterAccountController.isTransactionIdUsed(proof.data.requestBody.transactionId),
            true
        );
    }

    function testExecuteDepositAfterMintingRevertTransactionAlreadyExecuted() public {
        testExecuteDepositAfterMinting();

        // make a new collateral reservation
        uint16 lots = 2;
        bytes32 paymentReference = _encodeFirelightPaymentReference(0, 0, lots, 1, 1);
        bytes32 transactionId = bytes32("tx1");

        _mockCollateralReservationFee(lots, 123);
        _mockReserveCollateral(23);

        address personalAccountAddress = masterAccountController.getPersonalAccount(xrplAddress1);

        vm.expectEmit();
        emit IInstructionsFacet.CollateralReserved(
            personalAccountAddress,
            transactionId,
            paymentReference,
            xrplAddress1,
            23,
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
        assertEq(collateralReservationId, 23);

        assertEq(
            masterAccountController.getTransactionIdForCollateralReservation(collateralReservationId),
            transactionId
        );

        // attempt to execute deposit after minting again with the same transaction id
        IPayment.Proof memory proof;
        proof.data.sourceId = sourceId;
        proof.data.responseBody.standardPaymentReference = paymentReference;
        proof.data.responseBody.sourceAddressHash = keccak256(bytes(xrplAddress1));
        proof.data.responseBody.receivingAddressHash = xrplProviderWalletHash;
        proof.data.requestBody.transactionId = transactionId;

        vm.expectRevert(IInstructionsFacet.TransactionAlreadyExecuted.selector);
        masterAccountController.executeDepositAfterMinting(23, proof, xrplAddress1);
    }

    function testExecuteInstructionRevertInvalidPaymentAmount() public {
        bytes32 paymentReference = _encodeFxrpPaymentReference(0, 0, 2, 1);
        IPayment.Proof memory proof;
        proof.data.sourceId = sourceId;
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

    function testExecuteInstructionRevertInvalidSourceId() public {
        bytes32 paymentReference = _encodeFxrpPaymentReference(0, 0, 2, 1);
        IPayment.Proof memory proof;
        proof.data.sourceId = bytes32("invalidSourceId");
        proof.data.responseBody.standardPaymentReference = paymentReference;
        proof.data.responseBody.receivedAmount = int256(2 * defaultInstructionFee);

        vm.expectRevert(IPaymentProofsFacet.InvalidSourceId.selector);
        masterAccountController.executeInstruction(proof, xrplAddress1);
    }

    function testExecuteInstructionRevertInvalidTransactionStatus() public {
        bytes32 paymentReference = _encodeFxrpPaymentReference(0, 0, 2, 1);
        IPayment.Proof memory proof;
        proof.data.sourceId = sourceId;
        proof.data.responseBody.standardPaymentReference = paymentReference;
        proof.data.responseBody.receivedAmount = int256(2 * defaultInstructionFee);
        proof.data.responseBody.status = 1;

        vm.expectRevert(IPaymentProofsFacet.InvalidTransactionStatus.selector);
        masterAccountController.executeInstruction(proof, xrplAddress1);
    }

    function testExecuteInstructionRevertPaymentProofExpired() public {
        bytes32 paymentReference = _encodeFxrpPaymentReference(0, 0, 2, 1);
        IPayment.Proof memory proof;
        proof.data.sourceId = sourceId;
        proof.data.responseBody.standardPaymentReference = paymentReference;
        proof.data.responseBody.receivedAmount = int256(2 * defaultInstructionFee);
        proof.data.responseBody.status = 0;
        proof.data.responseBody.blockTimestamp = 1234;
        vm.warp(1234 + paymentProofValidityDurationSeconds + 1);

        vm.expectRevert(IPaymentProofsFacet.PaymentProofExpired.selector);
        masterAccountController.executeInstruction(proof, xrplAddress1);
    }

    function testExecuteInstructionRevertMismatchingSourceAndXrplAddr() public {
        bytes32 paymentReference = _encodeFxrpPaymentReference(0, 0, 2, 1);
        IPayment.Proof memory proof;
        proof.data.sourceId = sourceId;
        proof.data.responseBody.standardPaymentReference = paymentReference;
        proof.data.responseBody.receivedAmount = int256(2 * defaultInstructionFee);
        proof.data.responseBody.status = 0;
        proof.data.responseBody.blockTimestamp = uint64(block.timestamp);
        proof.data.responseBody.sourceAddressHash = keccak256(bytes("differentXrplAddress"));

        vm.expectRevert(IPaymentProofsFacet.MismatchingSourceAndXrplAddr.selector);
        masterAccountController.executeInstruction(proof, xrplAddress1);
    }

    function testExecuteInstructionInvalidReceivingAddressHash() public {
        bytes32 paymentReference = _encodeFxrpPaymentReference(0, 0, 2, 1);
        IPayment.Proof memory proof;
        proof.data.sourceId = sourceId;
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
        bytes32 paymentReference = _encodeFirelightPaymentReference(1, 0, 2, 1, 1);
        IPayment.Proof memory proof;
        proof.data.sourceId = sourceId;
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
        bytes32 paymentReference = _encodeFirelightPaymentReference(1, 0, 2, 1, 1);
        IPayment.Proof memory proof;
        proof.data.sourceId = sourceId;
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
        bytes32 paymentReference = _encodeFirelightPaymentReference(1, 0, 123, 1, 1);
        IPayment.Proof memory proof;
        proof.data.sourceId = sourceId;
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
            address(firelightVault),
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
        // check that fxrp were deposited into the vault
        assertEq(
            firelightVault.balanceOf(personalAccountAddr),
            123
        );
        assertEq(
            fxrp.balanceOf(address(firelightVault)),
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
        bytes32 paymentReference = _encodeUpshiftPaymentReference(1, 0, 123, 0, 4);
        IPayment.Proof memory proof;
        proof.data.sourceId = sourceId;
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
            address(upshiftVault),
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
        // check that fxrp were deposited into the vault
        assertEq(
            upshiftVault.balanceOf(personalAccountAddr),
            123
        );
        assertEq(
            fxrp.balanceOf(address(upshiftVault)),
            123
        );
        assertEq(
            fxrp.balanceOf(personalAccountAddr),
            0
        );
        assertEq(
            masterAccountController.isTransactionIdUsed(proof.data.requestBody.transactionId),
            true
        );
    }

    function testExecuteInstructionTransfer() public {
        // mint some fXRP to the personal account
        address personalAccountAddr = masterAccountController.getPersonalAccount(xrplAddress1);
        fxrp.mint(personalAccountAddr, 123);
        address recipient = makeAddr("recipient");
        bytes32 paymentReference = _encodeFxrpTransferPaymentReference(0, 123, recipient);
        IPayment.Proof memory proof;
        proof.data.sourceId = sourceId;
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
        proof.data.sourceId = sourceId;
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
        bytes32 paymentReference = _encodeFxrpPaymentReference(2, 0, 3, 1);
        uint256 lotSize = 100;
        address personalAccountAddr = masterAccountController.getPersonalAccount(xrplAddress1);
        IPayment.Proof memory proof;
        proof.data.sourceId = sourceId;
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
            firelightVault.balanceOf(personalAccountAddr),
            123
        );
        assertEq(
            fxrp.balanceOf(personalAccountAddr),
            0
        );
        bytes32 paymentReference = _encodeFirelightPaymentReference(2, 0, 100, 1, 1);
        IPayment.Proof memory proof;
        proof.data.sourceId = sourceId;
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
            address(firelightVault),
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
            firelightVault.balanceOf(personalAccountAddr),
            23 // 123 - 100 redeemed
        );
        assertEq(
            firelightVault.pendingWithdrawAssets(personalAccountAddr, 1),
            100
        );
    }

    function testExecuteInstructionClaimWithdraw() public {
        uint16 period = 1;
        address personalAccountAddr = masterAccountController.getPersonalAccount(xrplAddress1);
        testExecuteInstructionRedeem();
        assertEq(
            firelightVault.pendingWithdrawAssets(personalAccountAddr, period),
            100
        );
        assertEq(
            fxrp.balanceOf(personalAccountAddr),
            0
        );

        // move to the claimable period (to period 3)
        vm.warp(block.timestamp + 2 days);

        bytes32 paymentReference = _encodeFirelightPaymentReference(3, 0, period, 1, 1);
        IPayment.Proof memory proof;
        proof.data.sourceId = sourceId;
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
            address(firelightVault),
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
            firelightVault.pendingWithdrawAssets(personalAccountAddr, period),
            0
        );
        assertEq(
            fxrp.balanceOf(personalAccountAddr),
            100
        );
    }

    function testExecuteInstructionRequestRedeem() public {
        // deposit 123 fXRP to the personal account
        testExecuteInstructionDeposit2();
        address personalAccountAddr = masterAccountController.getPersonalAccount(xrplAddress1);
        assertEq(
            upshiftVault.balanceOf(personalAccountAddr),
            123
        );
        assertEq(
            fxrp.balanceOf(personalAccountAddr),
            0
        );
        bytes32 paymentReference = _encodeUpshiftPaymentReference(2, 0, 100, 1, 4);
        IPayment.Proof memory proof;
        proof.data.sourceId = sourceId;
        proof.data.responseBody.standardPaymentReference = paymentReference;
        proof.data.responseBody.receivedAmount = int256(defaultInstructionFee);
        proof.data.responseBody.status = 0;
        proof.data.responseBody.blockTimestamp = uint64(block.timestamp);
        proof.data.responseBody.sourceAddressHash = keccak256(bytes(xrplAddress1));
        proof.data.responseBody.receivingAddressHash = xrplProviderWalletHash;
        proof.data.requestBody.transactionId = bytes32("tx2");
        _mockVerifyPayment(true);

        (uint256 year, uint256 month, uint256 day) =
            DateUtils.timestampToDate(block.timestamp + upshiftVault.lagDuration());
        uint256 claimableEpoch = DateUtils.timestampFromDateTime(year, month, day, 0, 0, 0);
        uint256 period = DateUtils.timestampFromDateTime(year, month, day, 0, 0, 0) / 1 days;
        vm.expectEmit();
        emit IInstructionsFacet.RedeemRequested(
            personalAccountAddr,
            address(upshiftVault),
            100,
            claimableEpoch,
            year,
            month,
            day
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
            upshiftVault.balanceOf(personalAccountAddr),
            23 // 123 - 100 redeemed
        );
        assertEq(
            upshiftVault.pendingWithdrawAssets(personalAccountAddr, period),
            100
        );
    }

    function testExecuteInstructionClaim() public {
        address personalAccountAddr = masterAccountController.getPersonalAccount(xrplAddress1);
        testExecuteInstructionRequestRedeem();
        vm.warp(block.timestamp + 1 days); // move to next epoch
        uint256 claimableEpoch = 1;
        assertEq(
            upshiftVault.pendingWithdrawAssets(personalAccountAddr, claimableEpoch),
            100
        );
        assertEq(
            fxrp.balanceOf(personalAccountAddr),
            0
        );

        bytes32 paymentReference = _encodeUpshiftPaymentReference(3, 0, 19700102, 1, 4);
        IPayment.Proof memory proof;
        proof.data.sourceId = sourceId;
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
            address(upshiftVault),
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
            upshiftVault.pendingWithdrawAssets(personalAccountAddr, claimableEpoch),
            0
        );
        assertEq(
            fxrp.balanceOf(personalAccountAddr),
            100
        );
    }

    function testExecuteInstructionRevertInvalidInstruction() public {
        bytes32 paymentReference = _encodeUpshiftPaymentReference(9, 0, 20250913, 1, 4);
        IPayment.Proof memory proof;
        proof.data.sourceId = sourceId;
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
        vm.expectEmit();
        emit IExecutorsFacet.ExecutorSet(_executor);
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

    function testGetSourceId() public {
        bytes32 returnedSourceId = masterAccountController.getSourceId();
        assertEq(returnedSourceId, sourceId);
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
        bytes32 paymentReference = _encodeFirelightPaymentReference(1, 0, 10, 1, 1);
        IPayment.Proof memory proof;
        proof.data.sourceId = sourceId;
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

    function testRemoveInstructionFeesRevertInstructionFeeNotSet() public {
        uint256[] memory instructionIds = new uint256[](1);
        instructionIds[0] = 11; // not set
        vm.prank(governance);
        vm.expectRevert(
            abi.encodeWithSelector(
                IInstructionFeesFacet.InstructionFeeNotSet.selector,
                instructionIds[0]
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
        bytes32 paymentReference = _encodeFirelightPaymentReference(1, 0, 123, 1, 1);
        IPayment.Proof memory proof;
        proof.data.sourceId = sourceId;
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

    function testRemoveXrplProviderWalletsRevertOnlyOwner() public {
        // remove existing wallet
        string[] memory walletsToRemove = new string[](1);
        walletsToRemove[0] = xrplProviderWallet;
        vm.expectRevert(
            abi.encodeWithSelector(
                NotContractOwner.selector,
                address(this),
                governance
            )
        );
        masterAccountController.removeXrplProviderWallets(walletsToRemove);
    }

    function testRemoveXrplProviderWalletsRevertInvalidXrplProviderWallet() public {
        // remove existing wallet
        string[] memory walletsToRemove = new string[](1);
        walletsToRemove[0] = "nonExistingWallet";
        vm.prank(governance);
        vm.expectRevert(
            abi.encodeWithSelector(
                IXrplProviderWalletsFacet.InvalidXrplProviderWallet.selector,
                walletsToRemove[0]
            )
        );
        masterAccountController.removeXrplProviderWallets(walletsToRemove);
    }

    function testAddAgentVaults() public {
        uint256[] memory ids = new uint256[](2);
        address[] memory addresses = new address[](2);
        ids[0] = 2;
        addresses[0] = makeAddr("agentVault2");
        ids[1] = 3;
        addresses[1] = makeAddr("agentVault3");

        agentInfo.status = AgentInfo.Status.NORMAL;
        _mockGetAgentInfo(addresses[0], agentInfo);
        _mockGetAgentInfo(addresses[1], agentInfo);

        vm.prank(governance);
        vm.expectEmit();
        emit IAgentVaultsFacet.AgentVaultAdded(2, addresses[0]);
        vm.expectEmit();
        emit IAgentVaultsFacet.AgentVaultAdded(3, addresses[1]);
        masterAccountController.addAgentVaults(ids, addresses);

        (uint256[] memory returnedIds, address[] memory addrs) = masterAccountController.getAgentVaults();
        assertEq(returnedIds.length, 3);
        assertEq(returnedIds[0], 1);
        assertEq(returnedIds[1], 2);
        assertEq(returnedIds[2], 3);
        assertEq(addrs[0], agent);
        assertEq(addrs[1], addresses[0]);
        assertEq(addrs[2], addresses[1]);
    }

    function testAddAgentVaultsRevertOnlyOwner() public {
        uint256[] memory ids = new uint256[](1);
        address[] memory addresses = new address[](1);
        ids[0] = 2;
        addresses[0] = makeAddr("agentVault2");

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
        ids[0] = 2;
        ids[1] = 3;
        addresses[0] = makeAddr("agentVault2");

        vm.prank(governance);
        vm.expectRevert(IAgentVaultsFacet.AgentsVaultsLengthsMismatch.selector);
        masterAccountController.addAgentVaults(ids, addresses);
    }

    function testAddAgentVaultsRevertAgentVaultIdZero() public {
        uint256[] memory ids = new uint256[](1);
        address[] memory addresses = new address[](1);
        ids[0] = 0; // invalid
        addresses[0] = makeAddr("agentVault2");

        vm.prank(governance);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAgentVaultsFacet.AgentVaultIdZero.selector,
                0
            )
        );
        masterAccountController.addAgentVaults(ids, addresses);
    }

    function testAddAgentVaultsRevertAgentVaultIdAlreadyAdded() public {
        uint256[] memory ids = new uint256[](1);
        address[] memory addresses = new address[](1);
        ids[0] = 2;
        addresses[0] = makeAddr("agentVault2");

        agentInfo.status = AgentInfo.Status.NORMAL;
        _mockGetAgentInfo(addresses[0], agentInfo);
        vm.prank(governance);
        masterAccountController.addAgentVaults(ids, addresses);

        // try to add again
        vm.prank(governance);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAgentVaultsFacet.AgentVaultIdAlreadyAdded.selector,
                2
            )
        );
        masterAccountController.addAgentVaults(ids, addresses);
    }

    function testAddAgentVaultsRevertAgentVaultAddressZero() public {
        uint256[] memory ids = new uint256[](2);
        address[] memory addresses = new address[](2);
        ids[0] = 2;
        ids[1] = 3;
        addresses[0] = makeAddr("agentVault2");
        addresses[1] = address(0); // invalid

        agentInfo.status = AgentInfo.Status.NORMAL;
        _mockGetAgentInfo(addresses[0], agentInfo);

        vm.prank(governance);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAgentVaultsFacet.AgentVaultAddressZero.selector,
                1
            )
        );
        masterAccountController.addAgentVaults(ids, addresses);
    }

    function testAddAgentVaultsRevertAgentVaultAddressAlreadyAdded() public {
        uint256[] memory ids = new uint256[](1);
        address[] memory addresses = new address[](1);
        ids[0] = 2;
        addresses[0] = agent; // already added

        agentInfo.status = AgentInfo.Status.NORMAL;
        _mockGetAgentInfo(addresses[0], agentInfo);

        vm.prank(governance);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAgentVaultsFacet.AgentVaultAddressAlreadyAdded.selector,
                agent
            )
        );
        masterAccountController.addAgentVaults(ids, addresses);
    }

    function testAddAgentVaultsRevertAgentNotAvailable() public {
        uint256[] memory ids = new uint256[](2);
        address[] memory addresses = new address[](2);
        ids[0] = 2;
        ids[1] = 3;
        addresses[0] = makeAddr("agentVault2");
        addresses[1] = makeAddr("agentVault3");

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
        idsToRemove[0] = 1;
        vm.prank(governance);
        vm.expectEmit();
        emit IAgentVaultsFacet.AgentVaultRemoved(1, agent);
        masterAccountController.removeAgentVaults(idsToRemove);

        (returnedIds, addrs) = masterAccountController.getAgentVaults();
        assertEq(returnedIds.length, 2);
        assertEq(returnedIds[0], 3);
        assertEq(returnedIds[1], 2);
        assertEq(addrs[0], makeAddr("agentVault3"));
        assertEq(addrs[1], makeAddr("agentVault2"));
    }

    function testRemoveAgentVaultsRevertOnlyOwner() public {
        uint256[] memory idsToRemove = new uint256[](1);
        idsToRemove[0] = 1;
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
        idsToRemove[0] = 2;
        vm.prank(governance);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAgentVaultsFacet.InvalidAgentVault.selector,
                2
            )
        );
        masterAccountController.removeAgentVaults(idsToRemove);
    }

    function testAddVaults() public {
        uint256[] memory vaultIds = new uint256[](2);
        address[] memory vaultAddresses = new address[](2);
        uint8[] memory vaultTypes = new uint8[](2);
        vaultIds[0] = 2;
        vaultIds[1] = 3;
        vaultAddresses[0] = makeAddr("vault2");
        vaultAddresses[1] = makeAddr("vault3");
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
        assertEq(returnedIds[0], 1);
        assertEq(returnedIds[1], 4);
        assertEq(returnedIds[2], 2);
        assertEq(returnedIds[3], 3);
        assertEq(addrs[0], address(firelightVault));
        assertEq(addrs[1], address(upshiftVault));
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
        vaultIds[0] = 2;
        vaultAddresses[0] = makeAddr("vault2");
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

    function testAddVaultsRevertInvalidVaultType() public {
        uint256[] memory vaultIds = new uint256[](1);
        address[] memory vaultAddresses = new address[](1);
        uint8[] memory vaultTypes = new uint8[](1);
        vaultIds[0] = 2;
        vaultAddresses[0] = makeAddr("vault2");
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
        vaultIds[0] = 2;
        vaultAddresses[0] = makeAddr("vault2");
        vaultAddresses[1] = makeAddr("vault3");
        vaultTypes[0] = 1;

        vm.prank(governance);
        vm.expectRevert(IVaultsFacet.VaultsLengthsMismatch.selector);
        masterAccountController.addVaults(vaultIds, vaultAddresses, vaultTypes);
    }

    function testAddVaultsRevertLengthsMismatch2() public {
        uint256[] memory vaultIds = new uint256[](1);
        address[] memory vaultAddresses = new address[](1);
        uint8[] memory vaultTypes = new uint8[](2);
        vaultIds[0] = 2;
        vaultAddresses[0] = makeAddr("vault2");
        vaultTypes[0] = 1;
        vaultTypes[1] = 2;

        vm.prank(governance);
        vm.expectRevert(IVaultsFacet.VaultsLengthsMismatch.selector);
        masterAccountController.addVaults(vaultIds, vaultAddresses, vaultTypes);
    }

    function testAddVaultsRevertVaultIdZero() public {
        uint256[] memory vaultIds = new uint256[](1);
        address[] memory vaultAddresses = new address[](1);
        uint8[] memory vaultTypes = new uint8[](1);
        vaultIds[0] = 0; // invalid
        vaultAddresses[0] = makeAddr("vault2");
        vaultTypes[0] = 1;

        vm.prank(governance);
        vm.expectRevert(
            abi.encodeWithSelector(
                IVaultsFacet.VaultIdZero.selector,
                0
            )
        );
        masterAccountController.addVaults(vaultIds, vaultAddresses, vaultTypes);
    }

    function testAddVaultsRevertVaultIdAlreadyAdded() public {
        uint256[] memory vaultIds = new uint256[](1);
        address[] memory vaultAddresses = new address[](1);
        uint8[] memory vaultTypes = new uint8[](1);
        vaultIds[0] = 1; // already added
        vaultAddresses[0] = makeAddr("vault2");
        vaultTypes[0] = 1;

        vm.prank(governance);
        vm.expectRevert(
            abi.encodeWithSelector(
                IVaultsFacet.VaultIdAlreadyAdded.selector,
                1
            )
        );
        masterAccountController.addVaults(vaultIds, vaultAddresses, vaultTypes);
    }

    function testAddVaultsRevertVaultAddressZero() public {
        uint256[] memory vaultIds = new uint256[](1);
        address[] memory vaultAddresses = new address[](1);
        uint8[] memory vaultTypes = new uint8[](1);
        vaultIds[0] = 2;
        vaultAddresses[0] = address(0); // invalid
        vaultTypes[0] = 1;

        vm.prank(governance);
        vm.expectRevert(
            abi.encodeWithSelector(
                IVaultsFacet.VaultAddressZero.selector,
                0
            )
        );
        masterAccountController.addVaults(vaultIds, vaultAddresses, vaultTypes);
    }

    function testAddVaultsRevertVaultAddressAlreadyAdded() public {
        uint256[] memory vaultIds = new uint256[](1);
        address[] memory vaultAddresses = new address[](1);
        uint8[] memory vaultTypes = new uint8[](1);
        vaultIds[0] = 2;
        vaultAddresses[0] = address(upshiftVault); // already added
        vaultTypes[0] = 1;

        vm.prank(governance);
        vm.expectRevert(
            abi.encodeWithSelector(
                IVaultsFacet.VaultAddressAlreadyAdded.selector,
                vaultAddresses[0]
            )
        );
        masterAccountController.addVaults(vaultIds, vaultAddresses, vaultTypes);
    }

    function testSetPersonalAccountImplementation() public {
        assertEq(masterAccountController.implementation(), personalAccountImplementation);
        address newImplementation = address(new PersonalAccount());
        assertNotEq(newImplementation, personalAccountImplementation);
        vm.prank(governance);
        vm.expectEmit();
        emit IPersonalAccountsFacet.PersonalAccountImplementationSet(newImplementation);
        masterAccountController.setPersonalAccountImplementation(newImplementation);
        assertEq(masterAccountController.implementation(), newImplementation);
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
        vm.prank(governance);
        vm.expectEmit();
        emit ISwapFacet.SwapParamsSet(
            address(uniswapV3Router),
            address(usdt0),
            wNatUsdt0PoolFeeTierPPM,
            usdt0FXrpPoolFeeTierPPM,
            maxSlippagePPM,
            USDT_USD_FEED_ID,
            FLR_USD_FEED_ID
        );
        masterAccountController.setSwapParams(
            address(uniswapV3Router),
            address(usdt0),
            wNatUsdt0PoolFeeTierPPM,
            usdt0FXrpPoolFeeTierPPM,
            maxSlippagePPM,
            USDT_USD_FEED_ID,
            FLR_USD_FEED_ID
        );
        (
            address returnedRouter,
            address returnedUsdt0,
            uint24 returnedWnatUsdt0Fee,
            uint24 returnedUsdt0fxrpFee,
            uint24 returnedMaxSlippage,
            bytes21 returnedStableCoinUsdFeedId,
            bytes21 returnedWNatUsdFeedId
        ) = masterAccountController.getSwapParams();
        assertEq(returnedRouter, address(uniswapV3Router));
        assertEq(returnedUsdt0, address(usdt0));
        assertEq(returnedWnatUsdt0Fee, wNatUsdt0PoolFeeTierPPM);
        assertEq(returnedUsdt0fxrpFee, usdt0FXrpPoolFeeTierPPM);
        assertEq(returnedMaxSlippage, maxSlippagePPM);
        assertEq(returnedStableCoinUsdFeedId, USDT_USD_FEED_ID);
        assertEq(returnedWNatUsdFeedId, FLR_USD_FEED_ID);
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
            100,
            USDT_USD_FEED_ID,
            FLR_USD_FEED_ID
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
            100,
            USDT_USD_FEED_ID,
            FLR_USD_FEED_ID
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
            100,
            USDT_USD_FEED_ID,
            FLR_USD_FEED_ID
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
            100,
            USDT_USD_FEED_ID,
            FLR_USD_FEED_ID
        );
    }

    function testSwapParamsRevertInvalidStableCoin() public {
        vm.expectRevert(ISwapFacet.InvalidStableCoin.selector);
        vm.prank(governance);
        masterAccountController.setSwapParams(
            makeAddr("router"),
            address(0),
            500,
            3000,
            100,
            USDT_USD_FEED_ID,
            FLR_USD_FEED_ID
        );
    }

    function testSwapParamsRevertInvalidMaxSlippagePPM() public {
        vm.expectRevert(ISwapFacet.InvalidMaxSlippagePPM.selector);
        vm.prank(governance);
        masterAccountController.setSwapParams(
            makeAddr("router"),
            makeAddr("usdt0"),
            500,
            3000,
            1e6 + 1,
            USDT_USD_FEED_ID,
            FLR_USD_FEED_ID
        );
    }

    function testSwapParamsRevertInvalidFeedId() public {
        vm.expectRevert(ISwapFacet.InvalidFeedId.selector);
        vm.prank(governance);
        masterAccountController.setSwapParams(
            makeAddr("router"),
            makeAddr("usdt0"),
            500,
            3000,
            100,
            bytes21(0),
            FLR_USD_FEED_ID
        );

        vm.expectRevert(ISwapFacet.InvalidFeedId.selector);
        vm.prank(governance);
        masterAccountController.setSwapParams(
            makeAddr("router"),
            makeAddr("usdt0"),
            500,
            3000,
            100,
            USDT_USD_FEED_ID,
            bytes21(0)
        );
    }

    function testCreatePersonalAccountRevertPersonalAccountNotSuccessfullyDeployed() public {
        MockSingletonFactoryNoDeploy mockFactoryNoDeploy = new MockSingletonFactoryNoDeploy();
        vm.etch(SINGLETON_FACTORY, address(mockFactoryNoDeploy).code);

        address personalAccountAddr = masterAccountController.getPersonalAccount(xrplAddress1);
        fxrp.mint(personalAccountAddr, 123);
        assertEq(fxrp.balanceOf(personalAccountAddr), 123);
        bytes32 paymentReference = _encodeFirelightPaymentReference(1, 0, 123, 1, 1);
        IPayment.Proof memory proof;
        proof.data.sourceId = sourceId;
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
        bytes32 paymentReference = _encodeFirelightPaymentReference(1, 0, 123, 1, 2);
        IPayment.Proof memory proof;
        proof.data.sourceId = sourceId;
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
                2
            )
        );
        masterAccountController.executeInstruction(proof, xrplAddress1);
    }

    function testExecuteInstructionRevertInvalidInstructionType() public {
        // use upshift vault for firelight instruction type
        bytes32 paymentReference = _encodeFirelightPaymentReference(1, 0, 123, 1, 4);
        IPayment.Proof memory proof;
        proof.data.sourceId = sourceId;
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

    function testSwapWNatForStableCoin() public {
        testSetSwapParams();
        uint256 amountTokenIn = 1e20; // 100 WNat
        uint256 amountTokenOut = 1e8; // 100 USDT0
        uint256 wNatPriceInWei = 2e16; // $0.02
        uint256 usdt0PriceInWei = 1e18; // $1
        _mockGetFeedsByIdInWei(
            FLR_USD_FEED_ID,
            USDT_USD_FEED_ID,
            wNatPriceInWei,
            usdt0PriceInWei
        );
        uniswapV3Router.setPriceInWei(address(wNatMock), wNatPriceInWei);
        uniswapV3Router.setPriceInWei(address(usdt0), usdt0PriceInWei);

        address personalAccountAddr = masterAccountController.getPersonalAccount(xrplAddress1);
        wNatMock.mint(personalAccountAddr, amountTokenIn); // 100 WNat in personal account
        usdt0.mint(address(uniswapV3Router), amountTokenOut); // 100 USDT0 liquidity in router
        uint256 amountOut = wNatPriceInWei * amountTokenIn * (10 ** 6) * (1e6 - wNatUsdt0PoolFeeTierPPM) /
            1e6 / usdt0PriceInWei / (10 ** 18);
        vm.expectEmit(personalAccountAddr);
        emit IPersonalAccount.SwapExecuted(
            address(wNatMock),
            address(usdt0),
            amountTokenIn,
            amountOut
        );
        vm.expectEmit();
        emit ISwapFacet.SwapExecuted(
            personalAccountAddr,
            address(wNatMock),
            address(usdt0),
            xrplAddress1,
            amountTokenIn,
            amountOut
        );
        masterAccountController.swapWNatForStableCoin(xrplAddress1);
        assertEq(
            wNatMock.balanceOf(personalAccountAddr),
            0
        );
        assertEq(
            wNatMock.balanceOf(address(uniswapV3Router)),
            amountTokenIn
        );
        assertEq(
            wNatMock.allowance(personalAccountAddr, address(uniswapV3Router)),
            0
        );
        assertEq(
            usdt0.balanceOf(personalAccountAddr),
            amountOut
        );
        assertEq(
            usdt0.balanceOf(address(uniswapV3Router)),
            amountTokenOut - amountOut
        );
    }

    function testSwapWNatForStableCoinRevertTooLittleReceived() public {
        testSetSwapParams();
        uint256 amountTokenIn = 1e20; // 100 WNat
        uint256 amountTokenOut = 1e8; // 100 USDT0
        uint256 wNatPriceInWei = 2e16; // $0.02
        uint256 usdt0PriceInWei = 1e18; // $1
        _mockGetFeedsByIdInWei(
            FLR_USD_FEED_ID,
            USDT_USD_FEED_ID,
            wNatPriceInWei,
            usdt0PriceInWei
        );
        uniswapV3Router.setPriceInWei(address(wNatMock), wNatPriceInWei);
        // set higher price to cause too little received
        uniswapV3Router.setPriceInWei(address(usdt0), usdt0PriceInWei * 2);

        address personalAccountAddr = masterAccountController.getPersonalAccount(xrplAddress1);
        wNatMock.mint(personalAccountAddr, amountTokenIn); // 100 WNat in personal account
        usdt0.mint(address(uniswapV3Router), amountTokenOut); // 100 USDT0 liquidity in router
        vm.expectRevert(MockUniswapV3Router.TooLittleReceived.selector);
        masterAccountController.swapWNatForStableCoin(xrplAddress1);
    }

    function testSwapWNatForStableCoinRevertSwapDisabled() public {
        address personalAccountAddr = masterAccountController.getPersonalAccount(xrplAddress1);
        vm.expectRevert(UniswapV3.SwapDisabled.selector, personalAccountAddr);
        masterAccountController.swapWNatForStableCoin(xrplAddress1);
    }

    function testSwapWNatForStableCoinRevertAmountInZero() public {
        testSetSwapParams();
        address personalAccountAddr = masterAccountController.getPersonalAccount(xrplAddress1);
        vm.expectRevert(UniswapV3.AmountInZero.selector, personalAccountAddr);
        masterAccountController.swapWNatForStableCoin(xrplAddress1);
    }

    function testSwapStableCoinForFAsset() public {
        testSetSwapParams();
        uint256 amountTokenIn = 1e8; // 100 USDT0
        uint256 amountTokenOut = 1e8; // 100 FXRP
        uint256 usdt0PriceInWei = 1e18; // $1
        uint256 fassetPriceInWei = 3e18; // $3
        _mockGetFeedsByIdInWei(
            USDT_USD_FEED_ID,
            XRP_USD_FEED_ID,
            usdt0PriceInWei,
            fassetPriceInWei
        );
        uniswapV3Router.setPriceInWei(address(usdt0), usdt0PriceInWei);
        uniswapV3Router.setPriceInWei(address(fxrp), fassetPriceInWei);

        address personalAccountAddr = masterAccountController.getPersonalAccount(xrplAddress1);
        usdt0.mint(personalAccountAddr, amountTokenIn); // 100 USDT0 in personal account
        fxrp.mint(address(uniswapV3Router), amountTokenOut); // 100 FXRP liquidity in router
        // decimals are the same for USDT0 and FXRP, so no adjustment needed
        uint256 amountOut = usdt0PriceInWei * amountTokenIn * (1e6 - usdt0FXrpPoolFeeTierPPM) / 1e6 / fassetPriceInWei;
        vm.expectEmit(personalAccountAddr);
        emit IPersonalAccount.SwapExecuted(
            address(usdt0),
            address(fxrp),
            amountTokenIn,
            amountOut
        );
        vm.expectEmit();
        emit ISwapFacet.SwapExecuted(
            personalAccountAddr,
            address(usdt0),
            address(fxrp),
            xrplAddress1,
            amountTokenIn,
            amountOut
        );
        masterAccountController.swapStableCoinForFAsset(xrplAddress1);
        assertEq(
            usdt0.balanceOf(personalAccountAddr),
            0
        );
        assertEq(
            usdt0.balanceOf(address(uniswapV3Router)),
            amountTokenIn
        );
        assertEq(
            usdt0.allowance(personalAccountAddr, address(uniswapV3Router)),
            0
        );
        assertEq(
            fxrp.balanceOf(personalAccountAddr),
            amountOut
        );
        assertEq(
            fxrp.balanceOf(address(uniswapV3Router)),
            amountTokenOut - amountOut
        );
    }

    function testSwapStableCoinForFassetRevertTooLittleReceived() public {
        testSetSwapParams();
        uint256 amountTokenIn = 1e8; // 100 USDT0
        uint256 amountTokenOut = 1e8; // 100 FXRP
        uint256 usdt0PriceInWei = 1e18; // $1
        uint256 fassetPriceInWei = 3e18; // $3
        _mockGetFeedsByIdInWei(
            USDT_USD_FEED_ID,
            XRP_USD_FEED_ID,
            usdt0PriceInWei,
            fassetPriceInWei
        );
        uniswapV3Router.setPriceInWei(address(usdt0), usdt0PriceInWei);
        // set higher price to cause too little received
        uniswapV3Router.setPriceInWei(address(fxrp), fassetPriceInWei * 2);

        address personalAccountAddr = masterAccountController.getPersonalAccount(xrplAddress1);
        usdt0.mint(personalAccountAddr, amountTokenIn); // 100 USDT0 in personal account
        fxrp.mint(address(uniswapV3Router), amountTokenOut); // 100 FXRP liquidity in router
        vm.expectRevert(MockUniswapV3Router.TooLittleReceived.selector);
        masterAccountController.swapStableCoinForFAsset(xrplAddress1);
    }

    function testSwapStableCoinForFassetRevertSwapDisabled() public {
        address personalAccountAddr = masterAccountController.getPersonalAccount(xrplAddress1);
        vm.expectRevert(UniswapV3.SwapDisabled.selector, personalAccountAddr);
        masterAccountController.swapStableCoinForFAsset(xrplAddress1);
    }

    function testSwapStableCoinForFassetRevertAmountInZero() public {
        testSetSwapParams();
        address personalAccountAddr = masterAccountController.getPersonalAccount(xrplAddress1);
        vm.expectRevert(UniswapV3.AmountInZero.selector, personalAccountAddr);
        masterAccountController.swapStableCoinForFAsset(xrplAddress1);
    }

    function testSetTimelockDuration() public {
        assertEq(masterAccountController.getTimelockDurationSeconds(), 0);
        uint256 newDuration = 2 days;
        vm.prank(governance);
        vm.expectEmit();
        emit ITimelockFacet.TimelockDurationSet(newDuration);
        masterAccountController.setTimelockDuration(newDuration);
        assertEq(masterAccountController.getTimelockDurationSeconds(), newDuration);
    }

    function testSetTimelockDurationRevertOnlyOwner() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                NotContractOwner.selector,
                address(this),
                governance
            )
        );
        masterAccountController.setTimelockDuration(1 days);
    }

    function testSetTimelockDurationRevertTimelockDurationTooLong() public {
        vm.expectRevert(ITimelockFacet.TimelockDurationTooLong.selector);
        vm.prank(governance);
        masterAccountController.setTimelockDuration(7 days + 1);
    }

    function testCancelTimelockedCall() public {
        testSetTimelockDuration();
        vm.prank(governance);
        uint256 newDuration = 3 days;
        bytes memory encodedCall = abi.encodeWithSelector(
            IITimelockFacet.setTimelockDuration.selector,
            newDuration
        );
        vm.expectEmit();
        uint256 allowedAfterTimestamp = block.timestamp + 2 days;
        emit ITimelockFacet.CallTimelocked(encodedCall, keccak256(encodedCall), allowedAfterTimestamp);
        masterAccountController.setTimelockDuration(newDuration);
        uint256 timestamp = masterAccountController.getExecuteTimelockedCallTimestamp(encodedCall);
        assertEq(timestamp, allowedAfterTimestamp);
        vm.prank(governance);
        vm.expectEmit();
        emit ITimelockFacet.TimelockedCallCanceled(keccak256(encodedCall));
        masterAccountController.cancelTimelockedCall(encodedCall);
        vm.expectRevert(ITimelockFacet.TimelockInvalidSelector.selector);
        masterAccountController.getExecuteTimelockedCallTimestamp(encodedCall);
    }

    function testCancelTimelockedCallRevertOnlyOwner() public {
        uint256 newDuration = 3 days;
        bytes memory encodedCall = abi.encodeWithSelector(
            IITimelockFacet.setTimelockDuration.selector,
            newDuration
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                NotContractOwner.selector,
                address(this),
                governance
            )
        );
        masterAccountController.cancelTimelockedCall(encodedCall);
    }

    function testCancelTimelockedCallRevertTimelockInvalidSelector() public {
        vm.prank(governance);
        uint256 newDuration = 3 days;
        bytes memory encodedCall = abi.encodeWithSelector(
            IITimelockFacet.setTimelockDuration.selector,
            newDuration
        );
        vm.expectRevert(ITimelockFacet.TimelockInvalidSelector.selector);
        masterAccountController.cancelTimelockedCall(encodedCall);
    }

    function testExecuteTimelockedCall() public {
        testSetTimelockDuration();
        vm.prank(governance);
        uint256 newDuration = 3 days;
        bytes memory encodedCall = abi.encodeWithSelector(
            IITimelockFacet.setTimelockDuration.selector,
            newDuration
        );
        vm.expectEmit();
        uint256 allowedAfterTimestamp = block.timestamp + 2 days;
        emit ITimelockFacet.CallTimelocked(encodedCall, keccak256(encodedCall), allowedAfterTimestamp);
        masterAccountController.setTimelockDuration(newDuration);
        uint256 timestamp = masterAccountController.getExecuteTimelockedCallTimestamp(encodedCall);
        assertEq(timestamp, allowedAfterTimestamp);
        vm.warp(allowedAfterTimestamp);
        vm.expectEmit();
        emit ITimelockFacet.TimelockedCallExecuted(keccak256(encodedCall));
        masterAccountController.executeTimelockedCall(encodedCall);
        vm.expectRevert(ITimelockFacet.TimelockInvalidSelector.selector);
        masterAccountController.getExecuteTimelockedCallTimestamp(encodedCall);
    }

    function testExecuteTimelockedCallRevertTimelockInvalidSelector() public {
        testSetTimelockDuration();
        uint256 newDuration = 3 days;
        bytes memory encodedCall = abi.encodeWithSelector(
            IITimelockFacet.setTimelockDuration.selector,
            newDuration
        );
        vm.expectRevert(ITimelockFacet.TimelockInvalidSelector.selector);
        masterAccountController.executeTimelockedCall(encodedCall);
    }

    function testExecuteTimelockedCallRevertTimelockNotAllowedYet() public {
        testSetTimelockDuration();
        vm.prank(governance);
        uint256 newDuration = 3 days;
        bytes memory encodedCall = abi.encodeWithSelector(
            IITimelockFacet.setTimelockDuration.selector,
            newDuration
        );
        vm.expectEmit();
        uint256 allowedAfterTimestamp = block.timestamp + 2 days;
        emit ITimelockFacet.CallTimelocked(encodedCall, keccak256(encodedCall), allowedAfterTimestamp);
        masterAccountController.setTimelockDuration(newDuration);
        uint256 timestamp = masterAccountController.getExecuteTimelockedCallTimestamp(encodedCall);
        assertEq(timestamp, allowedAfterTimestamp);
        vm.warp(allowedAfterTimestamp - 1);
        vm.expectRevert(ITimelockFacet.TimelockNotAllowedYet.selector);
        masterAccountController.executeTimelockedCall(encodedCall);
        timestamp = masterAccountController.getExecuteTimelockedCallTimestamp(encodedCall);
        assertEq(timestamp, allowedAfterTimestamp);
    }

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

    function _mockGetFeedsByIdInWei(
        bytes32 _tokenInFeedId,
        bytes32 _tokenOutFeedId,
        uint256 _priceInWeiTokenIn,
        uint256 _priceInWeiTokenOut
    ) private {
        bytes32[] memory feedIds = new bytes32[](2);
        feedIds[0] = _tokenInFeedId;
        feedIds[1] = _tokenOutFeedId;
        uint256[] memory pricesInWei = new uint256[](2);
        pricesInWei[0] = _priceInWeiTokenIn;
        pricesInWei[1] = _priceInWeiTokenOut;
        vm.mockCall(
            ftsoV2Mock,
            abi.encodeWithSelector(
                FtsoV2Interface.getFeedsByIdInWei.selector,
                feedIds
            ),
            abi.encode(pricesInWei)
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
