// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import {IVaultsFacet} from "../../contracts/userInterfaces/facets/IVaultsFacet.sol";

/**
 * @title DeployConfigTypes
 * @notice JSON decode targets for the chain-config vault arrays, shared
 *         between DeploySmartAccounts and test/unit/deployment/DeployConfigDecode.t.sol.
 * @dev Kept out of the deploy script so the test can compile the structs
 *      without importing the script: DeploySmartAccounts compiles only
 *      via-ir (run() exceeds the legacy stack limit and the script assigns
 *      memory struct arrays to storage), while `forge coverage` builds
 *      without via-ir.
 *
 *      Field order is load-bearing. `vm.parseJson` orders a JSON object's members by
 *      looking up ANY compiled struct whose field names match, and `IReaderFacet`'s
 *      `AgentVaultDetails` and `VaultDetails` carry exactly these field-name sets. When two
 *      candidates disagree, the lookup's winner - and with it the decode - varies between
 *      runs, so these structs must declare their fields in the same order as their reader
 *      twins; `DeployConfigDecode.t.sol` pins the two orders against each other.
 */
abstract contract DeployConfigTypes {
    struct AgentVaultConfig {
        uint256 agentVaultId;
        address agentVaultAddress;
    }

    struct VaultConfig {
        uint256 vaultId;
        address vaultAddress;
        IVaultsFacet.VaultType vaultType;
    }
}
