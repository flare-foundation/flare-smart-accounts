// SPDX-License-Identifier: MIT
pragma solidity >=0.7.6 <0.9;

import {IPersonalAccount} from "../../userInterfaces/IPersonalAccount.sol";
import {IVaultsFacet} from "../../userInterfaces/facets/IVaultsFacet.sol";


/**
 * @title IIPersonalAccount
 * @notice Internal interface for PersonalAccount contract.
 */
interface IIPersonalAccount is IPersonalAccount {

    /**
     * @notice Reserve collateral for minting operation.
     * @param _agentVault Agent vault address.
     * @param _lots Number of lots to mint.
     * @param _executor Executor address.
     * @param _executorFee Executor fee to be paid.
     * @return _collateralReservationId The ID of the collateral reservation.
     */
    function reserveCollateral(
        address _agentVault,
        uint256 _lots,
        address payable _executor,
        uint256 _executorFee
    )
        external payable
        returns (uint256 _collateralReservationId);

    /**
     * @notice Transfer FXRP to another address.
     * @param _to Recipient address.
     * @param _amount Amount of FXRP to transfer.
     */
    function transferFXrp(
        address _to,
        uint256 _amount
    )
        external;

    /**
     * @notice Redeem FXRP and receive XRP.
     * @param _lots Number of lots to redeem.
     * @param _executor Executor address.
     * @param _executorFee Executor fee to be paid.
     * @return _amount The actual amount of FXRP redeemed.
     */
    function redeemFXrp(
        uint256 _lots,
        address payable _executor,
        uint256 _executorFee
    )
        external payable
        returns (uint256 _amount);

    /**
     * @notice Deposit assets into the vault.
     * @param _vaultType The type of the vault.
     * @param _vault Vault address.
     * @param _assets The amount of assets to deposit.
     * @return _shares The received shares.
     */
    function deposit(
        IVaultsFacet.VaultType _vaultType,
        address _vault,
        uint256 _assets
    )
        external
        returns (uint256 _shares);

    /**
     * @notice Redeem shares from the vault.
     * @param _vault Vault address.
     * @param _shares The amount of shares to redeem.
     * @return _assets The amount of assets redeemed.
     */
    function redeem(
        address _vault,
        uint256 _shares
    )
        external
        returns (uint256 _assets);

    /**
     * @notice Claim withdrawal assets from the vault.
     * @param _vault Vault address.
     * @param _period Period to claim.
     * @return _assets The amount of assets claimed.
     */
    function claimWithdraw(
        address _vault,
        uint256 _period
    )
        external
        returns (uint256 _assets);

    /**
     * @notice Request redemption of shares from the vault.
     * @param _vault Vault address.
     * @param _shares Number of shares to redeem.
     * @return _claimableEpoch The epoch when the assets can be claimed.
     * @return _year The year of the claimable date.
     * @return _month The month of the claimable date.
     * @return _day The day of the claimable date.
     */
    function requestRedeem(
        address _vault,
        uint256 _shares
    )
        external
        returns (uint256 _claimableEpoch, uint256 _year, uint256 _month, uint256 _day);

    /**
     * @notice Claim requested redeemed shares for a specific date from the vault.
     * @param _vault Vault address.
     * @param _year Year of the claim date.
     * @param _month Month of the claim date.
     * @param _day Day of the claim date.
     * @return _shares The number of shares claimed.
     * @return _assets The amount of assets claimed.
     */
    function claim(
        address _vault,
        uint256 _year,
        uint256 _month,
        uint256 _day
    )
        external
        returns (uint256 _shares, uint256 _assets);

    /**
     * @notice Execute a series of calls (user operation).
     * @param _calls Array of calls to execute.
     */
    function executeUserOp(
        IPersonalAccount.Call[] calldata _calls
    )
        external payable;
}
