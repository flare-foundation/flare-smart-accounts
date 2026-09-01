// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IISubaccountsFacet} from "../interface/IISubaccountsFacet.sol";
// import is needed for @inheritdoc
// solhint-disable-next-line no-unused-import
import {
    ISubaccountsFacet,
    SUBACCOUNT_TYPE_NONE
} from "../../userInterfaces/facets/ISubaccountsFacet.sol";
import {Subaccounts} from "../library/Subaccounts.sol";
import {PersonalAccounts} from "../library/PersonalAccounts.sol";
import {Pause} from "../library/Pause.sol";
import {FacetBase} from "./FacetBase.sol";

/**
 * @title SubaccountsFacet
 * @notice The type-generic subaccount surface: the per-type implementation registry and the
 * creation/prediction route, shared by every subaccount type. Type-specific configuration
 * lives on its own facet (e.g. {LoanBridgeSettingsFacet}).
 */
contract SubaccountsFacet is IISubaccountsFacet, FacetBase {

    modifier notPaused {
        Pause.checkNotPaused();
        _;
    }

    /// @inheritdoc IISubaccountsFacet
    function setSubaccountImplementation(
        uint256 _subaccountType,
        address _implementation
    )
        external
        onlyOwnerWithTimelock
    {
        Subaccounts.setSubaccountImplementation(_subaccountType, _implementation);
    }

    /// @inheritdoc ISubaccountsFacet
    function createSubaccount(
        string calldata _xrplOwner,
        uint256 _subaccountType
    )
        external
        notPaused
        returns (address)
    {
        // use the registered parent when present, otherwise its frozen computed address:
        // this preserves pre-PA materialization (materialize-to-sweep, and the loan-chain
        // diamond before the remote Personal Account exists) while matching getSubaccount
        address parentPersonalAccount =
            PersonalAccounts.getState().personalAccounts[_xrplOwner];
        if (parentPersonalAccount == address(0)) {
            parentPersonalAccount = PersonalAccounts.computePersonalAccountAddress(_xrplOwner);
        }

        return Subaccounts.getOrCreateSubaccount(parentPersonalAccount, _subaccountType);
    }

    /// @inheritdoc ISubaccountsFacet
    function getSubaccount(
        string calldata _xrplOwner,
        uint256 _subaccountType
    )
        external view
        returns (address _subaccount)
    {
        require(_subaccountType != SUBACCOUNT_TYPE_NONE, InvalidSubaccountType());

        address parentPersonalAccount =
            PersonalAccounts.getState().personalAccounts[_xrplOwner];
        if (parentPersonalAccount == address(0)) {
            parentPersonalAccount = PersonalAccounts.computePersonalAccountAddress(_xrplOwner);
        }

        _subaccount = Subaccounts.getState().subaccounts[parentPersonalAccount][_subaccountType];
        if (_subaccount == address(0)) {
            _subaccount = Subaccounts.computeSubaccountAddress(
                parentPersonalAccount,
                _subaccountType
            );
        }
    }

    /// @inheritdoc ISubaccountsFacet
    function implementationForType(
        uint256 _subaccountType
    )
        external view
        returns (address)
    {
        return Subaccounts.implementationForType(_subaccountType);
    }
}
