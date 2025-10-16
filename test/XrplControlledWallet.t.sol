// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {
    MasterAccountController,
    IGovernanceSettings,
    IPayment
} from "../contracts/smartAccounts/implementation/MasterAccountController.sol";
import {IPaymentVerification} from "flare-periphery/src/flare/IPaymentVerification.sol";
import {IFlareContractRegistry} from "flare-periphery/src/flare/IFlareContractRegistry.sol";
import {IAssetManager} from "flare-periphery/src/flare/IAssetManager.sol";
import {AgentInfo} from "flare-periphery/src/flare/data/AvailableAgentInfo.sol";
import {MasterAccountControllerProxy} from "../contracts/smartAccounts/proxy/MasterAccountControllerProxy.sol";
import {PersonalAccount} from "../contracts/smartAccounts/implementation/PersonalAccount.sol";
import {IPersonalAccount} from "../contracts/userInterfaces/IPersonalAccount.sol";
import {PersonalAccountProxy} from "../contracts/smartAccounts/proxy/PersonalAccountProxy.sol";
import {MintableERC20} from "../contracts/mock/MintableERC20.sol";
import {MyERC4626, IERC20} from "../contracts/mock/MyERC4626.sol";
import {MockSingletonFactory} from "../contracts/mock/MockSingletonFactory.sol";
import {PersonalAccountBase} from "../contracts/smartAccounts/implementation/PersonalAccountBase.sol";
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
    address private executor;
    uint256 private executorFee;
    MyERC4626 private depositVault;
    MintableERC20 private fxrp;
    string private xrplProviderWallet;
    bytes32 private xrplProviderWalletHash;
    uint256 private paymentProofValidityDurationSeconds;
    uint256 private defaultInstructionFee;
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
        assetManagerFxrpMock = makeAddr("AssetManagerFXRP");
        agent = makeAddr("agent");
        agentInfo.status = AgentInfo.Status.NORMAL;

        // deploy the personal account implementation
        personalAccountImpl = new PersonalAccount();
        personalAccountImplementation = address(personalAccountImpl);
        // deploy seed personal account implementation
        bytes memory bytecode = abi.encodePacked(
            type(PersonalAccountBase).creationCode
        );
        // needs to be the same on all networks
        bytes32 salt = keccak256(abi.encodePacked("tempSalt"));
        address seedPersonalAccountImpl = IISingletonFactory(SINGLETON_FACTORY).deploy(bytecode, salt);

        // deploy the controlled wallet
        masterAccountControllerImpl = new MasterAccountController();
        masterAccountControllerProxy = new MasterAccountControllerProxy(
            address(masterAccountControllerImpl),
            IGovernanceSettings(makeAddr("governanceSettings")),
            governance,
            payable(executor),
            executorFee,
            paymentProofValidityDurationSeconds,
            defaultInstructionFee,
            xrplProviderWallet,
            personalAccountImplementation,
            seedPersonalAccountImpl
        );
        masterAccountController = MasterAccountController(
            address(masterAccountControllerProxy)
        );

        _mockGetContractAddressByHash("FdcVerification", fdcVerificationMock);
        _mockGetContractAddressByHash("AssetManagerFXRP", assetManagerFxrpMock);
        _mockGetAgentInfo(agent, agentInfo);

        // add agent vault
        uint256[] memory agentVaultIds = new uint256[](1);
        address[] memory agentVaultAddresses = new address[](1);
        agentVaultIds[0] = 0;
        agentVaultAddresses[0] = agent;
        vm.prank(governance);
        masterAccountController.addAgentVaults(agentVaultIds, agentVaultAddresses);
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

    function test() public {
        IPayment.Proof memory proof;
        proof.data.responseBody.receivingAddressHash = xrplProviderWalletHash;
        proof.data.responseBody.sourceAddressHash = keccak256(bytes(xrplAddress1));
        proof.data.requestBody.transactionId = bytes32("tx1");
        proof.data.responseBody.receivedAmount = 1000000;
        proof
            .data
            .responseBody
            .standardPaymentReference = _encodePaymentReferenceDeposit(12345);
        _mockVerifyPayment(true);

        address predictedAddress1 = masterAccountController.computePersonalAccountAddress(xrplAddress1);
        fxrp.mint(predictedAddress1, 12345);

        assertEq(
            address(masterAccountController.getPersonalAccount(xrplAddress1)),
            address(PersonalAccount(payable(address(0))))
        );
        vm.expectEmit();
        emit IPersonalAccount.Approved(
            address(fxrp),
            address(depositVault),
            12345
        );
        masterAccountController.executeInstruction(proof, xrplAddress1);

        // PersonalAccount should be created
        assertNotEq(
            address(masterAccountController.getPersonalAccount(xrplAddress1)),
            address(PersonalAccount(payable(address(0))))
        );
        personalAccount1 = masterAccountController.getPersonalAccount(
            xrplAddress1
        );
        // check that the personal account was created at the expected address
        assertEq(
            address(masterAccountController.getPersonalAccount(xrplAddress1)),
            predictedAddress1
        );
        assertEq(
            personalAccount1.implementation(),
            address(personalAccountImpl)
        );
        assertEq(personalAccount1.xrplOwner(), xrplAddress1);
        assertEq(
            personalAccount1.controllerAddress(),
            address(masterAccountController)
        );

        // change implementation of MasterAccountController
        assertEq(
            masterAccountController.implementation(),
            address(masterAccountControllerImpl)
        );
        MasterAccountController newMasterAccountControllerImpl = new MasterAccountController();
        vm.prank(governance);
        masterAccountController.upgradeToAndCall(
            address(newMasterAccountControllerImpl),
            bytes("")
        );
        assertEq(
            masterAccountController.implementation(),
            address(newMasterAccountControllerImpl)
        );
        assertEq(
            address(masterAccountController.getPersonalAccount(xrplAddress1)),
            address(personalAccount1)
        );
        assertEq(
            personalAccount1.controllerAddress(),
            address(masterAccountController)
        );

        // deploy a new PersonalAccount implementation
        PersonalAccount newPersonalAccountImpl = new PersonalAccount();
        // create new transaction; personal account should not be upgraded
        proof.data.requestBody.transactionId = bytes32("tx2");
        fxrp.mint(predictedAddress1, 12345);
        masterAccountController.executeInstruction(proof, xrplAddress1);
        assertEq(
            personalAccount1.implementation(),
            address(personalAccountImpl)
        );

        // compute address of personal account for xrplAddress2 before implementation change
        address predictedAddress2 = masterAccountController.computePersonalAccountAddress(xrplAddress2);

        // update PersonalAccount implementation on MasterAccountController
        vm.prank(governance);
        masterAccountController.setPersonalAccountImplementation(
            address(newPersonalAccountImpl)
        );
        assertEq(
            masterAccountController.personalAccountImplementation(),
            address(newPersonalAccountImpl)
        );
        // create new transaction; personal account should be upgraded
        proof.data.requestBody.transactionId = bytes32("tx3");
        fxrp.mint(predictedAddress1, 12345);
        masterAccountController.executeInstruction(proof, xrplAddress1);
        assertEq(
            address(masterAccountController.getPersonalAccount(xrplAddress1)),
            address(personalAccount1)
        );
        assertEq(
            personalAccount1.implementation(),
            address(newPersonalAccountImpl)
        );
        assertEq(personalAccount1.xrplOwner(), xrplAddress1);
        assertEq(
            personalAccount1.controllerAddress(),
            address(masterAccountController)
        );

        // execute transaction for xrplAddress2; new personal account should be created with new implementation
        // and at the expected address
        proof.data.requestBody.transactionId = bytes32("tx4");
        proof.data.responseBody.sourceAddressHash = keccak256(bytes(xrplAddress2));
        fxrp.mint(predictedAddress2, 12345);
        masterAccountController.executeInstruction(proof, xrplAddress2);
        personalAccount2 = masterAccountController.getPersonalAccount(
            xrplAddress2
        );
        // check that the personal account was created at the expected address
        assertEq(
            address(masterAccountController.getPersonalAccount(xrplAddress2)),
            predictedAddress2
        );
        // check implementation of the new personal account
        assertEq(
            personalAccount2.implementation(),
            address(newPersonalAccountImpl)
        );
        assertEq(personalAccount2.xrplOwner(), xrplAddress2);
        assertEq(
            personalAccount2.controllerAddress(),
            address(masterAccountController)
        );
    }

    function _mockGetAgentInfo(address agentAddress, AgentInfo.Info memory info) private {
        vm.mockCall(
            assetManagerFxrpMock,
            abi.encodeWithSelector(
                IAssetManager.getAgentInfo.selector,
                agentAddress
            ),
            abi.encode(info)
        );
    }

    function _mockGetContractAddressByHash(string memory name, address addr) private {
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

    function _encodePaymentReferenceDeposit(
        uint128 amount
    ) private pure returns (bytes32) {
        // Place instructionId in the highest 8 bits, skip wallet identifier and put amount in the next 128 bits
        return bytes32((uint256(11) << 248) | (uint256(amount) << 112));
    }
}
