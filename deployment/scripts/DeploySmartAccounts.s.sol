// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;
// solhint-disable no-console

import {Script, console2} from "forge-std/Script.sol";
import {PersonalAccount} from "../../contracts/smartAccounts/implementation/PersonalAccount.sol";
import {MasterAccountControllerBase}
    from "../../contracts/smartAccounts/implementation/MasterAccountControllerBase.sol";
import {MasterAccountController} from "../../contracts/smartAccounts/implementation/MasterAccountController.sol";
import {MasterAccountControllerProxy} from "../../contracts/smartAccounts/proxy/MasterAccountControllerProxy.sol";
import {IISingletonFactory} from "../../contracts/smartAccounts/interface/IISingletonFactory.sol";
import {ContractRegistry} from "flare-periphery/src/flare/ContractRegistry.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

// solhint-disable-next-line max-line-length
// forge script deployment/scripts/DeploySmartAccounts.s.sol:DeploySmartAccounts --private-key $DEPLOYER_PRIVATE_KEY --rpc-url $COSTON2_RPC_URL --etherscan-api-key $FLARE_RPC_API_KEY --broadcast --verify --verifier-url $COSTON2_FLARE_EXPLORER_API

contract DeploySmartAccounts is Script {

    struct MasterAccountControllerParams {
        address initialOwner;
        address governance;
        address[] vaults;
        address executor;
        uint256 executorFee;
        uint256 paymentProofValidityDurationSeconds;
        uint256 defaultInstructionFee;
        string[] xrplProviderWallets;
        address uniswapV3Router;
        address usdt0;
        uint24 wNatUsdt0PoolFeeTierPPM;
        uint24 usdt0FXrpPoolFeeTierPPM;
        uint24 maxSlippagePPM;
    }

    address public constant SINGLETON_FACTORY = 0xce0042B868300000d44A59004Da54A005ffdcf9f;

    PersonalAccount private personalAccountImpl;
    address private personalAccountImplAddress;
    MasterAccountControllerProxy private masterAccountControllerProxy;
    MasterAccountController private masterAccountControllerImpl;
    address private masterAccountControllerAddress;
    MasterAccountController private masterAccountController;
    address private seedMasterAccountControllerBase;
    address private masterAccountControllerProxyAddr;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        string memory configFile = "deployment/chain-config/";
        string memory network;
        uint256 chainId = block.chainid;

        if (chainId == 14) {
            network = "flare";
        } else if (chainId == 114) {
            network = "coston2";
        } else {
            configFile = "scdev";
        }
        configFile = string.concat(configFile, network, ".json");
        console2.log(string.concat("NETWORK: ", network));

        MasterAccountControllerParams memory params;
        string memory config = vm.readFile(configFile);
        params.initialOwner = vm.parseJsonAddress(config, ".initialOwner");
        params.governance = vm.parseJsonAddress(config, ".governance");
        params.vaults = vm.parseJsonAddressArray(config, ".vaults");
        params.executor = vm.parseJsonAddress(config, ".executor");
        params.executorFee = vm.parseJsonUint(config, ".executorFee");
        params.paymentProofValidityDurationSeconds = vm.parseJsonUint(config, ".paymentProofValidityDurationSeconds");
        params.defaultInstructionFee = vm.parseJsonUint(config, ".defaultInstructionFee");
        params.xrplProviderWallets = vm.parseJsonStringArray(config, ".xrplProviderWallets");
        params.uniswapV3Router = vm.parseJsonAddress(config, ".uniswapV3Router");
        params.usdt0 = vm.parseJsonAddress(config, ".usdt0");
        params.wNatUsdt0PoolFeeTierPPM = uint24(vm.parseJsonUint(config, ".wNatUsdt0PoolFeeTierPPM"));
        params.usdt0FXrpPoolFeeTierPPM = uint24(vm.parseJsonUint(config, ".usdt0FXrpPoolFeeTierPPM"));
        params.maxSlippagePPM = uint24(vm.parseJsonUint(config, ".maxSlippagePPM"));

        // if initial owner not set in config, use deployer address - for testing purposes
        if (params.initialOwner == address(0)) {
            params.initialOwner = deployer;
        }

        vm.startBroadcast();

        // deploy controller base seed via EIP-2470 singleton factory using CREATE2
        // same on all networks
        bytes memory bytecode = abi.encodePacked(
            type(MasterAccountControllerBase).creationCode
        );
        bytes32 salt = bytes32(0);
        address expected = Create2.computeAddress(salt, keccak256(bytecode), SINGLETON_FACTORY);
        uint256 codeSize = expected.code.length;
        if (codeSize == 0) {
            console2.log("Deploying seed MasterAccountControllerBase via singleton factory");
            seedMasterAccountControllerBase = IISingletonFactory(SINGLETON_FACTORY).deploy(bytecode, salt);
            require(
                expected == seedMasterAccountControllerBase && expected.code.length > 0,
                "Seed MasterAccountControllerBase deployment failed"
            );
        } else {
            console2.log("Seed MasterAccountControllerBase already deployed, skipping");
            seedMasterAccountControllerBase = expected;
        }

        // deploy controller proxy using CREATE2
        // same on all networks
        bytecode = abi.encodePacked(
            type(MasterAccountControllerProxy).creationCode,
            abi.encode(
                seedMasterAccountControllerBase,
                params.initialOwner
            )
        );
        expected = Create2.computeAddress(salt, keccak256(bytecode), SINGLETON_FACTORY);
        codeSize = expected.code.length;
        if (codeSize == 0) {
            console2.log("Deploying MasterAccountControllerProxy via singleton factory");
            masterAccountControllerProxyAddr = IISingletonFactory(SINGLETON_FACTORY).deploy(bytecode, salt);
            require(
                expected == masterAccountControllerProxyAddr && expected.code.length > 0,
                "MasterAccountControllerProxy deployment failed"
            );
        } else {
            console2.log("MasterAccountControllerProxy already deployed, skipping");
            masterAccountControllerProxyAddr = expected;
        }

        // (re)deploy personal account implementation
        personalAccountImpl = new PersonalAccount();
        personalAccountImplAddress = address(personalAccountImpl);

        // (re)deploy real controller implementation
        masterAccountControllerImpl = new MasterAccountController();

        // Log deployment info for post-processing
        console2.log(
            string.concat(
                "DEPLOYED: SeedMasterAccountControllerImplementation, ",
                "MasterAccountControllerBase.sol: ",
                vm.toString(seedMasterAccountControllerBase)
            )
        );
        console2.log(
            string.concat(
                "DEPLOYED: MasterAccountController, ",
                "MasterAccountControllerProxy.sol:  ",
                vm.toString(masterAccountControllerProxyAddr)
            )
        );
        console2.log(
            string.concat(
                "DEPLOYED: MasterAccountControllerImplementation, ",
                "MasterAccountController.sol: ",
                vm.toString(address(masterAccountControllerImpl))
            )
        );
        console2.log(
            string.concat(
                "DEPLOYED: PersonalAccountImplementation, ",
                "PersonalAccount.sol: ",
                vm.toString(personalAccountImplAddress)
            )
        );

        masterAccountController = MasterAccountController(masterAccountControllerProxyAddr);
        if (deployer != masterAccountController.owner()) {
            console2.log("Deployer is not owner, skipping upgrades");
            vm.stopBroadcast();
            return;
        }

        if (seedMasterAccountControllerBase != masterAccountController.controllerImplementation()) {
            // deployer is owner, perform upgrades (initialization was already done)
            console2.log("Upgrading MasterAccountController and PersonalAccount implementations");
            masterAccountController.setPersonalAccountImplementation(personalAccountImplAddress);
            masterAccountController.upgradeToAndCall(address(masterAccountControllerImpl), bytes(""));
            vm.stopBroadcast();
            return;
        }

        // deployer is owner, perform upgrade and initialization
        console2.log("Upgrading MasterAccountController implementation and initializing");
        // upgrade controller proxy to real implementation and initialize in one call
        masterAccountController.upgradeToAndCall(
            address(masterAccountControllerImpl),
            abi.encodeWithSelector(
                MasterAccountController.initialize.selector,
                payable(params.executor),
                params.executorFee,
                params.paymentProofValidityDurationSeconds,
                params.defaultInstructionFee,
                personalAccountImplAddress
            )
        );

        // set swap parameters
        if (params.uniswapV3Router != address(0)) {
            console2.log("Setting swap parameters");
            masterAccountController.setSwapParams(
                params.uniswapV3Router,
                params.usdt0,
                params.wNatUsdt0PoolFeeTierPPM,
                params.usdt0FXrpPoolFeeTierPPM,
                params.maxSlippagePPM
            );
        } else {
            console2.log("Swap parameters not set, swap is disabled");
        }

        console2.log("Adding XRPL provider wallets");
        masterAccountController.addXrplProviderWallets(params.xrplProviderWallets);

        console2.log("Adding agent vaults");
        // get available agent vaults and add them
        (address[] memory agentVaultAddresses, ) =
            ContractRegistry.getAssetManagerFXRP().getAvailableAgentsList(0, 10);
        uint256[] memory agentVaultIds = new uint256[](agentVaultAddresses.length);
        for (uint256 i = 0; i < agentVaultAddresses.length; i++) {
            agentVaultIds[i] = i + 1; // agent vault IDs are 1-based
        }
        masterAccountController.addAgentVaults(agentVaultIds, agentVaultAddresses);

        console2.log("Adding vaults");
        uint256[] memory vaultIds = new uint256[](params.vaults.length);
        for (uint256 i = 0; i < params.vaults.length; i++) {
            vaultIds[i] = i + 1; // vault IDs are 1-based
        }
        masterAccountController.addVaults(vaultIds, params.vaults);

        if (params.governance == address(0)) {
            console2.log("Governance address is zero, skipping ownership transfer");
        } else {
            console2.log("Transferring ownership to governance");
            masterAccountController.transferOwnership(params.governance);
        }
        vm.stopBroadcast();
    }
}
