// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ContractRegistry} from "flare-periphery/src/flare/ContractRegistry.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IRedeemingSubaccount} from "../../userInterfaces/IRedeemingSubaccount.sol";
import {IPersonalAccount} from "../../userInterfaces/IPersonalAccount.sol";
import {IExecutorsFacet} from "../../userInterfaces/facets/IExecutorsFacet.sol";
import {SubaccountBase} from "./SubaccountBase.sol";

/**
 * @title RedeemingSubaccountBase
 * @notice What every Flare subaccount type whose idle FXRP means one thing - home - shares:
 * the permissionless rail ({sweepRedeem}) and the redemption core behind it ({_sweepRedeem}),
 * which pushes the whole balance to the parent Personal Account and has the parent redeem it
 * to the XRPL owner. Every entry to the core - the rail, and whatever authenticated entry a
 * type adds - redeems the same balance at the same price - the controller's executor fee - so
 * a redemption is never cheaper for arriving one way rather than another. What becomes of a
 * balance FAssets will not redeem is the parent's decision, not a type's: the parent keeps a
 * below-minimum balance unredeemed, and hands back an unfilled remainder that is itself
 * redeemable so that the next sweep finishes it.
 * @dev No state of its own and no native exit: whatever value a sweep carries travels whole to
 * the parent, as the FAssets executor fee or into the parent's float when nothing was redeemed.
 */
abstract contract RedeemingSubaccountBase is IRedeemingSubaccount, SubaccountBase, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    /// @inheritdoc IRedeemingSubaccount
    function sweepRedeem()
        external payable
        nonReentrant
        returns (uint256 _amount, uint256 _redeemedAmount)
    {
        return _sweepRedeem(msg.value);
    }

    /// @dev Shared redemption core behind every entry - the public rail and a type's
    /// authenticated one - so both redeem the whole balance and both pay the same price: the
    /// controller's configured executor fee, checked first, before the balance is even read, so
    /// a short call fails the same way whatever it would have found (and, delivered through an
    /// endpoint, stays retriable). For the rail the fee is the price of the one permissionless
    /// direction - a balance here can still be awaiting a signed forward move, so forcing it
    /// home is never gas-only; for an authenticated arrival it is parity, so a redemption is
    /// never had for nothing by arriving as a packet. The fee is read when the redemption runs;
    /// a change to it is timelocked, so it is known in advance, and a packet whose value a
    /// change left short is finished by a `lzCompose` retry carrying the current fee, or by
    /// anyone's {sweepRedeem} - the operator does either, from its own funds, so no user is
    /// left to top up a raise they could not have seen. An empty account reverts too, so a
    /// redeem-home packet whose
    /// credit a public sweep already moved stays retriable, and a caller's value is returned
    /// rather than trapped. The parent then pulls the balance and requests its redemption with
    /// `_fee` as the executor fee, so it is the recorded redeemer and every outcome remains with
    /// the user; what FAssets fills is FAssets' to decide, and a balance it would not redeem the
    /// parent keeps, value included - never `msg.sender`, which on an authenticated path is not
    /// the user.
    function _sweepRedeem(
        uint256 _fee
    )
        internal
        returns (uint256 _amount, uint256 _redeemedAmount)
    {
        // slither-disable-next-line unused-return
        (, uint256 executorFee) = IExecutorsFacet(controllerAddress).getExecutorInfo();
        require(_fee >= executorFee, InsufficientFundsForRedeem(executorFee));
        address parent = _parentAccount();
        IERC20 fxrp = ContractRegistry.getAssetManagerFXRP().fAsset();
        _amount = fxrp.balanceOf(address(this));
        require(_amount > 0, NothingToRedeem());

        // the parent pulls exactly this amount and requests its redemption - never more, so its
        // own balance is never part of it - and is the recorded redeemer, so every outcome
        // remains with the user; the whole fee rides along for the executor
        fxrp.forceApprove(parent, _amount);
        _redeemedAmount = IPersonalAccount(parent).redeemFromSubaccount{value: _fee}(_amount);
        if (_redeemedAmount == 0) {
            // FAssets would not redeem it: the parent kept the balance, and the value with it
            emit NativeSweptToParent(parent, _fee);
            emit TokenSweptToParent(parent, address(fxrp), _amount);
        } else {
            emit FXrpRedeemed(parent, _amount, _redeemedAmount);
        }
    }
}
