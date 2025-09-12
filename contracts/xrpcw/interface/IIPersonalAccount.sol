// SPDX-License-Identifier: MIT
pragma solidity >=0.7.6 <0.9;

import {IPersonalAccount} from "../../userInterfaces/IPersonalAccount.sol";

/**
 * @title IIPersonalAccount
 */
interface IIPersonalAccount is IPersonalAccount {
    /**
     * @notice Deposit assets into the vault.
     * @param _amount Amount to deposit.
     * @param _vault Vault address.
     */
    function deposit(uint256 _amount, address _vault) external;

    /**
     * @notice Withdraw assets from the vault.
     * @param _amount Amount to withdraw.
     * @param _vault Vault address.
     */
    function withdraw(uint256 _amount, address _vault) external;

    /**
     * @notice Approve assets for the vault.
     * @param _amount Amount to approve.
     * @param _fxrp Asset address.
     * @param _vault Vault address.
     */
    function approve(uint256 _amount, address _fxrp, address _vault) external;

    /**
     * @notice Redeem FXRP and receive XRP.
     * @param _lots Number of lots to redeem.
     * @param _executor Executor address.
     * @param _executorFee Executor fee to be paid.
     */
    function redeem(
        uint256 _lots,
        address payable _executor,
        uint256 _executorFee
    ) external payable;

    /**
     * @notice Reserve collateral for minting operation.
     * @param _lots Number of lots to mint.
     * @param _agentVault Agent vault address.
     * @param _executor Executor address.
     * @param _executorFee Executor fee to be paid.
     */
    function reserveCollateral(
        uint256 _lots,
        address _agentVault,
        address payable _executor,
        uint256 _executorFee
    ) external payable;
}
