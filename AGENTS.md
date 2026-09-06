# Flare Smart Accounts - Agents Guide

This document provides guidance for AI agents working in the `flare-smart-accounts` repository.

## Project Overview

This repository hosts two related on-chain modules.

### Flare Smart Accounts (`contracts/smartAccounts/`)

Flare Smart Accounts is an account abstraction protocol that lets XRPL users perform actions on Flare without holding FLR tokens. Each XRPL address gets a unique smart account on Flare, controlled exclusively through XRPL Payment transactions.

The system is implemented as an EIP-2535 Diamond proxy (`MasterAccountController`) that manages per-user `PersonalAccount`s linked to XRPL addresses. It supports FAsset minting and redeeming, vault deposits, and account abstraction through `IXRPPayment` proofs and XRPL memo instructions.

### FAsset Redeem Composer (`contracts/composer/`)

The FAsset Redeem Composer is a LayerZero-based module for cross-chain FAsset redemption. Users can initiate FAsset redemption from another chain through a LayerZero compose message, with per-redeemer deterministic accounts for isolation.

It is independent from Flare Smart Accounts, but shares the repository, governance patterns (`OwnableWithTimelock`), and FAsset interfaces.

## Tech Stack

- Solidity `^0.8.27`, compiled with solc 0.8.35
- Foundry (`forge`) for build, test, and coverage
- EVM target: Cancun (EIP-1153 transient storage supported)
- Optimizer enabled with 200 runs and `via_ir = true`
- Package manager: `pnpm`
- TypeScript runs directly through `tsx`

## Commands

### Setup

```bash
pnpm install
forge soldeer install
```

### Build and Test

```bash
forge build
forge test
forge test --match-contract <ContractName>
forge test --match-test <testName>
forge test -vvv --match-test <testName>
pnpm coverage
```

Verbosity can be increased with `-v`, `-vv`, `-vvv`, `-vvvv`, or `-vvvvv`.

### Lint, Format, and Type-Check

```bash
pnpm lint-sol
pnpm lint-sol-contracts
pnpm lint-sol-test
pnpm lint-sol-deployment
pnpm lint:check
pnpm lint:fix
pnpm format:check
pnpm format:fix
pnpm typecheck
pnpm spellcheck
```

Spellcheck uses cspell with the dictionary in `.vscode/cspell.json`; add legitimate new vocabulary there instead of ignoring findings. The CI job is advisory (`allow_failure: true`).

### Deployment

```bash
pnpm deploy_contracts <network> <fullDeploy>
pnpm deploy_personal_account_implementation <network>
pnpm diamond_cut <network> <cut-file-name>
pnpm check_cut <network> [cut-file-name] [--no-build]
pnpm deploy_composer <network>
pnpm verify_contracts <network>
```

- `<fullDeploy>` is a boolean (`true` or `false`). `false` skips initialization and is useful for diamond facets.
- Supported networks are `coston2`, `coston`, `flare`, `songbird`, and `scdev`, plus `-staging` variants such as `coston2-staging`.
- Deployment requires `.env` with `<NETWORK>_RPC_URL` and `DEPLOYER_PRIVATE_KEY`.
- All `forge script` invocations use `--offline` to skip Foundry's external selector/source lookups. Without it, runs on Flare/Songbird hang for several minutes — likely external signature/source database calls timing out for these chains. The chain RPC itself is unaffected.

### Required Checks

After every change, run the checks that match the touched area before considering work complete.

For Solidity or deployment-script changes:

```bash
pnpm lint-sol
forge build
pnpm coverage
pnpm build:upgrade-info && pnpm validate-upgrade   # when a proxy-backed implementation changed
```

Coverage target: **100% of lines, functions and branches** on every contract you touch. Branches
are the ones that slip: each `require`, `if` and short-circuit has an arm for both outcomes, and
reaching a guard that no production path can hit may need a harness (a mock exposing an internal
library, `vm.store` to clear or corrupt a slot, a parent mock that cannot receive native).
Comment such a test with why the guard is unreachable in production. Two caveats: `forge coverage`
mis-attributes branch arms inside modifiers (an arm can read as never taken while a test does
exercise it), and it reports 0/0 branches for files that have none.

For TypeScript changes:

```bash
pnpm lint:check
pnpm format:check
pnpm typecheck
```

## Project Structure

```text
contracts/
  smartAccounts/
    facets/          # Diamond facets (InstructionsFacet, VaultsFacet, MemoInstructionsFacet, etc.)
    implementation/  # MasterAccountController, PersonalAccount
    interface/       # Internal interfaces (II* prefix) for facet/library communication
    library/         # Core logic libraries (MemoInstructions, Instructions, Pause, etc.)
    proxy/           # PersonalAccountProxy (beacon proxy)
  composer/
    implementation/  # FAssetRedeemComposer, FAssetRedeemerAccount
    interface/       # Internal composer interfaces
    proxy/           # Composer proxies (UUPS + beacon)
  userInterfaces/    # Public API interfaces (I* prefix)
    facets/          # Public facet interfaces
  diamond/           # Diamond proxy infrastructure (EIP-2535)
  utils/             # Shared helpers (for example OwnableWithTimelock)
  mock/              # Test mocks
docs/specs/          # Protocol-level specification docs (per-module pages link to .sol sources)
test/
  unit/              # Per-module suites grouped like contracts/, plus deployment/tooling suites
  adversarial/       # Attack and ordering tests across whole flows, on both chains
  invariants/        # Stateful invariant campaigns (handlers live in utils/)
  fuzz/              # Property tests over the arithmetic and the gates
  utils/             # Fixtures, handlers and harnesses shared by the suites
deployment/
  chain-config/      # Per-network chain config JSON
  deploys/           # Deployed contract addresses per network
  build-info-v2.0.0/ # Reconstructed v2.0.0 build of the three live implementations: the upgrade validator's reference
  cuts/              # Diamond cut files per network
  scripts/           # Forge deploy scripts (.s.sol), bash wrappers, TS helpers
  utils/             # Deployment utility scripts
scripts/             # Repository utility scripts
audit/               # Security audit reports
```

Spec docs at [`docs/specs/`](./docs/specs/index.md) describe how the on-chain contracts fit together. Source files remain the source of truth — when you change behavior, update both.

## Architecture

### Diamond Proxy Pattern

`MasterAccountController` is the Diamond. It delegates to facets such as `InstructionsFacet`, `VaultsFacet`, `AgentVaultsFacet`, `MemoInstructionsFacet`, `ReaderFacet`, `PauseFacet`, `TimelockFacet`, and `ExecutorsFacet`. Facets are added or replaced through DiamondCut with timelock governance.

- Facets (`contracts/smartAccounts/facets/`) are thin entry points.
- Libraries (`contracts/smartAccounts/library/`) contain core business logic.
- Public interfaces live in `contracts/userInterfaces/` and use the `I` prefix.
- Internal interfaces live in `contracts/smartAccounts/interface/` and use the `II` prefix.

### Personal Accounts

Each XRPL user gets a `PersonalAccount` deployed as a beacon proxy (`PersonalAccountProxy`) through CREATE2. The beacon controller is the `MasterAccountController`. All personal accounts share one implementation but have isolated storage. The `onlyController` modifier restricts mutating entry points to the Diamond.

### FAsset Redeem Composer

The `composer/` module handles cross-chain FAsset redemption through LayerZero.

- `FAssetRedeemComposer` is UUPS upgradeable and implements `ILayerZeroComposer`.
- `FAssetRedeemerAccount` provides per-redeemer deterministic accounts through the beacon proxy pattern.

### Key Dependency Flow

```text
Facets -> Libraries -> Core Logic
  |
  v
PersonalAccount (beacon proxy) <- MasterAccountController (diamond)
```

### Instruction Flow

- Legacy path: XRPL payment -> FDC `IPayment.Proof` (`standardPaymentReference`) -> `InstructionsFacet` -> library routing -> `PersonalAccount` execution.
- Memo path: `handleMintedFAssets()` (direct minting with XRPL memo data) -> `MemoInstructionsFacet`.
- Memo instruction codes:
  - `0xFF`: execute UserOp with UserOp inlined in memo.
  - `0xFE`: execute UserOp with data; memo carries `keccak256(_data)` and UserOp arrives through `_data`.
  - `0xE0`: ignore memo.
  - `0xE1`: increase nonce.
  - `0xE2`: replace fee.
  - `0xD0`: set executor.
  - `0xD1`: remove executor.
- Transaction ID tracking uses `usedTransactionIds` in `Instructions.State`, shared by legacy and memo paths.
- Memo instruction nonce increments only on successful execution because XRPL transactions are irreversible and proofs must be retryable.
- `PauseFacet` provides separate pauser and unpauser roles. State-modifying functions in `InstructionsFacet` and `MemoInstructionsFacet` use `notPaused`.

## Code Conventions

### Solidity

- Use Solidity `^0.8.27`.
- Use named imports only, for example:

```solidity
import {ContractRegistry} from "flare-periphery/src/flare/ContractRegistry.sol";
```

- Contracts and libraries use `PascalCase`.
- Functions and variables use `camelCase`.
- Function parameters are prefixed with `_`.
- Constants use `UPPER_CASE_WITH_UNDERSCORES`.
- Use custom errors instead of revert strings.
- Use NatSpec (`/// @notice`, `/// @dev`) on public interfaces and complex logic.
- Use `ReentrancyGuardTransient` for state-changing external calls where appropriate.
- Use `SafeERC20` for token transfers.
- Keep facets thin; put core logic in libraries.
- Use `onlyController` on `PersonalAccount` functions that must only be called through the Diamond.
- Use `onlyOwner` or `onlyOwnerWithTimelock` on admin facet functions.

Formatting style:

- Prettier with `prettier-plugin-solidity`.
- Prettier settings use print width 80, tab width 4, and double quotes.
- Maximum Solidity line length: 119 characters.
- Function parameters go each on their own line.
- Visibility and mutability go on their own indented line after params.
- Opening brace goes on its own line after visibility.
- Never run `forge fmt` (or Prettier) over `.sol` files; format Solidity by hand to these conventions.
- Every `if`, `else`, `for` and `while` body goes in braces on its own lines, even a lone `return`: a
  brace-less body silently runs a later second statement unconditionally, and `forge coverage` line reports
  cannot show an untaken early return that shares its line with the condition.

Example:

```solidity
function doSomething(
    uint256 _value,
    address _target
)
    external view
    returns (uint256)
{
    ...
}
```

Storage uses ERC-7201 namespaced storage:

```solidity
keccak256(abi.encode(uint256(keccak256("smartAccounts.LibName.State")) - 1)) & ~bytes32(uint256(0xff))
```

### TypeScript

- Use ES modules syntax (`import ... from ...`).
- Run TS files directly through `tsx`.
- `tsconfig.json` targets `es2024`, `module: Node20`, strict mode, `noUncheckedIndexedAccess`, `exactOptionalPropertyTypes`, and `noEmit`.
- Maximum TypeScript line length: 120 characters.
- Use ESLint (`pnpm lint:check`) and Prettier (`pnpm format:check`).

### Testing

- Tests live in `test/`, grouped by kind, and use `forge-std` `Test`:
  - `test/unit/<module>/`: the per-module suites, grouped like `contracts/` (`smartAccounts`, `composer`, `vaults`)
    plus `deployment` for the deploy scripts and cut tooling; mostly one file per contract, with the pinning
    suites (storage layout, init code, Morpho conformance) beside them.
  - `test/adversarial/`: attack and ordering tests across whole flows; every test names the attack it rules out.
  - `test/invariants/`: stateful invariant campaigns, bounded and with a fixed seed; a smoke test pins that every
    handler path executes.
  - `test/fuzz/`: property tests, each stated as the spec's formula computed independently of the contract.
  - `test/utils/`: fixtures, handlers and harnesses shared by the suites. Mocks live in `contracts/mock/`. Both are
    excluded from the coverage figure.
- Test files are named `<ContractName>.t.sol`; a suite that is not about one contract names its subject
  (`LoanFeeFuzz.t.sol`).
- Test contracts are named `<ContractName>Test`.
- Use `setUp()` for initialization.
- Use `vm.mockCall`, `vm.prank`, `vm.deal`, `vm.expectRevert`, `vm.expectEmit`, `assertEq`, and `assertTrue`.
- Test function naming:
  - `testFeatureName` for success cases.
  - `testFeatureNameRevertReason` for reverts.

## Deployment Notes

- Chain configs: `deployment/chain-config/<network>.json`
- Deployed addresses: `deployment/deploys/<network>.json`
- Diamond cut files: `deployment/cuts/<network>/`
- Internal diamond-cut outputs: `deployment/output-internal/`

Diamond cut files can list all candidate facets. `ExecuteDiamondCut.s.sol` checks the previously deployed address in `deployment/deploys/<network>.json` and reuses it when functional deployed bytecode matches the freshly compiled artifact. The comparison ignores the facet's own trailing Solidity metadata, so unrelated metadata-only rebuilds should not force redeployment.

Facets that inline `PersonalAccounts` address-derivation logic (`PersonalAccountsFacet`, `InstructionsFacet`, `ReaderFacet`, `MemoInstructionsFacet`) bake the frozen `PROXY_CREATION_CODE` constant into their runtime bytecode. Because it is a constant, those bytes do not drift across rebuilds, so `check_cut` does not flag these facets for redeployment on unrelated metadata churn — only genuine logic changes trigger a redeploy. The embedded bytes change only if the constant itself is edited, which is a cross-chain coordination event: predicted addresses for not-yet-deployed Personal Accounts shift and must be recomputed after such a cut.

There are two valid ways to prepare the `facets` list:

- For the safest review flow, list all candidate facets and let the script reuse unchanged deployments.
- For a smaller cut file, first run `pnpm check_cut <network> [cut-file-name]` and include only facets reported as `ADD` or `REPLACE`.

Do not rely only on the source import graph, since internal libraries, interfaces, compiler settings, and embedded creation code can change facet bytecode.

Before executing a cut, run `pnpm check_cut <network> [cut-file-name]` to preview the full cut plan. It reports three sections:

- **Facets (deploy):** each facet as `ADD` (in the cut, not yet deployed), `REPLACE` (deployed but functional runtime bytecode differs), `REUSE` (deployed and unchanged — trailing Solidity metadata differences are ignored), or `REMOVE` (no longer in the source tree). `REMOVE` is decided by source-file presence, not artifact presence, so a leftover artifact from a deleted facet (`forge build` does not prune those) cannot hide a removal — when one is detected the reason tells you to run `forge clean`. Pass a cut file so facets you intend to add are detected as `ADD`; without one the scope is limited to already-deployed facets.
- **Selectors to remove:** live diamond selectors that no longer exist on any facet in current source. Each is marked `listed` (already in `deleteSelectorSigs`, so the cut removes it) or flagged as needing review; add only intentionally removed selectors to `deleteSelectorSigs`, and leave selectors out when they should remain live through an older facet. Entries accept either a 4-byte hex selector (e.g. `"0xe8a6eec2"`) or a canonical function signature (e.g. `"mintedFAssets(bytes32,string,uint256,uint256,bytes,address)"`); signatures are hashed to selectors at cut-build time. Signatures for orphaned selectors are resolved best-effort from local cut data and git history, and both live and currently deployed facet addresses are printed when the historical facet can be identified.
- **Moved selectors:** live diamond selectors that still exist in the repo but on a _different_ facet (e.g. a function relocated to a new facet). These are reported as `MOVE`, not deletions — repoint them by adding that facet to the cut's `facets` (they become `Replace`); do **not** add them to `deleteSelectorSigs`, which would drop a live function. The tool warns loudly if a moved selector is already wrongly listed in `deleteSelectorSigs`.

## External Dependencies

Dependencies are managed through Soldeer (`foundry.toml [dependencies]`).

- `@openzeppelin-contracts` 5.5.0: standard OpenZeppelin contracts
- `@openzeppelin-contracts-upgradeable` 5.5.0: upgradeable variants used by composer UUPS
- `flare-periphery` 0.1.52: Flare chain contract registry, FDC, and FAsset interfaces
- `@layerzerolabs-oft-evm` 4.0.1: LayerZero OFT used by `FAssetRedeemComposer`
- `@layerzerolabs-lz-evm-protocol-v2` 3.0.159: LayerZero V2 protocol primitives
- `@layerzerolabs-oapp-evm` 0.4.1: LayerZero OApp primitives (the canonical `IOFT`)
- `forge-std` 1.10.0: Foundry test utilities

`morpho-blue` is deliberately **not** a dependency: its interfaces and libraries are GPL-2.0-or-later and this
repository is MIT. The Morpho surface the accounts use is our own code (`contracts/smartAccounts/interface/IMorpho.sol`,
`contracts/smartAccounts/interface/IOracle.sol`, `contracts/smartAccounts/library/MorphoMath.sol`), pinned to upstream
v1.0.0 by `test/unit/smartAccounts/MorphoConformance.t.sol` (selectors, return schemas, the live market id,
share-math vectors). Do not add a Morpho import anywhere.

### Proxy storage layouts

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

## Commits

Follow [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/). Do not add `Co-authored-by` lines.

Always include a commit body explaining what changed and why.

| Type | When to use |
| ---- | ----------- |
| `feat` | Adding new features or functionality |
| `fix` | Fixing a bug |
| `refactor` | Restructuring code without changing behavior |
| `test` | Adding or updating tests |
| `docs` | Documentation changes |
| `chore` | Maintenance tasks, dependencies, tooling |
| `ci` | CI/CD pipeline changes |
| `chore(release)` | Creating a release |
| `chore(deploy)` | Updating deploy parameters and scripts |

`fix`, `feat`, and `refactor` modify production or audit-scoped code. `chore` and `test` should not modify audit-scoped files.
