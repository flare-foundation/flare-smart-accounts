# Reference builds

Frozen Foundry `build-info` snapshots, one directory per set of implementations that is live on some
chain. `validate-upgrade` compares every candidate against them with `--requireReference`, so a
storage-layout break — inside an ERC-7201 namespace included — fails CI by field name before it can
reach an upgrade. Without a reference the validator runs only the checks that need none, and an
incompatible layout passes unnoticed.

Each directory holds its snapshot alone, because `--referenceBuildInfoDirs` parses every file in it
as build-info; this record lives beside the directories rather than inside them. A `.gitattributes`
rule keeps the JSON from rendering in diffs.

**Freeze at the deployment, not later.** The window is not the CI artifact's one-day expiry —
`pnpm build:upgrade-info` regenerates a build locally and the compiler is pinned — but the certainty
of *which source* a chain is running, which decays as branches move. `build-info-v2.0.0` had to be
reconstructed for exactly that reason; see `README.md`.

## build-info-v2.0.0

The reconstructed v2.0.0 build of the three implementations live before this release: the Flare
Personal Account, `FAssetRedeemComposer` and `FAssetRedeemerAccount`. How it was reconstructed, and
the two expected validator findings, are in [`README.md`](./README.md).

## build-info-2026-09-14

The three lineages first deployed on 2026-09-14, each of which had no reference until then. It remains
the reference for `PersonalAccountRemote` and `LoanSubaccount`; `MorphoLoanSubaccountRemote` moved to
[`build-info-2026-10-06`](#build-info-2026-10-06) when its layout grew. Named
for the deployment rather than a release version, because the release it ships in is not yet
numbered and a name that turns out wrong is worse than one that is merely literal.

| | |
|---|---|
| Source commit | `65a6898022bb2a7ba6008f91e2eebc7e998e9098` — its `contracts/` is byte-identical to `e4b44e4`, the frozen audited revision |
| Snapshot | `deployment/build-info-2026-09-14/84e042a3da4de90f.json` |
| sha256 | `639ed06793844f146420a006485e5797a13688b44df9b9f4e98ca158444373e5` |
| Compiler | solc 0.8.35, via-ir, optimizer 200 runs, cancun — the `foundry.toml` default profile, which `upgrade_validation` inherits |
| Toolchain | forge 1.8.0-nightly, commit `eb4bf9b4a0ca13f5e3ed5b5be221f37bff56a4f9` |
| Build | `FOUNDRY_PROFILE=upgrade_validation forge clean && FOUNDRY_PROFILE=upgrade_validation forge build contracts/smartAccounts/implementation/PersonalAccountRemote.sol contracts/smartAccounts/implementation/LoanSubaccount.sol contracts/smartAccounts/implementation/MorphoLoanSubaccountRemote.sol`, run on the source commit's tree |

**What reproduces this, and what does not.** The build command and the toolchain are not enough on
another machine. The snapshot embeds absolute workspace paths and the remappings forge auto-detected
from whatever dependency directories were present, and an unused remapping is enough to change every
runtime's METADATA TRAILER while leaving the functional bytes identical — so the sha256, and the
full runtime hashes below, move with the environment even when the code does not. Treat the sha256
as an integrity check for this file.

**For exact reproduction, replay the archived compiler input.** The snapshot carries the complete
solc standard-json input under its `input` key — 173 sources with their content, the remappings and
every setting — so a replay depends on nothing outside the file. Foundry stores three extra keys
there (`allowPaths`, `basePath`, `includePaths`) that solc rejects, so keep only the standard three:

```bash
python3 -c "import json,sys; i=json.load(open('deployment/build-info-2026-09-14/84e042a3da4de90f.json'))['input']; json.dump({k:i[k] for k in ('language','sources','settings')}, sys.stdout)" > input.json
solc --standard-json < input.json > replay.json   # solc 0.8.35
```

Verified on 2026-09-15: the replayed runtimes equal the snapshot's byte for byte, metadata trailer
included, for all three contracts. (Feeding the `input` object unmodified fails with
`Unknown key "allowPaths"` and produces no contracts at all — an empty result that is easy to
mistake for a mismatch.)

What holds WITHOUT any replay is the functional-bytes column below: the runtime with its metadata
trailer stripped, which is what the cut planner and `verify_implementation` compare and what an
environment cannot move.

The three files are named explicitly rather than building everything: a reference only needs the
contracts it is a reference *for*, and their import closure comes with them. That is 8.9 MB against
46.5 MB for the whole tree with `--skip test --skip script`, and 94 MB without.

The CANDIDATE is built differently, and deliberately: `pnpm build:upgrade-info` and the
`upgrade-build-info` CI job both run `--skip test --skip script` over the whole tree, because the
candidate must contain all six validated contracts while a reference need only contain its own. The
two sides therefore do NOT share a build command — what they share is the compiler profile, and the
comparison is of storage layouts and bytecode rather than of the files.

Compiled runtime bytecode, read from the snapshot:

The FULL hash is what the deployed code must equal byte for byte, and it includes the metadata
trailer, so it is specific to this compilation in this environment. The FUNCTIONAL hash is the same
runtime with that trailer stripped: it survives a rebuild elsewhere, and it is what the cut planner
and `verify_implementation` compare.

| Implementation | keccak256 of `deployedBytecode` (full) | keccak256 of the functional bytes | bytes | immutables |
|---|---|---|---:|---:|
| `LoanSubaccount` | `0x3f3e6ecd8b2f8969cdc319c1cce776d0884d1f438118c60b91b0b0fc404199ba` | `0x475f21cb77c39ce12d36a1693e8e0622382040f3c31044399d1211c2168a0932` | 8901 / 8848 | 0 |
| `PersonalAccountRemote` | `0xabf1485b8f648334ac20dfaa68fa7471d180e041cc429bdd9feb0104c7a5b9d5` | `0xd4c1ff52e4ca40e0f6a672bdc59e64082b242ec388f7f315ffcae84db9dcaca1` | 3824 / 3771 | 0 |
| `MorphoLoanSubaccountRemote` | `0x52391a7f0bbf1c28499e69d6097439821256247b4086647e6e81d4a7cfc52630` | `0xc1df6f3fc8c26e5a5588e51bb23ab8bee6e6dc97d4490762b6b9f5f859ba1e17` | 17262 / 17209 | 0 |

None of the three carries an immutable, so on-chain code equals these compiled bytes exactly and a
plain code hash is the comparison. (A UUPS implementation would not: its `__self` immutable is
filled at construction, so a raw hash never matches and the immutable ranges must be masked first.)

### Deployments

Each address below was read on chain on 2026-09-14 and its runtime compared byte for byte against
the snapshot above. `pnpm verify_implementation <network> <Contract> <address> --stage live` is a
RELATED but weaker check: it compares the live code against the CURRENT artifact and ignores the
trailing metadata, so it says the deployed code is still functionally what the repository builds —
not that it is byte-for-byte this snapshot, and not that it still matches once the artifact moves.
The byte-for-byte tie to this snapshot is the hashes above, and re-checking it means comparing live
code against them directly.

| Chain | Implementation | Address | Matched |
|---|---|---|---|
| Coston2 | `LoanSubaccount` | `0xeAC08019597c9C09018BACa46fEACfCfB6386093` | 2026-09-14 |
| Sepolia | `PersonalAccountRemote` | `0xf4Cb397e97a99788014c74bA5B0356D1BcfDc84b` | 2026-09-14 |
| Sepolia | `MorphoLoanSubaccountRemote` | `0xA5E161DC265bb0fe50CAeE7A3772E72Fe3d8836F` | 2026-09-14 |

The Flare Personal Account deployed to Coston2 the same day
(`0x08A9a294FF6E8745FCd3B3Aeb5c4483ABA15C312`) is **not** here: its lineage already has a reference,
`build-info-v2.0.0`, and that deployment is an upgrade within it rather than a new lineage. That is
safe only because its layout is unchanged from v2.0.0 — checked, not assumed.

## build-info-2026-10-06

`MorphoLoanSubaccountRemote` re-frozen at its 2026-10-06 deployment, whose layout appends two fields
to the 2026-09-14 one: `feeBaseShares` and `feeBaseCollateral`, sharing slot 4 (the liquidation-fee
fix, `bb8b789`). Against the older reference a later implementation could drop them and still pass,
so this lineage's `validate-upgrade` clause points here (the rule below).

| | |
|---|---|
| Source commit | `06296415b9822c07b5981c4d5b7683cfa8ddbbc5` — its `contracts/` is what Sepolia's 2026-10-06 deployment was built from |
| Snapshot | `deployment/build-info-2026-10-06/7dd8b07abee18a00.json` |
| sha256 | `6ea5a13a110ad135504ffc7ba4459e2d81a6915c6537be020b70f8365d1ab3f5` |
| Compiler | solc 0.8.35, via-ir, optimizer 200 runs, cancun — the `foundry.toml` default profile, which `upgrade_validation` inherits |
| Toolchain | forge 1.8.3, the version CI pins since `1e69258` |
| Build | `FOUNDRY_PROFILE=upgrade_validation forge clean && FOUNDRY_PROFILE=upgrade_validation forge build contracts/smartAccounts/implementation/MorphoLoanSubaccountRemote.sol` |

The reproduction notes above apply unchanged: replay the snapshot's `input` key (three standard keys
kept) for byte-exact runtimes; the functional hash holds without a replay.

| Implementation | keccak256 of `deployedBytecode` (full) | keccak256 of the functional bytes | bytes | immutables |
|---|---|---|---:|---:|
| `MorphoLoanSubaccountRemote` | `0x26f73b65838a811bbd623a404fe42a5a3c1527be26275f30275a74eb1c04a2cf` | `0x7e66bb1a59db8d000705578be6128def07adac6b6cacf8951196cd3384c80fa8` | 17975 / 17922 | 0 |

### Deployments

| Chain | Implementation | Address | Matched |
|---|---|---|---|
| Sepolia | `MorphoLoanSubaccountRemote` | `0x681465D7f6CCf6E5E1b59ef85f1F3b4a344658fD` | 2026-10-06, byte for byte with the snapshot, metadata trailer included |

## The rule: freeze again whenever a DEPLOYED layout grows

A reference protects the layout it holds, not the layout a chain is running. Once a deployment
appends a field, the original reference no longer describes what is in the proxies, and a later
implementation can DELETE that appended field and still pass — against the original, both the
append and its removal are appends.

Measured against the installed validator on 2026-09-15, using `LoanSubaccount` and this directory as
its reference:

| Candidate | Against the reference | Against what would be deployed |
|---|---|---|
| appends `addedLater` | accepted, correctly | — |
| drops `addedLater`, appends `somethingElse` | **accepted** | a deleted field: a break |

So "keep the reference at the first production layout" is NOT the stricter choice, which is what an
earlier version of this file claimed. **Every deployment that changes a lineage's layout needs its
own frozen reference, and the validator must point at the newest one**, or the window between the
last freeze and the live layout is unprotected. Freezing is therefore part of deploying an
implementation, not a one-time setup — see RUNBOOK A6.
