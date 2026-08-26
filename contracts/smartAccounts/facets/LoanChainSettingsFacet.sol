// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IILoanChainSettingsFacet} from "../interface/IILoanChainSettingsFacet.sol";
import {ILoanChainSettingsFacet} from "../../userInterfaces/facets/ILoanChainSettingsFacet.sol";
import {LoanChainSettings} from "../library/LoanChainSettings.sol";
import {PersonalAccounts} from "../library/PersonalAccounts.sol";
import {Pause} from "../library/Pause.sol";
import {FacetBase} from "./FacetBase.sol";

/**
 * @title LoanChainSettingsFacet
 * @notice Facet holding the loan-chain configuration (global transport, per-type write-once
 * markets, the per-type borrow switch) and the loan-chain Personal Account creation route.
 * Cut only on the loan-chain diamond (Ethereum, at launch), never on the Flare side.
 * Subaccount creation goes through the generic {SubaccountsFacet}, whose parent resolution
 * works without a deployed Personal Account; Personal Account creation needs this explicit
 * route, because the instruction machinery that creates PAs lazily on Flare does not exist
 * here.
 */
contract LoanChainSettingsFacet is IILoanChainSettingsFacet, FacetBase {

    modifier notPaused {
        Pause.checkNotPaused();
        _;
    }

    /// @inheritdoc ILoanChainSettingsFacet
    function createLoanChainPersonalAccount(
        string calldata _xrplOwner
    )
        external
        notPaused
        returns (address)
    {
        // permissionless and idempotent: the PA proxy derivation is frozen and
        // chain-independent, so this materializes exactly the address the user's Flare
        // Personal Account already has - the compose-driven mirror lives there
        return address(PersonalAccounts.getOrCreatePersonalAccount(_xrplOwner));
    }

    /// @inheritdoc IILoanChainSettingsFacet
    function setLoanChainTransport(
        ILoanChainSettingsFacet.Transport calldata _transport
    )
        external
        onlyOwnerWithTimelock
    {
        LoanChainSettings.setLoanChainTransport(_transport);
    }

    /// @inheritdoc IILoanChainSettingsFacet
    function registerLoanChainMarket(
        uint256 _subaccountType,
        ILoanChainSettingsFacet.Market calldata _market
    )
        external
        onlyOwnerWithTimelock
    {
        LoanChainSettings.registerLoanChainMarket(_subaccountType, _market);
    }

    /// @inheritdoc IILoanChainSettingsFacet
    function disableLoanChainBorrowing(
        uint256 _subaccountType
    )
        external
        onlyOwnerWithTimelock
    {
        LoanChainSettings.disableLoanChainBorrowing(_subaccountType);
    }

    /// @inheritdoc IILoanChainSettingsFacet
    function enableLoanChainBorrowing(
        uint256 _subaccountType
    )
        external
        onlyOwnerWithTimelock
    {
        LoanChainSettings.enableLoanChainBorrowing(_subaccountType);
    }

    /// @inheritdoc ILoanChainSettingsFacet
    function getLoanChainTransport()
        external view
        returns (ILoanChainSettingsFacet.Transport memory)
    {
        return LoanChainSettings.getLoanChainTransport();
    }

    /// @inheritdoc ILoanChainSettingsFacet
    function getLoanChainMarket(
        uint256 _subaccountType
    )
        external view
        returns (ILoanChainSettingsFacet.Market memory)
    {
        return LoanChainSettings.getLoanChainMarket(_subaccountType);
    }

    /// @inheritdoc ILoanChainSettingsFacet
    function isLoanChainBorrowingDisabled(
        uint256 _subaccountType
    )
        external view
        returns (bool)
    {
        return LoanChainSettings.isLoanChainBorrowingDisabled(_subaccountType);
    }
}
