// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IILoanChainSettingsFacet} from "../interface/IILoanChainSettingsFacet.sol";
import {ILoanChainSettingsFacet} from "../../userInterfaces/facets/ILoanChainSettingsFacet.sol";
import {LoanChainSettings} from "../library/LoanChainSettings.sol";
import {Subaccounts} from "../library/Subaccounts.sol";
import {PersonalAccounts} from "../library/PersonalAccounts.sol";
import {Pause} from "../library/Pause.sol";
import {FacetBase} from "./FacetBase.sol";

/**
 * @title LoanChainSettingsFacet
 * @notice Facet holding the loan-chain configuration (global transport, per-type
 * write-once markets) and the loan-chain subaccount creation route. Cut only on the
 * loan-chain diamond (Ethereum, at launch), never on the Flare side.
 */
contract LoanChainSettingsFacet is IILoanChainSettingsFacet, FacetBase {

    modifier notPaused {
        Pause.checkNotPaused();
        _;
    }

    /// @inheritdoc ILoanChainSettingsFacet
    function createLoanChainSubaccount(
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
        return Subaccounts.getOrCreateSubaccount(parentPersonalAccount, _subaccountType);
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
