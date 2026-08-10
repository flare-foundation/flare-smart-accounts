// SPDX-License-Identifier: MIT
pragma solidity >=0.8.4 <0.9;

/**
 * @title ILoanSubaccountsFacet
 * @notice Interface for the LoanSubaccountsFacet contract, which resolves the
 * implementation used by loan subaccount proxies per subaccount type. The
 * controller (Diamond) is the beacon for loan subaccounts; a proxy resolves its
 * implementation through {loanImplementationForType} using its fixed type.
 */
interface ILoanSubaccountsFacet {

    /**
     * @notice Loan subaccount type. `None` (0) is reserved for "not configured".
     */
    enum SubaccountType {
        None,
        Loan
    }

    /**
     * @notice Emitted when the loan subaccount implementation is set for a type.
     * @param subaccountType The subaccount type.
     * @param implementation The implementation address set for the type.
     */
    event LoanSubaccountImplementationSet(
        SubaccountType indexed subaccountType,
        address implementation
    );

    /**
     * @notice Emitted when a new loan subaccount is created.
     * @param loanSubaccount The deployed loan subaccount contract address.
     * @param parentPersonalAccount The parent Personal Account address.
     * @param subaccountType The subaccount type.
     */
    event LoanSubaccountCreated(
        address indexed loanSubaccount,
        address indexed parentPersonalAccount,
        SubaccountType indexed subaccountType
    );

    /**
     * @notice Reverts if the loan subaccount implementation address is invalid.
     */
    error InvalidLoanSubaccountImplementation();

    /**
     * @notice Reverts if the subaccount type is invalid (for example `None`).
     */
    error InvalidSubaccountType();

    /**
     * @notice Reverts if no implementation is configured for the subaccount type.
     * @param subaccountType The subaccount type without an implementation.
     */
    error LoanSubaccountImplementationNotSet(
        SubaccountType subaccountType
    );

    /**
     * @notice Reverts if the loan subaccount was not successfully deployed.
     * @param loanSubaccountAddress The address of the loan subaccount.
     */
    error LoanSubaccountNotSuccessfullyDeployed(
        address loanSubaccountAddress
    );

    /**
     * @notice Reverts if the Personal Account for the XRPL owner is not deployed yet.
     * @param xrplOwner The XRPL owner address.
     */
    error PersonalAccountNotDeployed(
        string xrplOwner
    );

    /**
     * @notice Creates the loan subaccount for an XRPL owner's Personal Account if it does not exist yet.
     * @dev Permissionless: anyone can trigger creation. An executor uses it to materialize a
     * subaccount whose predicted address already received assets, so that they can be swept; a user
     * operation uses it as its first call, before calling a method on the subaccount. The Personal
     * Account must already be deployed.
     * @param _xrplOwner The XRPL address of the owner.
     * @param _subaccountType The subaccount type.
     * @return The loan subaccount contract address.
     */
    function createLoanSubaccount(
        string calldata _xrplOwner,
        SubaccountType _subaccountType
    )
        external
        returns (address);

    /**
     * @notice Get the loan subaccount for a given XRPL owner and subaccount type.
     * @param _xrplOwner The XRPL address of the owner.
     * @param _subaccountType The subaccount type.
     * @return The loan subaccount address associated with the XRPL owner
     * or the computed address if not yet deployed.
     */
    function getLoanSubaccount(
        string calldata _xrplOwner,
        SubaccountType _subaccountType
    )
        external view
        returns (address);

    /**
     * @notice Returns the implementation address for a given subaccount type.
     * @param _subaccountType The subaccount type to resolve.
     * @return The implementation address, or the zero address if not configured.
     */
    function loanImplementationForType(
        SubaccountType _subaccountType
    )
        external view
        returns (address);
}
