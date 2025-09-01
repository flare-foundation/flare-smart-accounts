// SPDX-License-Identifier: MIT
pragma solidity >=0.7.6 <0.9;

/**
 * @title IPersonalAccount
 * @notice Interface for PersonalAccount contract.
 */
interface IPersonalAccount {

    event Deposited(address vault, uint256 amount, uint256 actualAmount);
    event Withdrawn(address vault, uint256 amount, uint256 actualAmount);
    event WithdrawalClaimed(address vault, uint256 rewardEpochId, uint256 amount);
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
    error InsufficientFundsForCollateralReservation(uint256 collateralReservationFee);
    error OnlyController();
    error AlreadyInitialized();
    error InvalidControllerAddress();
    error InvalidXrplOwner();
    error AgentNotAvailable();
    error ApprovalFailed();
    error FxrpAssetManagerNotSet();
}