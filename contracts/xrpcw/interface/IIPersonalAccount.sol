// SPDX-License-Identifier: MIT
pragma solidity >=0.7.6 <0.9;

import {IPersonalAccount} from "../../userInterfaces/IPersonalAccount.sol";

/**
 * @title IIPersonalAccount
 * @notice Internal interface for PersonalAccount contract.
 */
interface IIPersonalAccount is IPersonalAccount {

    /**
     * @notice Reserve collateral for minting operation.
     * @param _lots Number of lots to mint.
     * @param _agentVault Agent vault address.
     * @param _executor Executor address.
     * @param _executorFee Executor fee to be paid.
     * @return _collateralReservationId The ID of the collateral reservation.
     */
    function reserveCollateral(
        uint256 _lots,
        address _agentVault,
        address payable _executor,
        uint256 _executorFee
    )
        external payable
        returns (uint256 _collateralReservationId);

    /**
     * @notice Redeem FXRP and receive XRP.
     * @param _lots Number of lots to redeem.
     * @param _executor Executor address.
     * @param _executorFee Executor fee to be paid.
     * @return _amount The actual amount of FXRP redeemed.
     */
    function redeem(
        uint256 _lots,
        address payable _executor,
        uint256 _executorFee
    )
        external payable
        returns (uint256 _amount);

    /**
     * @notice Deposit assets into the vault.
     * @param _amount Amount to deposit.
     * @param _vault Vault address.
     * @return _shares The received shares.
     */
    function deposit(
        uint256 _amount,
        address _vault
    )
        external
        returns (uint256 _shares);

    /**
     * @notice Withdraw assets from the vault.
     * @param _amount Amount to withdraw.
     * @param _vault Vault address.
     * @return _shares The withdrawn shares.
     */
    function withdraw(
        uint256 _amount,
        address _vault
    )
        external
        returns (uint256 _shares);

    /**
     * @notice Claim withdrawal assets from the vault.
     * @param _period Period to claim.
     * @param _vault Vault address.
     * @return _amount The amount claimed.
     */
    function claimWithdraw(
        uint256 _period,
        address _vault
    )
        external
        returns (uint256 _amount);
}
