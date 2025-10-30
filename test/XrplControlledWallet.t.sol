// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import {Test,console2} from "forge-std/Test.sol";
import {MasterAccountController} from "../contracts/smartAccounts/implementation/MasterAccountController.sol";
import {MasterAccountControllerBase} from "../contracts/smartAccounts/implementation/MasterAccountControllerBase.sol";
import {IMasterAccountController} from "../contracts/userInterfaces/IMasterAccountController.sol";
import {IPayment} from "flare-periphery/src/flare/IPayment.sol";
import {IGovernanceSettings} from "flare-periphery/src/flare/IGovernanceSettings.sol";
import {IPaymentVerification} from "flare-periphery/src/flare/IPaymentVerification.sol";
import {IFlareContractRegistry} from "flare-periphery/src/flare/IFlareContractRegistry.sol";
import {IAssetManager} from "flare-periphery/src/flare/IAssetManager.sol";
import {AgentInfo} from "flare-periphery/src/flare/data/AvailableAgentInfo.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {MasterAccountControllerProxy} from "../contracts/smartAccounts/proxy/MasterAccountControllerProxy.sol";
import {PersonalAccount} from "../contracts/smartAccounts/implementation/PersonalAccount.sol";
import {IPersonalAccount} from "../contracts/userInterfaces/IPersonalAccount.sol";
import {PersonalAccountProxy} from "../contracts/smartAccounts/proxy/PersonalAccountProxy.sol";
import {MintableERC20} from "../contracts/mock/MintableERC20.sol";
import {MyERC4626, IERC20} from "../contracts/mock/MyERC4626.sol";
import {MockSingletonFactory} from "../contracts/mock/MockSingletonFactory.sol";
import {IISingletonFactory} from "../contracts/smartAccounts/interface/IISingletonFactory.sol";

// solhint-disable-next-line max-states-count
contract XrplControlledWalletTest is Test {
    MasterAccountController private masterAccountController;
    MasterAccountController private masterAccountControllerImpl;
    MasterAccountControllerProxy private masterAccountControllerProxy;
    PersonalAccount private personalAccountImpl;
    PersonalAccountProxy private personalAccountProxy;
    IPersonalAccount private personalAccount1;
    IPersonalAccount private personalAccount2;

    address private constant SINGLETON_FACTORY = 0xce0042B868300000d44A59004Da54A005ffdcf9f;
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
        xrplProviderWallet = "rXrplProviderWallet";
        xrplProviderWalletHash = keccak256(bytes(xrplProviderWallet));
        contractRegistryMock = 0xaD67FE66660Fb8dFE9d6b1b4240d8650e30F6019;
        fdcVerificationMock = makeAddr("FDCVerificationMock");
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

        // deploy controller base seed using create2
        // same on all chains
        bytes memory bytecode = abi.encodePacked(
            type(MasterAccountControllerBase).creationCode
        );
        address seedControllerBase = IISingletonFactory(SINGLETON_FACTORY).deploy(bytecode, 0);

        // deploy controller proxy
        // same on all chains
        bytecode = abi.encodePacked(
            type(MasterAccountControllerProxy).creationCode,
            abi.encode(
                seedControllerBase,
                initialOwner
            )
        );
        address masterAccountControllerProxyAddr = IISingletonFactory(SINGLETON_FACTORY).deploy(bytecode, 0);

        // deploy real controller implementation
        masterAccountControllerImpl = new MasterAccountController();

        // upgrade controller proxy to real implementation
        vm.prank(initialOwner);
        UUPSUpgradeable(masterAccountControllerProxyAddr).upgradeToAndCall(
            address(masterAccountControllerImpl), bytes("")
        );
        masterAccountController = MasterAccountController(masterAccountControllerProxyAddr);

        string[] memory xrplProviderWallets = new string[](1);
        xrplProviderWallets[0] = xrplProviderWallet;

        // initialize controller
        vm.prank(initialOwner);
        masterAccountController.initialize(
            payable(executor),
            executorFee,
            paymentProofValidityDurationSeconds,
            defaultInstructionFee,
            xrplProviderWallets,
            personalAccountImplementation
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
        // add vault
        uint256[] memory vaultIds = new uint256[](1);
        address[] memory vaultAddresses = new address[](1);
        vaultIds[0] = 0;
        vaultAddresses[0] = address(depositVault);
        vm.prank(governance);
        masterAccountController.addVaults(vaultIds, vaultAddresses);

        xrplAddress1 = "xrplAddress1";
        xrplAddress2 = "xrplAddress2";
    }

    function testUpgrades() public {
        IPayment.Proof memory proof;
        proof.data.responseBody.receivingAddressHash = xrplProviderWalletHash;
        proof.data.responseBody.sourceAddressHash = keccak256(bytes(xrplAddress1));
        proof.data.requestBody.transactionId = bytes32("tx1");
        proof.data.responseBody.receivedAmount = 1000000;
        proof.data.responseBody.standardPaymentReference = _encodePaymentReferenceDeposit(12345);
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

        // change implementation of MasterAccountController
        assertEq(
            masterAccountController.controllerImplementation(),
            address(masterAccountControllerImpl)
        );
        MasterAccountController newMasterAccountControllerImpl = new MasterAccountController();
        vm.prank(governance);
        masterAccountController.upgradeToAndCall(
            address(newMasterAccountControllerImpl),
            bytes("")
        );
        assertEq(
            masterAccountController.controllerImplementation(),
            address(newMasterAccountControllerImpl)
        );
        assertEq(
            masterAccountController.getPersonalAccount(xrplAddress1),
            address(personalAccount1)
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
            masterAccountController.personalAccountImplementation(),
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

    //// reserveCollateral tests
    function testReserveCollateralRevertInvalidInstructionId() public {
        bytes32 paymentReference = _encodeFxrpPaymentReference(99, 0, 1000, 0);
        bytes32 transactionId = bytes32("tx1");
        vm.expectRevert(
            abi.encodeWithSelector(
                IMasterAccountController.InvalidInstructionId.selector,
                99
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
        vm.expectRevert(IMasterAccountController.InvalidTransactionId.selector);
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
                IMasterAccountController.InvalidAgentVault.selector,
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
        vm.expectRevert(IMasterAccountController.ValueZero.selector);
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
        emit IMasterAccountController.CollateralReserved(
            predictedAddress1,
            transactionId,
            paymentReference,
            xrplAddress1,
            22,
            masterAccountController.agentVaults(0),
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
            masterAccountController.collateralReservationIdToTransactionId(collateralReservationId),
            transactionId
        );
    }

    function testExecuteDepositAfterMintingRevertInvalidInstructionId() public {
        bytes32 paymentReference = _encodeFxrpPaymentReference(99, 0, 1000, 0);
        IPayment.Proof memory proof;
        proof.data.responseBody.standardPaymentReference = paymentReference;

        vm.expectRevert(
            abi.encodeWithSelector(
                IMasterAccountController.InvalidInstructionId.selector,
                99
            )
        );
        masterAccountController.executeDepositAfterMinting(0, proof, xrplAddress1);
    }

    function testExecuteDepositAfterMintingRevertUnknownCollateralReservationId() public {
        bytes32 paymentReference = _encodeFxrpPaymentReference(10, 0, 1000, 0);
        IPayment.Proof memory proof;
        proof.data.responseBody.standardPaymentReference = paymentReference;

        vm.expectRevert(
            abi.encodeWithSelector(
                IMasterAccountController.UnknownCollateralReservationId.selector,
                0
            )
        );
        masterAccountController.executeDepositAfterMinting(0, proof, xrplAddress1);
    }

    //// helper functions
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

    function _encodePaymentReferenceDeposit(
        uint128 amount
    )
        private pure
        returns (bytes32)
    {
        // Place instructionId in the highest 8 bits, skip wallet identifier and put amount in the next 128 bits
        return bytes32((uint256(11) << 248) | (uint256(amount) << 112));
    }

    // FXRP payment reference (32 bytes)
    function _encodeFxrpPaymentReference(
        uint8 _instructionId,
        uint8 _walletId,
        uint128 _value,
        uint16 _agentVaultId
    ) private pure returns (bytes32) {
        return
            (bytes32(uint256(_instructionId)) << 248) |
            (bytes32(uint256(_walletId)) << 240) |
            (bytes32(uint256(_value)) << 112) |
            (bytes32(uint256(_agentVaultId)) << 96);
        // bytes 20-31 are zero (future use)
    }

    // Firelight vaults payment reference (32 bytes)
    function _encodeFirelightPaymentReference(
        uint8 _instructionId,
        uint8 _walletId,
        uint128 _value,
        uint16 _agentVaultId,
        uint16 _vaultId
    ) private pure returns (bytes32) {
        return
            (bytes32(uint256(_instructionId)) << 248) |
            (bytes32(uint256(_walletId)) << 240) |
            (bytes32(uint256(_value)) << 112) |
            (bytes32(uint256(_agentVaultId)) << 96) |
            (bytes32(uint256(_vaultId)) << 80);
        // bytes 22-31 are zero (future use)
    }

    // Upshift vaults payment reference (32 bytes)
    function _encodeUpshiftPaymentReference(
        uint8 _instructionId,
        uint8 _walletId,
        uint128 _value,
        uint16 _agentVaultId,
        uint16 _vaultId
    ) private pure returns (bytes32) {
        return
            (bytes32(uint256(_instructionId)) << 248) |
            (bytes32(uint256(_walletId)) << 240) |
            (bytes32(uint256(_value)) << 112) |
            (bytes32(uint256(_agentVaultId)) << 96) |
            (bytes32(uint256(_vaultId)) << 80);
        // bytes 22-31 are zero (future use)
    }
}
