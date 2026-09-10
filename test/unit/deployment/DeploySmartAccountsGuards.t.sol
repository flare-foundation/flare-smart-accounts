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
    uint256 private constant FLARE = 14;
    uint256 private constant SONGBIRD = 19;
    uint256 private constant COSTON = 16;
    uint256 private constant COSTON2 = 114;

    DeploySmartAccounts private script;

    function setUp() public {
        vm.setEnv("DEPLOYER_PRIVATE_KEY", "1");
        script = new DeploySmartAccounts();
    }

    function testRefusesEveryLoanChain() public {
        // Ethereum for the pinned bootstrap's sake, Sepolia as a loan chain: a single-id guard
        // would deploy and record both home implementations there
        uint256[2] memory loan = [ETHEREUM, SEPOLIA];
        for (uint256 i = 0; i < loan.length; i++) {
            vm.chainId(loan[i]);
            vm.expectRevert(
                bytes("the generic deployment runs on a Flare-family chain; loan chains use the pinned bootstrap")
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
            bytes("the generic deployment runs on a Flare-family chain; loan chains use the pinned bootstrap")
        );
        script.run("coston2", false, false);
    }

    function testAnUndeclaredUnknownChainIsRefusedByTheGuardItself() public {
        vm.chainId(31337);
        vm.expectRevert(
            bytes("the generic deployment runs on a Flare-family chain; loan chains use the pinned bootstrap")
        );
        script.run("coston2", false, false);
    }

    function testAKnownChainDeclaredLocalIsRefusedByName() public {
        // the declaration opens only the family guard: on a known chain of either family the name
        // check refuses `scdev`, so declaring a local run cannot put the generic deployment on a
        // loan chain
        uint256[6] memory known = [FLARE, SONGBIRD, COSTON, COSTON2, ETHEREUM, SEPOLIA];
        for (uint256 i = 0; i < known.length; i++) {
            vm.chainId(known[i]);
            vm.expectRevert(
                bytes(
                    string.concat(
                        "RPC chain is ", DeployNetworks.networkName(known[i]), ", not the named network scdev"
                    )
                )
            );
            script.run("scdev", false, false);
        }
    }
}
