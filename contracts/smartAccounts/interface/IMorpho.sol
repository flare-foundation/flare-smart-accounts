// SPDX-License-Identifier: MIT
pragma solidity >=0.8.4 <0.9;

/**
 * @title IMorpho
 * @notice Minimal Morpho Blue interface: only the entry points the Ethereum-side loan
 * subaccount uses. Signatures and the `MarketParams` layout match the canonical
 * `morpho-org/morpho-blue` `IMorpho`; replace with the canonical package if it gets vendored.
 */
interface IMorpho {

    struct MarketParams {
        address loanToken;
        address collateralToken;
        address oracle;
        address irm;
        uint256 lltv;
    }

    /**
     * @notice Supplies collateral on behalf of an account.
     * @param marketParams The market to supply collateral to.
     * @param assets The amount of collateral to supply.
     * @param onBehalf The account that owns the increased collateral position.
     * @param data Arbitrary callback data (unused by the caller in this repo).
     */
    function supplyCollateral(
        MarketParams memory marketParams,
        uint256 assets,
        address onBehalf,
        bytes memory data
    )
        external;

    /**
     * @notice Borrows assets against the caller's collateral position.
     * @param marketParams The market to borrow from.
     * @param assets The amount of assets to borrow (exactly one of assets/shares is non-zero).
     * @param shares The amount of shares to borrow.
     * @param onBehalf The account that owns the increased borrow position.
     * @param receiver The receiver of the borrowed assets.
     * @return assetsBorrowed The amount of assets borrowed.
     * @return sharesBorrowed The amount of shares borrowed.
     */
    function borrow(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        address receiver
    )
        external
        returns (uint256 assetsBorrowed, uint256 sharesBorrowed);

    /**
     * @notice Withdraws collateral from the caller's position.
     * @param marketParams The market to withdraw collateral from.
     * @param assets The amount of collateral to withdraw.
     * @param onBehalf The account that owns the reduced collateral position.
     * @param receiver The receiver of the withdrawn collateral.
     */
    function withdrawCollateral(
        MarketParams memory marketParams,
        uint256 assets,
        address onBehalf,
        address receiver
    )
        external;

    /**
     * @notice Repays assets on behalf of a borrow position.
     * @param marketParams The market to repay to.
     * @param assets The amount of assets to repay (exactly one of assets/shares is non-zero).
     * @param shares The amount of shares to repay.
     * @param onBehalf The account whose debt is reduced.
     * @param data Arbitrary callback data (unused by the caller in this repo).
     * @return assetsRepaid The amount of assets repaid.
     * @return sharesRepaid The amount of shares repaid.
     */
    function repay(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        bytes memory data
    )
        external
        returns (uint256 assetsRepaid, uint256 sharesRepaid);
}
