// SPDX-License-Identifier: MIT
pragma solidity >=0.8.4 <0.9;

/**
 * @title IPersonalAccount
 * @notice Interface for PersonalAccount contract.
 */
interface IPersonalAccount {
    event CollateralReserved(
        address agentVault,
        uint256 lots,
        address executor,
        uint256 executorFee,
        uint256 collateralReservationId
    );
    event Redeemed(uint256 lots, uint256 amount, address executor, uint256 executorFee);
    event Approved(address fxrp, address vault, uint256 amount);
    event Deposited(address vault, uint256 amount, uint256 shares);
    event Withdrawn(address vault, uint256 amount, uint256 shares);
    event WithdrawalClaimed(address vault, uint256 period, uint256 amount);
    event RedeemRequested(address vault, uint256 shares, uint256 amount, uint256 claimableEpoch);
    event Claimed(address vault, uint256 year, uint256 month, uint256 day, uint256 shares, uint256 amount);

    error InsufficientFundsForCollateralReservation(uint256 collateralReservationFee, uint256 executorFee);
    error InsufficientFundsForRedeem(uint256 executorFee);
    error OnlyController();
    error AlreadyInitialized();
    error InvalidControllerAddress();
    error InvalidXrplOwner();
    error AgentNotAvailable();
    error ApprovalFailed();

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
