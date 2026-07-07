# Memo instructions (direct minting)

The **direct-minting** flow lets a user mint FXRP straight to their Personal Account and, in the same XRPL transaction, push an instruction encoded in the memo. The FAssets [`AssetManager`](https://github.com/flare-foundation/fassets) does the minting and then calls back into [`MemoInstructionsFacet.handleMintedFAssets`](../../../contracts/smartAccounts/facets/MemoInstructionsFacet.sol), which dispatches one of seven memo opcodes.

This is the path used for ERC-4337-style `PackedUserOperation` execution and for management opcodes that update the Personal Account's memo state.

## Entry point

```solidity
function handleMintedFAssets(
    bytes32 _transactionId,
    string calldata _sourceAddress,
    uint256 _amount,
    uint256 /* _underlyingTimestamp */,
    bytes calldata _memoData,
    address payable _executor,
    bytes calldata _data
) external payable notPaused;
```

`onlyAssetManager` — the call must come from `ContractRegistry.getAssetManagerFXRP()`. The AssetManager has already minted `_amount` fAsset to the diamond before invoking this method.

### XRPL `DestinationTag` is not permitted

XRPL transactions to smart accounts must **not** use a destination tag. A destination tag on the XRPL Payment lets a third party purchase the tag on the direct-minting facet and front-run the user. Off-chain wallets and the executor pipeline should reject any direct-mint payment that carries a `DestinationTag`.

## Step-by-step (the order matters)

[`handleMintedFAssets`](../../../contracts/smartAccounts/facets/MemoInstructionsFacet.sol) runs:

1. **Resolve PA.** `PersonalAccounts.getOrCreatePersonalAccount(_sourceAddress)`. Even with an empty memo, the PA is created — the mint itself is the action.
2. **Check `ignoreMemo` first** — before *any* memo validation. If a `0xE0` opcode has previously marked this `_transactionId` as ignored, the flag is consumed (deleted from storage) and the rest of the memo handling is skipped. This is how a user recovers from a stuck transaction whose memo would otherwise revert (malformed memo, bad UserOp, …).
3. **Check the pinned PA executor.** If a memo is present and is not ignored, and the opcode is not `0xD0`/`0xD1`, the call's `_executor` must equal `MemoInstructions.getExecutor(personalAccount)` when one is pinned. `0xD0` / `0xD1` themselves bypass this check so a user can never lock themselves out by pinning a now-unreachable executor.
4. **Resolve the executor fee.** From the memo bytes when one is present and not ignored (bytes 2–10 = `uint64 fee`), otherwise from `AssetManager.getDirectMintingExecutorFeeUBA()`. A `0xE2`-set fee override on `(personalAccount, _transactionId)` wins over both and is consumed when read.
5. **Distribute fAsset.** Require `_amount >= executorFee`, mark `_transactionId` as used in `Instructions.State.usedTransactionIds` (replay protection — shared with the proof flow), transfer `executorFee` fAsset to `_executor`, transfer the remaining `_amount - executorFee` to the PA. Emit `DirectMintingExecuted`.
6. **Dispatch the memo opcode** (if a memo is present and was not ignored). The opcode is the first byte; unsupported opcodes revert with `InvalidInstructionId`.

The order is important. Steps 1–2 must happen before any memo validation so a malformed memo can still be recovered. The dispatch in step 6 runs in the same call as steps 1–5 with **no `try/catch`** around it, so a revert from any opcode handler unwinds the entire `handleMintedFAssets` transaction — including the `usedTransactionIds` mark and the fAsset transfers from step 5. The replay set is therefore consistent with on-chain outcomes: it is only set when the whole flow (distribution **and** opcode dispatch, if any) succeeded.

A consequence: when a memo UserOp (`0xFF`/`0xFE`) reverts, the AssetManager's call to `handleMintedFAssets` reverts with it and the transaction does not commit. XRPL Payment transactions are irreversible, so the user is left with a Payment whose memo cannot execute. A stuck Payment can also occur for reasons that aren't on-chain reverts at all — most commonly, the memo's executor fee is technically valid but too low for any off-chain executor to find it worth submitting.

The management opcodes target these scenarios. Each is delivered by a **follow-up** XRPL Payment whose memo addresses the stuck `_transactionId`:

- **`0xE0` — ignore memo.** Skips memo dispatch wholesale for the stuck `_transactionId`. On the next retry against that id the flag from step 2 is consumed, the FAsset is distributed, and `DirectMintingExecuted` is emitted without dispatching the broken opcode. Use when the failure was in the opcode handler itself (malformed memo, bad UserOp callData, unsupported opcode byte, …) and the user just wants the FAsset delivered.
- **`0xE2` — replace executor fee.** Sets the fee that the next retry against the stuck `_transactionId` will use (overriding both the memo's own fee field and the AssetManager default). Two distinct use cases:
  - **Lower the fee** when the original memo specified `executorFee > _amount`, which causes `InsufficientAmountForFee` on chain. Lowering it below `_amount` lets the retry distribute fAsset.
  - **Raise the fee** when the original memo's fee passed the on-chain check but was too low to incentivize any off-chain executor. Raising the override makes the retry economically attractive.
- **`0xE1` — bump nonce.** Advances `nonces[personalAccount]` strictly upward (the library reverts on equal or lower; the jump is also capped at `type(uint32).max`). The interaction with a stuck UserOp's `userOp.nonce == nonces[personalAccount]` check depends on where the stuck UserOp's nonce sits relative to the stored nonce:
  - **Stored nonce < stuck UserOp's nonce.** The UserOp was ahead of state — the failure mode is `InvalidNonce(expected = stored, actual = userOp.nonce)`. Bumping the stored nonce to **exactly** the stuck UserOp's nonce lets a retry succeed; the original Payment is released.
  - **Stored nonce ≥ stuck UserOp's nonce.** The original UserOp cannot be made to succeed via `0xE1`: stored is already past it (or, if equal, any `0xE1` bump moves past it), and `0xE1` cannot decrease the nonce. The stuck UserOp's equality check is out of reach. `0xE1` can still be used here for a different purpose — intentionally advancing past the broken UserOp so later UserOps signed at higher nonces can run — but releasing the skipped Payment's fAsset still requires `0xE0` against that same `_transactionId`.

  In short, `0xE1` has two distinct uses: align state to an ahead-of-state stuck UserOp by snapping the stored nonce to its value, or intentionally advance *past* a broken UserOp so later UserOps signed at higher nonces can run. The two opcodes are complementary, not interchangeable — `0xE1` moves the nonce, `0xE0` releases a stuck Payment's fAsset without dispatching its memo. If `0xE1` is used to advance past a stuck UserOp and the user *also* wants the fAsset from that original Payment, they need `0xE0` for the same `_transactionId` — the ignored-memo path in step 2 is what lets distribution proceed without re-running the broken opcode.

Retries against the stuck `_transactionId` are submitted by an off-chain executor; whether and when the AssetManager re-invokes `handleMintedFAssets` for that id is upstream behavior outside this protocol.

## The seven opcodes

Memo bytes (10-byte header common to every opcode):

```text
byte:  0       1                2..9
       opcode  walletId (uint8) executorFee (uint64, big endian)
```

| Opcode | Bytes after header | Effect |
|--------|--------------------|--------|
| `0xFF` | ABI-encoded `PackedUserOperation` | Execute UserOp inline from the XRPL memo. |
| `0xFE` | `bytes32 keccak256(_data)` (memo length must equal 42) | Execute UserOp passed via the `_data` argument; the memo only commits to its hash. |
| `0xE0` | `bytes32 targetTxId` (memo length must equal 42) | Mark `targetTxId` as ignored for this PA. Recovery path for stuck transactions. |
| `0xE1` | `uint256 newNonce` (memo length must equal 42) | Set the PA's memo nonce. Must strictly increase and the increase must fit in `uint32`. |
| `0xE2` | `bytes32 targetTxId` `uint64 newFee` (memo length must equal 50) | Override the executor fee for `targetTxId`. Stored as `newFee + 1` so 0 means "not set". |
| `0xD0` | `address newExecutor` (memo length must equal 30) | Pin a PA executor. Bypasses the executor check during dispatch. |
| `0xD1` | *(none)* (memo length must equal 10) | Clear the PA executor. Bypasses the executor check during dispatch. |

The memo length checks are exact for the management opcodes (`0xE0`/`0xE1`/`0xE2`/`0xD0`/`0xD1`). Anything else reverts with `InvalidMemoData`. `0xFF` accepts a memo of length `10 + abi.encode(PackedUserOperation).length` (variable). `0xFE` accepts exactly 42 bytes.

### `0xFF` — Execute UserOp inline

```text
[0xFF][walletId][fee:uint64][ abi.encode(PackedUserOperation) ]
```

The `PackedUserOperation` is decoded from `_memoData[10:]`. Only three fields are honored — `sender`, `nonce`, and `callData`. The rest are present for ABI compatibility but ignored.

Checks:
- `userOp.sender == personalAccount` — the UserOp can only operate on the calling PA.
- `userOp.nonce == nonces[personalAccount]` — the UserOp must use the next nonce.

On success the nonce is incremented and `personalAccount.call{value: msg.value}(userOp.callData)` is executed. The diamond is the controller, so calls to PA functions that require `onlyController` (notably `executeUserOp(Call[])`) pass the check.

### `0xFE` — Execute UserOp with `_data`

```text
[0xFE][walletId][fee:uint64][ keccak256(_data) ]
```

Memo length must be exactly 42 bytes. The XRPL `MemoData` field has a hard cap that often makes inline encoding (`0xFF`) impossible for non-trivial UserOps. `0xFE` commits in the memo only to the hash of an externally-supplied UserOp.

The executor passes the ABI-encoded `PackedUserOperation` in the `_data` argument of `handleMintedFAssets`. The library asserts `keccak256(_data) == _memoData[10:42]` and then decodes the UserOp from `_data`. From that point the validation and dispatch are identical to `0xFF`.

The cost is one off-chain coordination step: whoever assembles the UserOp must publish it to whoever calls `handleMintedFAssets`, since the memo alone doesn't carry the UserOp body. The benefit is no memo-size limit.

### `0xE0` — Ignore memo (the recovery path)

```text
[0xE0][walletId][fee:uint64][ targetTxId:bytes32 ]
```

Marks `targetTxId` as ignored for this PA. The next time `handleMintedFAssets` is called with `_transactionId == targetTxId`, the memo-validation step is skipped entirely — the flag is consumed, fAssets are distributed, no opcode dispatch happens. This is how a user un-sticks an XRPL Payment whose memo would otherwise revert.

The `0xE0` memo itself can be `notPaused`, has length 42, has valid executor fee bytes, and emits `IgnoreMemoSet(personalAccount, targetTxId)`.

### `0xE1` — Set nonce

```text
[0xE1][walletId][fee:uint64][ newNonce:uint256 ]
```

Sets `nonces[personalAccount] = newNonce`. Constraints:
- `newNonce > currentNonce` — must strictly increase.
- `newNonce - currentNonce <= type(uint32).max` — cap of 2³² - 1 per jump.

The cap exists so a single misconfigured XRPL Payment cannot brick the PA by jumping the nonce to near-`uint256.max`.

### `0xE2` — Replacement fee

```text
[0xE2][walletId][fee:uint64][ targetTxId:bytes32 ][ newFee:uint64 ]
```

Sets `replacementFee[personalAccount][targetTxId] = newFee + 1` (1-based so 0 stays "unset"). The next `handleMintedFAssets` for `(personalAccount, targetTxId)` uses `newFee` as the executor fee instead of whatever was in the original memo or the AssetManager default. The override is consumed (`delete state.replacementFee[...][...]`) on use.

This is the recovery path for an executor whose original fee was too low for it to be worth submitting.

### `0xD0` — Set PA executor

```text
[0xD0][walletId][fee:uint64][ executor:address ]
```

Sets `executor[personalAccount] = executor`. While set, only this address may submit `handleMintedFAssets` calls for the PA — see step 3 above. The executor check is bypassed for `0xD0` and `0xD1` themselves, so a user can always re-key or clear the pin even if the currently-pinned executor is offline.

`newExecutor` must be non-zero.

### `0xD1` — Remove PA executor

```text
[0xD1][walletId][fee:uint64]
```

Memo length must be exactly 10. Clears the pin so any executor can subsequently submit for this PA.

## Replay protection

`handleMintedFAssets` writes to `Instructions.State.usedTransactionIds` — the same set used by the proof flow ([Payment-reference instructions](./PaymentReferenceInstructions.md)). One XRPL transaction can never drive two on-chain instructions, regardless of which flow consumed it.

The nonce in `MemoInstructions.State.nonces` is **separate** and only advances when a UserOp opcode (`0xFF` / `0xFE`) succeeds. That keeps reverted UserOps retryable across distinct XRPL transactions until off-chain tooling cleans them up via `0xE0`.

## Events

`IMemoInstructionsFacet` declares:
- `DirectMintingExecuted(personalAccount, transactionId, sourceAddress, amount, executorFee, executor)` — every successful call to `handleMintedFAssets`, regardless of memo content.
- `UserOperationExecuted(personalAccount, nonce)` — on successful `0xFF` / `0xFE` execution.
- `IgnoreMemoSet`, `NonceIncreased`, `ReplacementFeeSet`, `ExecutorSet`, `ExecutorRemoved` — one per management opcode.

## View accessors

- `isTransactionIdUsed(transactionId)` — checks the shared `usedTransactionIds` set.
- `getNonce(personalAccount)` — current memo nonce.
- `getExecutor(personalAccount)` — current pinned executor (`address(0)` if not pinned).
