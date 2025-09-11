// SPDX-License-Identifier: UNLICENSED
// solhint-disable one-contract-per-file
// solhint-disable no-console
pragma solidity ^0.8.27;

import {Test, console2} from "forge-std/Test.sol";
// solhint-disable-next-line max-line-length
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
    IMasterAccountController.CustomInstruction public customInstruction;
    SimpleExample public simpleExample;

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
    string private xrplAccount1;
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
            address(fxrp),
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

        xrplAccount1 = "xrplAccount1";

        simpleExample = new SimpleExample();

        customInstruction = IMasterAccountController.CustomInstruction(
            address(simpleExample),
            1,
            abi.encodeWithSignature("foo(uint256)", [uint256(1)])
        );
    }

    // solhint-disable-next-line func-name-mixedcase
    function test_registerCustomInstruction() public {
        masterAccountController.registerCustomInstruction(customInstruction);

        uint256 callHash = masterAccountController.encodeCustomInstruction(
            customInstruction
        );
        console2.log("callHash: ", callHash);
        IMasterAccountController.CustomInstruction
            memory storedCustomInstruction = masterAccountController
                .getCustomInstruction(callHash);

        console2.log("storedCustomInstruction: ");
        console2.log("  contract:", storedCustomInstruction._contract);
        console2.log("  value:", storedCustomInstruction._value);
        // console2.log("  calldata:", storedCustomInstruction._calldata);
        console2.log("customInstruction: ");
        console2.log("  contract:", customInstruction._contract);
        console2.log("  value:", customInstruction._value);
        // console2.log("  calldata:", customInstruction._calldata);

        console2.log("hashes of all custom instructions: ");
        for (
            uint256 i = 0;
            i < masterAccountController.getAllCallHashes().length;
            i++
        ) {
            console2.log("  ", masterAccountController.allCallHashes(i));
        }
        // Custom instruction should be stored under the right hash
        assertEq(
            abi.encode(storedCustomInstruction),
            abi.encode(customInstruction)
        );
    }

    // solhint-disable-next-line func-name-mixedcase
    function test_executeCustomInstruction() public {
        masterAccountController.registerCustomInstruction(customInstruction);
        uint256 callHash = masterAccountController.encodeCustomInstruction(
            customInstruction
        );
        console2.log("callHash: ", callHash);

        IPayment.Proof memory proof;
        proof.data.responseBody.receivingAddressHash = xrplProviderWalletHash;
        proof.data.responseBody.sourceAddressHash = keccak256(
            abi.encodePacked(xrplAccount1)
        );
        proof.data.requestBody.transactionId = bytes32("tx1");
        proof
            .data
            .responseBody
            .standardPaymentReference = _encodePaymentReference(callHash);
        console2.log("paymentReference: ");
        console2.logBytes32(proof.data.responseBody.standardPaymentReference);
        console2.log("");
        console2.log(
            "instruction id:",
            (uint256(proof.data.responseBody.standardPaymentReference) >> 248) &
                0xFF
        );
        console2.log(
            "remainder: ",
            uint256(proof.data.responseBody.standardPaymentReference) &
                ((uint256(1) << 248) - 1)
        );

        _mockVerifyPayment(true);
        deal(address(masterAccountController), 100 ether);
        vm.prank(operator);
        masterAccountController.executeTransaction(proof, xrplAccount1);

        console2.log("simpleExample.map(1): ", simpleExample.map(1));
        console2.log("customInstruction._value: ", customInstruction._value);
        console2.log("allKeys: ");
        for (uint256 i = 0; i < simpleExample.getAllKeys().length; i++) {
            console2.log("  ", simpleExample.allKeys(i));
        }

        // The state of the example contract should be updated by the master account controller
        assertEq(simpleExample.map(1), customInstruction._value);
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

contract SimpleExample {
    mapping(uint256 => uint256) public map;
    uint256[] public allKeys;

    function foo(uint256 a) public payable {
        require(a > 0, "a must be greater than 0");
        require(msg.value > 0, "msg.value must be greater than 0");
        if (map[a] == 0) {
            allKeys.push(a);
        }
        map[a] = map[a] + msg.value;
    }

    function getAllKeys() public view returns (uint256[] memory) {
        return allKeys;
    }
}
