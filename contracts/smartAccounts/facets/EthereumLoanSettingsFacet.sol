// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IIEthereumLoanSettingsFacet} from "../interface/IIEthereumLoanSettingsFacet.sol";
import {IEthereumLoanSettingsFacet} from "../../userInterfaces/facets/IEthereumLoanSettingsFacet.sol";
import {EthereumLoanSettings} from "../library/EthereumLoanSettings.sol";
import {Subaccounts} from "../library/Subaccounts.sol";
import {PersonalAccounts} from "../library/PersonalAccounts.sol";
import {Pause} from "../library/Pause.sol";
import {FacetBase} from "./FacetBase.sol";

/**
 * @title EthereumLoanSettingsFacet
 * @notice Facet holding the Ethereum-side loan configuration and the Ethereum-side subaccount
 * creation route. Cut only on the Ethereum-side diamond.
 */
contract EthereumLoanSettingsFacet is IIEthereumLoanSettingsFacet, FacetBase {

    modifier notPaused {
        Pause.checkNotPaused();
        _;
    }

    /// @inheritdoc IEthereumLoanSettingsFacet
    function createEthereumLoanSubaccount(
        string calldata _xrplOwner,
        uint256 _subaccountType
    )
        external
        notPaused
        returns (address)
    {
        // the parent Personal Account exists only on Flare; its computed address is the same
        // derivation the Flare side uses, so this materializes exactly the predicted account
        address parentPersonalAccount = PersonalAccounts.computePersonalAccountAddress(_xrplOwner);
        return address(
            Subaccounts.getOrCreateSubaccount(parentPersonalAccount, _subaccountType)
        );
    }

    /// @inheritdoc IIEthereumLoanSettingsFacet
    function setEthereumLoanSettings(
        IEthereumLoanSettingsFacet.Settings calldata _settings
    )
        external
        onlyOwnerWithTimelock
    {
        EthereumLoanSettings.setEthereumLoanSettings(_settings);
    }

    /// @inheritdoc IEthereumLoanSettingsFacet
    function getEthereumLoanSettings()
        external view
        returns (IEthereumLoanSettingsFacet.Settings memory)
    {
        return EthereumLoanSettings.getEthereumLoanSettings();
    }

    /// @inheritdoc IEthereumLoanSettingsFacet
    function getActiveRouteId()
        external view
        returns (bytes32)
    {
        return EthereumLoanSettings.getActiveRouteId();
    }

    /// @inheritdoc IEthereumLoanSettingsFacet
    function getRoute(
        bytes32 _routeId
    )
        external view
        returns (IEthereumLoanSettingsFacet.Route memory)
    {
        return EthereumLoanSettings.getRoute(_routeId);
    }

    /// @inheritdoc IEthereumLoanSettingsFacet
    function getRouteIds()
        external view
        returns (bytes32[] memory)
    {
        return EthereumLoanSettings.getRouteIds();
    }

    /// @inheritdoc IEthereumLoanSettingsFacet
    function getPinnedTokens()
        external view
        returns (address _loanToken, address _collateralToken)
    {
        return EthereumLoanSettings.getPinnedTokens();
    }

    /// @inheritdoc IEthereumLoanSettingsFacet
    function isProtectedToken(
        address _token
    )
        external view
        returns (bool)
    {
        return EthereumLoanSettings.isProtectedToken(_token);
    }
}
