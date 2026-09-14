# Deployment tooling

What the deployment tooling does and how its pieces fit: the records the deploy scripts write, the
cut planner, the diamond verifier, the implementation registration check and the upgrade-safety
validator over the proxy layouts. The ordered release sequence — which governance call to make when,
and what proves each step landed — is [`RUNBOOK.md`](./RUNBOOK.md); the commands themselves, and the
checks to run after a change, are listed in [`AGENTS.md`](../AGENTS.md). The specs under
[`docs/specs/`](../docs/specs/index.md) say what the contracts do.

## Networks

Every tool takes the network by name and holds the chain the RPC actually serves to it; the two must
agree. The names come in two families, kept in one table on each side - `lib/DeployNetworks.sol`
for the Forge scripts, `utils/networks.ts` for the TypeScript - and a new production chain is added
to its family there before anything is deployed to it:

- the Flare family, `flare`, `songbird`, `coston` and `coston2`, where the home accounts live. Each
  has a public RPC the tooling defaults to, and a `-staging` alias with its own record and chain config;
- the loan chains, `ethereum` and `sepolia` (its testnet), where the remote accounts live. Each has
  one tracked deployment, the pinned one, so no `-staging` alias, and its `<NETWORK>_RPC_URL` is
  required. Sepolia also takes a throwaway deployment for rehearsals, which records itself in the
  gitignored `sepolia_mock` record rather than the tracked one and is named explicitly by every tool
  that can touch it.

A chain in neither family has no name, no record and no chain config here, and every tool refuses it
whatever the wrapper called it. There is deliberately no local-development network: a rehearsal runs
against a fork of the real chain under the real name (anvil keeps the forked chain's id), in a
disposable worktree, since the run writes that network's tracked record.

Explorer verification (`pnpm verify_contracts <network>`) holds the RPC to the network's chain id like every
other tool, then submits to every verifier a chain has: Blockscout for the Flare family, at a predictable host;
Blockscout and Etherscan for the loan chains, where Etherscan needs `ETHERSCAN_API_KEY` (one V2 key for every
chain) and is skipped with a note without it; and Sourcify everywhere it lists the chain (Coston it does not), a
keyless record no explorer owns. Blockscout takes `BLOCKSCOUT_API_KEY` in the same Etherscan-compatible flag.
Its rate limits vary by instance and endpoint; the public Sepolia instance refused every keyless submission
after the first two in a run, twenty or sixty seconds apart alike, and a key raises the limit. A keyless run
says so once per Blockscout explorer and proceeds. Each explorer is given its own key by argument and none
other: the run blanks `ETHERSCAN_API_KEY` in forge's environment, because forge would otherwise fall back to
it - from the environment or from the env file it loads itself - for any verifier, and send the Etherscan key
to Blockscout. Submissions are spaced twenty seconds apart; `VERIFY_SUBMIT_DELAY_MS` overrides the spacing, and
`0` disables it for a re-run of one already-verified contract.

## The Sepolia rehearsal market

The Coston2 ↔ Sepolia rehearsal borrows against a market of our own making on the public Sepolia
Morpho: `pnpm deploy_sepolia_market <phase>` with `deployment/market-config/sepolia.json` as its one
configuration. It is Sepolia-only - a market over feeds we control has no place on a production chain,
Ethereum included - and its four phases are each re-runnable. `assets` deploys the loan token
(`TestnetLoanToken`: owner-only mint, no burn) and two operator-controlled feeds (`TestnetPriceFeed`, the
Chainlink aggregator shape with a dated-answer setter and a failure switch), skipping whatever the
deployment record already holds; a recorded asset is accepted, here and in every later phase, only
with code at its address, the deployer as its owner and the configured decimals, since the phases
mint and move feeds as the owner and the oracle's scale is built from the decimals. `market` checks
the infrastructure it builds on - the collateral's decimals, the LLTV and rate model enabled on that
Morpho, the rate model's own Morpho - builds the oracle through Morpho's factory over the two feeds,
asserts `2e48` for a $2 collateral over a $1 loan token at creation, and creates the market unless
its id already exists. Fresh or recorded, the oracle is held to the factory's registry and to its
immutable wiring - our two feeds, one per side, no vaults, the scale the decimals give - so a record
pointing at some other factory oracle is refused; only the price is not re-asserted on reuse, since
the feeds may deliberately be elsewhere by then. `fund` supplies the configured liquidity once, judged
by the supplier's own position rather than the pool's totals, and mints only what the supplier does
not already hold, so an attempt that minted and stopped is completed rather than repeated.
`reset-feeds` returns both feeds to their configured answers and lifts any failure; it is the only
phase that moves a feed, so a rerun of the others never ends a scenario in progress, and it fails the
collateral feed first and restores it last, so no block prices the market against one answer
restored and the other not. The market's parameters, id and the oracle's code hash are written to
`deployment/output-internal/sepolia/market.json` - by the script's simulation, so before the
broadcast; the fork suite writes a file of its own beside it and removes it.

Nothing here redeploys quietly. Assets are deployed only where the record lacks them, and the
factory's `CREATE2` refuses a second oracle under the same salt, so a lost oracle record stops the
market phase rather than doubling the oracle. The wrapper keeps `forge-deploy-output.txt` when forge
or the recorder fails, and refuses to run again while that file names a deployment (`DEPLOYED:`
lines) that was never recorded.

Recovering from that is a manual step, because the `DEPLOYED:` lines come from the simulation: they
name every deployment the run intended, whether or not its transaction landed, and the recorder
writes every line it is given. Every deploy wrapper here tees to that one path, so read the file
first: the network it names and the contracts it lists say which script's run to recover, and the
hash of every transaction that run sent is under `broadcast/<that script>.s.sol/<chain id>/run-latest.json`
(for this one, `DeploySepoliaMarket.s.sol` and `11155111`). Settle each hash against the chain
(`cast tx <hash>`, `cast receipt <hash>`) before deciding anything. A missing receipt is not proof: the transaction may still be in
the mempool, and it can land minutes later, after a rerun has decided it never would. Wait for a
pending one, or replace it at its nonce, until every hash is either mined or gone for good.

Then: if nothing landed, delete the output file and run the phase again. If some did, delete the
lines whose deployment did not, keep the rest, run `npx tsx
deployment/scripts/save-deployed-addresses.ts`, and run the phase again for what is still missing.
The oracle is the one address not to look for as a receipt's own contract: Morpho's factory creates
it, so it appears in that transaction's logs, and `isMorphoChainlinkOracleV2` on the factory is the
confirmation. A phantom record is not silently fatal either way - every phase demands code at the
addresses it reads, so an entry for a deployment that never landed stops the next run with `has no
code` rather than building on it. A leftover output without `DEPLOYED:` lines came from a run that
deployed nothing and is overwritten.

Two facts about that oracle, read from its source and pinned by the fork suite: its feed reader
requires only a non-negative answer, so a zero collateral answer prices the collateral at nothing
rather than reverting, while a zero loan-token answer - the quote the price is divided by - reverts
the oracle, as a reverting feed does; and it never reads a timestamp, so a stale answer is priced
like a fresh one. The oracle's source is Morpho's, GPL and deliberately not in this repository, so
`verify_contracts` reports it as having no source here; the factory's registration and the recorded
code hash are its provenance.

## Deployment records

```bash
pnpm deploy_contracts <network> <fullDeploy>
```

`<fullDeploy>` is a boolean (`true` or `false`). **Both modes are a full deployment from current source** — `false` only skips the diamond cut, the init and the vault/wallet configuration. It still deploys a controller, every facet and both account implementations, and records them. It is therefore **not** a facet-only mode and not for a live network: current source deliberately cannot reproduce the historical production controller address, so recording one over the live entry misdirects `check_cut` and `verify_diamond`, which resolve the diamond through that record. To add or replace facets on a live network, use a cut file and `pnpm diamond_cut` (see [`deployment/RUNBOOK.md`](./RUNBOOK.md)). The recorder refuses to replace the `MasterAccountController` or `FAssetRedeemComposer_FXRP` entry with a different address unless the caller names it in `ALLOW_RECORD_REPLACEMENT` — those two name live contracts and the tooling resolves the deployment through them. Every other entry, facets and account implementations alike, follows its redeployment freely, since that is what the deploy scripts are for. The `_mock` records are exempt: gitignored throwaways describing no live deployment.

## Cut files and the frozen creation code

Diamond cut files can list all candidate facets. `ExecuteDiamondCut.s.sol` checks the previously deployed address in `deployment/deploys/<network>.json` and reuses it when functional deployed bytecode matches the freshly compiled artifact. The comparison ignores the facet's own trailing Solidity metadata, so unrelated metadata-only rebuilds should not force redeployment.

Facets that inline `PersonalAccounts` address-derivation logic (`PersonalAccountsFacet`, `InstructionsFacet`, `ReaderFacet`, `MemoInstructionsFacet`, and `SubaccountsFacet`, which resolves the parent account) bake the frozen `PersonalAccounts.PROXY_CREATION_CODE` constant into their runtime bytecode, and `SubaccountsFacet` carries `Subaccounts.PROXY_CREATION_CODE` as well. Because it is a constant, those bytes do not drift across rebuilds, so `check_cut` does not flag these facets for redeployment on unrelated metadata churn — only genuine logic changes trigger a redeploy. The embedded bytes change only if one of the constants itself is edited, which is a cross-chain coordination event: predicted addresses for not-yet-deployed accounts of that kind shift and must be recomputed after such a cut.

There are two valid ways to prepare the `facets` list:

- For the safest review flow, list all candidate facets and let the script reuse unchanged deployments.
- For a smaller cut file, first run `pnpm check_cut <network> [cut-file-name]` and include only facets reported as `ADD` or `REPLACE`.

Do not rely only on the source import graph, since internal libraries, interfaces, compiler settings, and embedded creation code can change facet bytecode.

## Previewing a cut: `check_cut`

Before executing a cut, run `pnpm check_cut <network> [cut-file-name]` to preview the full cut plan. It reports three sections:

- **Facets (deploy):** each facet as `ADD` (in the cut, not yet deployed), `REPLACE` (deployed but functional runtime bytecode differs), `REUSE` (deployed and unchanged — trailing Solidity metadata differences are ignored), or `REMOVE` (no longer in the source tree). `REMOVE` is decided by source-file presence, not artifact presence, so a leftover artifact from a deleted facet (`forge build` does not prune those) cannot hide a removal — when one is detected the reason tells you to run `forge clean`. Pass a cut file so facets you intend to add are detected as `ADD`; without one the scope is limited to already-deployed facets.
- **Selectors to remove:** live diamond selectors that no longer exist on any facet in current source. Each is marked `listed` (already in `deleteSelectorSigs`, so the cut removes it) or flagged as needing review; add only intentionally removed selectors to `deleteSelectorSigs`, and leave selectors out when they should remain live through an older facet. Entries accept either a 4-byte hex selector (e.g. `"0xe8a6eec2"`) or a canonical function signature (e.g. `"mintedFAssets(bytes32,string,uint256,uint256,bytes,address)"`); signatures are hashed to selectors at cut-build time. Signatures for orphaned selectors are resolved best-effort from local cut data and git history, and both live and currently deployed facet addresses are printed when the historical facet can be identified.
- **Moved selectors:** live diamond selectors that still exist in the repo but on a _different_ facet (e.g. a function relocated to a new facet). These are reported as `MOVE`, not deletions — repoint them by adding that facet to the cut's `facets` (they become `Replace`); do **not** add them to `deleteSelectorSigs`, which would drop a live function. The tool warns loudly if a moved selector is already wrongly listed in `deleteSelectorSigs`.

## Verifying the diamond: `verify_diamond`

After a cut, run `pnpm verify_diamond <network> [cut-file-name]` to read the diamond back: it checks that the loupe exposes exactly the recorded facets' artifact selectors (less the cut file's `deleteSelectorSigs`), that no stale or orphan selector or facet is live, that every facet has code, that the four ERC-165 flags answer true and `0xffffffff` false, and the owner (`--expect-owner`, else what the stage implies: before the cut a loan chain's diamond is still the bootstrap's, so the pinned initial owner is expected, and from the cut on it is governance's, so the chain config's `governance` is - which is why omitting the flag after the handover no longer reports a mismatch it should not; where no config names a governance the pin stays the default, which on Ethereum today means a post-cut run without the flag cannot prove the handover, and a `governance` present but not an address stops the run instead of reading as no expectation; elsewhere the config's governance is used as before). On a loan chain (Ethereum, or Sepolia reproducing it) it also checks the record and the on-chain code against the pinned controller and base facets. `--pre-cut` verifies the bootstrapped diamond is pristine before its first cut: the pinned owner, exactly the three pinned base facets with their canonical selectors, no flag set. Every expected facet's on-chain code must also be the artifact's functional code (the planner's `REUSE` verdict: identical modulo the facet's own metadata trailer; a change in the embedded proxy creation code's metadata counts as a change) from a source still in the repository, and the diamond's own code the controller artifact's where no pin covers it. A cut file with `deleteAllOldMethods` narrows the expected surface to its own facets. The dispatch table is also read straight from the diamond's storage for the selectors the verifier itself calls, so a facet that lies about the layout cannot pass (the diamond's code, which is what the pins or the artifact comparison authenticate, is what reads that table), and a cut file's deleted selectors must have no dispatch entry left. The cut file must target the record's one controller. The cut wrapper runs the post-cut check itself when the cut file has `"execute": true`. All reads are made at one block; `VERIFY_BLOCK_TAG=finalized` makes it a finalized one. The checks live in `deployment/utils/diamond-verifier.ts` behind a chain reader and a repository reader, so `pnpm test:tooling` drives them against a fake chain (a forged loupe answer, a wrong runtime, both deletion modes, the pre-cut state, a wrong cut target, one failing fixture per check), runs the CLI itself against a fake JSON-RPC server (exit 1 on a failed check, every read at the resolved block, the chain-id guard) and runs the wrapper against stubbed `forge` and `npx` (the execute flag is validated before forge runs; verification follows an executed cut only and only after a successful forge run, under the staging name for a staging network; a failing verification fails the wrapper).

## Verifying an account implementation: `verify_implementation`

Registering an account implementation is the deployment's one blind step: `setPersonalAccountImplementation` and `setSubaccountImplementation` check only that the address has code, so a wrong but `initialize`-compatible implementation would let permissionless creation materialize proxies over the wrong storage layout — permanently, since initialization cannot be replayed. `pnpm verify_implementation <network> <Contract> <address>` asks the same question at the three moments it has to hold, with `--stage`: `pre` before the timelocked registration is queued, `queued` after queueing and before execution, `live` after it. `<Contract>` is `PersonalAccount`, `PersonalAccountRemote`, `LoanSubaccount` or `MorphoLoanSubaccountRemote`; the contract name decides which registry is read (the Personal Account beacon, or the subaccount type) and which chain family the implementation belongs to — the Flare accounts must not be registered on a loan chain (Ethereum, or Sepolia as its testnet) and the remote accounts must not be registered on a Flare-family chain, judged from the same two sets of chain ids the deploy scripts use (`deployment/lib/DeployNetworks.sol`, mirrored by `deployment/utils/networks.ts`). Each script allows its own family and nothing else; a chain in neither family is refused by every tool (see [Networks](#networks)). Every stage checks that the address holds the reviewed artifact's functional code (the planner's `REUSE` verdict) from a source still in the repository. `pre` prints the exact calldata governance must queue; `queued` requires that exact calldata to be queued (the timelock getter reverts for a call it never recorded, which reads as "not queued"); `pre` and `queued` both require a non-zero timelock duration, since with a zero delay the calldata handed to governance registers immediately instead of queueing; `live` requires the registry to point at the address, and with `--xrpl-owner` reads a materialized account back — it reports this controller, and it was initialized with the expected owner, or parent and type for a subaccount; for a Personal Account the ERC-1967 beacon slot must also name the controller, which only `PersonalAccountProxy` records (`SubaccountProxy` is a plain proxy holding the controller and the type as immutables and resolving `implementationForType` on every call, so the registry check is what proves which implementation serves it). An account the flag names that is not materialized fails, since asking for a sample is asking for that proof; omit the flag to verify the registry alone. A registry whose facet is not cut yet is reported as such rather than crashing. All reads are made at one block; `VERIFY_BLOCK_TAG=finalized` makes it a finalized one.

## Deploying the remote controller: pinned and throwaway

The loan chains have two deploy scripts, and which one applies is the same choice
[`RUNBOOK.md`](./RUNBOOK.md) Part B opens with. `pnpm deploy_remote_controller_pinned <network>` is the
production bootstrap: historical init code through the singleton factory, reproducing the controller and its
three base facets at the production addresses on Ethereum and on Sepolia alike, owned by the historical EOA
that must then hand it on. `pnpm deploy_remote_controller_throwaway sepolia` is the rehearsal's: the same
controller shape built from current source and owned by the deploying key, so it lands at a different address
on purpose, with its facet set cut and both remote implementations deployed and registered in the one run —
everything downstream of the bootstrap, without the ceremony. It refuses Ethereum, and its addresses go to the
gitignored `<network>_mock` record rather than the tracked one, so nothing resolves a live deployment through
them. Both of its sides must run the same build or the two controllers diverge; `controllerAddress(owner)`
derives the address without deploying, for checking that in advance. Every step of it is derived and reused
rather than freshly created, so a run that failed half way through is resumed by running it again.

## Configuring the remote controller: `configure_remote_controller`

The Flare deploy applies its network's settings inside its own run; the loan chains have no such run,
because the controller there is bootstrapped from pinned bytes and owned by a multisig from its first hour.
`pnpm configure_remote_controller <network> <prepare|execute|verify> [section] [target]` is that step, reading the same
per-network chain config. The sections are one governance group each: `governance` (pausers, unpausers, then
the timelock duration, which goes last because it is what makes every later timelocked call queue),
`transport`, `market` and `fees`, plus `wiring` for the last three and `all` for every one; the section
defaults to `governance`. The target is `pinned` or `throwaway` - which controller on that chain the run
configures, named rather than assumed and defaulting to `pinned`; the throwaway one is found through the
gitignored `_mock` record its deploy writes, and refused if that record turns out to name the production
address or one with no code. A throwaway run therefore reads
`pnpm configure_remote_controller sepolia execute all throwaway`. Order inside a run is fixed and is not a preference: the market's registration
validates its collateral token against the transport's OFT, and the first fee-terms call is the type's
activation, so borrowing reverts until it lands.

`prepare` sends nothing and takes no key. It prints one line per call — target and calldata — and writes them
to `deployment/output-internal/<network>/configuration-<section>.txt`, the way a cut file with
`"execute": false` prepares a cut for governance. Once a duration is in force it prints the matching
`executeTimelockedCall` beside each one, so nobody re-encodes it by hand, and it reports who actually holds
the diamond, since calls prepared for an owner that has not been handed it cannot be submitted by anyone.
The calls themselves depend on the config and the record rather than on the chain, so a run against a diamond
whose `TimelockFacet` is not cut yet still emits them, marked `PROVISIONAL` in the print and as the output
file's first line: an absent getter does not prove a zero delay — a facet cut, set and removed leaves its
duration in storage while the read reverts exactly as on a fresh diamond — so that output carries no
`executeTimelockedCall` lines and is not the one to submit from. Run `prepare` again after the cut, and the
post-cut run becomes the cross-check. Only that one revert is tolerated, matched in full against the
diamond's own `FunctionNotFound` for that selector; any other failure of the read stops the run.
`pnpm describe_calls <network> [section] [--sheet] [--flat]` names the parameters of what `prepare` wrote, decoding each
payload against the compiled ABI, so a governance sheet can be filled from the tool rather than by reading hex; the
decode reads back what was encoded, which a rendering written beside the encoder could not.
`execute` submits them and requires the signer to be the current owner with the duration still zero, which is
the throwaway flow alone — a multisig can never sign here, and a diamond that already has a duration would
queue every call while the run reported it sent them. `verify` reads the chain back and fails unless the roles
are exactly the configured set (no extra member either), the duration matches to the second, and every wired
field agrees; that is the half `verify_diamond` does not cover, since it checks ownership and the diamond's
surface and says nothing about roles, delay, transport, market or fees. A section named on its own must be
complete in the config or the run stops naming what is missing; a sweep skips an incomplete one with a note,
which is how a transport is prepared while the market's loan token and oracle are still to be deployed.

## Proxy storage layouts

Proxies keep their storage across upgrades, so every implementation in a proxy's chain-local
lineage must preserve that proxy's layout: append fields, never insert, reorder or retype. The
OpenZeppelin upgrade-safety validator gates this, locally and in CI (`upgrade-build-info` +
`validate-upgrade`):

```bash
pnpm build:upgrade-info && pnpm validate-upgrade
```

`build:upgrade-info` compiles the isolated `upgrade_validation` profile (full build-info and storage
layouts under `artifacts-upgrades/`); `validate-upgrade` runs the validator over the six proxy-backed
implementations. The three that are live — the Flare Personal Account, `FAssetRedeemComposer` and
`FAssetRedeemerAccount` — are checked against `deployment/build-info-v2.0.0/`, a reconstructed v2.0.0
reference: the build-info of those three compilation units rebuilt from the `v2.0.0` tag with its solc
0.8.30. The reconstructed runtimes match the deployed implementations modulo the identified generated fields (the
metadata hashes, including the one embedded in the redeemer-proxy creation code, and the UUPS
immutable), so an incompatible layout change fails with field-level diagnostics while a safe append
passes. The remote
Personal Account and both loan subaccounts have no proxy on any network yet and run the checks that
need no reference (constructor and initializer safety, unsafe operations, annotated namespaces); before
re-laying one of those layouts, check the lineage is still empty with
`pnpm check_lineage_fresh <network> [subaccounts|personal-accounts]`. It is decisive on chain only through
the beacon or the registration event history, which needs an RPC serving full-range logs (a private
node); otherwise it answers from the retained git history of the network's deployment record and cut
files (a full clone), on the stated assumption that every installation was committed under its canonical
facet name before execution and remains reachable from the clone's refs (a facet named by any current,
historical or example record may have been installed), and fails
closed on anything unproven. At a lineage's first production
deployment, copy that build's `artifacts-upgrades/build-info` into a tracked
`deployment/build-info-<version>/` directory right away (CI artifacts expire, so the window closes
with the deployment) and add it to `validate-upgrade` with `--referenceBuildInfoDirs` and
`--reference <dirname>:<Contract> --requireReference`.

Two things to know about the validator's output. The implementations' constructors carry the
`@custom:oz-upgrades-unsafe-allow constructor` waiver (`ControlledAccountBase` for the four accounts, the
two composer contracts for theirs). The validator's constructor rule applies to them as to any
implementation; the waiver suppresses its finding because these constructors run on the implementation
only, never on a proxy, and it keeps the exception reviewed rather than silent. And the
diamond libraries' `State` structs raise "namespace struct is defined outside of a contract" warnings,
which is expected (the validator covers the proxied implementations; the diamond's namespaces are the
facets' concern). The rule the
account bases follow — controller at slot 0 in every lineage, `xrplOwner` at slot 1 in every Personal
Account lineage, every other base field in an ERC-7201 namespace — stays pinned by
`test/unit/smartAccounts/AccountStorageLayout.t.sol`, which pins the cross-lineage layout rule the validator
does not compare (it checks each lineage only against its own reference).
