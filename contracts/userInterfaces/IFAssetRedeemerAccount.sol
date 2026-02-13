// SPDX-License-Identifier: MIT
pragma solidity >=0.8.4 <0.9;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title IFAssetRedeemerAccount
 * @notice User interface for per-redeemer account operations.
 */
interface IFAssetRedeemerAccount {

    /**
     * @notice Emitted when allowances are set to max from account to owner.
     * @param owner Owner of redeemer account.
     * @param fAsset FAsset token.
     * @param stableCoin Stable coin token.
     * @param wNat Wrapped native token.
     */
    event MaxAllowancesSet(
        address indexed owner,
        IERC20 fAsset,
        IERC20 stableCoin,
        IERC20 wNat
    );

    /**
     * @notice Reverts when a required address is zero.
     */
    error InvalidAddress();

    /**
     * @notice Reverts when caller is not the composer.
     */
    error ComposerOnly();

    /**
     * @notice Reverts when initialize is called more than once.
     */
    error AlreadyInitialized();

    /**
     * @notice Reverts when provided native value does not cover executor fee.
     * @param sent Native value sent with redemption call.
     * @param required Required executor fee.
     */
    error ExecutorFeeNotCovered(uint256 sent, uint256 required);

}
