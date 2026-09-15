// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import {Script, console2} from "forge-std/Script.sol";
import {FAssetRedeemComposer} from "../../contracts/composer/implementation/FAssetRedeemComposer.sol";
import {FAssetRedeemerAccount} from "../../contracts/composer/implementation/FAssetRedeemerAccount.sol";
import {FAssetRedeemComposerProxy} from "../../contracts/composer/proxy/FAssetRedeemComposerProxy.sol";
import {IOwnableWithTimelock} from "../../contracts/userInterfaces/IOwnableWithTimelock.sol";
import {DeployNetworks} from "../lib/DeployNetworks.sol";

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

    function run(
        string calldata _expectedNetwork,
        bool _onlyImpl
    )
        external
    {
        // The signer is forge's, resolved from whatever the wrapper passed - a raw key, a keystore
        // or a Ledger - and `msg.sender` is that account. Reading DEPLOYER_PRIVATE_KEY here would
        // check one account and sign as another the moment the two differ, which is exactly what a
        // hardware run is. Note this validates the sender forge was GIVEN; a device whose address
        // is not that one fails later, at signing, rather than here.
        address deployer = msg.sender;

        // the composer is a Flare-side contract, held to the Flare family like the account
        // implementations are, and to the name the wrapper dialed the RPC by. Only the Flare and
        // Coston2 chain configs carry usable composer values
        require(DeployNetworks.isFlareFamily(block.chainid), "the composer belongs on a Flare-family chain");
        string memory network = DeployNetworks.networkName(block.chainid);
        DeployNetworks.requireExpectedNetwork(network, _expectedNetwork);
        string memory configFile = string.concat("deployment/chain-config/", network, ".json");
        console2.log(string.concat("NETWORK: ", network));

        // Broadcast AS the validated account rather than leaving it implicit. In a script run the
        // two are the same - forge resolves the signer and `msg.sender` is it - but naming it keeps
        // the account this script checked and the account that signs from ever drifting apart.
        vm.startBroadcast(msg.sender);

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

            // mirrors `OwnableWithTimelock.MAX_TIMELOCK_DURATION_SECONDS`, which is internal:
            // a longer duration makes the arming call revert, so it is caught before anything
            // is deployed rather than after the composer is live
            require(
                params.timelockDurationSeconds <= 7 days,
                "timelockDurationSeconds above the 7 day maximum"
            );

            // Governance owns the composer from its first block whenever it is configured:
            // every setting is applied by `initialize`, so the deployer never needs the role.
            // The other order - deployer as owner, arm the timelock, then hand over - would
            // queue the transfer, because `transferOwnership` is guarded too, leaving the
            // deployer owning the composer (and able to cancel that handover) until someone
            // executed it. Arming the timelock is instead governance's own first call,
            // immediate because the duration starts at zero; it is printed below.
            address initialOwner =
                params.governance != address(0) ? params.governance : deployer;

            // 2. Deploy Redeemer Account Implementation
            redeemerAccountImpl = new FAssetRedeemerAccount();

            // 3. Deploy Composer Proxy (initializes the composer)
            composerProxy = new FAssetRedeemComposerProxy(
                address(composerImpl),
                initialOwner,
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

            // 4. Arm the timelock. Only the owner can: the deployer does it directly when
            // no governance address is configured, otherwise it is governance's own first
            // call and the script prints exactly what to send.
            if (initialOwner == deployer) {
                console2.log("Setting timelock duration...");
                composer.setTimelockDuration(params.timelockDurationSeconds);
            } else {
                console2.log("Owner is governance; timelock NOT armed yet.");
                console2.log("  governance must call setTimelockDuration on:", address(composer));
                console2.log("  seconds: ", params.timelockDurationSeconds);
                console2.log("  calldata:", vm.toString(
                    abi.encodeCall(IOwnableWithTimelock.setTimelockDuration, (params.timelockDurationSeconds))
                ));
            }
        }

        vm.stopBroadcast();

        _logDeploymentInfo(_onlyImpl);
    }

    function _logDeploymentInfo(
        bool _onlyImpl
    )
        internal view
    {
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
                    "DEPLOYED: FAssetRedeemComposer_FXRP, ",
                    "FAssetRedeemComposerProxy.sol: ",
                    vm.toString(address(composerProxy))
                )
            );
        }
    }
}
