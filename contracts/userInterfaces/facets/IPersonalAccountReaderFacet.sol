// SPDX-License-Identifier: MIT
pragma solidity >=0.8.4 <0.9;

import {IVaultsFacet} from "./IVaultsFacet.sol";

/**
 * @title IPersonalAccountReaderFacet
 * @notice Interface for the PersonalAccountReaderFacet contract.
 */
interface IPersonalAccountReaderFacet {

    struct VaultBalance {
        uint256 vaultId;
        address vaultAddress;
        IVaultsFacet.VaultType vaultType;
        uint256 shares;
        uint256 assets;
    }

    struct AccountBalances {
        uint256 natBalance;
        uint256 wNatBalance;
        uint256 fXrpBalance;
        VaultBalance[] vaults;
    }

    struct AgentVaultInfo {
        uint256 agentVaultId;
        address agentVaultAddress;
    }

    struct VaultInfo {
        uint256 vaultId;
        address vaultAddress;
        IVaultsFacet.VaultType vaultType;
    }

    /**
     * @notice Reverts if the vault type is not supported.
     * @param vaultType The unsupported vault type.
     */
    error UnsupportedVaultType(IVaultsFacet.VaultType vaultType);

    /**
     * @notice Get all balances for a personal account address.
     * @param _personalAccount The personal account address.
     * @return _balances The account balances (NAT, WNAT, FXRP, vault balances).
     */
    function getBalances(
        address _personalAccount
    )
        external view
        returns (AccountBalances memory _balances);

    /**
     * @notice Get all balances for a personal account by XRPL address.
     * @param _xrplOwner The XRPL owner address.
     * @return _balances The account balances (NAT, WNAT, FXRP, vault balances).
     */
    function getBalances(
        string calldata _xrplOwner
    )
        external view
        returns (AccountBalances memory _balances);

    /**
     * @notice Get all registered agent vaults.
     * @return _agentVaults The list of agent vaults.
     */
    function agentVaults()
        external view
        returns (AgentVaultInfo[] memory _agentVaults);

    /**
     * @notice Get all registered vaults.
     * @return _vaults The list of vaults.
     */
    function vaults()
        external view
        returns (VaultInfo[] memory _vaults);

    /**
     * @notice Check if a Flare address is a smart account (personal account).
     * @param _address The Flare address to check.
     * @return _isSmartAccount True if the address is a personal account.
     * @return _xrplOwner The XRPL owner address if it is a personal account.
     */
    function isSmartAccount(
        address _address
    )
        external view
        returns (bool _isSmartAccount, string memory _xrplOwner);
}
