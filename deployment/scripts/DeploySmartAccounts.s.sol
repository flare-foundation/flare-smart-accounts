// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;
// solhint-disable no-console

import {Script, console2} from "forge-std/Script.sol";
import {PersonalAccount} from "../../contracts/smartAccounts/implementation/PersonalAccount.sol";
import {MasterAccountController} from "../../contracts/smartAccounts/implementation/MasterAccountController.sol";
import {DiamondArgs} from "../../contracts/diamond/implementation/Diamond.sol";
import {IISingletonFactory} from "../../contracts/smartAccounts/interface/IISingletonFactory.sol";
import {IIMasterAccountController} from "../../contracts/smartAccounts/interface/IIMasterAccountController.sol";
import {IDiamond} from "../../contracts/diamond/interfaces/IDiamond.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
// facets
import {MasterAccountControllerInit} from "../../contracts/smartAccounts/facets/MasterAccountControllerInit.sol";
import {DiamondLoupeFacet} from "../../contracts/diamond/facets/DiamondLoupeFacet.sol";
import {DiamondCutFacet} from "../../contracts/smartAccounts/facets/DiamondCutFacet.sol";
import {OwnershipFacet} from "../../contracts/diamond/facets/OwnershipFacet.sol";
import {AgentVaultsFacet} from "../../contracts/smartAccounts/facets/AgentVaultsFacet.sol";
import {ExecutorsFacet} from "../../contracts/smartAccounts/facets/ExecutorsFacet.sol";
import {InstructionFeesFacet} from "../../contracts/smartAccounts/facets/InstructionFeesFacet.sol";
import {InstructionsFacet} from "../../contracts/smartAccounts/facets/InstructionsFacet.sol";
import {PaymentProofsFacet} from "../../contracts/smartAccounts/facets/PaymentProofsFacet.sol";
import {PersonalAccountsFacet} from "../../contracts/smartAccounts/facets/PersonalAccountsFacet.sol";
import {SwapFacet} from "../../contracts/smartAccounts/facets/SwapFacet.sol";
import {TimelockFacet} from "../../contracts/smartAccounts/facets/TimelockFacet.sol";
import {VaultsFacet} from "../../contracts/smartAccounts/facets/VaultsFacet.sol";
import {XrplProviderWalletsFacet} from "../../contracts/smartAccounts/facets/XrplProviderWalletsFacet.sol";

// solhint-disable no-console
// solhint-disable-next-line max-line-length
// forge script deployment/scripts/DeploySmartAccounts.s.sol:DeploySmartAccounts --private-key $DEPLOYER_PRIVATE_KEY --rpc-url $COSTON2_RPC_URL --etherscan-api-key $FLARE_RPC_API_KEY --broadcast --verify --verifier-url $COSTON2_FLARE_EXPLORER_API

contract DeploySmartAccounts is Script {
    struct AgentVaultConfig {
        address agentVaultAddress;
        uint256 agentVaultId;
    }

    struct VaultConfig {
        uint256 vaultId;
        address vaultAddress;
        uint8 vaultType;
    }

    struct MasterAccountControllerParams {
        address initialOwner;
        address governance;
        VaultConfig[] vaults;
        AgentVaultConfig[] agentVaults;
        address executor;
        uint256 executorFee;
        bytes32 sourceId;
        uint256 paymentProofValidityDurationSeconds;
        uint256 defaultInstructionFee;
        string[] xrplProviderWallets;
        address uniswapV3Router;
        address usdt0;
        uint24 wNatStableCoinPoolFeeTierPPM;
        uint24 stableCoinFXrpPoolFeeTierPPM;
        uint24 maxSlippagePPM;
        bytes21 stableCoinUsdFeedId;
        bytes21 wNatUsdFeedId;
        uint256 timelockDurationSeconds;
    }

    address public constant SINGLETON_FACTORY = 0xce0042B868300000d44A59004Da54A005ffdcf9f;

    PersonalAccount private personalAccountImpl;
    address private personalAccountImplAddress;
    IIMasterAccountController private masterAccountController;
    address private masterAccountControllerAddress;

    // facets
    IDiamond.FacetCut[] private baseFacets;
    IDiamond.FacetCut[] private smartAccountsFacets;
    address private diamondCutFacet;
    address private diamondLoupeFacet;
    address private ownershipFacet;
    AgentVaultsFacet private agentVaultsFacet;
    ExecutorsFacet private executorsFacet;
    InstructionFeesFacet private instructionFeesFacet;
    InstructionsFacet private instructionsFacet;
    PaymentProofsFacet private paymentProofsFacet;
    PersonalAccountsFacet private personalAccountsFacet;
    SwapFacet private swapFacet;
    TimelockFacet private timelockFacet;
    VaultsFacet private vaultsFacet;
    XrplProviderWalletsFacet private xrplProviderWalletsFacet;

    function run(bool _fullDeploy) external {
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

        MasterAccountControllerParams memory params;
        string memory config = vm.readFile(configFile);
        params.initialOwner = vm.parseJsonAddress(config, ".initialOwner");
        params.governance = vm.parseJsonAddress(config, ".governance");
        params.vaults = abi.decode(vm.parseJson(config, ".vaults"), (VaultConfig[]));
        params.agentVaults = abi.decode(vm.parseJson(config, ".agentVaults"), (AgentVaultConfig[]));
        params.executor = vm.parseJsonAddress(config, ".executor");
        params.executorFee = vm.parseJsonUint(config, ".executorFee");
        params.sourceId = bytes32(bytes(vm.parseJsonString(config, ".sourceId")));
        params.paymentProofValidityDurationSeconds = vm.parseJsonUint(config, ".paymentProofValidityDurationSeconds");
        params.defaultInstructionFee = vm.parseJsonUint(config, ".defaultInstructionFee");
        params.xrplProviderWallets = vm.parseJsonStringArray(config, ".xrplProviderWallets");
        params.uniswapV3Router = vm.parseJsonAddress(config, ".uniswapV3Router");
        params.usdt0 = vm.parseJsonAddress(config, ".usdt0");
        params.wNatStableCoinPoolFeeTierPPM = uint24(vm.parseJsonUint(config, ".wNatStableCoinPoolFeeTierPPM"));
        params.stableCoinFXrpPoolFeeTierPPM = uint24(vm.parseJsonUint(config, ".stableCoinFXrpPoolFeeTierPPM"));
        params.maxSlippagePPM = uint24(vm.parseJsonUint(config, ".maxSlippagePPM"));
        params.stableCoinUsdFeedId = bytes21(vm.parseJsonBytes(config, ".stableCoinUsdFeedId"));
        params.wNatUsdFeedId = bytes21(vm.parseJsonBytes(config, ".wNatUsdFeedId"));
        params.timelockDurationSeconds = vm.parseJsonUint(config, ".timelockDurationSeconds");

        // if initial owner not set in config, use deployer address - for testing purposes
        if (params.initialOwner == address(0)) {
            params.initialOwner = deployer;
        }

        vm.startBroadcast();

        // (re)deploy personal account implementation
        personalAccountImpl = new PersonalAccount();
        personalAccountImplAddress = address(personalAccountImpl);

        bytes32 salt = bytes32(0);
        // bytes32 salt = keccak256(abi.encodePacked("salt", block.timestamp)); // only for testing
        // deploy diamond cut, diamond loupe and ownership facets via EIP-2470 singleton factory using CREATE2
        // same address on all networks
        bytes memory bytecode = abi.encodePacked(
            type(DiamondCutFacet).creationCode
        );
        address expected = Create2.computeAddress(salt, keccak256(bytecode), SINGLETON_FACTORY);
        uint256 codeSize = expected.code.length;
        if (codeSize == 0) {
            console2.log("Deploying DiamondCutFacet via singleton factory");
            diamondCutFacet = IISingletonFactory(SINGLETON_FACTORY).deploy(bytecode, salt);
            require(
                expected == diamondCutFacet && expected.code.length > 0,
                "DiamondCutFacet deployment failed"
            );
        } else {
            console2.log("DiamondCutFacet already deployed, skipping");
            diamondCutFacet = expected;
        }
        baseFacets.push(_addFacet(diamondCutFacet, "DiamondCutFacet"));

        bytecode = abi.encodePacked(
            type(DiamondLoupeFacet).creationCode
        );
        expected = Create2.computeAddress(salt, keccak256(bytecode), SINGLETON_FACTORY);
        codeSize = expected.code.length;
        if (codeSize == 0) {
            console2.log("Deploying DiamondLoupeFacet via singleton factory");
            diamondLoupeFacet = IISingletonFactory(SINGLETON_FACTORY).deploy(bytecode, salt);
            require(
                expected == diamondLoupeFacet && expected.code.length > 0,
                "DiamondLoupeFacet deployment failed"
            );
        } else {
            console2.log("DiamondLoupeFacet already deployed, skipping");
            diamondLoupeFacet = expected;
        }
        baseFacets.push(_addFacet(diamondLoupeFacet, "DiamondLoupeFacet"));

        bytecode = abi.encodePacked(
            type(OwnershipFacet).creationCode
        );
        expected = Create2.computeAddress(salt, keccak256(bytecode), SINGLETON_FACTORY);
        codeSize = expected.code.length;
        if (codeSize == 0) {
            console2.log("Deploying OwnershipFacet via singleton factory");
            ownershipFacet = IISingletonFactory(SINGLETON_FACTORY).deploy(bytecode, salt);
            require(
                expected == ownershipFacet && expected.code.length > 0,
                "OwnershipFacet deployment failed"
            );
        } else {
            console2.log("OwnershipFacet already deployed, skipping");
            ownershipFacet = expected;
        }
        baseFacets.push(_addFacet(ownershipFacet, "OwnershipFacet"));

        // deploy MasterAccountController (with base facets) using CREATE2 (same address on all networks)
        // TODO check if facets are already deployed and skip deployment if so
        DiamondArgs memory args = DiamondArgs({
            owner: params.initialOwner,
            initAddress: address(0),
            initCalldata: ""
        });
        bytecode = abi.encodePacked(
            type(MasterAccountController).creationCode,
            abi.encode(
                baseFacets,
                args
            )
        );
        expected = Create2.computeAddress(salt, keccak256(bytecode), SINGLETON_FACTORY);
        codeSize = expected.code.length;
        if (codeSize == 0) {
            console2.log("Deploying MasterAccountController via singleton factory");
            masterAccountControllerAddress = IISingletonFactory(SINGLETON_FACTORY).deploy(bytecode, salt);
            require(
                expected == masterAccountControllerAddress && expected.code.length > 0,
                "MasterAccountController deployment failed"
            );
        } else {
            console2.log("MasterAccountController already deployed, skipping");
            masterAccountControllerAddress = expected;
        }
        masterAccountController = IIMasterAccountController(masterAccountControllerAddress);

        // deploy smart account facets and initialize master account controller
        _deploySmartAccountsFacets();
        MasterAccountControllerInit masterAccountControllerInit = new MasterAccountControllerInit();

        if (_fullDeploy) {
            console2.log("Executing diamond cut to add smart accounts facets and initialize");
            masterAccountController.diamondCut(
                smartAccountsFacets,
                address(masterAccountControllerInit),
                abi.encodeWithSelector(
                    MasterAccountControllerInit.init.selector,
                    payable(params.executor),
                    params.executorFee,
                    params.sourceId,
                    params.paymentProofValidityDurationSeconds,
                    params.defaultInstructionFee,
                    personalAccountImplAddress
                )
            );
        } else {
            console2.log("Skipping diamond cut execution and initialization as per input flag");
        }


        // Log deployment info for post-processing
        console2.log(
            string.concat(
                "DEPLOYED: DiamondCutFacet, ",
                "DiamondCutFacet.sol:  ",
                vm.toString(diamondCutFacet)
            )
        );
        console2.log(
            string.concat(
                "DEPLOYED: DiamondLoupeFacet, ",
                "DiamondLoupeFacet.sol:  ",
                vm.toString(diamondLoupeFacet)
            )
        );
        console2.log(
            string.concat(
                "DEPLOYED: OwnershipFacet, ",
                "OwnershipFacet.sol:  ",
                vm.toString(ownershipFacet)
            )
        );
        _logSmartAccountsFacetAddresses();
        console2.log(
            string.concat(
                "DEPLOYED: MasterAccountControllerInit, ",
                "MasterAccountControllerInit.sol:  ",
                vm.toString(address(masterAccountControllerInit))
            )
        );
        console2.log(
            string.concat(
                "DEPLOYED: MasterAccountController, ",
                "MasterAccountController.sol:  ",
                vm.toString(address(masterAccountController))
            )
        );
        console2.log(
            string.concat(
                "DEPLOYED: PersonalAccountImplementation, ",
                "PersonalAccount.sol: ",
                vm.toString(personalAccountImplAddress)
            )
        );

        if (_fullDeploy) {
            // set swap parameters
            if (params.uniswapV3Router != address(0)) {
                console2.log("Setting swap parameters");
                masterAccountController.setSwapParams(
                    params.uniswapV3Router,
                    params.usdt0,
                    params.wNatStableCoinPoolFeeTierPPM,
                    params.stableCoinFXrpPoolFeeTierPPM,
                    params.maxSlippagePPM,
                    params.stableCoinUsdFeedId,
                    params.wNatUsdFeedId
                );
            } else {
                console2.log("Swap parameters not set, swap is disabled");
            }

            console2.log("Adding XRPL provider wallets");
            masterAccountController.addXrplProviderWallets(params.xrplProviderWallets);

            console2.log("Adding agent vaults");
            uint256[] memory agentVaultIds = new uint256[](params.agentVaults.length);
            address[] memory agentVaultAddresses = new address[](params.agentVaults.length);
            for (uint256 i = 0; i < params.agentVaults.length; i++) {
                agentVaultIds[i] = params.agentVaults[i].agentVaultId;
                agentVaultAddresses[i] = params.agentVaults[i].agentVaultAddress;
            }
            masterAccountController.addAgentVaults(agentVaultIds, agentVaultAddresses);

            console2.log("Adding vaults");
            uint256[] memory vaultIds = new uint256[](params.vaults.length);
            address[] memory vaultAddresses = new address[](params.vaults.length);
            uint8[] memory vaultTypes = new uint8[](params.vaults.length);
            for (uint256 i = 0; i < params.vaults.length; i++) {
                vaultIds[i] = params.vaults[i].vaultId;
                vaultAddresses[i] = params.vaults[i].vaultAddress;
                vaultTypes[i] = params.vaults[i].vaultType;
            }
            masterAccountController.addVaults(vaultIds, vaultAddresses, vaultTypes);

            console2.log("Setting timelock duration");
            masterAccountController.setTimelockDuration(params.timelockDurationSeconds);
        }
        else {
            console2.log(
                "Skipping setting parameters as per input flag"
            );
        }

        if (params.governance == address(0) || params.initialOwner != deployer) {
            console2.log("Governance address is zero or initial owner is not deployer, skipping ownership transfer");
        }
        else {
            console2.log("Transferring ownership to governance");
            masterAccountController.transferOwnership(params.governance);
        }
        vm.stopBroadcast();
    }

    function _addFacet(
        address facetAddr,
        string memory facetName
    )
        internal
        returns (IDiamond.FacetCut memory)
    {
        string[] memory cmds = new string[](3);
        // cmds[0] = "bash";
        // cmds[1] = "scripts/master-controller-selectors.sh";
        cmds[0] = "node";
        cmds[1] = "scripts/master-controller-selectors.js";
        cmds[2] = facetName;
        bytes memory out = vm.ffi(cmds);
        bytes4[] memory selectors = abi.decode(out, (bytes4[]));
        return IDiamond.FacetCut({
            facetAddress: facetAddr,
            action: IDiamond.FacetCutAction.Add,
            functionSelectors: selectors
        });
    }

    function _deploySmartAccountsFacets() internal {
        agentVaultsFacet = new AgentVaultsFacet();
        executorsFacet = new ExecutorsFacet();
        instructionFeesFacet = new InstructionFeesFacet();
        instructionsFacet = new InstructionsFacet();
        paymentProofsFacet = new PaymentProofsFacet();
        personalAccountsFacet = new PersonalAccountsFacet();
        swapFacet = new SwapFacet();
        timelockFacet = new TimelockFacet();
        vaultsFacet = new VaultsFacet();
        xrplProviderWalletsFacet = new XrplProviderWalletsFacet();

        smartAccountsFacets = new IDiamond.FacetCut[](10);
        smartAccountsFacets[0] = _addFacet(address(agentVaultsFacet), "AgentVaultsFacet");
        smartAccountsFacets[1] = _addFacet(address(executorsFacet), "ExecutorsFacet");
        smartAccountsFacets[2] = _addFacet(address(instructionFeesFacet), "InstructionFeesFacet");
        smartAccountsFacets[3] = _addFacet(address(instructionsFacet), "InstructionsFacet");
        smartAccountsFacets[4] = _addFacet(address(paymentProofsFacet), "PaymentProofsFacet");
        smartAccountsFacets[5] = _addFacet(address(personalAccountsFacet), "PersonalAccountsFacet");
        smartAccountsFacets[6] = _addFacet(address(swapFacet), "SwapFacet");
        smartAccountsFacets[7] = _addFacet(address(timelockFacet), "TimelockFacet");
        smartAccountsFacets[8] = _addFacet(address(vaultsFacet), "VaultsFacet");
        smartAccountsFacets[9] = _addFacet(address(xrplProviderWalletsFacet), "XrplProviderWalletsFacet");
    }

    function _logSmartAccountsFacetAddresses() internal view {
        console2.log("Smart Accounts Facet Addresses:");
        console2.log(
            string.concat(
                "DEPLOYED: AgentVaultsFacet, ",
                "AgentVaultsFacet.sol: ",
                vm.toString(address(agentVaultsFacet))
            )
        );
        console2.log(
            string.concat(
                "DEPLOYED: ExecutorsFacet, ",
                "ExecutorsFacet.sol: ",
                vm.toString(address(executorsFacet))
            )
        );
        console2.log(
            string.concat(
                "DEPLOYED: InstructionFeesFacet, ",
                "InstructionFeesFacet.sol: ",
                vm.toString(address(instructionFeesFacet))
            )
        );
        console2.log(
            string.concat(
                "DEPLOYED: InstructionsFacet, ",
                "InstructionsFacet.sol: ",
                vm.toString(address(instructionsFacet))
            )
        );
        console2.log(
            string.concat(
                "DEPLOYED: PaymentProofsFacet, ",
                "PaymentProofsFacet.sol: ",
                vm.toString(address(paymentProofsFacet))
            )
        );
        console2.log(
            string.concat(
                "DEPLOYED: PersonalAccountsFacet, ",
                "PersonalAccountsFacet.sol: ",
                vm.toString(address(personalAccountsFacet))
            )
        );
        console2.log(
            string.concat(
                "DEPLOYED: SwapFacet, ",
                "SwapFacet.sol: ",
                vm.toString(address(swapFacet))
            )
        );
        console2.log(
            string.concat(
                "DEPLOYED: TimelockFacet, ",
                "TimelockFacet.sol: ",
                vm.toString(address(timelockFacet))
            )
        );
        console2.log(
            string.concat(
                "DEPLOYED: VaultsFacet, ",
                "VaultsFacet.sol: ",
                vm.toString(address(vaultsFacet))
            )
        );
        console2.log(
            string.concat(
                "DEPLOYED: XrplProviderWalletsFacet, ",
                "XrplProviderWalletsFacet.sol: ",
                vm.toString(address(xrplProviderWalletsFacet))
            )
        );
    }
}

