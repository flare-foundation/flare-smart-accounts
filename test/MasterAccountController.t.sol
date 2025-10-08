// SPDX-License-Identifier: UNLICENSED
// solhint-disable one-contract-per-file
// solhint-disable no-console
pragma solidity ^0.8.27;

import {Test, console2} from "forge-std/Test.sol";
import {
    MasterAccountController,
    IGovernanceSettings,
    IPayment
} from "../contracts/xrpcw/implementation/MasterAccountController.sol";
import {IPaymentVerification} from "flare-periphery/src/flare/IPaymentVerification.sol";
import {IFlareContractRegistry} from "flare-periphery/src/flare/IFlareContractRegistry.sol";
import {IMasterAccountController} from "../contracts/userInterfaces/IMasterAccountController.sol";
import {MasterAccountControllerProxy} from "../contracts/xrpcw/proxy/MasterAccountControllerProxy.sol";
import {PersonalAccount} from "../contracts/xrpcw/implementation/PersonalAccount.sol";
import {PersonalAccountProxy} from "../contracts/xrpcw/proxy/PersonalAccountProxy.sol";
import {MintableERC20} from "../contracts/mock/MintableERC20.sol";
import {MyERC4626, IERC20} from "../contracts/mock/MyERC4626.sol";
// import {IPersonalAccount} from "../contracts/userInterfaces/IPersonalAccount.sol";

// solhint-disable-next-line max-states-count
contract MasterAccountControllerTest is Test {
    MasterAccountController private masterAccountController;
    MasterAccountController private masterAccountControllerImpl;
    MasterAccountControllerProxy private masterAccountControllerProxy;
    PersonalAccount private personalAccountImpl;
    PersonalAccountProxy private personalAccountProxy;

    address private governance;
    address private executor;
    uint256 private executorFee;
    MyERC4626 private depositVault;
    MintableERC20 private fxrp;
    string private xrplProviderWallet;
    bytes32 private xrplProviderWalletHash;
    address private operator;
    address private personalAccountImplementation;
    uint256 private operatorExecutionWindowSeconds;
    string private xrplAddress1;
    address private contractRegistryMock;
    address private fdcVerificationMock;

    function setUp() public {
        governance = makeAddr("governance");
        executor = makeAddr("executor");
        fxrp = new MintableERC20("F-XRP", "fXRP");
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

    function _encodePaymentReference(
        uint256 callHash
    ) private pure returns (bytes32) {
        return bytes32((uint256(99) << 248) | callHash);
    }
}

