// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IILoanSubaccountsFacet} from "../interface/IILoanSubaccountsFacet.sol";
// import is needed for @inheritdoc
// solhint-disable-next-line no-unused-import
import {
    ILoanSubaccountsFacet,
    SUBACCOUNT_TYPE_NONE
} from "../../userInterfaces/facets/ILoanSubaccountsFacet.sol";
import {LoanSubaccounts} from "../library/LoanSubaccounts.sol";
import {PersonalAccounts} from "../library/PersonalAccounts.sol";
import {Pause} from "../library/Pause.sol";
import {FacetBase} from "./FacetBase.sol";

/**
 * @title LoanSubaccountsFacet
 * @notice Facet for creating and resolving loan subaccounts per subaccount type.
 */
contract LoanSubaccountsFacet is IILoanSubaccountsFacet, FacetBase {

    modifier notPaused {
        Pause.checkNotPaused();
        _;
    }

    /// @inheritdoc IILoanSubaccountsFacet
    function setLoanSubaccountImplementation(
        uint256 _subaccountType,
        address _implementation
    )
        external
        onlyOwnerWithTimelock
    {
        LoanSubaccounts.setLoanSubaccountImplementation(_subaccountType, _implementation);
    }

    /// @inheritdoc IILoanSubaccountsFacet
    function setLoanBridgeSettings(
        address _fxrpOft,
        uint32 _destinationEid,
        bytes32 _destinationPeer
    )
        external
        onlyOwnerWithTimelock
    {
        LoanSubaccounts.setLoanBridgeSettings(_fxrpOft, _destinationEid, _destinationPeer);
    }

    /// @inheritdoc ILoanSubaccountsFacet
    function createLoanSubaccount(
        string calldata _xrplOwner,
        uint256 _subaccountType
    )
        external
        notPaused
        returns (address)
    {
        // the subaccount tree is rooted in existing Personal Accounts
        address parentPersonalAccount =
            address(PersonalAccounts.getState().personalAccounts[_xrplOwner]);
        require(parentPersonalAccount != address(0), PersonalAccountNotDeployed(_xrplOwner));

        return address(LoanSubaccounts.getOrCreateLoanSubaccount(parentPersonalAccount, _subaccountType));
    }

    /// @inheritdoc ILoanSubaccountsFacet
    function getLoanSubaccount(
        string calldata _xrplOwner,
        uint256 _subaccountType
    )
        external view
        returns (address _loanSubaccount)
    {
        require(_subaccountType != SUBACCOUNT_TYPE_NONE, InvalidSubaccountType());

        address parentPersonalAccount =
            address(PersonalAccounts.getState().personalAccounts[_xrplOwner]);
        if (parentPersonalAccount == address(0)) {
            parentPersonalAccount = PersonalAccounts.computePersonalAccountAddress(_xrplOwner);
        }

        _loanSubaccount = address(
            LoanSubaccounts.getState().loanSubaccounts[parentPersonalAccount][_subaccountType]
        );
        if (_loanSubaccount == address(0)) {
            _loanSubaccount = LoanSubaccounts.computeLoanSubaccountAddress(
                parentPersonalAccount,
                _subaccountType
            );
        }
    }

    /// @inheritdoc ILoanSubaccountsFacet
    function loanImplementationForType(
        uint256 _subaccountType
    )
        external view
        returns (address)
    {
        return LoanSubaccounts.getLoanSubaccountImplementation(_subaccountType);
    }

    /// @inheritdoc ILoanSubaccountsFacet
    function getLoanBridgeSettings()
        external view
        returns (address _fxrpOft, uint32 _destinationEid, bytes32 _destinationPeer)
    {
        return LoanSubaccounts.getLoanBridgeSettings();
    }
}
