# Fees

Three fee surfaces:

1. **Instruction fees** — minimum received-amount check on the proof flow, in fAsset units.
2. **Protocol executor fee** — wei the relayer forwards to the proof-flow executor.
3. **Direct-mint executor fee** — fAsset units deducted from the minted amount.

## Instruction fees

[`InstructionFees`](../../../contracts/smartAccounts/library/InstructionFees.sol) holds:

```solidity
struct State {
    uint256 defaultInstructionFee;
    mapping(uint256 instructionId => uint256 fee) instructionFees;  // 1-based!
}
```

The per-instruction-ID override is stored **1-based**: an entry of `0` means "no override, use default"; an entry of `1` means "override = 0" (free); an entry of `n+1` means "override = n". This lets the protocol explicitly waive a fee without colliding with the "unset" sentinel.

Lookup ([`getInstructionFee`](../../../contracts/smartAccounts/library/InstructionFees.sol)):

```solidity
function getInstructionFee(uint256 _instructionId) internal view returns (uint256) {
    uint256 fee = state.instructionFees[_instructionId];
    return fee > 0 ? fee - 1 : state.defaultInstructionFee;
}
```

[`InstructionFeesFacet`](../../../contracts/smartAccounts/facets/InstructionFeesFacet.sol) is the admin surface, all `onlyOwnerWithTimelock`:

- `setDefaultInstructionFee(fee)` — set the catch-all.
- `setInstructionFees(ids[], fees[])` — set per-instruction overrides. Stored as `fee + 1`.
- `removeInstructionFees(ids[])` — delete overrides. Reverts on entries that weren't set.

Views: `getDefaultInstructionFee()`, `getInstructionFee(instructionId)`.

### Enforcement

`InstructionsFacet.executeInstruction` reads the configured fee for the instruction ID, then asserts `receivedAmount >= fee`:

```solidity
uint256 instructionFee = InstructionFees.getInstructionFee(instructionId);
int256 receivedAmount = _proof.data.responseBody.receivedAmount;
require(
    receivedAmount >= 0 && uint256(receivedAmount) >= instructionFee,
    InvalidPaymentAmount(instructionFee)
);
```

`receivedAmount` is reported by the FDC payment proof and denominates the underlying-chain amount that actually landed on the receiving address (i.e., a protocol provider wallet). The fee is therefore consumed by the protocol; the user pays it as part of the XRPL Payment, not as a separate transaction.

`executeDepositAfterMinting` does **not** check the instruction fee — the collateral-reservation fee paid earlier covers protocol cost, and the AssetManager's direct-minting accounting already accounted for the executor's fAsset slice.

The unit is the underlying chain's smallest unit (drops for XRP), as documented on `IInstructionFeesFacet.getInstructionFee`.

## Protocol executor fee

Set together with the executor address — see [Executors](./Executors.md). Lives in [`Executors.State`](../../../contracts/smartAccounts/library/Executors.sol):

```solidity
struct State {
    address payable executor;
    uint256 executorFee;  // wei
}
```

Setters: `setExecutor` (`onlyOwner`, no timelock) and `setExecutorFee` (`onlyOwnerWithTimelock`). The split is intentional — the address may need to rotate quickly under operational pressure, but the fee level is an economic parameter.

Forwarded by the diamond into the AssetManager via `IAssetManager.reserveCollateral(..., executor, executorFee)` and `IAssetManager.redeem(..., executor)`. The wei comes from `msg.value` on `reserveCollateral` / `executeInstruction(redeem)`.

## Direct-mint executor fee

[`MemoInstructionsFacet._resolveExecutorFee`](../../../contracts/smartAccounts/facets/MemoInstructionsFacet.sol) chooses the fee in this order:

1. **`0xE2` override** — `MemoInstructions.getReplacementFee(personalAccount, transactionId) - 1` if set. Consumed on use (`delete`).
2. **Memo's own fee field** — bytes 2–10 of the memo as `uint64`, if a memo is present and not ignored.
3. **AssetManager default** — `getDirectMintingExecutorFeeUBA()` if no memo or the memo is ignored.

The fee is paid in fAsset units, transferred to the executor via `SafeERC20.safeTransfer` before the rest of the minted amount is forwarded to the Personal Account.

`require(_amount >= _executorFee, InsufficientAmountForFee(_amount, _executorFee))` runs before any transfer.

## Comparison

| | Instruction fee | Protocol executor fee | Direct-mint executor fee |
|---|---|---|---|
| Unit | Underlying-chain drops (fAsset units) | Wei (native FLR) | fAsset units |
| Paid by | XRPL Payment sender | Relayer (out of `msg.value`) | The minter (deducted from minted amount) |
| Paid to | Protocol (via provider wallet) | Default protocol executor | The submitter of `handleMintedFAssets` |
| Configured at | `InstructionFees.State` (default + per-id) | `Executors.State` | Memo (per-payment), `0xE2` override, or AssetManager default |
| Per-call override | `instructionFees[instructionId]` (1-based) | None | `0xE2` opcode (`replacementFee` map) |
| Governance change | `onlyOwnerWithTimelock` | Address: `onlyOwner`. Fee: `onlyOwnerWithTimelock`. | None — user-driven each Payment |

Mixing fees: a single XRPL Payment either takes the proof flow (paying the instruction fee) or the direct-mint flow (paying the executor fee). Never both for one Payment.
