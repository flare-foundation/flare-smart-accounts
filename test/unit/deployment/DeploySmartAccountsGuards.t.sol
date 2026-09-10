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
    /// @dev anvil's default: a chain in neither family, which the guard refuses under any name.
    uint256 private constant UNKNOWN = 31337;

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

    function testAnUnknownChainIsRefusedUnderAnyName() public {
        // a chain in neither family is refused by the guard itself, whatever the wrapper called
        // it - there is no local-development network for a name to open
        vm.chainId(UNKNOWN);
        vm.expectRevert(
            bytes("the generic deployment runs on a Flare-family chain; loan chains use the pinned bootstrap")
        );
        script.run("coston2", false, false);
        vm.expectRevert(
            bytes("the generic deployment runs on a Flare-family chain; loan chains use the pinned bootstrap")
        );
        script.run("scdev", false, false);
    }
}
