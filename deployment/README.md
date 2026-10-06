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
after the first two in a run, twenty or sixty seconds apart alike. A KEY BUYS NOTHING HERE - measured
2026-09-15, and worth reading with its correction attached, because the first version of this paragraph
asserted the same thing on evidence that turned out worthless. That attempt reported "keyed and keyless
refused alike, twelve of twelve each way"; it sent an EMPTY key on both sides, `BLOCKSCOUT_API_KEY` having
been commented out of the environment file, so it compared keyless with keyless and measured nothing.

Re-measured with a real key against the Etherscan-compatible `/api` endpoint forge verifies through - the v2
read API was not throttling that day and cannot stand in for it - one burst of 15 rapid reads per arm, each
the FIRST thing a freshly changed IP did, so neither arm inherited the other's penalty:

| | requests served | first limited |
|---|---:|---:|
| keyless | 10 of 15 | 11th |
| keyed | 10 of 15 | 11th |

Identical, down to the request the limiter cut in on. The reason is not that the key is wrong but that it is
for a different service: it is a PRO key for `api.blockscout.com`, the multichain API, which answers 402
without it and 200 with it (as `?apikey=` or `Authorization: Bearer`; `x-api-key` is refused). The per-chain
host is a separate service that does not know that token, and its own key page now reads "Chain-specific API
keys are deprecated. Please migrate to the Blockscout PRO API" - so **there is no key this host will honour,
at any price.** Its limiting is per IP and cannot be raised. Two caveats kept in view on the burst figures:
one burst per arm, one public instance, one day.

The spacing below is therefore set for the keyless case, and the wait is NOT conditioned on holding a key: a
run that shortened it on seeing one would fail rather than finish sooner. The key is still passed whenever it
is set, for an instance that does honour it. A keyless run says so once per Blockscout explorer and proceeds. Each explorer is given its own key by argument and none
other: the run blanks `ETHERSCAN_API_KEY` in forge's environment, because forge would otherwise fall back to
it - from the environment or from the env file it loads itself - for any verifier, and send the Etherscan key
to Blockscout. Spacing is PER EXPLORER, because a rate limit is per host: twenty seconds before a Blockscout
submission and one before Etherscan's or Sourcify's, which never needed Blockscout's figure and were two of
every three gaps on a loan chain. `VERIFY_SUBMIT_DELAY_MS` overrules all of them, and `0` disables the wait for
a re-run of one already-verified contract.

### The four pinned contracts need the original compilation

On a loan chain `MasterAccountController` and the three base facets (`DiamondCutFacet`,
`DiamondLoupeFacet`, `OwnershipFacet`) are deployed from the historical init code in
`pinned-init-code/`, so the diamond reproduces at its Flare address - see
`lib/PinnedControllerInitCode.sol`. That code was built with **solc 0.8.30** and flare-periphery 0.1.38;
this repository builds 0.8.35. The functional bytes are identical either way - checked, with the metadata
trailer stripped, against the deployed code - but the compiler version lives IN that trailer, so Blockscout
and Sourcify compare the runtime and accept all four (two exactly, two as partial matches - `partial` is
precisely that trailer), while Etherscan requires an exact deployment-bytecode match and refuses them with
`Fail - Unable to verify. Compiled contract deployment bytecode does NOT match the transaction deployment
bytecode`. `verify_contracts` will never fix that: it submits current source.

They ARE verifiable, from the original compilation. The Flare mainnet explorer holds a full-match verification
of all four at `v0.8.30+commit.73712a01` (cancun, viaIR, optimizer 200), and the Flare deployed runtime equals
the loan chain's byte for byte, because both came from the same pinned init code. Rebuild the standard-json
input from that verification's `source_code`, `additional_sources` and `compiler_settings`, **forcing
`language` to `"Solidity"`**: Blockscout reports it lowercase, solc accepts only
`Solidity`/`Yul`/`SolidityAST`/`EVMAssembly`, and an unfixed input therefore fails to COMPILE - which Etherscan
reports as `Unable to get compiled bytecode`, reading like a bytecode mismatch when it is not one. Compile the
assembled input locally before submitting; solc 0.8.30 reproduces all four runtimes byte for byte, metadata
included, which is the match Etherscan wants. Only the controller takes constructor arguments - 960 bytes, the
tail of `pinned-init-code/MasterAccountController.hex` - and Etherscan cannot infer them because the deployment
went through the EIP-2470 singleton factory, so the creating transaction's input is factory calldata. Done this
way on Sepolia on 2026-09-15; all four verified.

**The recovered inputs are checked in**, at [`pinned-verification/`](./pinned-verification/), so doing this
again needs nothing but solc 0.8.30 and does not depend on the Flare explorer still serving that verification.
Rebuilding them from the explorer is the fallback, not the procedure.

## Signing

Every wrapper that broadcasts passes arguments after its own straight through to `forge`, so the
signer is the caller's choice:

```bash
cast wallet import my-deployer --interactive        # once
pnpm transfer_ownership sepolia 0xCurrent 0xNew --account my-deployer --sender 0xMyAddress
pnpm transfer_ownership sepolia 0xCurrent 0xNew --ledger --sender 0xLedgerAddress
```

A wrapper's own arguments come first and never begin with `-`, so the two need no separator. A
caller-supplied signer REPLACES `DEPLOYER_PRIVATE_KEY` rather than joining it: the raw key is
appended only when nothing else signs, because handing forge two signers lets forge pick, and it
picks the keystore.

**The Solidity scripts take the signer from forge, not from the environment.** They broadcast as
`_signer()`, which is `msg.sender` - the account forge resolved from the command line.

Until 2026-09-15 they called `vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"))`, which silently
outranked anything on the command line: a run given `--ledger` was signed by the environment key
instead, and the wrapper's flags did nothing. The checks stayed self-consistent - `TransferOwnership`
compared that same environment account against the owner, so it never signed with something it had
not checked - but the account the operator ASKED for was ignored, which on a hardware run means
either a confusing refusal naming an account they never chose, or a transfer made from the
environment key while they watched a device that was never used.

`_signer()` is a seam rather than a bare `msg.sender` because a test cannot name that account any
other way: `vm.prank` and a broadcast are mutually exclusive in Foundry, so a harness overrides it.
Without that, a test would broadcast from forge's default sender while the script read `msg.sender`
as the caller - a split that cannot happen in a real run, and that would have the tests exercising a
configuration the deployment never sees.

One limit worth knowing for hardware: the comparison is against the `--sender` forge was GIVEN, so a
device holding a different address fails later, at signing, rather than in the preflight.

Prefer a keystore to the environment variable. A variable is expanded by the shell before `exec`,
so the key reaches the process list and, typed once, the shell history; `--account` reaches neither.
The RPC URL has the same exposure when it carries an API key, which is why `cast` reads
`ETH_RPC_URL` from the environment instead of taking a flag.

**Output flags are refused by the nine wrappers whose output is parsed.** The recorder reads
`NETWORK:` and `DEPLOYED:` lines out of forge's output, and `--quiet`, `-q` or `--json` silences or
reshapes them. Forge broadcasts BEFORE the recorder runs, so accepting one would put a contract on
chain and then fail with "Network name not found in output", leaving the record naming whatever it
named before - which re-running cannot undo, the contract being already deployed. They are refused
before anything is sent.

**The flags do not ship without the preflight.** Forge binds `ETH_KEYSTORE_ACCOUNT` to `--account`
and `ETH_KEYSTORE` to `--keystore`, and it resolves a keystore AHEAD of every other signer. So with
either variable set, `--ledger` signs from the keystore instead - asking only for the password of an
account nobody named - and `--account` beside `ETH_KEYSTORE` is rejected by forge itself, citing a
flag the caller never typed. A wrapper cannot neutralize this by unsetting the variable: forge loads
the environment file on its own, afterwards, restoring it. So
[`scripts/signer-preflight.sh`](./scripts/signer-preflight.sh) refuses the combination and says
which variable caused it. Its classification is tested directly, over every spelling forge accepts
including short clusters, in `test/tooling/signer-preflight.test.sh`; that a Ledger actually reaches
forge, and that a stale variable actually stops the run, is pinned end to end against a stubbed
forge in `test/tooling/transfer-ownership.test.sh` - that being the wrapper whose one call cannot be
undone.

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

**A failed SIGNATURE leaves the same file and is the cheapest case to settle.** A hardware or
keystore run that forge refuses - a `--sender` the device does not derive, a declined confirmation, a
locked Ledger - fails after the simulation has already printed its `DEPLOYED:` lines and written
them here, so the leftover looks exactly like a run that deployed. It is not: nothing was signed.
Three independent signals say so, and all are reads:

- `run-latest.json` carries NO transaction hashes and no receipts, where a sent run carries both;
- `cast code <address>` is `0x` for every address the file names;
- the sender's nonce is unchanged from before the attempt.

With all three agreeing, delete the file and run again. Seen on 2026-09-15, rehearsing the Ledger
path on Sepolia: forge derived a different account than `--sender` named, stopped before signing, and
the next run was then blocked by this guard until the file was settled.

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

### Nothing is recorded until the chain has it

No deploy script writes the record itself. Each one PRINTS a `DEPLOYED: <name>, <Source>.sol: <address>` line per deployment and a `NETWORK:` line naming the record file; the wrapper tees that to `forge-deploy-output.txt`, and only after forge has exited does the record get written. The reason is that `forge script` runs the whole script in simulation before it broadcasts anything, and a filesystem write is not EVM state: a record written from inside the script outlives the simulation that computed it, so a run that reverted afterwards, was refused by the signer, or never reached the chain at all would still leave the deployment record naming an address with no code. Every tool that resolves through the record — `check_cut`, `verify_diamond`, `verify_contracts` — would then ask its questions of that address, which is exactly what an operator reaches for after a run has just failed.

A successful forge exit is not on its own proof about any single address, because those lines were printed by the simulation. The cut wrapper therefore puts two steps between them and the record, in order; every other wrapper runs only the second:

1. `verify-deployed-runtime.ts <network>` asks the chain whether each printed address carries the runtime of the artifact its record names — exactly, or modulo the trailing Solidity metadata, the same tolerance `check_cut` and `verify_diamond` apply. An address with no code, or one holding something else, fails the run here. It suits a run whose every entry is a plain contract built from this repository's artifacts, which is why a wrapper opts in rather than this running everywhere: a record naming a proxy would fail it, since a proxy's runtime is the proxy's and not its implementation's.
2. `save-deployed-addresses.ts` merges the lines into `deployment/deploys/<network>.json` under the guards above, and removes the output file.

A failure at either step leaves both the record and `forge-deploy-output.txt` untouched, and the next run of any wrapper that tees refuses to start while that file names deployments the record never got (`deploy-output-preflight.sh`). That file is the evidence a recovery starts from; the manual settlement it needs is the one described for the Sepolia market above, and it applies to any script's leftover.

## Cut files and the frozen creation code

Diamond cut files can list all candidate facets. `ExecuteDiamondCut.s.sol` checks the previously deployed address in `deployment/deploys/<network>.json` and reuses it when functional deployed bytecode matches the freshly compiled artifact. The comparison ignores the facet's own trailing Solidity metadata, so unrelated metadata-only rebuilds should not force redeployment.

Facets that inline `PersonalAccounts` address-derivation logic (`PersonalAccountsFacet`, `InstructionsFacet`, `ReaderFacet`, `MemoInstructionsFacet`, and `SubaccountsFacet`, which resolves the parent account) bake the frozen `PersonalAccounts.PROXY_CREATION_CODE` constant into their runtime bytecode, and `SubaccountsFacet` carries `Subaccounts.PROXY_CREATION_CODE` as well. Because it is a constant, those bytes do not drift across rebuilds, so `check_cut` does not flag these facets for redeployment on unrelated metadata churn — only genuine logic changes trigger a redeploy. The embedded bytes change only if one of the constants itself is edited, which is a cross-chain coordination event: predicted addresses for not-yet-deployed accounts of that kind shift and must be recomputed after such a cut.

The composer is the exception. `FAssetRedeemComposer` derives redeemer accounts from the live `type(FAssetRedeemerAccountProxy).creationCode`, so a new composer implementation embeds whatever the current compiler and settings produce. Upgrading it moves the predicted address of every redeemer account not yet created; accounts already created are stored and unaffected. Before upgrading the composer on a network, either freeze the creation code to the one its live implementation embeds, or confirm that nothing was sent to a predicted address. See `docs/specs/Composer/RedeemerAccounts.md`.

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

Registering an account implementation is the deployment's one blind step: `setPersonalAccountImplementation` and `setSubaccountImplementation` check only that the address has code, so a wrong but `initialize`-compatible implementation would let permissionless creation materialize proxies over the wrong storage layout — permanently, since initialization cannot be replayed. `pnpm verify_implementation <network> <Contract> <address>` asks the same question at the three moments it has to hold, with `--stage`: `pre` before the timelocked registration is queued, `queued` after queueing and before execution, `live` after it. `<Contract>` is `PersonalAccount`, `PersonalAccountRemote`, `LoanSubaccount` or `MorphoLoanSubaccountRemote`; the contract name decides which registry is read (the Personal Account beacon, or the subaccount type) and which chain family the implementation belongs to — the Flare accounts must not be registered on a loan chain (Ethereum, or Sepolia as its testnet) and the remote accounts must not be registered on a Flare-family chain, judged from the same two sets of chain ids the deploy scripts use (`deployment/lib/DeployNetworks.sol`, mirrored by `deployment/utils/networks.ts`). Each script allows its own family and nothing else; a chain in neither family is refused by every tool (see [Networks](#networks)). Every stage checks that the address holds the reviewed artifact's functional code (the planner's `REUSE` verdict) from a source still in the repository. `pre` prints the exact calldata governance must queue; `queued` requires that exact calldata to be queued (the timelock getter reverts for a call it never recorded, which reads as "not queued"); `pre` and `queued` both require a non-zero timelock duration, since with a zero delay the calldata handed to governance registers immediately instead of queueing; `live` requires the registry to point at the address, and with `--xrpl-owner` reads a materialized account back — it reports this controller, and it was initialized with the expected owner, or parent and type for a subaccount; for a Personal Account the ERC-1967 beacon slot must also name the controller, which only `PersonalAccountProxy` records (`SubaccountProxy` is a plain proxy holding the controller and the type as immutables and resolving `implementationForType` on every call, so the registry check is what proves which implementation serves it). An account the flag names that is not materialized fails, since asking for a sample is asking for that proof; omit the flag to verify the registry alone. Before the registration, and only when the address being registered has itself passed the code check, `pre` also NOTES when the address the registry already holds carries this exact code: the registration would then change which address serves and nothing else, which is a timelocked call, its signatures and its execution for no new behavior - worth a second look at whether the redeploy was intended, but a note rather than a failure, since replacing a live implementation is a legitimate registration and which address a deployment should name is not this check's to decide. Only at `pre`: at `queued` and `live` the question is whether the exact requested registration landed, and equal code at another address does not answer it. A registry whose facet is not cut yet is reported as such rather than crashing. All reads are made at one block; `VERIFY_BLOCK_TAG=finalized` makes it a finalized one.

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
`implementations`, `transport`, `market` and `fees`, plus `wiring` for the last three and `all` for every one;
the section defaults to `governance`. The target is `pinned` or `throwaway` - which controller on that chain the run
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
Each call's calldata comes from the config and the record rather than from the chain — WHICH calls appear can
still depend on chain state, since `implementations` is filtered against the registry, below — so a run against a
diamond whose `TimelockFacet` is not cut yet still emits them, marked `PROVISIONAL` in the print and as the output
file's first line: an absent getter does not prove a zero delay — a facet cut, set and removed leaves its
duration in storage while the read reverts exactly as on a fresh diamond — so that output carries no
`executeTimelockedCall` lines and is not the one to submit from. Run `prepare` again after the cut, and the
post-cut run becomes the cross-check. Only that one revert is tolerated, matched in full against the
diamond's own `FunctionNotFound` for that selector; any other failure of the read stops the run.
`pnpm describe_calls <network> [section] [--sheet] [--flat]` names the parameters of what `prepare` wrote, decoding each
payload against the compiled ABI, so a governance sheet can be filled from the tool rather than by reading hex; the
decode reads back what was encoded, which a rendering written beside the encoder could not. It makes no chain call
and takes no key, and prints one `name = value` line per parameter. A STRUCT is one parameter whose value is the
bracketed form a governance sheet cell and the Safe Transaction Builder both take
(`_market = ["0xd011...",["0x1B5A...",...,"770000000000000000"]]`), nested to any depth and in declaration order.
EVERY scalar inside the brackets is quoted, integers included: the builder parses them with `JSON.parse` and takes a
decimal string for any integer field, while a bare integer is read as a double and is exact only to about 9.0e15 in
either direction. A top-level scalar stays plain, since its own cell is not JSON. `--sheet` emits the pairs tab
separated for pasting, naming a selector it could not decode rather than leaving the row looking argument-free;
`--flat` gives one line per leaf, walking arrays with an index (`_cuts[0].facetAddress`), for reading a call rather
than pasting it. The names come from the compiled ABI, searched internal interfaces first because a selector fixes
the signature but not the parameter names, so the decode is a SECOND SOURCE on what was encoded rather than a
restatement of the inputs. Its suite needs a `forge build`; without artifacts it skips, and `REQUIRE_FORGE_TOOLING`
turns that into a failure, which is how the Foundry CI job demands it run.
`execute` submits them and requires the signer to be the current owner with the duration still zero, which is
the throwaway flow alone — a multisig can never sign here, and a diamond that already has a duration would
queue every call while the run reported it sent them. `verify` reads the chain back and fails unless the roles
are exactly the configured set (no extra member either), the duration matches to the second, and every wired
field agrees; that is the half `verify_diamond` does not cover, since it checks ownership and the diamond's
surface and says nothing about roles, delay, transport, market or fees. A section named on its own must be
complete in the config or the run stops naming what is missing; a sweep skips an incomplete one with a note,
which is how a transport is prepared while the market's loan token and oracle are still to be deployed.

`implementations` is the one section FILTERED against the chain. A registration the diamond has already made is
skipped with a note, because the deploy reuses an implementation whose code has not changed, and re-registering the
address the diamond already serves costs a timelocked call, three signatures and an execution to change nothing.
`prepare` and `execute` skip the same ones. A registry that cannot be read yet — the facet is not cut — filters
nothing, and a registry pointing at an address the config does not name is never filtered, since the registration is
how that disagreement gets resolved. It is also the one section whose two addresses are not in the chain config: the
remote Personal Account and the type's remote subaccount are deploy outputs, read from the target's own deployment
record, and a record naming neither leaves the section unready. No other section is filtered: re-registering a
market is refused on chain and a different one is a disagreement a person must see, the transport and the fee terms
are legitimately re-set to the same values, and the duration is every run's last call. Registering is not
verification: it does not replace `verify_implementation --stage pre`, which is the check that can still refuse a
wrong address before it is registered.

## Remote account implementations: `deploy_remote_account_implementations`

`pnpm deploy_remote_account_implementations <network> <all|name[,name...]>` takes a mandatory selection: `all`, or a
comma-separated list of `personal-account` and `morpho-loan-subaccount`. Names rather than a flag each, so a new
subaccount type is a new name rather than a moved argument.

A preflight (`plan-remote-implementations.ts`) compares each named implementation's recorded address against the
artifact, modulo the runtime's trailing metadata as the cut planner does, and SKIPS one that already carries this
code — a successful skip, so `all` can deploy one and reuse the rest, and a run that deploys nothing leaves the
record untouched and never reaches the recorder. Reuse is not registration: the plan reports what the diamond's
registry holds separately, and where the record and the registry name different addresses it says so rather than
choosing.

## Handing the pinned controller on: `transfer_ownership`

`pnpm transfer_ownership <network> <expected-current-owner> <new-owner>` exists for its preflight rather than for
the call. `transferOwnership` is one step, has no acceptance from the new owner, is not timelocked, and a wrong
address ends that diamond's governance for good.

The expected current owner is an argument, compared against the chain, so a run pointed at the wrong network stops
instead of handing away whatever it found. The signer must be that owner — a Ledger through `--ledger --sender` is
what the mainnet handover needs. The zero address, the diamond itself and the current owner are refused, and a new
owner with no code is called out rather than refused.

It covers BOTH handovers: the bootstrap owner's transfer at the start of a chain's deployment, signed from
hardware, and the deployer-owned one at the end of a rehearsal, signed with `--account` or the raw key. A throwaway
controller is never handed on, so there is no target argument — the pinned controller is the only diamond it
touches. The broadcast is followed by a separate `verify` run, since the script's own read-back would see simulated
state.

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
Personal Account and both loan subaccounts were first deployed on 2026-09-14 and are checked against
the newest frozen build of each lineage (below), so all six now run with
`--requireReference`; before re-laying a layout that has no proxy yet, check the lineage is still
empty with
`pnpm check_lineage_fresh <network> [subaccounts|personal-accounts]`. It is decisive on chain only through
the beacon or the registration event history, which needs an RPC serving full-range logs (a private
node); otherwise it answers from the retained git history of the network's deployment record and cut
files (a full clone), on the stated assumption that every installation was committed under its canonical
facet name before execution and remains reachable from the clone's refs (a facet named by any current,
historical or example record may have been installed), and fails
closed on anything unproven. At a lineage's first production
deployment, copy that build's `artifacts-upgrades/build-info` into a tracked
`deployment/build-info-<version>/` directory right away — the window is not the CI artifact's
expiry, since `pnpm build:upgrade-info` regenerates the build locally against a pinned compiler, but
the certainty of WHICH source a chain is running, which decays as branches move — and add it to `validate-upgrade` with `--referenceBuildInfoDirs` and
`--reference <dirname>:<Contract> --requireReference`.

The three lineages first deployed on 2026-09-14 — the remote Personal Account, the Flare loan
subaccount and the remote one — are checked against `deployment/build-info-2026-09-14/`, frozen at
that deployment, except the remote loan subaccount: its layout grew on 2026-10-06, and it is checked
against `deployment/build-info-2026-10-06/`, frozen at that deployment. Each directory, its build command,
its checksum and the addresses it matches are recorded in
[`reference-builds.md`](./reference-builds.md); storage compatibility does not establish which
compilation a chain is running, and that record does.

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
