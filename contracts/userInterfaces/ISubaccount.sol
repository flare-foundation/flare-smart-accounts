// SPDX-License-Identifier: MIT
pragma solidity >=0.8.4 <0.9;

/**
 * @title ISubaccount
 * @notice The type-generic subaccount surface every implementation must expose. The frozen
 * `LoanSubaccountProxy` creation code embeds `initialize`'s exact selector and delegate-calls
 * it from the proxy constructor, so a new subaccount type is not merely "any contract with a
 * registered implementation": its implementation must implement this interface. The ABI is
 * frozen with the proxy — changing it shifts every predicted subaccount address.
 */
interface ISubaccount {

    /**
     * @notice Initializes the subaccount. Delegate-called by the subaccount proxy's
     * constructor; implementations must reject re-initialization and lock the implementation
     * contract itself in their own constructor.
     * @param _controllerAddress MasterAccountController address.
     * @param _parentPersonalAccount Parent Personal Account address.
     * @param _subaccountType The subaccount type.
     */
    function initialize(
        address _controllerAddress,
        address _parentPersonalAccount,
        uint256 _subaccountType
    )
        external;

    /**
     * @notice Returns the controller address associated with this subaccount.
     * @return The controller address.
     */
    function controllerAddress()
        external view
        returns (address);

    /**
     * @notice Returns the parent Personal Account address for this subaccount.
     * @return The parent Personal Account address.
     */
    function parentPersonalAccount()
        external view
        returns (address);

    /**
     * @notice Returns the subaccount type.
     * @return The subaccount type.
     */
    function subaccountType()
        external view
        returns (uint256);

    /**
     * @notice Returns the implementation address of the subaccount.
     * @return The implementation address.
     */
    function implementation()
        external view
        returns (address);
}
