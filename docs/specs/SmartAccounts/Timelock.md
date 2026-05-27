# Timelock

Every owner-driven state-changing operation on the diamond goes through a timelock. The pattern is the same one used by the composer's [`OwnableWithTimelock`](../../../contracts/utils/implementation/OwnableWithTimelock.sol) — record on first call, execute after a delay.

## Library and facet

[`Timelock`](../../../contracts/smartAccounts/library/Timelock.sol):

```solidity
struct State {
    bool executing;                                 // re-entry flag
    uint256 timelockDurationSeconds;
    mapping(bytes32 encodedCallHash => uint256 allowedAfterTimestamp) timelockedCalls;
}
```

[`TimelockFacet`](../../../contracts/smartAccounts/facets/TimelockFacet.sol):

| Function | Access | Effect |
|----------|--------|--------|
| `setTimelockDuration(uint256)` | `onlyOwnerWithTimelock` | Update the delay. Capped at `MAX_TIMELOCK_DURATION_SECONDS = 7 days`. |
| `executeTimelockedCall(bytes)` | open to anyone | Run a previously-recorded call if the delay has passed. |
| `cancelTimelockedCall(bytes)` | `onlyOwner` | Drop a recorded call without executing. |
| `getTimelockDurationSeconds()` | view | — |
| `getExecuteTimelockedCallTimestamp(bytes)` | view | Returns the timestamp at which a recorded call becomes executable. |

`MAX_TIMELOCK_DURATION_SECONDS = 7 days` is hard-coded.

## The `onlyOwnerWithTimelock` modifier

[`FacetBase`](../../../contracts/smartAccounts/facets/FacetBase.sol):

```solidity
modifier onlyOwnerWithTimelock {
    if (Timelock.timeToExecute()) {
        Timelock.beforeExecute();
        _;
    } else {
        Timelock.recordTimelockedCall(msg.data);
    }
}
```

`Timelock.timeToExecute()` returns true in two cases: the `executing` flag is set (we're inside an `executeTimelockedCall` re-entrance), or `timelockDurationSeconds == 0` (direct execution allowed).

`Timelock.beforeExecute()`:
- If `executing == true`: assert that `msg.sender == address(this)` (the diamond re-entering itself), then clear the flag and let the body run.
- Else (timelock is zero): require `LibDiamond.enforceIsContractOwner()` and let the body run.

`Timelock.recordTimelockedCall(_encodedCall)`:
- Require `LibDiamond.enforceIsContractOwner()`.
- Compute `encodedCallHash = keccak256(_encodedCall)`.
- Store `timelockedCalls[encodedCallHash] = block.timestamp + timelockDurationSeconds`.
- Emit `CallTimelocked(_encodedCall, encodedCallHash, allowedAt)`.

So the **same selector** behaves differently depending on the state:
- Default state, `timelockDurationSeconds > 0`: the owner's first call records the timelock; the *second* call (after the delay, via `executeTimelockedCall`) actually runs.
- `timelockDurationSeconds == 0`: the owner's call runs immediately. (This is the deploy-time state for fresh diamonds — operators can set everything up before raising the timelock.)
- Inside `executeTimelockedCall`: the diamond delegate-calls itself with the recorded calldata; `executing == true` makes the modifier let the body run.

## `executeTimelockedCall` mechanics

```solidity
function executeTimelockedCall(bytes calldata _encodedCall) external {
    Timelock.State storage state = Timelock.getState();
    bytes32 encodedCallHash = keccak256(_encodedCall);
    uint256 allowedAfterTimestamp = state.timelockedCalls[encodedCallHash];
    require(allowedAfterTimestamp != 0, TimelockInvalidSelector());
    require(block.timestamp >= allowedAfterTimestamp, TimelockNotAllowedYet());
    delete state.timelockedCalls[encodedCallHash];
    state.executing = true;
    (bool success,) = address(this).call(_encodedCall);
    state.executing = false;
    emit TimelockedCallExecuted(encodedCallHash);
    _passReturnOrRevert(success);
}
```

Three points worth noting:

1. **Anyone can call `executeTimelockedCall`.** Once the owner has recorded a call and the delay has passed, anyone can poke the diamond to actually execute it. This makes operational tooling simple and keeps governance from being held hostage to the owner key being online at any specific moment after the delay.
2. **The recorded entry is deleted before re-entry, but only persists deletion on success.** The `delete` runs at the top of `executeTimelockedCall`, before the inner `address(this).call(_encodedCall)`. If the inner call reverts, `_passReturnOrRevert(false)` re-reverts the outer call, rolling the deletion back. A recorded call therefore executes **exactly once on success** — a failed attempt leaves the recorded entry in place and the call remains retryable.
3. **Return data and reverts pass through verbatim.** `_passReturnOrRevert` does an inline-assembly `returndatacopy` + `return`/`revert`, so revert reasons (custom errors) from the timelocked call surface unchanged to the caller of `executeTimelockedCall`.

## `cancelTimelockedCall`

`onlyOwner` (no nesting in another timelock — cancellation must be instant to make sense). Deletes the recorded entry and emits `TimelockedCallCanceled(encodedCallHash)`. Reverts with `TimelockInvalidSelector` if no entry exists.

## What is timelocked

Every state-changing owner call **except** these two:

- `ExecutorsFacet.setExecutor(address)` — `onlyOwner`, no timelock. Rationale: rotating a compromised executor address must be fast.
- `TimelockFacet.cancelTimelockedCall(bytes)` — `onlyOwner`, no timelock. Rationale: cancellation has to outpace the original execution.

Everything else — diamond cuts, pause role management, vault registration, agent vault registration, instruction fee changes, payment-proof validity duration changes, PA implementation upgrades, executor *fee* changes, XRPL provider wallet rotation, the timelock duration itself — is `onlyOwnerWithTimelock`.

Pause and unpause are role-gated (not owner-gated) and explicitly **not** timelocked — see [Pause](./Pause.md).

## Setting the duration

`setTimelockDuration(_seconds)` is itself `onlyOwnerWithTimelock`. So:

- **First setting** from the deploy-time `0`: runs immediately (timeToExecute returns true because duration is currently 0).
- **Subsequent change** from a non-zero value: records, waits, re-executes through `executeTimelockedCall`.

The upper bound is `7 days`. Past that, `TimelockDurationTooLong()`.

## Bootstrapping

Init runs in a non-timelocked context (it is a `delegatecall` from the diamond constructor, not a regular external call). After init the diamond has `timelockDurationSeconds == 0` until the owner explicitly sets it. The cuts under [`deployment/cuts/`](../../../deployment/cuts/) raise the timelock as one of the post-deploy operations — see the deployment notes in `AGENTS.md`.

## Identity with the composer

The composer's [`OwnableWithTimelock`](../../../contracts/utils/implementation/OwnableWithTimelock.sol) is a feature-equivalent port of `Timelock` + `TimelockFacet`:

- Same `MAX_TIMELOCK_DURATION_SECONDS = 7 days`.
- Same `executing` re-entry flag.
- Same `keccak256(msg.data) → allowedAfter` storage shape.
- Same "anyone can call `executeTimelockedCall`" property.
- Same `_passReturnOrRevert` mechanic.

The differences are just the storage slot (`erc7201:utils.OwnableWithTimelock.State` vs. `erc7201:smartAccounts.Timelock.State`) and the access-control source (`Ownable`-based `_checkOwner` vs. `LibDiamond.enforceIsContractOwner`).
