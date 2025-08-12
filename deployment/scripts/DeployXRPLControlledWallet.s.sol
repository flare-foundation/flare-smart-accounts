// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.25;

import {Script, console2} from "forge-std/Script.sol";
import {PersonalAccount} from "../../contracts/xrpcw/implementation/PersonalAccount.sol";
import {MasterAccountController} from "../../contracts/xrpcw/implementation/MasterAccountController.sol";
import {MasterAccountControllerProxy} from "../../contracts/xrpcw/proxy/MasterAccountControllerProxy.sol";
import {IGovernanceSettings} from "@flarenetwork/flare-periphery-contracts/flare/IGovernanceSettings.sol";

contract DeployXRPLControlledWallet is Script {

    PersonalAccount private personalAccountImpl;
    address private personalAccountImplAddress;
    MasterAccountControllerProxy private masterAccountControllerProxy;
    MasterAccountController private masterAccountControllerImpl;
    address private masterAccountControllerAddress;
    MasterAccountController private masterAccountController;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        address governanceSettings = 0x1000000000000000000000000000000000000007;
        address governance = deployer;
        address depositVault = makeAddr("DepositVault");
        address fxrp = makeAddr("FXRP");
        address executor = makeAddr("Executor");
        uint256 executorFee = 100;
        string memory xrplProviderWallet = "rXrplProviderWallet";
        address operator = makeAddr("Operator");
        uint256 operatorExecutionWindowSeconds = 60;

        vm.startBroadcast();

        // deploy personal account implementation
        personalAccountImpl = new PersonalAccount();
        personalAccountImplAddress = address(personalAccountImpl);

        // deploy master account controller implementation
        masterAccountControllerImpl = new MasterAccountController();
        masterAccountControllerProxy = new MasterAccountControllerProxy(
            address(masterAccountControllerImpl),
            IGovernanceSettings(governanceSettings),
            governance,
            address(depositVault),
            address(fxrp),
            payable(executor),
            executorFee,
            xrplProviderWallet,
            operator,
            operatorExecutionWindowSeconds,
            personalAccountImplAddress
        );
        masterAccountController = MasterAccountController(address(masterAccountControllerProxy));
        masterAccountControllerAddress = address(masterAccountControllerProxy);

        // switch to production mode
        masterAccountController.switchToProductionMode();

        console2.log("Personal Account Implementation Address:");
        console2.log(personalAccountImplAddress);
        console2.log("Master Account Controller Proxy Address:");
        console2.log(masterAccountControllerAddress);
        console2.log("Master Account Controller Implementation Address:");
        console2.log(address(masterAccountControllerImpl));

        vm.stopBroadcast();
    }
}
