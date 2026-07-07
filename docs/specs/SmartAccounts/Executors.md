# Executors

"Executor" means three different things in Smart Accounts. The name is shared because the role is the same — an off-chain actor paid to push state forward — but the mechanics, the unit of payment, and the access control differ across the three contexts.

## 1. Default protocol executor (proof flow)

[`ExecutorsFacet`](../../../contracts/smartAccounts/facets/ExecutorsFacet.sol) + [`Executors` library](../../../contracts/smartAccounts/library/Executors.sol) configure a single global executor that the diamond passes to the AssetManager whenever it reserves collateral or initiates an FXRP redemption on a user's behalf.

State:

```solidity
struct State {
    address payable executor;
    uint256 executorFee;      // wei, NOT fAsset units
}
```

Set at deployment via `MasterAccountControllerInit`. Updated later via:

- `setExecutor(payable)` — `onlyOwner`, **not** timelocked. Rotating the executor address must be possible quickly (e.g., if the executor's key is compromised).
- `setExecutorFee(uint256)` — `onlyOwnerWithTimelock`. Fee changes are economic decisions, not emergencies.
- `getExecutorInfo() → (executor, fee)` — read.

This executor is paid in **wei** (native FLR), funded out of the `msg.value` the relayer sends with `reserveCollateral` or `executeInstruction(...redeem)`. `FXrp.reserveCollateral` and `FXrp.redeem` read `Executors.getExecutorInfo()` and forward the pair to the PA's `IAssetManager.reserveCollateral` / `IAssetManager.redeem` call.

## 2. Personal-Account-pinned executor (direct-mint flow)

[`MemoInstructions.State.executor`](../../../contracts/smartAccounts/library/MemoInstructions.sol) is a per-PA pin. The user sets or clears it via the XRPL memo `0xD0` / `0xD1` opcodes.

While set:
- `handleMintedFAssets` requires `_executor == MemoInstructions.getExecutor(personalAccount)` before distribution.
- The check is **bypassed** when the opcode is `0xD0` or `0xD1` themselves, so the user can never lock themselves out — re-keying or clearing the pin always succeeds.
- The check is also bypassed when the memo is being **ignored** (a prior `0xE0` matched this `_transactionId`).

The direct-mint executor is paid in **fAsset units**, deducted from the minted amount. The fee comes from one of three sources, in priority order:

1. **`0xE2` replacement-fee override** for this `(personalAccount, _transactionId)`. Consumed on use.
2. **The memo's own fee field** (bytes 2–10 of every memo).
3. **`AssetManager.getDirectMintingExecutorFeeUBA()`** when no memo is present or the memo is ignored.

The view accessor `getExecutor(personalAccount)` is available on `MemoInstructionsFacet`.

## 3. PersonalAccount-side executor parameter

The PA's `reserveCollateral` and `redeemFXrp` accept `(executor, executorFee)` as parameters and forward them to the FAssets AssetManager. The diamond is the only caller (`onlyController`); it always passes the *protocol* executor from `Executors.getExecutorInfo`. The PA does not enforce any further executor policy.

For `executeUserOp`, no executor concept applies — the multi-call is whatever the UserOp's `callData` says.

## Why three distinct concepts

Each context has a different funding source:

- **Proof flow** is initiated by a relayer who already holds FLR; paying the executor in wei is the cheap path. The proof-flow executor is global because relaying proofs is a coordinated, protocol-level service.
- **Direct mint** is funded out of the minted fAsset itself. Paying the executor in fAsset units keeps the user from having to hold FLR for direct-mint UserOps. The PA-level pin lets a user nominate a preferred relayer (e.g., one they have an off-chain arrangement with) without admin-level governance.
- **AssetManager-level executor** is FAssets' own concept; Smart Accounts just plumbs the global value through.

The three are mutually exclusive: an instruction either takes the proof flow (paying in wei) or the direct-mint flow (paying in fAsset), never both.

## Recovery if the pinned executor disappears

`0xD0` / `0xD1` both bypass the executor check. So even if the currently-pinned executor is no longer answering, the user can:

1. Send an XRPL Payment with a `0xD1` memo to clear the pin — any executor can submit this.
2. Or send a `0xD0` memo with a new pinned executor — again, any executor can submit.

After that, normal direct minting resumes against the new (or absent) pin.

`0xE2` is the matching recovery path when the fee on a stuck transaction is too low. `0xE0` is the broader recovery path that ignores the memo wholesale.
