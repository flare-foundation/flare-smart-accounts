// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import {IVaultsFacet} from "../../contracts/userInterfaces/facets/IVaultsFacet.sol";

/**
 * @title DeployConfigTypes
 * @notice JSON decode targets for the chain-config vault arrays, shared
 *         between DeploySmartAccounts and test/DeployConfigDecode.t.sol.
 * @dev Kept out of the deploy script so the test can compile the structs
 *      without importing the script: DeploySmartAccounts compiles only
 *      via-ir (run() exceeds the legacy stack limit and the script assigns
 *      memory struct arrays to storage), while `forge coverage` builds
 *      without via-ir.
 */
abstract contract DeployConfigTypes {
    struct AgentVaultConfig {
        address agentVaultAddress;
        uint256 agentVaultId;
    }

    struct VaultConfig {
        uint256 vaultId;
        address vaultAddress;
        IVaultsFacet.VaultType vaultType;
    }
}
