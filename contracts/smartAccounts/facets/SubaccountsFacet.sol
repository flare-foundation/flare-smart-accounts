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
import {FacetBase} from "./FacetBase.sol";

/**
 * @title SubaccountsFacet
 * @notice The type-generic subaccount surface: the per-type implementation registry and the
 * creation/prediction route, shared by every subaccount type. The bridging configuration the
 * types share lives on {BridgeRoutesFacet}; loan-specific configuration on the loan chain's
 * {MorphoLoanMarketsFacet}.
 */
contract SubaccountsFacet is IISubaccountsFacet, FacetBase {

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
        returns (address)
    {
        // the parent comes into being with the subaccount: a codeless parent leaves the account
        // with no caller and no way home on Flare, and what the remote rails push to it beyond
        // reach; nothing here can create it later, since this holds its address while the
        // deployment needs the owner string. Not pause-gated, as `createPersonalAccount` is not
        address parentPersonalAccount = PersonalAccounts.getOrCreatePersonalAccount(_xrplOwner);

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
