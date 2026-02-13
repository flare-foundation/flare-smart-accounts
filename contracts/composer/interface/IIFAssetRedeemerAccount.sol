// SPDX-License-Identifier: MIT
pragma solidity >=0.8.4 <0.9;

import {IAssetManager} from "flare-periphery/src/flare/IAssetManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IFAssetRedeemerAccount} from "../../userInterfaces/IFAssetRedeemerAccount.sol";

/**
 * @title IIFAssetRedeemerAccount
 * @notice Internal interface for per-redeemer account operations.
 */
interface IIFAssetRedeemerAccount is IFAssetRedeemerAccount {

    /**
     * @notice Executes f-asset redemption via configured asset manager.
     * @param _assetManager Asset manager contract.
     * @param _amountToRedeemUBA Amount to redeem in UBA.
     * @param _redeemerUnderlyingAddress Underlying-chain destination for redemption.
     * @param _executor Executor used by the asset manager redemption flow.
     * @param _executorFee Executor fee for the redemption.
     * @return _redeemedAmountUBA Redeemed amount reported by asset manager.
     */
    function redeemFAsset(
        IAssetManager _assetManager,
        uint256 _amountToRedeemUBA,
        string calldata _redeemerUnderlyingAddress,
        address payable _executor,
        uint256 _executorFee
    )
        external payable
        returns (uint256 _redeemedAmountUBA);

    /**
     * @notice Sets max allowances from account to owner for selected tokens.
     * @param _fAsset FAsset token.
     * @param _stableCoin Stable coin token.
     * @param _wNat Wrapped native token.
     */
    function setMaxAllowances(
        IERC20 _fAsset,
        IERC20 _stableCoin,
        IERC20 _wNat
    )
        external;
}
