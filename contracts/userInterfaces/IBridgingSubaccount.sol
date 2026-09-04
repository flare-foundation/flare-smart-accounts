// SPDX-License-Identifier: MIT
pragma solidity >=0.8.4 <0.9;

import {IComposeReceiverAccountBase} from "./IComposeReceiverAccountBase.sol";
import {ISubaccount} from "./ISubaccount.sol";

/// @dev Redeem-home action: the compose the remote bridge-back attaches to the FXRP it
/// returns - the withdraw action's return leg. Its
/// `actionData` is `abi.encode(uint64 deadline)`, stamped by the sender as its block time plus
/// `REDEEM_HOME_TTL`. Before expiry, at most the authenticated `amountLD` is redeemed through
/// the parent; below the FAssets minimum it is transferred unredeemed, and the compose value is
/// the executor fee (zero allowed - the packet already cost its sender the LayerZero fee).
/// Expired packets skip terminally, leaving the FXRP for {IBridgingSubaccount.sweepRedeem} and
/// forwarding the compose value to the parent. The cap limits the amount, not the token
/// provenance.
uint8 constant ACTION_REDEEM_HOME = 1;

/// @dev Redeem-home delivery window: verification, executor delivery and ordinary retries,
/// normally minutes. Later packets skip and leave their FXRP for {IBridgingSubaccount.sweepRedeem},
/// which is what an extended LayerZero outage falls back to. Tune from observed delivery
/// latency after deployment.
uint64 constant REDEEM_HOME_TTL = 1 hours;

/**
 * @title IBridgingSubaccount
 * @notice The surface every Flare subaccount type that bridges FXRP to its own address on a
 * remote chain shares, whatever the type does there: the one permissionless rail (`sweepRedeem`,
 * home is the only public direction), and the redeem-home compose of its own remote twin's
 * bridge-back (see {IComposeReceiverAccountBase}) - FXRP coming home is redeemed on arrival.
 * The type's own parent-driven instructions are declared on the type's interface (e.g.
 * {ILoanSubaccount}).
 */
interface IBridgingSubaccount is IComposeReceiverAccountBase, ISubaccount {

    /**
     * @notice Emitted when idle FXRP is pushed to the parent Personal Account and redeemed by
     * it to its XRPL owner.
     * @param parentPersonalAccount The parent Personal Account address (the redeemer).
     * @param amount Amount of FXRP pushed and requested for redemption (the whole balance from
     * the public rail; at most the packet's authenticated amount from the redeem-home compose).
     * @param redeemedAmount Amount of FXRP actually redeemed, which can be less; the rest
     * stays on the parent.
     */
    event FXrpRedeemed(
        address indexed parentPersonalAccount,
        uint256 amount,
        uint256 redeemedAmount
    );

    /**
     * @notice Emitted when a redeem-home compose arrives past its deadline and skips: nothing
     * is redeemed, the packet's credit stays for the public rail, its value went to the parent.
     * @param parentPersonalAccount The parent Personal Account address.
     * @param guid The LayerZero message id of the skipped packet.
     */
    event RedeemHomeSkipped(
        address indexed parentPersonalAccount,
        bytes32 guid
    );

    /**
     * @notice Emitted when a {sweepRedeem} or redeem-home compose pushes a below-minimum FXRP
     * balance to the parent Personal Account unredeemed (in place of {FXrpRedeemed}).
     * @param parentPersonalAccount The parent Personal Account address.
     * @param token The FXRP token.
     * @param amount The pushed amount.
     */
    event TokenSweptToParent(
        address indexed parentPersonalAccount,
        address indexed token,
        uint256 amount
    );

    /**
     * @notice Emitted when native is sent to the parent Personal Account: the value of a
     * {sweepRedeem} or redeem-home compose that pushed a below-minimum balance without
     * redeeming, or of a redeem-home compose that arrived past its deadline.
     * @param parentPersonalAccount The parent Personal Account address.
     * @param amount The amount sent.
     */
    event NativeSweptToParent(
        address indexed parentPersonalAccount,
        uint256 amount
    );

    /**
     * @notice Reverts if there is no FXRP to redeem.
     */
    error NothingToRedeem();

    /**
     * @notice Reverts if this subaccount's type has no complete bridge route on the controller:
     * no FXRP OFT adapter, a type never pinned to a remote chain, a suspended type, or a
     * cleared route.
     */
    error BridgeRouteNotConfigured();

    /**
     * @notice Reverts if the OFT's live peer for the destination chain no longer matches the
     * peer pinned in the controller's bridge route for this subaccount's type.
     */
    error WrongDestinationPeer();

    /**
     * @notice Reverts if the value sent with a forward move does not cover the LayerZero
     * messaging fee of the bridge.
     * @param messagingFee The required messaging fee.
     */
    error InsufficientFundsForBridge(
        uint256 messagingFee
    );

    /**
     * @notice Reverts if the caller's excess native refund could not be returned.
     */
    error RefundFailed();

    /**
     * @notice Reverts if the value sent with {sweepRedeem} does not cover the controller's
     * executor fee: the configured fee is the price of the permissionless backward rail.
     * @param executorFee The required executor fee.
     */
    error InsufficientFundsForRedeem(
        uint256 executorFee
    );

    /**
     * @notice Reverts if native could not be sent to the parent Personal Account.
     */
    error NativeSweepFailed();

    /**
     * @notice Reverts if the requested bridge amount exceeds the account's FXRP balance.
     * @param amount The requested amount.
     * @param balance The account's FXRP balance.
     */
    error AmountExceedsBalance(
        uint256 amount,
        uint256 balance
    );

    /**
     * @notice Redeems all idle FXRP through the parent Personal Account, to its XRPL owner.
     * @dev Permissionless and parameterless: the destination is the parent (fixed at
     * deployment, part of this account's address), which pulls and redeems exactly the pushed
     * amount through {IPersonalAccount-redeemFromSubaccount}, so every outcome - a partial fill
     * when FAssets tickets run out, a payment-default payout, a refund - remains under the
     * user's control. `msg.value` must cover the controller's configured executor fee
     * ({InsufficientFundsForRedeem}) and travels whole as that fee (FAssets records it in whole
     * gwei); the fee is the price of the permissionless rail. The whole balance is redeemed
     * rather than whole lots, so nothing strands here. Below the FAssets minimum, the FXRP and
     * the value are transferred to the parent unredeemed instead ({TokenSweptToParent} and
     * {NativeSweptToParent} in place of {FXrpRedeemed}, `_redeemedAmount` zero) - the rail
     * never fails on amount and costs the same either way.
     * @return _amount Amount of FXRP pushed to the parent (the whole balance).
     * @return _redeemedAmount Amount of FXRP actually redeemed; zero below the minimum.
     */
    function sweepRedeem()
        external payable
        returns (uint256 _amount, uint256 _redeemedAmount);
}
