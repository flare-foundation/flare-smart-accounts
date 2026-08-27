// SPDX-License-Identifier: MIT
pragma solidity >=0.8.4 <0.9;

import {ILoanChainSettingsFacet} from "../../userInterfaces/facets/ILoanChainSettingsFacet.sol";

/**
 * @title IILoanChainSettingsFacet
 * @notice Internal interface for the LoanChainSettingsFacet contract.
 */
interface IILoanChainSettingsFacet is ILoanChainSettingsFacet {
    /**
     * @notice Sets the global loan transport, validated against the FXRP OFT (canonical
     * interface/codec version, decimals shared with its own token, wired to the `lzCompose`
     * endpoint, live peer equal to the pinned one). Once any market is registered, the OFT
     * must wrap the pinned collateral token — the adapter can rotate, the token cannot.
     * An all-zero struct clears the transport, disabling composed actions and the
     * bridge-back sweep for all loan types until reconfigured; markets, the collateral-token
     * pin, repayment, defensive deposits, and recovery persist.
     * @param _transport The transport settings.
     * Can only be called by the owner (timelocked).
     */
    function setLoanChainTransport(
        ILoanChainSettingsFacet.Transport calldata _transport
    )
        external;

    /**
     * @notice Registers the market a subaccount type is bound to, write-once: a different
     * market means a new subaccount type. Requires the transport (the collateral token must
     * be the OFT's token) and an existing market on the Morpho contract. The first
     * registration permanently pins the collateral token for every later transport.
     * @param _subaccountType The subaccount type to bind.
     * @param _market The Morpho contract and market.
     * Can only be called by the owner (timelocked).
     */
    function registerLoanChainMarket(
        uint256 _subaccountType,
        ILoanChainSettingsFacet.Market calldata _market
    )
        external;

    /**
     * @notice Disables new debt increases for a subaccount type — the routine way to sunset
     * a pool. Repayment, collateral deposits, withdrawals, and recovery are never affected.
     * @param _subaccountType The subaccount type.
     * Can only be called by the owner (timelocked).
     */
    function disableLoanChainBorrowing(
        uint256 _subaccountType
    )
        external;

    /**
     * @notice Re-enables new debt increases for a subaccount type.
     * @param _subaccountType The subaccount type.
     * Can only be called by the owner (timelocked).
     */
    function enableLoanChainBorrowing(
        uint256 _subaccountType
    )
        external;
}
