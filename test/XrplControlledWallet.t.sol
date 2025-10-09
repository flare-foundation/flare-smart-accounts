// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {
    MasterAccountController,
    IGovernanceSettings,
    IPayment
} from "../contracts/xrpcw/implementation/MasterAccountController.sol";
import {IPaymentVerification} from "flare-periphery/src/flare/IPaymentVerification.sol";
import {IFlareContractRegistry} from "flare-periphery/src/flare/IFlareContractRegistry.sol";
import {MasterAccountControllerProxy} from "../contracts/xrpcw/proxy/MasterAccountControllerProxy.sol";
import {PersonalAccount} from "../contracts/xrpcw/implementation/PersonalAccount.sol";
import {IPersonalAccount} from "../contracts/userInterfaces/IPersonalAccount.sol";
import {PersonalAccountProxy} from "../contracts/xrpcw/proxy/PersonalAccountProxy.sol";
import {MintableERC20} from "../contracts/mock/MintableERC20.sol";
import {MyERC4626, IERC20} from "../contracts/mock/MyERC4626.sol";
import {IPersonalAccount} from "../contracts/userInterfaces/IPersonalAccount.sol";

// solhint-disable-next-line max-states-count
contract XrplControlledWalletTest is Test {
    MasterAccountController private masterAccountController;
    MasterAccountController private masterAccountControllerImpl;
    MasterAccountControllerProxy private masterAccountControllerProxy;
    PersonalAccount private personalAccountImpl;
    PersonalAccountProxy private personalAccountProxy;
    IPersonalAccount private personalAccount1;
    IPersonalAccount private personalAccount2;

    address private governance;
    address private executor;
    uint256 private executorFee;
    MyERC4626 private depositVault;
    MintableERC20 private fxrp;
    string private xrplProviderWallet;
    bytes32 private xrplProviderWalletHash;
    address private operator;
    address private personalAccountImplementation;
    string private xrplAddress1;
    string private xrplAddress2;
    uint256 private operatorExecutionWindowSeconds;
    address private assetManagerFxrpMock;
    address private agent;

    address private contractRegistryMock;
    address private fdcVerificationMock;

    function setUp() public {
        governance = makeAddr("governance");
        executor = makeAddr("executor");
        fxrp = new MintableERC20("F-XRPL", "fXRP");
        depositVault = new MyERC4626(
            IERC20(address(fxrp)),
            "Deposit Vault",
            "DV"
        );
        xrplProviderWallet = "rXrplProviderWallet";
        xrplProviderWalletHash = keccak256(
            abi.encodePacked(xrplProviderWallet)
        );
        operator = makeAddr("operator");
        contractRegistryMock = 0xaD67FE66660Fb8dFE9d6b1b4240d8650e30F6019;
        fdcVerificationMock = makeAddr("FDCVerificationMock");
        executorFee = 100;
        operatorExecutionWindowSeconds = 3600;
        assetManagerFxrpMock = makeAddr("AssetManagerFXRP");
        agent = makeAddr("agent");

        // deploy the personal account implementation
        personalAccountImpl = new PersonalAccount();
        personalAccountImplementation = address(personalAccountImpl);

        _mockGetContractAddressByName(
            "AssetManagerFXRP",
            assetManagerFxrpMock
        );

        address[] memory agents = new address[](1);
        agents[0] = agent;
        vm.mockCall(
            assetManagerFxrpMock,
            abi.encodeWithSelector(
                bytes4(keccak256("getAvailableAgentsList(uint256,uint256)")), 0, 100
            ),
            abi.encode(agents, 1)
        );

        // deploy the controlled wallet
        masterAccountControllerImpl = new MasterAccountController();
        masterAccountControllerProxy = new MasterAccountControllerProxy(
            address(masterAccountControllerImpl),
            IGovernanceSettings(makeAddr("governanceSettings")),
            governance,
            address(depositVault),
            payable(executor),
            executorFee,
            xrplProviderWallet,
            operator,
            operatorExecutionWindowSeconds,
            personalAccountImplementation
        );
        masterAccountController = MasterAccountController(
            address(masterAccountControllerProxy)
        );
        xrplAddress1 = "xrplAddress1";
        xrplAddress2 = "xrplAddress2";
    }

    function test() public {
        IPayment.Proof memory proof;
        proof.data.responseBody.receivingAddressHash = xrplProviderWalletHash;
        proof.data.responseBody.sourceAddressHash = keccak256(
            abi.encodePacked(xrplAddress1)
        );
        proof.data.requestBody.transactionId = bytes32("tx1");
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
        vm.prank(operator);
        vm.expectEmit();
        emit IPersonalAccount.Approved(
            address(fxrp),
            address(depositVault),
            12345
        );
        masterAccountController.executeTransaction(proof, xrplAddress1);

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
        vm.prank(operator);
        masterAccountController.executeTransaction(proof, xrplAddress1);
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
        vm.prank(operator);
        masterAccountController.executeTransaction(proof, xrplAddress1);
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
        proof.data.responseBody.sourceAddressHash = keccak256(
            abi.encodePacked(xrplAddress2)
        );
        fxrp.mint(predictedAddress2, 12345);
        vm.prank(operator);
        masterAccountController.executeTransaction(proof, xrplAddress2);
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

    function _mockVerifyPayment(bool _result) private {
        vm.mockCall(
            contractRegistryMock,
            abi.encodeWithSelector(
                IFlareContractRegistry.getContractAddressByName.selector,
                "FdcVerification"
            ),
            abi.encode(fdcVerificationMock)
        );

        vm.mockCall(
            fdcVerificationMock,
            abi.encodeWithSelector(IPaymentVerification.verifyPayment.selector),
            abi.encode(_result)
        );
    }

    function _mockGetContractAddressByName(string memory name, address addr) private {
        vm.mockCall(
            contractRegistryMock,
            abi.encodeWithSelector(
                IFlareContractRegistry.getContractAddressByName.selector,
                name
            ),
            abi.encode(addr)
        );
    }

    function _encodePaymentReferenceDeposit(
        uint128 amount
    ) private pure returns (bytes32) {
        // Place instructionId in the highest 8 bits, amount in the next 128 bits
        return bytes32((uint256(10) << 248) | (uint256(amount) << 120));
    }

    function _encodePaymentReferenceRedeem(
        uint8 instructionId,
        uint88 lots
    ) private pure returns (bytes32) {
        require(instructionId == 4, "Invalid instructionId for redeem");
        return
            bytes32((uint256(instructionId) << 248) | (uint256(lots) << 160));
    }

    function _encodePaymentReferenceReserve(
        uint8 _instructionId,
        uint88 _lots,
        address _agent // uint160
    ) private pure returns (bytes32) {
        require(
            _instructionId == 5,
            "Invalid instructionId for collateral reservation"
        );
        return
            bytes32(
                (uint256(_instructionId) << 248) |
                    (uint256(_lots) << 160) |
                    (uint256(uint160(_agent)))
            );
    }

}
