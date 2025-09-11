// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import {Script, console2} from "forge-std/Script.sol";
import {PersonalAccount} from "../../contracts/xrpcw/implementation/PersonalAccount.sol";
import {MasterAccountController} from "../../contracts/xrpcw/implementation/MasterAccountController.sol";
import {MasterAccountControllerProxy} from "../../contracts/xrpcw/proxy/MasterAccountControllerProxy.sol";
import {IGovernanceSettings} from "flare-periphery/src/flare/IGovernanceSettings.sol";

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

        string memory configFile = "deployment/chain-config/";
        string memory network;
        uint256 chainId = block.chainid;

        if (chainId == 114) {
            network = "coston2";
        } else {
            configFile = "scdev";
        }
        configFile = string.concat(configFile, network, ".json");
        console2.log(string.concat("NETWORK: ", network));

        string memory config = vm.readFile(configFile);
        address depositVault = vm.parseJsonAddress(config, ".depositVault");
        address executor = vm.parseJsonAddress(config, ".executor");
        uint256 executorFee = vm.parseJsonUint(config, ".executorFee");
        string memory xrplProviderWallet = vm.parseJsonString(
            config,
            ".xrplProviderWallet"
        );
        address operator = vm.parseJsonAddress(config, ".operator");
        uint256 operatorExecutionWindowSeconds = vm.parseJsonUint(
            config,
            ".operatorExecutionWindowSeconds"
        );

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
            payable(executor),
            executorFee,
            xrplProviderWallet,
            operator,
            operatorExecutionWindowSeconds,
            personalAccountImplAddress
        );
        masterAccountController = MasterAccountController(
            address(masterAccountControllerProxy)
        );
        masterAccountControllerAddress = address(masterAccountControllerProxy);

        // switch to production mode
        masterAccountController.switchToProductionMode();

        vm.stopBroadcast();
        // Log deployment info for post-processing
        console2.log(
            string.concat(
                "DEPLOYED: PersonalAccountImplementation, ",
                "PersonalAccount.sol: ",
                vm.toString(personalAccountImplAddress)
            )
        );
        console2.log(
            string.concat(
                "DEPLOYED: MasterAccountController, ",
                "MasterAccountControllerProxy.sol:  ",
                vm.toString(masterAccountControllerAddress)
            )
        );
        console2.log(
            string.concat(
                "DEPLOYED: MasterAccountControllerImplementation, ",
                "MasterAccountController.sol: ",
                vm.toString(address(masterAccountControllerImpl))
            )
        );
    }
}
