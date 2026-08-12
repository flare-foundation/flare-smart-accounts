// SPDX-License-Identifier: MIT
pragma solidity >=0.8.4 <0.9;

/// @dev Reserved subaccount type: "not configured". Never has an implementation.
uint256 constant SUBACCOUNT_TYPE_NONE = 0;
/// @dev The loan subaccount type.
uint256 constant SUBACCOUNT_TYPE_LOAN = 1;

/**
 * @title ILoanSubaccountsFacet
 * @notice Interface for the LoanSubaccountsFacet contract, which resolves the
 * implementation used by loan subaccount proxies per subaccount type. The
 * controller (Diamond) is the beacon for loan subaccounts; a proxy resolves its
 * implementation through {loanImplementationForType} using its fixed type.
 * @dev The subaccount type is a raw `uint256` rather than an enum on purpose: the proxy creation
 * code (and with it this ABI) is frozen for deterministic CREATE2 addresses, and a compiled enum
 * decoder rejects values outside the range it was compiled with, which would make future type
 * values undeployable through the frozen artifact. Type `0` is reserved and invalid; any other
 * value is usable once governance registers an implementation for it.
 */
interface ILoanSubaccountsFacet {

    /**
     * @notice Emitted when the loan subaccount implementation is set for a type.
     * @param subaccountType The subaccount type.
     * @param implementation The implementation address set for the type.
     */
    event LoanSubaccountImplementationSet(
        uint256 indexed subaccountType,
        address implementation
    );

    /**
     * @notice Emitted when the loan bridge settings are set.
     * @param fxrpOft The FXRP OFT used to bridge FXRP to the loan chain.
     * @param destinationEid The LayerZero endpoint id of the loan chain.
     */
    event LoanBridgeSettingsSet(
        address fxrpOft,
        uint32 destinationEid,
        bytes32 destinationPeer
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
        uint256 indexed subaccountType
    );

    /**
     * @notice Reverts if the loan subaccount implementation address is invalid.
     */
    error InvalidLoanSubaccountImplementation();

    /**
     * @notice Reverts if the subaccount type is invalid (the reserved type `0`).
     */
    error InvalidSubaccountType();

    /**
     * @notice Reverts if the FXRP OFT address is invalid.
     */
    error InvalidFxrpOft();

    /**
     * @notice Reverts if the destination endpoint id is invalid.
     */
    error InvalidDestinationEid();

    /**
     * @notice Reverts if the destination peer is invalid, or does not match the OFT's live peer.
     */
    error InvalidDestinationPeer();

    /**
     * @notice Reverts if no implementation is configured for the subaccount type.
     * @param subaccountType The subaccount type without an implementation.
     */
    error LoanSubaccountImplementationNotSet(
        uint256 subaccountType
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
        uint256 _subaccountType
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
        uint256 _subaccountType
    )
        external view
        returns (address);

    /**
     * @notice Returns the implementation address for a given subaccount type.
     * @param _subaccountType The subaccount type to resolve.
     * @return The implementation address, or the zero address if not configured.
     */
    function loanImplementationForType(
        uint256 _subaccountType
    )
        external view
        returns (address);

    /**
     * @notice Returns the settings used to bridge FXRP to the loan chain.
     * @dev These are governance-set rather than supplied by the caller, so that a permissionless
     * sweep cannot choose where the assets are bridged to.
     * @return _fxrpOft The FXRP OFT used to bridge FXRP.
     * @return _destinationEid The LayerZero endpoint id of the loan chain.
     * @return _destinationPeer The expected remote OApp (peer) on the loan chain. Pinned so a
     * peer mutation on the OFT after configuration fails sweeps closed.
     */
    function getLoanBridgeSettings()
        external view
        returns (address _fxrpOft, uint32 _destinationEid, bytes32 _destinationPeer);
}
