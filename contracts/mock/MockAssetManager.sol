// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IReferencedPaymentNonexistence} from "flare-periphery/src/flare/IReferencedPaymentNonexistence.sol";
import {IXRPPaymentNonexistence} from "flare-periphery/src/flare/IXRPPaymentNonexistence.sol";
import {MintableERC20} from "./MintableERC20.sol";

/**
 * @title MockAssetManager
 * @notice Behavioral FAssets asset manager mock for redemption: `redeemAmount` enforces the
 * governance-set minimum, burns the redeemed FAssets from the caller, and can fill partially
 * (as real FAssets does when redemption tickets run out), so tests exercise real balance
 * invariants instead of stubbed return values. Functions unrelated to redemption are left to
 * `vm.mockCall`.
 */
contract MockAssetManager {

    MintableERC20 public immutable fAssetToken;
    uint256 public minimumRedeemAmount;
    /// @notice Cap on how much a single `redeemAmount` call redeems; 0 means "no cap".
    uint256 public maxRedeemPerCall;
    uint256 public lastRedeemValue;
    /// @notice Token minted to the redeemer on a payment default, standing in for the vault
    /// collateral / pool WNat payout of real FAssets.
    MintableERC20 public defaultPayoutToken;
    uint256 public defaultPayoutAmount;
    uint256 public lastDefaultRequestId;
    address public lastDefaultCaller;

    constructor(MintableERC20 _fAssetToken) {
        fAssetToken = _fAssetToken;
    }

    function redeemAmount(
        uint256 _amountUBA,
        string calldata /* _redeemerUnderlyingAddressString */,
        address payable /* _executor */
    )
        external payable
        returns (uint256 _redeemedAmountUBA)
    {
        require(_amountUBA >= minimumRedeemAmount, "amount too small");

        _redeemedAmountUBA = _amountUBA;
        if (maxRedeemPerCall != 0 && _redeemedAmountUBA > maxRedeemPerCall) {
            // partial fill: only part of the request is redeemed, the rest stays with the caller
            _redeemedAmountUBA = maxRedeemPerCall;
        }
        // the redeemed FAssets are burned from the redeemer
        fAssetToken.burn(msg.sender, _redeemedAmountUBA);
        lastRedeemValue = msg.value;
    }

    function redemptionPaymentDefault(
        IReferencedPaymentNonexistence.Proof calldata /* _proof */,
        uint256 _redemptionRequestId
    )
        external
    {
        _payOutDefault(_redemptionRequestId);
    }

    function xrpRedemptionPaymentDefault(
        IXRPPaymentNonexistence.Proof calldata /* _proof */,
        uint256 _redemptionRequestId
    )
        external
    {
        _payOutDefault(_redemptionRequestId);
    }

    function setDefaultPayout(MintableERC20 _token, uint256 _amount) external {
        defaultPayoutToken = _token;
        defaultPayoutAmount = _amount;
    }

    function setMinimumRedeemAmountUBA(uint256 _minimumRedeemAmount) external {
        minimumRedeemAmount = _minimumRedeemAmount;
    }

    function setMaxRedeemPerCall(uint256 _maxRedeemPerCall) external {
        maxRedeemPerCall = _maxRedeemPerCall;
    }

    function fAsset() external view returns (IERC20) {
        return IERC20(address(fAssetToken));
    }

    function minimumRedeemAmountUBA() external view returns (uint256) {
        return minimumRedeemAmount;
    }

    /// @dev The default payout goes to the caller, which real FAssets only permits to be the
    /// redeemer, the appointed executor, or the agent owner.
    function _payOutDefault(uint256 _redemptionRequestId) private {
        lastDefaultRequestId = _redemptionRequestId;
        lastDefaultCaller = msg.sender;
        if (address(defaultPayoutToken) != address(0)) {
            defaultPayoutToken.mint(msg.sender, defaultPayoutAmount);
        }
    }
}
