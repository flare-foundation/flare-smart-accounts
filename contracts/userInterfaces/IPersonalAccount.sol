// SPDX-License-Identifier: MIT
pragma solidity >=0.8.4 <0.9;

/**
 * @title IPersonalAccount
 * @notice Interface for PersonalAccount contract.
 */
interface IPersonalAccount {
    event Deposited(address vault, uint256 amount, uint256 shares);
    event Withdrawn(address vault, uint256 amount, uint256 shares);
    event WithdrawalClaimed(
        address vault,
        uint256 period,
        uint256 amount
    );
    event Approved(address fxrp, address vault, uint256 amount);
    event Redeemed(uint256 lots, address executor, uint256 executorFee);
    event CollateralReserved(
        uint256 lots,
        address agentVault,
        address executor,
        uint256 executorFee,
        uint256 reservationId
    );

    error InsufficientFundsForRedeemExecutor();
    error InsufficientFundsForCollateralReservation(
        uint256 collateralReservationFee
    );
    error OnlyController();
    error AlreadyInitialized();
    error InvalidControllerAddress();
    error InvalidXrplOwner();
    error AgentNotAvailable();
    error ApprovalFailed();
    error FxrpAssetManagerNotSet();
    error CustomInstructionCallFailed();

    /**
     * @notice Returns the XRPL owner address associated with this personal account.
     * @return The XRPL owner address
     */
    function xrplOwner() external view returns (string memory);

    /**
     * @notice Returns the controller address that manages this personal account.
     * @return The controller address
     */
    function controllerAddress() external view returns (address);

    /**
     * @notice Returns implementation address of the personal account.
     * @return The implementation address
     */
    function implementation() external view returns (address);
}
