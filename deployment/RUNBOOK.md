# Release runbook

The ordered, verified sequence for putting a release on chain. The specs under
[`docs/specs/`](../docs/specs/index.md) say what the contracts do; this says what to run, in what
order, and what proves each step landed.

Three rules govern the whole document. **Every step names its own verification, and a step is not
done until that check passes** — a successful transaction is not the check. **Every governance call
is named explicitly**, because the steps most often missed are the ones that are a governance call
rather than a script. And **a timelocked call is not done when it is submitted**; see the shared
procedure below.

## Record the release

Before anything, write down what is being deployed: the commit or tag, the reviewed cut file per
network, and who executes governance on each. Every verification below compares the chain against
*this* working tree, so a runbook execution that cannot name its commit cannot be reproduced or
audited afterwards.

**The subaccount creation-code constant belongs to this commit.** `Subaccounts.PROXY_CREATION_CODE`
was re-frozen onto the release build on 2026-09-09, so it is the byte-exact creation code of the
reviewed source. Do not re-freeze it again. Every subaccount address derives from it, and from the
first predicted address onward — published to a user or funded before the subaccount exists — a
change misdirects assets already sent to the old one. Later metadata-only drift in the proxy's
sources is expected and is not a reason to touch it: what that drift moves is only the
fresh-source comparison in `test/unit/smartAccounts/SubaccountsLibrary.t.sol`, which is deliberately
metadata-blind. The two fixtures that would catch an address moving — the frozen hash there and the
golden vectors in `PinnedInitCode.t.sol` — stay exact, and a diff in either is the signal to stop.

## Scope — every row resolved before execution

Implementation upgrades and loan activation are separate decisions and are listed separately. A
network may need the first without the second; a network that takes neither still diverges from the
others' proxy lineage, which is a thing to choose rather than discover. **An unresolved row blocks
execution** — leaving one open while drafting is fine, starting with one open is not.

| Network | Chain id | Controller | Counterpart chain | Implementation upgrades | Loan activation |
| --- | ---: | --- | --- | --- | --- |
| `ethereum` | 1 | new, bootstrapped | `flare` | remote Personal Account, remote loan subaccount | yes |
| `flare` | 14 | live | `ethereum` | home Personal Account, home loan subaccount | yes |
| `songbird` | 19 | live | — | **to resolve** | **to resolve** |
| `coston2` | 114 | live | **to resolve** | **to resolve** | **to resolve** |
| `coston2-staging` | 114 | live | **to resolve** | **to resolve** | **to resolve** |

> **Coston2 carries a known exception.** Seven Personal Accounts registered before the proxy
> creation code was frozen sit at addresses the current derivation does not reproduce, so their
> subaccounts and their own cross-chain messages resolve differently per chain. Settle that before
> resolving Coston2's rows. See the audit's SA-02.

## Shared procedure: a timelocked governance call

`diamondCut` and every `set*` below are `onlyOwnerWithTimelock`. With a non-zero duration the first
call **queues** rather than applies, and calling it again **reschedules** it, pushing the earliest
execution further out. So:

1. Submit the call as the owner. It emits `CallTimelocked` with the exact calldata, its hash and
   the earliest execution time. **Keep that calldata**; execution replays it byte for byte.
2. Read the deadline back: `getExecuteTimelockedCallTimestamp(encodedCall)`.
3. Wait. Do not re-submit — that only moves the deadline.
4. Execute `executeTimelockedCall(encodedCall)`. It is permissionless once matured.
5. Run the step's verification, which is what proves the state actually changed.

Two consequences worth stating. First, what `pnpm diamond_cut` does depends on the cut file's
`execute` flag, and the current cut files set it to `false`: it then only **prepares** the calldata
for governance to submit, and runs no verification, so verifying is a separate manual step after
governance executes. With `"execute": true` the script submits the cut itself and reads the diamond
back at once — and on a timelocked network that read-back sees the *unchanged* diamond, because the
submission only queued. That failure is correct, not a bug. Second, a zero duration applies
everything immediately: if a bootstrap deliberately runs at zero, write that down as a decision and
record when it stopped.

## Part A — an existing deployment

What each network needs and why is the spec's
[Deployment section](../docs/specs/SmartAccounts/LoanSubaccounts.md#deployment); this part is the
order to do it in and the evidence for each step.

### A0. Inventory queued governance before touching anything

List every outstanding timelocked call on the diamond, in particular any queued
`removeUnpausers`: that call is becoming immediate, and one queued under the old facet **cannot
execute after the cut**. Note them now; A3 clears them.

### A1. Safety checks, before anything is executed

These gate the **upgrade**, not the routes, and they apply to every network in scope — including one
that receives implementation upgrades but no loan activation, which is exactly the case that skips
them if they only appear under the new-chain part.

```bash
pnpm build:upgrade-info && pnpm validate-upgrade
pnpm check_lineage_fresh <network> [subaccounts|personal-accounts]   # where a layout is laid first
```

`check_lineage_fresh` is decisive on chain only through the beacon or the registration event
history, which needs an endpoint serving full-range logs. Otherwise it answers from the retained git
history of the deployment record and cut files, on the stated assumption that every installation was
committed under its canonical facet name before execution and remains reachable from this clone's
refs. It fails closed on anything unproven — read its output for *which* of those two it used.

**And the predecessor rehearsal must already be recorded** (Part C, item 1). It gates the upgrade
because that is what it tests: registration verification proves the code, the registry and one
account's identity, and none of that shows an upgrade preserves live state. Discovering otherwise
after execution means a governance-delayed rollback.

### A2. The facet cut

```bash
pnpm check_cut <network> <cut-file>       # review the plan: ADD / REPLACE / REUSE / REMOVE
pnpm diamond_cut <network> <cut-file>     # prepares or submits, per `execute`; see above
pnpm verify_diamond <network> <cut-file> --expect-owner <approved owner>
```

Moved selectors are repointed by including the new facet, never by listing them for deletion.

Pass `--expect-owner` explicitly. Its default is the chain config's `governance`, which is the zero
address on `coston2-staging` and therefore checks nothing, and on Ethereum the default is the pinned
historical owner, which stops being correct the moment ownership is transferred.

### A3. The unpauser migration, immediately after the cut

`removeUnpausers` is now immediate rather than timelocked. Using the A0 inventory: remove the
intended unpausers directly, cancel the obsolete queued removals — cancellation still works after
the cut — and verify both the resulting role set and that nothing stale remains queued. See
[Pause](../docs/specs/SmartAccounts/Pause.md).

### A4. The home Personal Account implementation

The step most often missed, because it is not part of the cut. Replacing `PersonalAccountsFacet`
does **not** change the code behind existing Personal Account proxies: the beacon keeps serving the
implementation recorded by `PersonalAccounts`, and only `setPersonalAccountImplementation` moves it.
A release that adds account functionality — this one adds `sendCrossChainUserOp` and
`redeemFromSubaccount` — does nothing for existing users until this lands.

```bash
pnpm deploy_personal_account_implementation <network>
pnpm verify_implementation <network> PersonalAccount <address> --stage pre
```

`--stage pre` prints the exact calldata to queue and requires a non-zero timelock duration, since a
zero delay would register immediately instead of queueing.

**Governance call: `setPersonalAccountImplementation(address)`.** Follow the timelocked procedure,
with `--stage queued` after submitting and, after execution:

```bash
pnpm verify_implementation <network> PersonalAccount <address> --stage live --xrpl-owner <owner>
```

Use an owner that exists on that network: the flag reads a materialized account back, including the
ERC-1967 beacon slot. Then freeze the lineage — see A6.

### A5. The home loan subaccount implementation

Only where loan activation is in scope.

```bash
pnpm deploy_loan_subaccount_implementation <network>
pnpm verify_implementation <network> LoanSubaccount <address> --stage pre
```

**Governance call: `setSubaccountImplementation(1, address)`** (`1` is the loan type). Timelocked
procedure, then `--stage live`. Then freeze the lineage — see A6.

### A6. Freeze the reference for every lineage that just went live

Any implementation deployed above is now the reference every future upgrade is validated against,
and the window closes with the deployment because CI artifacts expire. For **each** newly live
lineage — the home Personal Account and the home loan subaccount included, not only the remote ones
— copy that build's `artifacts-upgrades/build-info` into a tracked `deployment/build-info-<version>/`
and add it to `validate-upgrade` with `--referenceBuildInfoDirs` and
`--reference <dirname>:<Contract> --requireReference`. Until that is done the validator runs the
weaker checks that need no reference, and a later layout change would pass unnoticed.

### A7. Governance state, read back

Owner, pausers, unpausers and the timelock duration — set as intended and read back.

## Part B — a new chain, from nothing

### B1. Prove control of the bootstrap owner, then bootstrap

The bootstrap is permissionless, but the first cut must come from the pinned historical owner.
**Reading that address proves nothing about who holds its key**: obtain signing evidence from the
holder before deploying anything, because a controller nobody can cut is a dead deployment at a
frozen address.

```bash
pnpm deploy_ethereum_controller
pnpm verify_diamond ethereum --pre-cut
```

`--pre-cut` requires the pinned owner, exactly the three pinned base facets, and no ERC-165 flag.

### B2. Now the safety and plan checks

The same checks as A1, plus the cut plan. They run **after** B1 here, not before: they need a
deployed controller and a deployment record, and on Ethereum the recorded base facets.

```bash
pnpm build:upgrade-info && pnpm validate-upgrade
pnpm check_lineage_fresh <network> [subaccounts|personal-accounts]
pnpm check_cut <network> <cut-file>
```

### B3. The cut, with its init in one transaction

`EthereumControllerInit.init()` sets the four ERC-165 flags and nothing else. Verify after with
`pnpm verify_diamond ethereum <cut> --expect-owner <owner>`.

### B4. Governance configuration, then the ownership transfer

In this order: set pausers, unpausers and a non-zero timelock duration **while the bootstrap owner
still holds the diamond**, then transfer ownership to the intended governance, then re-verify with
`--expect-owner` naming the new owner. The init establishes none of these. Transferring first means
every remaining configuration call has to go through the new owner, which is slower and easy to get
half-done.

Read the configuration itself back, not only the owner — `verify_diamond` checks ownership and the
diamond's surface and says nothing about roles or delay. Compare `getPausers()`, `getUnpausers()`
and `getTimelockDurationSeconds()` against the approved configuration, as sets and as a number,
before proceeding. A diamond with the right owner and no pauser is not configured.

### B5. Remote implementations

`pnpm deploy_remote_account_implementations ethereum`, then register `PersonalAccountRemote` and
type-1 `LoanSubaccountRemote` through the same three-stage verification and timelocked procedure as
A4 and A5, then freeze both lineages exactly as A6 describes.

### B6. Transport and market

`setComposeTransport`, then `registerLoanMarket`, then `setLoanFeeTerms` — the first fee-terms call
is the activation, and borrowing reverts until it lands, so the market is registered but inert
across the gap. Read back the transport, the market id and parameters, the token and oracle
addresses, the rate model, the liquidation ratio, the fee recipient and rates, and the borrowing
status.

## Part C — the release-readiness gate

**Item 1 gates the upgrade itself (A1); items 2 to 4 gate the routes. Nothing opens until all four
are recorded, with results, against the release commit.** Each answers a question no post-hoc smoke
test can answer, because by then the change is already live.

Note where they can run. The bootstrap refuses any chain id but Ethereum's, and the remote
implementation deployment refuses the Flare-family chain ids, so the pinned bootstrap sequence
cannot be rehearsed on an ordinary public testnet at all — rehearse it against a **mainnet fork**.
The live transport rehearsal needs real endpoints and a real OFT, so it needs its own stated network
plan (which testnets, which endpoint deployment, which peer) rather than being assumed to fit
alongside the rest.

1. **Upgrade rehearsal against the actual predecessor bytecode** — not a fresh deployment. Fork the
   network, upgrade the live implementation, and exercise existing accounts: short and long XRPL
   owner strings, native and token balances, standing allowances, existing vault behavior, and both
   newly added selectors through a proxy that predates them. Registration verification proves the
   code, the registry and one account's identity; it does not prove an upgrade preserves live state.
2. **Canonical endpoint and OFT rehearsal** — the wire hop against the real contracts, not the
   mocked rail.
3. **Measured delivery-option presets** — the gas and value figures clients will sign, measured
   rather than estimated.
4. **Full activation rehearsal** — the whole of Parts A, B and D, by the operators who will run
   it, from this document, split across the environments named above: the pinned bootstrap on a
   mainnet fork, the rest on the networks the transport plan names.

Record where each result lives. A gate whose evidence cannot be found later was not a gate.

## Part D — opening the routes

Last, and only once Part C is recorded.

```
setFxrpOft(oft)                    # validated against the token, its decimals and oftVersion
setBridgeRoute(eid, peer)          # one pinned peer per remote chain
setSubaccountTypeRoute(type, eid)  # WRITE-ONCE: the type's chain identity
```

Each is timelocked and read back before the next. The opening point is `setBridgeRoute`, not the
type pin: it already enables the generic Personal Account cross-chain operations.

## Part E — after activation, on every network touched

Rerun the diamond, registration and activation checks; run the rehearsed bounded smoke flow (a round
trip and a repayment); confirm the operator sees the same operation ids, GUIDs, balances and fee
state. Expand availability only per the reviewed plan.
