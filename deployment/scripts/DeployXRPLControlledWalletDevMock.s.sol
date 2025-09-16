// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;
// solhint-disable no-console

import {Script, console2} from "forge-std/Script.sol";
import {PersonalAccount} from "../../contracts/xrpcw/implementation/PersonalAccount.sol";
import {MasterAccountControllerDevMock} from "../../contracts/xrpcw/implementation/MasterAccountControllerDevMock.sol";
// solhint-disable-next-line max-line-length
import {MasterAccountControllerDevMockProxy} from "../../contracts/xrpcw/proxy/MasterAccountControllerDevMockProxy.sol";
import {IGovernanceSettings} from "flare-periphery/src/flare/IGovernanceSettings.sol";

// solhint-disable-next-line max-line-length
// forge script deployment/scripts/DeployXRPLControlledWallet.s.sol:DeployXRPLControlledWallet --private-key $DEPLOYER_PRIVATE_KEY --rpc-url $COSTON2_RPC_URL --etherscan-api-key $FLARE_RPC_API_KEY --broadcast --verify --verifier-url $COSTON2_FLARE_EXPLORER_API

contract DeployXRPLControlledWalletDevMock is Script {
    PersonalAccount private personalAccountImpl;
    address private personalAccountImplAddress;
    MasterAccountControllerDevMockProxy private masterAccountControllerDevMockProxy;
    MasterAccountControllerDevMock private masterAccountControllerDevMockImpl;
    address private masterAccountControllerDevMockAddress;
    MasterAccountControllerDevMock private masterAccountControllerDevMock;

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
        masterAccountControllerDevMockImpl = new MasterAccountControllerDevMock();
        masterAccountControllerDevMockProxy = new MasterAccountControllerDevMockProxy(
            address(masterAccountControllerDevMockImpl),
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
        masterAccountControllerDevMock = MasterAccountControllerDevMock(
            address(masterAccountControllerDevMockProxy)
        );
        masterAccountControllerDevMockAddress = address(masterAccountControllerDevMockProxy);

        // switch to production mode
        masterAccountControllerDevMock.switchToProductionMode();

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
                "DEPLOYED: MasterAccountControllerDevMock, ",
                "MasterAccountControllerDevMockProxy.sol:  ",
                vm.toString(masterAccountControllerDevMockAddress)
            )
        );
        console2.log(
            string.concat(
                "DEPLOYED: MasterAccountControllerDevMockImplementation, ",
                "MasterAccountControllerDevMock.sol: ",
                vm.toString(address(masterAccountControllerDevMockImpl))
            )
        );
    }
}
