// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import {Script, console2} from "forge-std/Script.sol";
import {FAssetRedeemComposer} from "../../contracts/composer/implementation/FAssetRedeemComposer.sol";
import {FAssetRedeemerAccount} from "../../contracts/composer/implementation/FAssetRedeemerAccount.sol";
import {FAssetRedeemComposerProxy} from "../../contracts/composer/proxy/FAssetRedeemComposerProxy.sol";

// solhint-disable no-console
contract DeployComposer is Script {
    struct ComposerParams {
        address governance;
        address endpoint;
        address trustedSourceOApp;
        address assetManager;
        address stableCoin;
        address wNat;
        address composerFeeRecipient;
        uint256 defaultComposerFeePPM;
        address payable executor;
        uint256 timelockDurationSeconds;
    }

    FAssetRedeemComposer private composerImpl;
    FAssetRedeemerAccount private redeemerAccountImpl;
    FAssetRedeemComposerProxy private composerProxy;
    FAssetRedeemComposer private composer;

    function run(bool _onlyImpl) external {
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
            network = "scdev";
        }
        configFile = string.concat(configFile, network, ".json");
        console2.log(string.concat("NETWORK: ", network));

        vm.startBroadcast();

        // 1. Deploy Composer Implementation
        composerImpl = new FAssetRedeemComposer();

        if (!_onlyImpl) {
            ComposerParams memory params;
            string memory config = vm.readFile(configFile);

            // Parse config
            params.governance = vm.parseJsonAddress(config, ".governance");
            params.endpoint = vm.parseJsonAddress(config, ".endpoint");
            params.trustedSourceOApp = vm.parseJsonAddress(config, ".trustedSourceOApp");
            params.assetManager = vm.parseJsonAddress(config, ".assetManager");
            params.stableCoin = vm.parseJsonAddress(config, ".stableCoin");
            params.wNat = vm.parseJsonAddress(config, ".wNat");
            params.composerFeeRecipient = vm.parseJsonAddress(config, ".composerFeeRecipient");
            params.defaultComposerFeePPM = vm.parseJsonUint(config, ".defaultComposerFeePPM");
            params.executor = payable(vm.parseJsonAddress(config, ".composerExecutor"));
            params.timelockDurationSeconds = vm.parseJsonUint(config, ".timelockDurationSeconds");

            // 2. Deploy Redeemer Account Implementation
            redeemerAccountImpl = new FAssetRedeemerAccount();

            // 3. Deploy Composer Proxy (initializes the composer)
            // Initialize with deployer as owner to allow setup
            composerProxy = new FAssetRedeemComposerProxy(
                address(composerImpl),
                deployer,
                params.endpoint,
                params.trustedSourceOApp,
                params.assetManager,
                params.stableCoin,
                params.wNat,
                params.composerFeeRecipient,
                params.defaultComposerFeePPM,
                params.executor,
                address(redeemerAccountImpl)
            );

            composer = FAssetRedeemComposer(address(composerProxy));

            // 4. Set Timelock Duration
            console2.log("Setting timelock duration...");
            composer.setTimelockDuration(params.timelockDurationSeconds);

            // 5. Transfer ownership to governance
            if (params.governance != address(0) && params.governance != deployer) {
                console2.log("Transferring ownership to governance...");
                composer.transferOwnership(params.governance);
            }
        }

        vm.stopBroadcast();

        _logDeploymentInfo(_onlyImpl);
    }

    function _logDeploymentInfo(bool _onlyImpl) internal view {
        // Logs formatted for save-deployed-addresses.ts
        console2.log(
            string.concat(
                "DEPLOYED: FAssetRedeemComposerImplementation, ",
                "FAssetRedeemComposer.sol: ",
                vm.toString(address(composerImpl))
            )
        );
        if (!_onlyImpl) {
            console2.log(
                string.concat(
                    "DEPLOYED: FAssetRedeemerAccountImplementation, ",
                    "FAssetRedeemerAccount.sol: ",
                    vm.toString(address(redeemerAccountImpl))
                )
            );
            console2.log(
                string.concat(
                    "DEPLOYED: FAssetRedeemComposer, ",
                    "FAssetRedeemComposerProxy.sol: ",
                    vm.toString(address(composerProxy))
                )
            );
        }
    }
}
