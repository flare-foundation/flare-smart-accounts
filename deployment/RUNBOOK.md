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
was re-frozen onto the release build on 2026-09-09, so it is the creation code of the reviewed
source as that build compiled it: byte for byte wherever every input matches, and in its functional
prefix given the same compiler and code-generation settings over the same resolved dependencies.
The CBOR trailer holds the compiler version and a hash of the metadata JSON, which carries the
source unit names and hashes, the settings and the remappings — so another machine can compile this
same source to another trailer. Do not re-freeze the constant. Every subaccount address derives from
it, and from the first predicted address onward — published to a user or funded before the
subaccount exists — a change misdirects assets already sent to the old one.

Running the check, and what each outcome means. Run the comparisons in
`test/unit/smartAccounts/SubaccountsLibrary.t.sol` under the normal build profile, not the
upgrade-validation one. If the frozen hash there and the golden vectors in `PinnedInitCode.t.sol`
pass while only the trailer differs from a fresh compilation, that is the tolerated metadata drift:
record it and carry on, since the constant and every address derived from it are unchanged. If the
length or the metadata-blind functional comparison fails, stop and reconcile the build inputs —
compiler, dependencies, settings — and if they are already identical, the proxy's source itself has
moved, which is a release decision rather than an execution one. If the frozen hash or a golden
vector differs, stop outright: that is the constant changing, and with it every predicted address.
In none of these cases is the answer to update the constant or a fixture to make a test pass.

## Scope — every row resolved before execution

Implementation upgrades and loan activation are separate decisions and are listed separately. A
network may need the first without the second; a network that takes neither still diverges from the
others' proxy lineage, which is a thing to choose rather than discover. **An unresolved row blocks
execution** — leaving one open while drafting is fine, starting with one open is not.

| Network | Chain id | Controller | Counterpart chain | Implementation upgrades | Loan activation |
| --- | ---: | --- | --- | --- | --- |
| `ethereum` | 1 | new, bootstrapped | `flare` | remote Personal Account, remote loan subaccount | yes |
| `flare` | 14 | live | `ethereum` | home Personal Account, home loan subaccount | yes |
| `songbird` | 19 | live | — | no | no |
| `coston2` | 114 | live | `sepolia` | home Personal Account, home loan subaccount | yes |
| `coston2-staging` | 114 | live | — | no | no |
| `sepolia` | 11155111 | new, bootstrapped | `coston2` | remote Personal Account, remote loan subaccount | yes |

Resolved 2026-09-11. Songbird takes neither, so its Personal Account lineage stays on the
implementation it has: that is the divergence this table warns about, taken deliberately rather than
discovered. Coston2 takes the whole release against its live controller, and Sepolia is the loan
chain opposite it, bootstrapped and activated exactly as Ethereum will be — so the flow is rehearsed
end to end on a pair that reproduces the production controller at both ends. `coston2-staging` is
dormant and takes nothing.

> **Coston2 carries a known exception, and it is settled — see step A2.** Seven Personal
> Accounts registered before the proxy creation code was frozen sit at addresses the current
> derivation does not reproduce, so their subaccounts and their own cross-chain messages resolve
> differently per chain. They are migrated as part of the Coston2 deployment, not before it.

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
execute after the cut**. Note them now; A3 clears them. The queue is a mapping keyed by calldata
hash and cannot be enumerated on chain, so this is a `CallTimelocked` log scan.

**Answered for Coston2 on 2026-09-12: nothing is queued, and nothing will be queued before the
cut.** A3 is therefore a no-op there and the release is six governance calls. Re-confirm on the day
if anything has been submitted since; the question stands unanswered for every other network.

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

Pass `--expect-owner` when you know who should hold it. The default is the chain config's
`governance`, which is the zero address on `coston2-staging` and therefore checks nothing. On a loan
chain the default follows the stage: `--pre-cut` expects the pinned historical owner, since the
bootstrap's diamond is still his, and every later run expects that network's configured governance,
because B3 hands it over before the cut - falling back to the pin where no config names one, which is
Ethereum today, so there a post-cut run without the flag cannot prove the handover happened. A
`governance` that is present but not an address stops the run rather than being read as "nothing to
expect".

**Coston2 only — the seven pre-freeze registrations.** Decided 2026-09-09: the seven accounts
registered before the proxy creation code was frozen are cleared here, in this cut, by a
separately reviewed migration initializer for exactly those owners — never a public method, since
a permissionless reset lets anyone trigger it before an owner is ready.

1. **Settle everything tied to the legacy addresses first**, not just their balances. They hold
   FXRP (about 10 each). Also check for an outstanding collateral reservation, because a mint
   completed after the migration names the legacy address as its minter while the deposit resolves
   the canonical one, and that mint can then never be deposited; and for redemption or vault
   claims and any instruction still in flight. Confirm the inventory is empty before continuing.
2. **Execute the cut** with the initializer.
3. **Read back** that each of the seven owners resolves to its canonical address, and that
   creating one materializes there.

Clearing a registration stops the ordinary route: instructions keyed by the XRPL owner resolve the
canonical account from then on. The legacy proxy still trusts the controller, so anything left
behind is recoverable only by a separate governance action — which is the work step 1 avoids.

### A3. The unpauser migration, immediately after the cut

**Skip where the A0 inventory came back empty and no unpauser is to be removed — which is Coston2's
case for this release.** Nothing here is owed by the cut itself: the step exists because the change
of guard strands calls queued under the old one, so with nothing queued there is nothing to strand.

Where it does apply: `removeUnpausers` is now immediate rather than timelocked. Using the A0
inventory, remove the intended unpausers directly, cancel the obsolete queued removals —
cancellation still works after the cut — and verify both the resulting role set and that nothing
stale remains queued. See [Pause](../docs/specs/SmartAccounts/Pause.md).

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

### A6. Freeze the reference for every lineage whose layout just changed

Any implementation deployed above is now the layout every future upgrade must preserve. For each
lineage that is newly live **or whose layout changed in this deployment**, copy that build's
`artifacts-upgrades/build-info` into a tracked `deployment/build-info-<name>/` and point
`validate-upgrade` at it with `--referenceBuildInfoDirs` and
`--reference <dirname>:<Contract> --requireReference`.

**Not only the first deployment.** A reference protects the layout it HOLDS, not the one a chain is
running: once a deployment appends a field, a later implementation can delete that field and still
pass, because against the original both the append and its removal are appends. Measured, with the
table, in [`reference-builds.md`](./reference-builds.md). So freezing is part of shipping an
implementation whose layout moved, and the validator must point at the newest reference. Until it
does, the window between the last freeze and the live layout is unprotected.

Record the new directory in `reference-builds.md`: the source commit, the exact build, the compiled
runtime hashes and the addresses they match. Storage compatibility says nothing about WHICH
compilation a chain runs, and that record is what does.

### A7. Governance state, read back

Owner, pausers, unpausers and the timelock duration — set as intended and read back.

## Part B — a new chain, from nothing

Part B runs on a loan chain: Ethereum, or Sepolia, where the same singleton factory and the same
pinned init code reproduce the production controller at the same address — which is what makes
Sepolia the network this part is rehearsed on. Every command below takes the network name; the
tooling refuses any other chain.

**Two modes, and the address decides which.** A CREATE2 address is the factory, the salt and the
init code; the salt is zero everywhere here, so the init code is what decides. It carries the
compiled controller, the three base facets' addresses with their selector lists, and the owner — so
reproducing the production address needs **every one of those** to match, not the owner alone. That
is what the pinned bootstrap is for: it deploys historical bytes rather than rebuilding them, which
is why current source deliberately cannot reproduce the address and the generic script must not be
pointed at a loan chain (it refuses: Flare family only). Within one build the owner is the input
that moves, and moving it is what separates the two modes. Everything below is the **pinned** mode;
the other is named here so nobody reaches for the wrong one.

| | pinned (production) | throwaway (staging, testing) |
| --- | --- | --- |
| initial owner | the historical EOA, in the pinned init code | the deployer |
| the rest of the init code | historical bytes, deployed as they were | current source, rebuilt |
| controller address | the production one, on every chain | another one, deliberately |
| who broadcasts | any funded key; CREATE2 ignores the sender | the deployer, who must be the owner |
| the cut | the multisig, after the transfer | the deploy run itself |
| the configuration | `configure_remote_controller`: prepared, multisig submits | the same, `execute` |
| ownership transfer | one transaction from the initial owner | none: the deployer keeps it, or hands it on by hand |
| what it rehearses | the real thing, ceremony included | everything but the bootstrap and that |
| the script | `deploy_remote_controller_pinned` | `deploy_remote_controller_throwaway` (sepolia only) |

This is the sequence Coston2 followed in January: base facets deployed from an ordinary key with
the historical owner passed in, that owner transferring to the multisig in a separate transaction,
and every cut and setting arriving from the multisig afterwards. Its staging controller is the other
mode and sits at another address, still owned by the key that deployed it. On the loan chain the
throwaway script deploys the controller, cuts its facet set and registers both implementations in
one run, leaving the roles, the duration and the wiring to `configure_remote_controller`'s `execute`
phase; it refuses Ethereum, where a throwaway would sit beside real money for nothing. Its addresses
go to the gitignored `<network>_mock` record, so no tool resolves a real deployment through them.
Both sides must run the SAME build or their controllers land at different addresses:
`controllerAddress(owner)` on the script derives it without deploying, which is the cheap way to
check that before anything is sent.

### B1. Prove control of the bootstrap owner, then bootstrap

The bootstrap is permissionless, but the diamond it produces is owned by the pinned historical
owner, and only that key can hand it on. **Reading the address proves nothing about who holds its
key**: obtain signing evidence from the holder before deploying anything, because a controller
nobody can transfer is a dead deployment at a frozen address, with no way to cut a facet into it.

```bash
pnpm deploy_remote_controller_pinned <network>   # ethereum, or sepolia for the rehearsal
pnpm verify_diamond <network> --pre-cut
```

`--pre-cut` requires the pinned owner — the bootstrap's own initial owner, the default the verifier
expects on a loan chain — exactly the three pinned base facets, and no ERC-165 flag.

### B2. Now the safety and plan checks

The same checks as A1, plus the cut plan. They run **after** B1 here, not before: they need a
deployed controller and a deployment record, and on a loan chain the recorded base facets.

```bash
pnpm build:upgrade-info && pnpm validate-upgrade
pnpm check_lineage_fresh <network> [subaccounts|personal-accounts]
pnpm check_cut <network> <cut-file>
```

### B3. The ownership transfer

The bootstrap's owner is the historical EOA, which is on hardware: it signs **one** transaction
here, `transferOwnership` to the intended governance, and nothing else. That is the plain EIP-2535
ownership facet — an owner check and no timelock — and it is available the moment B1 lands, since
the three pinned base facets include it. Re-verify with
`pnpm verify_diamond <network> --pre-cut --expect-owner <new owner>`: the diamond is still in its
pre-cut shape, and the pre-cut default expects the pinned owner it no longer has, so the new owner is
named explicitly here.

A handover made from a **key** rather than a wallet - the deployer-owned rehearsal variant, where
the diamond is handed to governance at the end instead of the start - is
`pnpm transfer_ownership <network> <expected-current-owner> <new-owner>`, which compares the owner
against the one named before it sends and reads it back afterwards. The bootstrap owner's transfer
here is not that case: it is signed from a wallet, which no wrapper can drive.

Everything owner-gated therefore comes **after** this step, not before it: the diamond arrives owned
by that EOA, so a cut or a role change made first would need it to sign each one. In the throwaway
mode the order is the opposite, because there the deployer owns the diamond from the start: its deploy
cuts the facets in the same run, and its configuration follows as a second command it can sign for.

### B4. The cut, from the new owner

`EthereumControllerInit.init()` sets the four ERC-165 flags and nothing else, in the same
transaction as the cut. Verify after with
`pnpm verify_diamond <network> <cut> --expect-owner <owner>`, naming the new owner.

Nothing else is configured here, and the timelock duration is still zero — deliberately. It is set
once, near the end (B7), after every setting the deployment needs is in place. While it is zero,
every owner call applies in the transaction that submits it, so the whole configuration below is
one signature per call: no queue, no deadline, no second transaction, and no chance of the trap
where re-submitting a queued call only pushes its deadline further out. What it costs is that a
zero-delay window exists at all — the owner can change anything instantly until B7 closes it —
which is why B7 is not optional and why reading the duration back is the gate rather than a
formality.

`prepare` sends nothing and takes no key: it writes the calls under
`deployment/output-internal/<network>/` and prints them, which is what a multisig owner needs. The
throwaway mode names its own controller and signs for it, so there the whole of B4 to B7 is:

```bash
pnpm configure_remote_controller sepolia execute all throwaway
```

which sends every section in one run, the duration last of all, and then verifies against mined
state. Leave the target off and the run configures the PINNED controller, which on a rehearsal chain
is a different deployment entirely. That sweep's own order is the one B5 to B7 follow — the roles
and the wiring first, the duration last of everything — so the pinned flow differs only in being
split across commands a multisig can submit one at a time.

### B5. Remote implementations

```bash
pnpm deploy_remote_account_implementations <network> all
pnpm verify_implementation <network> PersonalAccountRemote <address> --stage pre
pnpm verify_implementation <network> MorphoLoanSubaccountRemote <address> --stage pre
pnpm configure_remote_controller <network> prepare implementations   # execute, where the deployer owns it
pnpm configure_remote_controller <network> verify implementations
```

The selection is mandatory: `all`, or a comma-separated list of `personal-account` and
`morpho-loan-subaccount`. A first deployment wants `all`; a later change to one of them wants that
one named, because redeploying the other would move a record this tooling resolves through and cost
a timelocked re-registration for nothing. Naming one does not force a deploy either way - a
preflight compares each named implementation against the address already recorded and SKIPS one
that already carries this code, so `all` can legitimately deploy one and reuse the rest, and a run
that deploys nothing is a success that leaves the record untouched.

Then freeze both lineages exactly as A6 describes. The section reads both addresses out of the
target's deployment record, so there is nothing to fill in and nothing to encode by hand; a record
that names neither - a run before the deploy above - leaves it unready rather than registering
something. It also SKIPS a registration the diamond has already made, so a rerun after a deploy that
reused an unchanged implementation emits only what is actually still due - a registration nobody
needs is still a timelocked call, three signatures and an execution.

Unlike A4 and A5, there is no queued stage to verify here: the registrations are
`onlyOwnerWithTimelock` like everything else, so at zero delay each applies in the transaction that
submits it.

Still run `--stage pre` **before** registering, and accept exactly one failed check,
`timelock: the duration is non-zero` — the tool stating what this part has already decided, that the
call is not a queue step. Its other checks are the reviewed artifact's bytecode at the address, that
source still being in the repository, and the chain family, and they are the only ones that can stop
a wrong implementation from being registered at all. `--stage live` afterwards proves what was
registered, which detects a wrong one rather than preventing it. Run both.

### B6. Transport and market

On Sepolia the market is ours to make before it can be registered — on Ethereum it is the live
FXRP/RLUSD market and this paragraph does not apply. `pnpm deploy_sepolia_market assets`, then
`market`, then `fund`, each re-runnable: a rerun deploys, creates or supplies only what is missing,
judged by the deployment record, the market id and the supplier's own position, and never touches
the feeds — `reset-feeds` is the one phase that does, explicitly. Record from the run: the oracle's
address, its registration with Morpho's factory (`isMorphoChainlinkOracleV2`), its code hash and its
explorer status (its source is Morpho's and not this repository's, so it is not ours to verify), and
the market's id and parameters from `deployment/output-internal/sepolia/market.json`. Those last two
are what the chain config's `loanMarket` section is filled in from.

Then the same tool as B4, and the same chain config, with the three wiring sections:

```bash
pnpm configure_remote_controller <network> prepare wiring
pnpm configure_remote_controller <network> verify wiring
```

`setComposeTransport`, then `registerLoanMarket`, then `setLoanFeeTerms` — the order is not a
preference and the tool does not offer another: the market's registration validates its collateral
token against the transport's OFT, and `setLoanFeeTerms` reverts unless the market for that type is
already registered. All three still apply in the transaction that submits them, since the duration
is set after them, in B7.

The fee terms are the activation. `registerLoanMarket` leaves borrowing blocked on purpose, so the
market can be registered, read back and inspected while nothing can borrow against it; the first
fee-terms call opens the type, and its recipient is a marker that can never return to zero. So it
is the last setting of the deployment, and the one to arrive at deliberately.

`wiring` prepares all three at once and **skips**, with a note, any section the config has not been
given yet — which is how a transport is prepared while the market's loan token and oracle are still
to be deployed. Read what it printed: a skipped section here is one that will have to be set after
the duration is in force, and will queue. A section asked for **by name** and not filled in stops
the run instead, which is the safer form once the config is complete.

Read back the transport, the market id and parameters, the token and oracle addresses, the rate
model, the liquidation ratio, the fee recipient and rates, and the borrowing status. The `verify`
phase covers everything the chain config names; the borrowing status and the market id are read by
hand.

### B7. The roles and the duration, last of all

```bash
pnpm configure_remote_controller <network> prepare governance   # the calls, for the owner to submit
pnpm configure_remote_controller <network> verify governance    # after they land
```

The order it emits is pausers, unpausers, and the timelock duration **last**. The init established
none of them. Within this run the roles still apply immediately, because the duration is the final
call in it; from the moment it lands, every **timelocked** call queues — adding a pauser or an
unpauser included. The one exception is `removeUnpausers`, which this release makes immediate
(`onlyOwner`); pauser removal stays timelocked like the rest. From here `prepare` prints an
`EXECUTE` line beside each call: the `executeTimelockedCall` that lands it after the delay,
permissionless once matured, so whoever submits a call need not be the one to send it.

Everything before this point applied in the transaction that submitted it, which is the whole
reason the duration is last: the deployment is one signature per call, with no queue, no deadline
and no second transaction, and the timelock takes effect over a diamond that is already configured
and read back rather than over one still being assembled.

The failure this order makes possible is forgetting it — a live deployment left at zero delay.
`verify governance` compares the duration to the second and both role lists as sets, so run it as
the closing gate rather than a formality. And read the configuration back, not only the owner:
`verify_diamond` checks ownership and the diamond's surface and says nothing about roles, delay,
transport, market or fees. A diamond with the right owner and no duration is not configured.

## Part C — the release-readiness gate

**Item 1 gates the upgrade itself (A1); items 2 to 4 gate the routes. Nothing opens until all four
are recorded, with results, against the release commit.** Each answers a question no post-hoc smoke
test can answer, because by then the change is already live.

Note where they can run. The pinned bootstrap and the remote implementation deployment run on the
loan chains only — Ethereum, and Sepolia, where the same factory and pinned init code reproduce the
production controller at the same address — so Part B is rehearsed end to end on the
Coston2 ↔ Sepolia run. Ethereum itself is rehearsed against a **mainnet fork**, under the
real network name (anvil keeps the forked chain's id; there is no local-development network) and in
a disposable worktree: the run writes the network's tracked record, and a rehearsal's addresses left
in the release workspace would misdirect every later check.
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
