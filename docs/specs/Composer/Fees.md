# Composer fees

The composer has two distinct fee surfaces:

1. **Composer fee** — paid out of the bridged fAsset on every successful `lzCompose`. Configurable.
2. **Executor fee** — paid in wei via `msg.value`, enforced as a lower bound on every `lzCompose` and forwarded to the asset manager. Set by the user in the compose message.

## Composer fee

Charged in fAsset units (PPM of the bridged `amountLD`). Skimmed before the redeem and sent to `composerFeeRecipient`.

State (on the composer contract directly):

```solidity
uint256 public defaultComposerFeePPM;
mapping(uint32 srcEid => uint256 feePPM) private composerFeesPPM;  // 1-based!
```

The per-srcEid override is stored 1-based, same convention as Smart Accounts' instruction fees: `0` means "unset, use default", `n+1` means "override = n". Lets the operator explicitly waive the fee for a specific source endpoint without colliding with "unset".

Lookup ([`_getComposerFeePPM`](../../../contracts/composer/implementation/FAssetRedeemComposer.sol)):

```solidity
function _getComposerFeePPM(uint32 _srcEid) internal view returns (uint256) {
    uint256 srcEidFeePlusOne = composerFeesPPM[_srcEid];
    return srcEidFeePlusOne > 0 ? srcEidFeePlusOne - 1 : defaultComposerFeePPM;
}
```

Administration (all `onlyOwnerWithTimelock`):

- `setDefaultComposerFee(uint256)` — capped strictly below `1_000_000` (PPM denominator).
- `setComposerFees(uint32[], uint256[])` — same cap per entry. Stored as `feePPM + 1`.
- `removeComposerFees(uint32[])` — drops overrides. Reverts on unset entries.
- `setComposerFeeRecipient(address)` — non-zero.

Reads: `getComposerFeePPM(srcEid)` returns the effective PPM (override or default).

### Enforcement

In `lzCompose` (see [Redeem flow](./RedeemFlow.md)):

```solidity
uint256 composerFee = Math.mulDiv(amountLD, _getComposerFeePPM(srcEid), 1_000_000);
uint256 amountToRedeemAfterFee = amountLD - composerFee;
if (composerFee > 0) {
    fAsset.safeTransfer(composerFeeRecipient, composerFee);
    emit ComposerFeeCollected(_guid, srcEid, composerFeeRecipient, composerFee);
}
```

`Math.mulDiv` is the OZ-provided 512-bit-intermediate mul-div; it can't overflow for `amountLD * feePPM` because `feePPM < 2^20`. The skim happens **before** the asset-manager redeem is attempted — even a failing redeem still pays the composer fee. That's intentional: the bridge-and-compose path costs the composer fAsset to operate even when the underlying redemption fails.

## Executor fee

Set by the user in the `RedeemComposeMessage.executorFee` field. Carries native FLR on the Flare side that ultimately funds the FAssets executor.

### Source-side requirement (integrator note)

The composer enforces:

```solidity
require(msg.value >= redeemComposeMessage.executorFee, InsufficientExecutorFee(msg.value, redeemComposeMessage.executorFee));
```

The matching expectation is on the source side: the source's `send` call must include a `lzComposeOption` whose compose-side `msg.value` is at least `executorFee`. LayerZero's `send` does not enforce this — only `lzCompose` does. If the source side underprovisions the compose value, the LayerZero executor is under-incentivized to deliver `lzCompose` with the intended `msg.value`, and the message stays undelivered.

This requirement is documented on [`IFAssetRedeemComposer`](../../../contracts/userInterfaces/IFAssetRedeemComposer.sol) at the top of the interface and again on `RedeemComposeMessage.executorFee`.

### Resolution and forwarding

The executor address comes from the compose message or falls back to `defaultExecutor`:

```solidity
address payable executor = redeemComposeMessage.executor != address(0)
    ? redeemComposeMessage.executor
    : defaultExecutor;
```

`setDefaultExecutor(payable)` is `onlyOwnerWithTimelock`; the default executor must be non-zero.

The `executorFee` itself is forwarded as `msg.value` into the redeemer account's `redeemFAsset`, which forwards it again into `IAssetManager.redeemAmount{value: msg.value}` / `redeemWithTag{value: msg.value}`. The asset manager pays the executor on completion.

### Excess and refund

Any `msg.value` above `executorFee` is wrapped to wNat and deposited into the redeemer account on success. On failure, **all** of `msg.value` is wrapped to wNat and deposited there — the redeemer-account allowance to the redeemer's EVM address is already at `type(uint256).max`, so the user can sweep it.

## Composer fee on failure

If `redeemFAsset` reverts (caught by the composer's `try / catch`), the composer fee transfer in step 3 has **already** completed. The composer fee is therefore consumed by every `lzCompose` that gets past authorization and decoding — successful or not. That keeps the fee model simple and prevents users from gaming the failure path to dodge fees.

## Comparison

| | Composer fee | Executor fee |
|---|---|---|
| Unit | fAsset (PPM of `amountLD`) | Wei |
| Paid by | Whoever bridged the OFT (out of the bridged amount) | Source-side caller (via `lzComposeOption` value) |
| Paid to | `composerFeeRecipient` | The configured executor, via the FAssets AssetManager |
| Set by | Owner (timelocked) | Per-message, in `RedeemComposeMessage.executorFee` |
| Lower bound | None (0 PPM allowed) | None — the user sets it. The composer enforces `msg.value >= executorFee`, not a hard minimum. |
| Upper bound | < 1_000_000 PPM (i.e. < 100%) | None |
| Per-srcEid override | Yes (`composerFeesPPM`) | No |
| Charged on failure | Yes (already transferred before the try/catch) | Yes — `msg.value` is wrapped to wNat, parked in the redeemer account |
