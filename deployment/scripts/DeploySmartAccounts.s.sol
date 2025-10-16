// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;
// solhint-disable no-console

import {Script, console2} from "forge-std/Script.sol";
import {PersonalAccount} from "../../contracts/smartAccounts/implementation/PersonalAccount.sol";
import {PersonalAccountBase} from "../../contracts/smartAccounts/implementation/PersonalAccountBase.sol";
import {MasterAccountController} from "../../contracts/smartAccounts/implementation/MasterAccountController.sol";
import {MasterAccountControllerProxy} from "../../contracts/smartAccounts/proxy/MasterAccountControllerProxy.sol";
import {IISingletonFactory} from "../../contracts/smartAccounts/interface/IISingletonFactory.sol";
import {IGovernanceSettings} from "flare-periphery/src/flare/IGovernanceSettings.sol";
import {ContractRegistry} from "flare-periphery/src/flare/ContractRegistry.sol";
import {Create2} from "@openzeppelin-contracts/utils/Create2.sol";

// solhint-disable-next-line max-line-length
// forge script deployment/scripts/DeploySmartAccounts.s.sol:DeploySmartAccounts --private-key $DEPLOYER_PRIVATE_KEY --rpc-url $COSTON2_RPC_URL --etherscan-api-key $FLARE_RPC_API_KEY --broadcast --verify --verifier-url $COSTON2_FLARE_EXPLORER_API

contract DeploySmartAccounts is Script {
    address public constant SINGLETON_FACTORY = 0xce0042B868300000d44A59004Da54A005ffdcf9f;

    PersonalAccount private personalAccountImpl;
    address private personalAccountImplAddress;
    address private seedPersonalAccountImpl;
    MasterAccountControllerProxy private masterAccountControllerProxy;
    MasterAccountController private masterAccountControllerImpl;
    address private masterAccountControllerAddress;
    MasterAccountController private masterAccountController;

    struct MasterAccountControllerParams {
        address depositVault;
        address executor;
        uint256 executorFee;
        uint256 paymentProofValidityDurationSeconds;
        uint256 defaultInstructionFee;
        string xrplProviderWallet;
    }

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

        MasterAccountControllerParams memory params;
        string memory config = vm.readFile(configFile);
        params.depositVault = vm.parseJsonAddress(config, ".depositVault");
        params.executor = vm.parseJsonAddress(config, ".executor");
        params.executorFee = vm.parseJsonUint(config, ".executorFee");
        params.paymentProofValidityDurationSeconds = vm.parseJsonUint(config, ".paymentProofValidityDurationSeconds");
        params.defaultInstructionFee = vm.parseJsonUint(config, ".defaultInstructionFee");
        params.xrplProviderWallet = vm.parseJsonString(config, ".xrplProviderWallet");

        vm.startBroadcast();
        // deploy personal account implementation
        personalAccountImpl = new PersonalAccount();
        personalAccountImplAddress = address(personalAccountImpl);

        // deploy seed personal account implementation via EIP-2470 singleton factory using CREATE2
        bytes memory bytecode = abi.encodePacked(
            type(PersonalAccountBase).creationCode
        );
        // needs to be the same on all networks
        bytes32 salt = keccak256(abi.encodePacked("PersonalAccountBaseSeed"));

        address expected = Create2.computeAddress(salt, keccak256(bytecode), SINGLETON_FACTORY);
        uint256 codeSize;
        assembly { codeSize := extcodesize(expected) }
        // require(codeSize == 0, "Contract already deployed at expected address");


        seedPersonalAccountImpl = IISingletonFactory(SINGLETON_FACTORY).deploy(bytecode, salt);

        // deploy master account controller implementation
        masterAccountControllerImpl = new MasterAccountController();
        masterAccountControllerProxy = new MasterAccountControllerProxy(
            address(masterAccountControllerImpl),
            IGovernanceSettings(governanceSettings),
            governance,
            payable(params.executor),
            params.executorFee,
            params.paymentProofValidityDurationSeconds,
            params.defaultInstructionFee,
            params.xrplProviderWallet,
            personalAccountImplAddress,
            seedPersonalAccountImpl
        );
        masterAccountController = MasterAccountController(
            address(masterAccountControllerProxy)
        );
        masterAccountControllerAddress = address(masterAccountControllerProxy);

        // add agent vaults
        (address[] memory agentVaultAddresses, ) = ContractRegistry.getAssetManagerFXRP().getAvailableAgentsList(0, 10);
        uint256[] memory agentVaultIds = new uint256[](agentVaultAddresses.length);
        for (uint256 i = 0; i < agentVaultAddresses.length; i++) {
            agentVaultIds[i] = i;
        }
        masterAccountController.addAgentVaults(agentVaultIds, agentVaultAddresses);
        // add vault
        uint256[] memory vaultIds = new uint256[](1);
        address[] memory vaultAddresses = new address[](1);
        vaultIds[0] = 0;
        vaultAddresses[0] = params.depositVault;
        masterAccountController.addVaults(vaultIds, vaultAddresses);

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
