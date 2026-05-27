# Pause

Smart Accounts has an emergency-stop mechanism with **two separate role sets** — pausers and unpausers — so the act of freezing the protocol can be granted without granting the ability to thaw it.

## State and library

[`Pause`](../../../contracts/smartAccounts/library/Pause.sol):

```solidity
struct State {
    bool paused;
    EnumerableSet.AddressSet pausers;
    EnumerableSet.AddressSet unpausers;
}
```

Stored at `smartAccounts.Pause.State`. The `EnumerableSet` lets the facet enumerate the role members; that information feeds operational tooling.

`Pause.checkNotPaused()` is the guard called by every `notPaused` modifier in the codebase.

## Facet

[`PauseFacet`](../../../contracts/smartAccounts/facets/PauseFacet.sol):

| Function | Access | Effect |
|----------|--------|--------|
| `pause()` | `isPauser(msg.sender)` | Sets `paused = true`. **No timelock.** |
| `unpause()` | `isUnpauser(msg.sender)` | Sets `paused = false`. **No timelock.** |
| `addPausers(address[])` | `onlyOwnerWithTimelock` | Add to the pauser set. |
| `removePausers(address[])` | `onlyOwnerWithTimelock` | Remove from the pauser set. |
| `addUnpausers(address[])` | `onlyOwnerWithTimelock` | Add to the unpauser set. |
| `removeUnpausers(address[])` | `onlyOwnerWithTimelock` | Remove from the unpauser set. |
| `isPaused()` | view | — |
| `isPauser(address)` | view | — |
| `isUnpauser(address)` | view | — |
| `getPausers()` | view | Returns the pauser set. |
| `getUnpausers()` | view | Returns the unpauser set. |

Role management is timelocked — adding or removing a pauser/unpauser is a governance decision. Pause itself is **not** timelocked: the whole point is to freeze instantly under incident pressure.

## Scope of `notPaused`

Both state-modifying instruction facets gate their entry points behind `notPaused`:

- [`InstructionsFacet`](../../../contracts/smartAccounts/facets/InstructionsFacet.sol): `reserveCollateral`, `executeDepositAfterMinting`, `executeInstruction`.
- [`MemoInstructionsFacet`](../../../contracts/smartAccounts/facets/MemoInstructionsFacet.sol): `handleMintedFAssets`.

When the diamond is paused, all four revert with `IsPaused()`.

Notably **not** behind `notPaused`:
- View functions on every facet.
- `executeUserOp` on `PersonalAccount` (it has no `notPaused` — the diamond couldn't invoke it anyway, since `MemoInstructions.execute` is gated by the facet's `notPaused`).
- Admin functions (timelock recording, ownership transfer, executor / pauser / vault / agent management). The owner can keep performing governance during a pause; that's how an incident is resolved.
- Pause / unpause themselves.

## Separate pauser and unpauser sets

The split is deliberate. Three implications:

1. A pauser that is **not** also an unpauser can stop a live incident but cannot resume operations on its own. That makes pause keys cheap to distribute — give them to monitoring services, junior responders, etc. — without inflating the keyset that can re-open the protocol.
2. An unpauser that is **not** also a pauser can resume operations after governance has reviewed the incident, but cannot itself trigger another pause out of band.
3. Adding the same address to both sets is allowed; the sets are independent.

If both sets are empty, the protocol is effectively un-pausable (no one can call `pause`) and un-resumable (no one can call `unpause`); the owner can recover by adding members via the timelocked `addPausers` / `addUnpausers`.

## Init

The init contract does **not** seed pausers or unpausers. They are added post-deploy via the timelocked admin path; live deployment artifacts under [`deployment/`](../../../deployment/) include the seeding cuts.
