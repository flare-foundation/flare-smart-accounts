// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ContractRegistry} from "flare-periphery/src/flare/ContractRegistry.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IIPersonalAccountReaderFacet} from "../interface/IIPersonalAccountReaderFacet.sol";
// import is needed for @inheritdoc
// solhint-disable-next-line no-unused-import
import {IPersonalAccountReaderFacet} from "../../userInterfaces/facets/IPersonalAccountReaderFacet.sol";
import {IPersonalAccount} from "../../userInterfaces/IPersonalAccount.sol";
import {IVaultsFacet} from "../../userInterfaces/facets/IVaultsFacet.sol";
import {IIVault} from "../interface/IIVault.sol";
import {Vaults} from "../library/Vaults.sol";
import {AgentVaults} from "../library/AgentVaults.sol";
import {PersonalAccounts} from "../library/PersonalAccounts.sol";

/**
 * @title PersonalAccountReaderFacet
 * @notice Read-only facet that aggregates balance and account data.
 */
contract PersonalAccountReaderFacet is IIPersonalAccountReaderFacet {

    /// @inheritdoc IPersonalAccountReaderFacet
    function getBalances(
        address _personalAccount
    )
        external view
        returns (AccountBalances memory _balances)
    {
        _balances = _getBalances(_personalAccount);
    }

    /// @inheritdoc IPersonalAccountReaderFacet
    function getBalances(
        string calldata _xrplOwner
    )
        external view
        returns (AccountBalances memory _balances)
    {
        PersonalAccounts.State storage paState = PersonalAccounts.getState();
        address personalAccount = address(paState.personalAccounts[_xrplOwner]);
        if (personalAccount == address(0)) {
            personalAccount = PersonalAccounts.computePersonalAccountAddress(_xrplOwner);
        }
        _balances = _getBalances(personalAccount);
    }

    /// @inheritdoc IPersonalAccountReaderFacet
    function agentVaults()
        external view
        returns (AgentVaultInfo[] memory _agentVaults)
    {
        AgentVaults.State storage state = AgentVaults.getState();
        uint256[] memory ids = state.agentVaultIds;
        _agentVaults = new AgentVaultInfo[](ids.length);
        for (uint256 i = 0; i < ids.length; i++) {
            _agentVaults[i] = AgentVaultInfo({
                agentVaultId: ids[i],
                agentVaultAddress: state.agentVaultIdToAgentVaultAddress[ids[i]]
            });
        }
    }

    /// @inheritdoc IPersonalAccountReaderFacet
    function vaults()
        external view
        returns (VaultInfo[] memory _vaults)
    {
        Vaults.State storage state = Vaults.getState();
        uint256[] memory ids = state.vaultIds;
        _vaults = new VaultInfo[](ids.length);
        for (uint256 i = 0; i < ids.length; i++) {
            Vaults.VaultInfo memory info = state.vaultIdToVaultInfo[ids[i]];
            _vaults[i] = VaultInfo({
                vaultId: ids[i],
                vaultAddress: info.vaultAddress,
                vaultType: info.vaultType
            });
        }
    }

    /// @inheritdoc IPersonalAccountReaderFacet
    function isSmartAccount(
        address _address
    )
        external view
        returns (bool _isSmartAccount, string memory _xrplOwner)
    {
        if (_address.code.length == 0) {
            return (false, "");
        }
        try IPersonalAccount(_address).xrplOwner() returns (string memory owner) {
            if (bytes(owner).length > 0) {
                // verify by computing expected PA address from the returned owner
                address expectedPA = PersonalAccounts.computePersonalAccountAddress(owner);
                if (expectedPA == _address) {
                    return (true, owner);
                }
            }
        } catch {}
        return (false, "");
    }

    function _getBalances(
        address _personalAccount
    )
        internal view
        returns (AccountBalances memory _balances)
    {
        _balances.natBalance = _personalAccount.balance;
        _balances.wNatBalance = IERC20(address(ContractRegistry.getWNat())).balanceOf(_personalAccount);
        _balances.fXrpBalance = ContractRegistry.getAssetManagerFXRP().fAsset().balanceOf(_personalAccount);

        Vaults.State storage vaultState = Vaults.getState();
        uint256[] memory vaultIds = vaultState.vaultIds;
        _balances.vaults = new VaultBalance[](vaultIds.length);

        for (uint256 i = 0; i < vaultIds.length; i++) {
            Vaults.VaultInfo memory info = vaultState.vaultIdToVaultInfo[vaultIds[i]];
            _balances.vaults[i].vaultId = vaultIds[i];
            _balances.vaults[i].vaultAddress = info.vaultAddress;
            _balances.vaults[i].vaultType = info.vaultType;

            if (info.vaultType == IVaultsFacet.VaultType.Firelight) {
                // Firelight: vault is the ERC20 share token
                _balances.vaults[i].shares = IERC20(info.vaultAddress).balanceOf(_personalAccount);
                if (_balances.vaults[i].shares > 0) {
                    _balances.vaults[i].assets =
                        IERC4626(info.vaultAddress).convertToAssets(_balances.vaults[i].shares);
                }
            } else if (info.vaultType == IVaultsFacet.VaultType.Upshift) {
                // Upshift: shares are in a separate LP token
                _balances.vaults[i].shares =
                    IERC20(IIVault(info.vaultAddress).lpTokenAddress()).balanceOf(_personalAccount);
                if (_balances.vaults[i].shares > 0) {
                    (_balances.vaults[i].assets, ) =
                        IIVault(info.vaultAddress).previewRedemption(_balances.vaults[i].shares, false);
                }
            } else {
                revert UnsupportedVaultType(info.vaultType);
            }
        }
    }
}
