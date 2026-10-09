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
| `removeUnpausers(address[])` | `onlyOwner` | Remove from the unpauser set. **No timelock** — see below. |
| `isPaused()` | view | — |
| `isPauser(address)` | view | — |
| `isUnpauser(address)` | view | — |
| `getPausers()` | view | Returns the pauser set. |
| `getUnpausers()` | view | Returns the unpauser set. |

Role management is timelocked — adding a pauser or an unpauser, or removing a pauser, is a governance decision. Removing an unpauser is the one immediate role change: it can only keep the system paused, and delaying it would leave a compromised unpauser able to undo every pause for the whole timelock window. Pause itself is **not** timelocked: the whole point is to freeze instantly under incident pressure.

## Scope of `notPaused`

Both state-modifying instruction facets gate their entry points behind `notPaused`:

- [`InstructionsFacet`](../../../contracts/smartAccounts/facets/InstructionsFacet.sol): `reserveCollateral`, `executeDepositAfterMinting`, `executeInstruction`.
- [`MemoInstructionsFacet`](../../../contracts/smartAccounts/facets/MemoInstructionsFacet.sol): `handleMintedFAssets`.

When the diamond is paused, all four revert with `IsPaused()`.

Notably **not** behind `notPaused`:
- View functions on every facet.
- `createPersonalAccount` and `createSubaccount`. Both proxies' creation code is public and the EIP-2470 singleton factory permissionless, so a gate would withhold the diamond's record and not the deployment — and a frozen derivation commits each account to its owner and this controller, so there is no authority to withhold. What a gate did cost was usability during an incident: the ungated `sweepRedeem` redeems through a parent Personal Account, and with the creation routes shut the only way to materialize one was to build the proxy's init code by hand and call the factory directly.

**A pause does not stop accounts from being created.** Both proxies are deployable through the singleton factory at their deterministic addresses whether or not the diamond is paused, and a Personal Account deployed that way serves `redeemFromSubaccount` without ever being registered, because the subaccount check resolves through `getSubaccount`, a view with a computed-address fallback. An incident response must therefore not rely on the pause to prevent new accounts appearing; what the pause stops is the instruction routes that move assets.
- `executeUserOp` on `PersonalAccount` (it has no `notPaused` — the diamond couldn't invoke it anyway, since `MemoInstructions.execute` is gated by the facet's `notPaused`).
- Admin functions (timelock recording, ownership transfer, executor / pauser / vault / agent management). The owner can keep performing governance during a pause; that's how an incident is resolved.
- Pause / unpause themselves.

## Separate pauser and unpauser sets

The split is deliberate. Three implications:

1. A pauser that is **not** also an unpauser can stop a live incident but cannot resume operations on its own. That makes pause keys cheap to distribute — give them to monitoring services, junior responders, etc. — without inflating the keyset that can re-open the protocol.
2. An unpauser that is **not** also a pauser can resume operations after governance has reviewed the incident, but cannot itself trigger another pause out of band.
3. Adding the same address to both sets is allowed; the sets are independent.

If both sets are empty, the protocol is effectively un-pausable (no one can call `pause`) and un-resumable (no one can call `unpause`); the owner can recover by adding members via the timelocked `addPausers` / `addUnpausers`.

## Upgrading to the immediate unpauser removal

`removeUnpausers` used to be `onlyOwnerWithTimelock`. A removal queued under that facet cannot execute once the immediate facet replaces it: `executeTimelockedCall` self-calls the diamond, and `onlyOwner` sees the diamond — not the owner — as the caller, so the attempt reverts with `NotContractOwner` and leaves both the queue entry and the role in place. The cut runbook therefore has one extra step: inventory queued `removeUnpausers` calls before the cut, and after it have the owner remove each address directly and cancel the obsolete entry with `cancelTimelockedCall`. Pinned by [`QueuedPauseMigration.t.sol`](../../../test/adversarial/QueuedPauseMigration.t.sol).

## Init

The init contract does **not** seed pausers or unpausers. They are added post-deploy via the timelocked admin path; live deployment artifacts under [`deployment/`](../../../deployment/) include the seeding cuts.
