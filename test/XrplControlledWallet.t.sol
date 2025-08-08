// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {
    MasterAccountController,
    IGovernanceSettings,
    IPayment
} from "../contracts/xrpcw/implementation/MasterAccountController.sol";
import {IPaymentVerification} from "@flarenetwork/flare-periphery-contracts/flare/IPaymentVerification.sol";
import {IFlareContractRegistry} from "@flarenetwork/flare-periphery-contracts/flare/IFlareContractRegistry.sol";
import {MasterAccountControllerProxy} from "../contracts/xrpcw/proxy/MasterAccountControllerProxy.sol";
import {PersonalAccount} from "../contracts/xrpcw/implementation/PersonalAccount.sol";
import {PersonalAccountProxy} from "../contracts/xrpcw/proxy/PersonalAccountProxy.sol";
import {MintableERC20} from "../contracts/mock/MintableERC20.sol";
import {MyERC4626, IERC20} from "../contracts/mock/MyERC4626.sol";

contract XrplControlledWalletTest is Test {
    MasterAccountController private masterAccountController;
    MasterAccountController private masterAccountControllerImpl;
    MasterAccountControllerProxy private masterAccountControllerProxy;
    PersonalAccount private personalAccountImpl;
    PersonalAccountProxy private personalAccountProxy;
    PersonalAccount private personalAccount1;
    PersonalAccount private personalAccount2;

    address private governance;
    address private executor;
    uint256 private executorFee;
    MyERC4626 private depositVault;
    MintableERC20 private fxrp;
    string private xrplProviderWallet;
    bytes32 private xrplProviderWalletHash;
    address private operator;
    address private personalAccountImplementation;
    string private xrplAccount1;
    string private xrplAccount2;
    uint256 private operatorExecutionWindowSeconds;

    address private contractRegistryMock;
    address private fdcVerificationMock;

    function setUp() public {
        governance = makeAddr("governance");
        executor = makeAddr("executor");
        fxrp = new MintableERC20("F-ripple", "fXRP");
        depositVault = new MyERC4626(
            IERC20(address(fxrp)),
            "Deposit Vault",
            "DV"
        );
        xrplProviderWallet = "rXrplProviderWallet";
        xrplProviderWalletHash = keccak256(abi.encodePacked(xrplProviderWallet));
        operator = makeAddr("operator");
        contractRegistryMock = 0xaD67FE66660Fb8dFE9d6b1b4240d8650e30F6019;
        fdcVerificationMock = makeAddr("FDCVerificationMock");
        executorFee = 100;
        operatorExecutionWindowSeconds = 3600;

        // deploy the personal account implementation
        personalAccountImpl = new PersonalAccount();
        personalAccountImplementation = address(personalAccountImpl);

        // deploy the controlled wallet
        masterAccountControllerImpl = new MasterAccountController();
        masterAccountControllerProxy = new MasterAccountControllerProxy(
            address(masterAccountControllerImpl),
            IGovernanceSettings(makeAddr("governanceSettings")),
            governance,
            address(depositVault),
            address(fxrp),
            payable(executor),
            executorFee,
            xrplProviderWallet,
            operator,
            operatorExecutionWindowSeconds,
            personalAccountImplementation
        );
        masterAccountController = MasterAccountController(address(masterAccountControllerProxy));
        xrplAccount1 = "xrplAccount1";
        xrplAccount2 = "xrplAccount2";

    }

    function test() public {
        IPayment.Proof memory proof;
        proof.data.responseBody.receivingAddressHash = xrplProviderWalletHash;
        proof.data.responseBody.sourceAddressHash = keccak256(abi.encodePacked(xrplAccount1));
        proof.data.requestBody.transactionId = bytes32("tx1");
        // instruction id is 3, amount is 12345
        proof.data.responseBody.standardPaymentReference =
            0x0300000000000000000000000000000000000000000000000000000000003039;
        _mockVerifyPayment(true);

        assertEq(
            address(masterAccountController.getPersonalAccount(xrplAccount1)),
            address(PersonalAccount(address(0)))
        );
        vm.prank(operator);
        masterAccountController.executeTransaction(proof, xrplAccount1);

        // PersonalAccount should be created
        assertNotEq(
            address(masterAccountController.getPersonalAccount(xrplAccount1)),
            address(PersonalAccount(address(0)))
        );
        personalAccount1 = masterAccountController.getPersonalAccount(xrplAccount1);
        assertEq(personalAccount1.implementation(), address(personalAccountImpl));
        assertEq(personalAccount1.xrplOwner(), xrplAccount1);
        assertEq(personalAccount1.controllerAddress(), address(masterAccountController));

        // change implementation of MasterAccountController
        assertEq(masterAccountController.implementation(), address(masterAccountControllerImpl));
        MasterAccountController newMasterAccountControllerImpl = new MasterAccountController();
        vm.prank(governance);
        masterAccountController.upgradeToAndCall(address(newMasterAccountControllerImpl), bytes(""));
        assertEq(masterAccountController.implementation(), address(newMasterAccountControllerImpl));
        assertEq(address(masterAccountController.getPersonalAccount(xrplAccount1)), address(personalAccount1));
        assertEq(personalAccount1.controllerAddress(), address(masterAccountController));

        // deploy a new PersonalAccount implementation
        PersonalAccount newPersonalAccountImpl = new PersonalAccount();
        // create new transaction; personal account should not be upgraded
        proof.data.requestBody.transactionId = bytes32("tx2");
        vm.prank(operator);
        masterAccountController.executeTransaction(proof, xrplAccount1);
        assertEq(personalAccount1.implementation(), address(personalAccountImpl));

        // update PersonalAccount implementation on MasterAccountController
        vm.prank(governance);
        masterAccountController.setPersonalAccountImplementation(address(newPersonalAccountImpl));
        assertEq(masterAccountController.personalAccountImplementation(), address(newPersonalAccountImpl));
        // create new transaction; personal account should be upgraded
        proof.data.requestBody.transactionId = bytes32("tx3");
        vm.prank(operator);
        masterAccountController.executeTransaction(proof, xrplAccount1);
        assertEq(address(masterAccountController.getPersonalAccount(xrplAccount1)), address(personalAccount1));
        assertEq(personalAccount1.implementation(), address(newPersonalAccountImpl));
        assertEq(personalAccount1.xrplOwner(), xrplAccount1);
        assertEq(personalAccount1.controllerAddress(), address(masterAccountController));
    }


    function _mockVerifyPayment(bool _result) internal {
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
            abi.encodeWithSelector(
                IPaymentVerification.verifyPayment.selector
            ),
            abi.encode(_result)
        );
    }

}
