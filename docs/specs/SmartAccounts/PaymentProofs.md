# Payment proofs

The proof-based instruction flow trusts an FDC [`IPayment.Proof`](https://github.com/flare-foundation/flare-periphery-package) — a Merkle-proof that an XRPL Payment was finalized — as authorization to operate on the corresponding `PersonalAccount`. Verification is done in [`PaymentProofs`](../../../contracts/smartAccounts/library/PaymentProofs.sol), called from `InstructionsFacet.executeInstruction` and `InstructionsFacet.executeDepositAfterMinting`.

## What `verifyPayment` checks

[`PaymentProofs.verifyPayment(_proof, _xrplAddress)`](../../../contracts/smartAccounts/library/PaymentProofs.sol) walks every field that has to be correct for the instruction to be safe:

| Check | Reverts with | What it pins |
|-------|--------------|--------------|
| `_proof.data.sourceId == state.sourceId` | `InvalidSourceId` | The chain — XRPL mainnet vs. testnet vs. an unrelated chain. |
| `_proof.data.responseBody.status == 0` | `InvalidTransactionStatus` | The Payment was successful on XRPL, not failed/partial. |
| `block.timestamp <= validity + responseBody.blockTimestamp` | `PaymentProofExpired` | The XRPL block hasn't drifted past the configured validity window. |
| `responseBody.sourceAddressHash == keccak256(_xrplAddress)` | `MismatchingSourceAndXrplAddr` | The XRPL sender matches the address the user claims to own. |
| `xrplProviderWalletHashes[responseBody.receivingAddressHash] != 0` | `InvalidReceivingAddressHash` | The XRPL recipient was a protocol provider wallet, not an arbitrary address. |
| `IFdcVerification.verifyPayment(_proof)` | `InvalidTransactionProof` | The Merkle proof actually verifies against the FDC. |

The order is intentional — the FDC verification (the most expensive step) runs last, after all cheap checks have passed.

## Configuration

State lives at `smartAccounts.PaymentProofs.State`:

```solidity
struct State {
    bytes32 sourceId;
    uint256 paymentProofValidityDurationSeconds;
}
```

Both are set at diamond init via [`MasterAccountControllerInit`](../../../contracts/smartAccounts/facets/MasterAccountControllerInit.sol). `sourceId` is **immutable after init** — there's no setter on [`PaymentProofsFacet`](../../../contracts/smartAccounts/facets/PaymentProofsFacet.sol). Migrating to a different underlying chain would require a `diamondCut` that replaces the init contract.

`paymentProofValidityDurationSeconds` can be updated via `setPaymentProofValidityDuration` (timelocked, must be > 0). Read with `getPaymentProofValidityDurationSeconds`. Typical configuration: one day; tightening this is a defense against very stale proofs.

`sourceId` is read with `getSourceId()`. Live values:
- `bytes32("testXRP")` on coston/coston2 test deploys.
- `bytes32("XRP")` (or chain-specific equivalents) on production.

## XRPL provider wallets

[`XrplProviderWallets`](../../../contracts/smartAccounts/library/XrplProviderWallets.sol) holds the receiver allowlist as both a `string[]` and a `mapping(bytes32 hash => uint256 oneBasedIndex)`. The 1-based index lets `removeXrplProviderWallets` swap-and-pop in O(1) without ambiguous zero-equals-unset semantics.

Adding / removing wallets goes through [`XrplProviderWalletsFacet`](../../../contracts/smartAccounts/facets/XrplProviderWalletsFacet.sol):

- `addXrplProviderWallets(string[])` — `onlyOwnerWithTimelock`. Rejects empty strings and duplicates.
- `removeXrplProviderWallets(string[])` — `onlyOwnerWithTimelock`. Rejects unknown wallets.
- `getXrplProviderWallets()` — returns the full list (the string array, not the hash map).

The hash map is the only thing `verifyPayment` reads; the string list is for off-chain enumeration.

## Why the receiving-address allowlist exists

Without it, anyone could fund the protocol by sending XRP to an unrelated wallet and then submit a forged-but-FDC-valid proof to execute an instruction at no cost. Pinning the receiver to a known protocol wallet ensures the user actually paid the protocol (in particular, paid the instruction fee — see [Fees](./Fees.md)).

Provider wallets can be rotated by adding a new one, waiting for off-chain tooling to migrate, and then removing the old one. Both operations are timelocked.

## What `verifyPayment` does **not** check

- The XRPL `DestinationTag`. Proof-flow Payments don't use tags; the protocol parses the *payment reference* instead, which lives in the FDC-attested `standardPaymentReference` field.
- The XRPL `Amount`. The instruction-fee check (`receivedAmount >= getInstructionFee(instructionId)`) lives in `InstructionsFacet.executeInstruction`, not in `PaymentProofs`. `executeDepositAfterMinting` skips the fee check entirely because the collateral-reservation fee already paid covers it.
- Replay. The `usedTransactionIds` mark also lives in `InstructionsFacet`, not in `PaymentProofs`. The same proof can be presented twice and verify — only the first one will get past the replay check on the facet side.

The library exposes only `verifyPayment`. Storage mutation goes through `setSourceId` and `setPaymentProofValidityDuration`, both of which are gated by the facet (and `setSourceId` has no facet path — only the init contract calls it).
