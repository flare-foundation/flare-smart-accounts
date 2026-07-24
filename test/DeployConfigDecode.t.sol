// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {DeployConfigTypes} from "../deployment/types/DeployConfigTypes.sol";
import {IVaultsFacet} from "../contracts/userInterfaces/facets/IVaultsFacet.sol";

/**
 * @title DeployConfigDecodeTest
 * @notice Pins the field order `vm.parseJson` uses when decoding the deploy
 *         script's config structs, so a Foundry behavior change — or a newly
 *         added struct elsewhere in the project with the same field-name
 *         set — fails CI instead of silently reordering values at deploy
 *         time.
 *
 * `vm.parseJson` ABI-encodes a JSON object's members in alphabetical key
 * order on Foundry < 1.5; newer versions first look for any compiled struct
 * whose field names match the object's keys and use that struct's declared
 * order (foundry-rs/foundry#11612). DeploySmartAccounts.run therefore
 * requires forge >= 1.5.0 via `vm.foundryVersionAtLeast`, and this test pins
 * the resulting decode mapping — if a future Foundry changes the rule, or a
 * struct with the same field-name set is ever added elsewhere in the project
 * and wins the struct lookup, CI fails here instead of a deploy silently
 * miswiring vaults.
 *
 * The fixture values below are ABI-compatible in each other's slots (a small
 * id fits an address slot and any address fits a uint256), so a reordering
 * would NOT revert — only these assertions catch it.
 */
contract DeployConfigDecodeTest is Test, DeployConfigTypes {
    address private constant VAULT_1 = 0x1111111111111111111111111111111111111111;
    address private constant VAULT_2 = 0x2222222222222222222222222222222222222222;
    address private constant AGENT_VAULT = 0x3333333333333333333333333333333333333333;

    string private constant VAULTS_JSON =
        "{\"vaults\": ["
        "{\"vaultId\": 1, \"vaultAddress\": \"0x1111111111111111111111111111111111111111\", \"vaultType\": 1},"
        "{\"vaultId\": 2, \"vaultAddress\": \"0x2222222222222222222222222222222222222222\", \"vaultType\": 2}"
        "]}";

    // Same array with each object's keys written in a different textual
    // order; must decode identically (the parser's order is canonical, not
    // textual).
    string private constant VAULTS_JSON_REORDERED =
        "{\"vaults\": ["
        "{\"vaultType\": 1, \"vaultAddress\": \"0x1111111111111111111111111111111111111111\", \"vaultId\": 1},"
        "{\"vaultAddress\": \"0x2222222222222222222222222222222222222222\", \"vaultType\": 2, \"vaultId\": 2}"
        "]}";

    string private constant AGENT_VAULTS_JSON =
        "{\"agentVaults\": ["
        "{\"agentVaultId\": 7, \"agentVaultAddress\": \"0x3333333333333333333333333333333333333333\"}"
        "]}";

    function setUp() public view {
        // On an older forge the decode assertions below would fail with
        // confusing value mismatches; fail with the actual reason instead.
        require(
            vm.foundryVersionAtLeast("1.5.0"),
            "forge >= 1.5.0 required: config struct decoding relies on declared field order"
        );
    }

    function testVaultConfigDecode() public pure {
        _assertVaults(VAULTS_JSON);
    }

    function testVaultConfigDecodeIsTextualOrderIndependent() public pure {
        _assertVaults(VAULTS_JSON_REORDERED);
    }

    function testAgentVaultConfigDecode() public pure {
        AgentVaultConfig[] memory agentVaults = abi.decode(
            vm.parseJson(AGENT_VAULTS_JSON, ".agentVaults"),
            (AgentVaultConfig[])
        );

        assertEq(agentVaults.length, 1, "agent vault count");
        assertEq(agentVaults[0].agentVaultId, 7, "agentVaultId");
        assertEq(agentVaults[0].agentVaultAddress, AGENT_VAULT, "agentVaultAddress");
    }

    function _assertVaults(string memory json) private pure {
        VaultConfig[] memory vaults =
            abi.decode(vm.parseJson(json, ".vaults"), (VaultConfig[]));

        assertEq(vaults.length, 2, "vault count");
        assertEq(vaults[0].vaultId, 1, "vaultId[0]");
        assertEq(vaults[0].vaultAddress, VAULT_1, "vaultAddress[0]");
        assertEq(uint256(vaults[0].vaultType), uint256(IVaultsFacet.VaultType.Firelight), "vaultType[0]");
        assertEq(vaults[1].vaultId, 2, "vaultId[1]");
        assertEq(vaults[1].vaultAddress, VAULT_2, "vaultAddress[1]");
        assertEq(uint256(vaults[1].vaultType), uint256(IVaultsFacet.VaultType.Upshift), "vaultType[1]");
    }
}
