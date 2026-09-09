// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {DeployNetworks} from "../../../deployment/scripts/DeployNetworks.sol";
import {DeploySmartAccounts} from "../../../deployment/scripts/DeploySmartAccounts.s.sol";

/**
 * @title DeploySmartAccountsGuardsTest
 * @notice The full deployment's share of the family guard (see DeployNetworkGuards). It deploys
 * both home implementations whatever `_fullDeploy` says, so it refuses every loan chain the same
 * way the implementation scripts do; only its refusals are driven here, since a successful run
 * needs a chain config and a live registry.
 *
 * Kept apart from DeployNetworkGuards on purpose: this script copies a memory array of structs
 * into storage, which only the IR pipeline compiles (solc error 1834), so any test importing it
 * has to be skipped by `forge coverage`, which builds without via-IR. Skipping this file costs
 * the coverage figure nothing - deploy scripts are pruned from it anyway - while the other
 * guard tests stay inside coverage's compile.
 */
contract DeploySmartAccountsGuardsTest is Test {
    uint256 private constant ETHEREUM = 1;
    uint256 private constant SEPOLIA = 11155111;
    uint256 private constant COSTON2 = 114;

    DeploySmartAccounts private script;

    function setUp() public {
        vm.setEnv("DEPLOYER_PRIVATE_KEY", "1");
        script = new DeploySmartAccounts();
    }

    function testRefusesEveryLoanChain() public {
        // Ethereum was always refused, for the pinned bootstrap's sake; Sepolia is the case that
        // used to pass, and would have deployed and recorded both home implementations there
        uint256[2] memory loan = [ETHEREUM, SEPOLIA];
        for (uint256 i = 0; i < loan.length; i++) {
            vm.chainId(loan[i]);
            vm.expectRevert(
                bytes("loan chains use the pinned bootstrap (DeployEthereumController), never this script")
            );
            script.run(DeployNetworks.networkName(loan[i]), false, false);
        }
    }

    function testAWrongNetworkNameIsRefusedOnAPermittedChain() public {
        // the family guard first, the RPC-versus-name check second: a chain the script belongs
        // on is still refused when the wrapper named a different one
        vm.chainId(COSTON2);
        vm.expectRevert(bytes("RPC chain is coston2, not the named network coston"));
        script.run("coston", false, false);
    }

    function testTheGuardFiresBeforeTheNetworkNameIsChecked() public {
        vm.chainId(SEPOLIA);
        vm.expectRevert(
            bytes("loan chains use the pinned bootstrap (DeployEthereumController), never this script")
        );
        script.run("coston2", false, false);
    }
}
