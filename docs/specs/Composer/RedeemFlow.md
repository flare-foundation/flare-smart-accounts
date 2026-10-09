# Redeem flow

The composer's only state-changing entry point from the outside world is `lzCompose`. This document walks through what happens between "a compose message arrives" and "fAsset has been redeemed (or refunded)".

## Inputs

```solidity
function lzCompose(
    address _from,
    bytes32 _guid,
    bytes calldata _message,
    address /* _executor */,
    bytes calldata /* _extraData */
) external payable nonReentrant;
```

The trailing two arguments are ignored — the composer reads its own executor preference from the decoded message body. `nonReentrant` uses `ReentrancyGuardTransient` (EIP-1153 transient storage).

The `_message` is a LayerZero OFT compose envelope:
- `srcEid` (4 bytes) — source endpoint ID.
- `amountLD` (32 bytes) — local-decimal amount that arrived on Flare.
- The composer message body (variable) — ABI-encoded `RedeemComposeMessage`.

Decoding uses `OFTComposeMsgCodec.srcEid`, `OFTComposeMsgCodec.amountLD`, and `OFTComposeMsgCodec.composeMsg` from `@layerzerolabs/oft-evm`.

`RedeemComposeMessage`:

```solidity
struct RedeemComposeMessage {
    address redeemer;                       // EVM owner of the per-redeemer account
    string redeemerUnderlyingAddress;       // destination on the FAsset underlying chain
    bool redeemWithTag;                     // true → call redeemWithTag (XRP only)
    uint256 destinationTag;                 // tag value; only used if redeemWithTag
    address payable executor;               // if zero, use defaultExecutor
    uint256 executorFee;                    // wei expected from msg.value
}
```

## Step-by-step

### 1. Authorization

```solidity
require(msg.sender == endpoint, OnlyEndpoint());
require(_from == trustedSourceOApp, InvalidSourceOApp(_from));
```

Only the trusted Flare-side LayerZero endpoint can call. Only the trusted source-chain OFT adapter can be the message's logical source.

### 2. Decode

```solidity
uint32 srcEid = OFTComposeMsgCodec.srcEid(_message);
uint256 amountLD = OFTComposeMsgCodec.amountLD(_message);
RedeemComposeMessage memory redeemComposeMessage = abi.decode(
    OFTComposeMsgCodec.composeMsg(_message),
    (RedeemComposeMessage)
);
require(redeemComposeMessage.redeemer != address(0), InvalidAddress());
require(msg.value >= redeemComposeMessage.executorFee, InsufficientExecutorFee(msg.value, executorFee));
```

The composer enforces `msg.value >= executorFee`. The matching expectation on the source side is that the `lzComposeOption` is configured with a compose value of at least `executorFee` so the LayerZero executor is incentivized to deliver `lzCompose` with the right native value. The integration note on [`IFAssetRedeemComposer`](../../../contracts/userInterfaces/IFAssetRedeemComposer.sol) calls this out.

### 3. Composer fee

```solidity
uint256 composerFee = mulDiv(amountLD, _getComposerFeePPM(srcEid), 1_000_000);
uint256 amountToRedeemAfterFee = amountLD - composerFee;
if (composerFee > 0) {
    fAsset.safeTransfer(composerFeeRecipient, composerFee);
    emit ComposerFeeCollected(_guid, srcEid, composerFeeRecipient, composerFee);
}
```

`_getComposerFeePPM(srcEid)` returns the per-srcEid override (if set) or the default. See [Fees](./Fees.md).

### 4. Forward fAsset to the redeemer account

```solidity
address redeemerAccount = _getOrCreateRedeemerAccount(redeemComposeMessage.redeemer);
fAsset.safeTransfer(redeemerAccount, amountToRedeemAfterFee);
emit FAssetTransferred(redeemerAccount, amountToRedeemAfterFee);
```

`_getOrCreateRedeemerAccount` returns the existing account if one is registered, otherwise CREATE2-deploys a new `FAssetRedeemerAccountProxy` and primes its allowances via `setMaxAllowances(fAsset, stableCoin, wNat)` so the redeemer (the user's EVM address) can sweep the account if redemption later fails. See [Redeemer accounts](./RedeemerAccounts.md).

### 5. Select executor

```solidity
address payable executor = redeemComposeMessage.executor != address(0)
    ? redeemComposeMessage.executor
    : defaultExecutor;
```

The composer never falls back to `msg.sender` — `msg.sender` is always the LayerZero endpoint, not a user-facing identity.

### 6. Try redeem

```solidity
try IIFAssetRedeemerAccount(redeemerAccount).redeemFAsset{value: executorFee}(
    assetManager,
    amountToRedeemAfterFee,
    redeemerUnderlyingAddress,
    redeemWithTag,
    destinationTag,
    executor
) returns (uint256 redeemedAmountUBA) {
    // success path
} catch {
    // failure path
}
```

Inside the redeemer account:
- If `redeemWithTag`: assert `assetManager.redeemWithTagSupported()` (XRP only), then `assetManager.redeemWithTag{value: msg.value}(amount, underlying, executor, destinationTag)`.
- Else: `assetManager.redeemAmount{value: msg.value}(amount, underlying, executor)`.

Either path returns the redeemed UBA amount reported by the asset manager.

### 7a. Success: wrap any excess native

```solidity
uint256 excessAmount = 0;
if (msg.value > executorFee) {
    excessAmount = msg.value - executorFee;
    IWNat(address(wNat)).depositTo{value: excessAmount}(redeemerAccount);
}

emit FAssetRedeemed(
    guid, srcEid, redeemer, redeemerAccount,
    amountToRedeemAfterFee, redeemerUnderlyingAddress,
    redeemWithTag, destinationTag,
    executor, executorFee, redeemedAmountUBA, excessAmount
);
```

`executorFee` was forwarded as `msg.value` into `redeemFAsset`. Any native FLR the LayerZero executor over-delivered is wrapped to wNat and parked in the redeemer account — it isn't refunded to `tx.origin` and it isn't burned.

### 7b. Failure: wrap the whole `msg.value`

```solidity
if (msg.value > 0) {
    IWNat(address(wNat)).depositTo{value: msg.value}(redeemerAccount);
}

emit FAssetRedeemFailed(
    guid, srcEid, redeemer, redeemerAccount,
    amountToRedeemAfterFee, msg.value
);
```

The fAsset transfer in step 4 has already happened. So even on failure, the user's fAsset is in their redeemer account (allowance already set to `type(uint256).max` to the user's EVM address — they can transfer it out themselves). The native value gets wrapped into wNat the same way.

The failure path is wide on purpose — any revert from the asset manager (insufficient backing, unsupported tag, agent fault) lands here. The whole `lzCompose` call still **succeeds at the LayerZero level**, because if it reverted the message would be retried indefinitely and the composer doesn't want that.

## What replay protection looks like

The composer maintains **no replay set**. LayerZero guarantees `lzCompose(guid)` is delivered to the destination at most once per `guid` — the endpoint enforces that on its own state. The `_guid` parameter exists only for event correlation; the composer never reads it for replay decisions.

If a compose call reverts at the *composer* level (e.g., `OnlyEndpoint`, `InvalidSourceOApp`, `InvalidAddress`, `InsufficientExecutorFee`), the LayerZero endpoint can re-deliver it later — that's deliberate. The composer's revert checks are conditions on the message itself, not on protocol state, so they don't change between retries.

## Idempotent address derivation

After a redeemer's first `lzCompose`, `redeemerToRedeemerAccount[redeemer]` is set. Subsequent calls re-use the same account address. Off-chain code can predict the address before any redemption with `getRedeemerAccountAddress(redeemer)` — the function returns the stored address if known, otherwise the CREATE2 prediction. For an account not yet created, the prediction holds only until the composer's next implementation upgrade: an account first created after an upgrade can land at a different address than the one predicted before it (see [Address derivation](./RedeemerAccounts.md#address-derivation)), so do not send assets to a predicted address.

## Recovery user actions

Recovery uses either the owner's ERC-20 allowances or the account's `onlyOwner` payment-default entry points, depending on the scenario.

### After `FAssetRedeemFailed` — sweep residuals

When `redeemFAsset` reverts, the AssetManager's `redeemAmount` / `redeemWithTag` reverted with it, so **no redemption request was created**. There is no `redemptionRequestId` to default on. The composer has, however, already transferred the post-fee fAsset to the redeemer account (step 4) and wrapped all of `msg.value` to wNat in the redeemer account (step 7b). Both transfers stay put — they aren't unwound because the `try/catch` swallows the revert at the composer level.

The `setMaxAllowances` call performed at account creation set `forceApprove(owner, type(uint256).max)` on fAsset, stableCoin, and wNat. The user recovers any of those three tokens with a single `transferFrom(redeemerAccount, theirAddress, amount)` — no composer interaction needed. This allowance does not cover other tokens; see [Supported recovery tokens](./RedeemerAccounts.md#supported-recovery-tokens).

### After `FAssetRedeemed` — redemption payment default

This applies to the **success** path: the redemption request was created, but the agent never made the corresponding underlying-chain payment within the allowed window. The user submits a non-payment proof to the AssetManager via the redeemer account:

- `FAssetRedeemerAccount.redemptionPaymentDefault(proof, requestId)` — generic variant.
- `FAssetRedeemerAccount.xrpRedemptionPaymentDefault(proof, requestId)` — XRP-specific variant.

Both are `onlyOwner` (the user's EVM redeemer address). The asset manager handles the actual payment-default accounting and returns the collateral payout into the redeemer account. The user can sweep it via the pre-approved allowance only when the payout token is one of that account's three approved tokens. Before FAssets adds another collateral token, operators must establish recovery for affected accounts as described in [Supported recovery tokens](./RedeemerAccounts.md#supported-recovery-tokens).
