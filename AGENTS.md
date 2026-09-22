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
pnpm deploy_loan_subaccount_implementation <network>
pnpm deploy_remote_account_implementations <network> <all|name[,name...]>
pnpm deploy_remote_controller_pinned <network>
pnpm deploy_remote_controller_throwaway <network>
pnpm configure_remote_controller <network> <prepare|execute|verify> [section] [target]
pnpm describe_calls <network> [section] [--sheet] [--flat]
pnpm transfer_ownership <network> <expected-current-owner> <new-owner>
pnpm deploy_sepolia_market <assets|market|fund|reset-feeds>
pnpm diamond_cut <network> <cut-file-name>
pnpm check_cut <network> [cut-file-name] [--no-build]
pnpm check_lineage_fresh <network> [subaccounts|personal-accounts]
pnpm verify_diamond <network> [cut-file-name] [--pre-cut] [--expect-owner <address>] [--no-build]
pnpm verify_implementation <network> <Contract> <address> [--stage pre|queued|live] [--xrpl-owner <owner>] [--no-build]
pnpm deploy_composer <network> <onlyImpl>
pnpm verify_contracts <network>
```

- The ordered, verified release sequence — which governance call to make when, and what proves each step landed — is [`deployment/RUNBOOK.md`](./deployment/RUNBOOK.md). The commands above are its building blocks; the runbook says in which order to run them and on which networks. How each tool decides what it does is [`deployment/README.md`](./deployment/README.md).
- `<fullDeploy>` is a boolean. **Both modes are a full deployment from current source** — `false` only skips the diamond cut, the init and the vault/wallet configuration — so neither is a facet-only mode nor for a live network. To add or replace facets on a live network, use a cut file and `pnpm diamond_cut`.
- Networks are the Flare family (`coston2`, `coston`, `flare`, `songbird`, plus `-staging` variants) and the loan chains `ethereum` and `sepolia`. A chain in neither family is refused by every tool. See [Networks](./deployment/README.md#networks).
- Deployment needs `<NETWORK>_RPC_URL` in an environment file and something to sign with. A **keystore** (`--account <name> --sender <address>`) or a **Ledger** (`--ledger --sender <address>`) REPLACES `DEPLOYER_PRIVATE_KEY`, which is only the fallback when nothing else signs. Never pass `--quiet`/`-q`/`--json` to a wrapper whose output the recorder parses: forge broadcasts before the recorder runs, so silencing it deploys a contract no record then names. `deployment/scripts/signer-preflight.sh` enforces both rules; the reasoning is in [Signing](./deployment/README.md#signing). **A Solidity deploy script takes its signer from forge, never from the environment**: it broadcasts as `_signer()`, which is `msg.sender`, so nothing in the script outranks what the command line chose. Never read `DEPLOYER_PRIVATE_KEY` inside a script.
- `configure_remote_controller <network> <prepare|execute|verify> [section] [target]` applies everything a remote controller is configured with after its cut, from `deployment/chain-config/<network>.json`. `prepare` writes calls for the owner to submit, `execute` signs them (the throwaway flow only), `verify` reads the chain back. `implementations` is the one section read from the deployment record rather than the config, and the one filtered against the chain. Details in [Configuring the remote controller](./deployment/README.md#configuring-the-remote-controller-configure_remote_controller).
- `describe_calls` names the parameters of the calls `prepare` wrote, decoding them against the compiled ABI as a second source on what was encoded. `--sheet` formats them for a governance sheet.
- `deploy_remote_account_implementations` takes a mandatory selection and skips an implementation whose recorded address already carries the current code, so naming `all` can legitimately deploy one and reuse the rest.
- `transfer_ownership` exists for its preflight: `transferOwnership` applies at once, the new owner never accepts it and no timelock delays it, so a wrong address ends that diamond's governance for good.
- All `forge script` invocations use `--offline`. Without it, runs on Flare/Songbird hang for minutes on external selector/source lookups; the chain RPC itself is unaffected.

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

For TypeScript or deployment-tooling changes:

```bash
pnpm lint:check
pnpm format:check
pnpm typecheck
pnpm test:tooling
```

`test:tooling` runs everything in `test/tooling/`: the node tests of the deployment utilities, the verifier CLI's
own test against a fake JSON-RPC server, the recorder's and the explorer submission's tests (the latter against a
stubbed `forge`, so the argument vector itself is pinned), the market script's own output against a local chain
answering with Sepolia's id (`deploy-sepolia-market.output.test.ts`, which needs `anvil`, `forge` and no Sepolia
deployment record, skips without them, and turns those skips into a failure when `REQUIRE_FORGE_TOOLING` is set -
which is what the Foundry-equipped `test-tooling-forge` job does, since the node-only job cannot run it), the cut
executor's own output against a local chain answering with Coston2's id (`execute-diamond-cut.output.test.ts`, the
same shape and the same gate: the record lines it prints are observable nowhere else, forge swallowing console
output before a cheatcode can see it) and the shell scenarios of the cut wrapper, the configuration wrapper and
the market wrapper. They live under `test/` like
every other suite and are held to the same lint rules as the tooling they exercise, not the looser ones the shared
config gives `test/**/*.ts` - `eslint.config.mjs` exempts this directory from that relaxation. Run them from the
repository root: several read pinned sources by a path relative to it. CI runs the script too.

For shell scripts:

```bash
shellcheck deployment/scripts/*.sh scripts/*.sh test/tooling/*.sh
```

CI runs the same check (the shared `lint-shell` component) and fails the pipeline on any finding, informational
ones included. Silence a deliberate one with a `# shellcheck disable=SC<code>` directive above the line and a
comment saying why; never by loosening the job.

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
  tooling/           # The deployment tooling's own node and shell tests (TypeScript, not forge)
  utils/             # Fixtures, handlers and harnesses shared by the suites
deployment/
  chain-config/      # Per-network chain config JSON
  deploys/           # Deployed contract addresses per network
  build-info-v2.0.0/ # Reconstructed v2.0.0 build of the three implementations live before this release
  build-info-2026-09-14/ # The three lineages first deployed 2026-09-14; both are the upgrade validator's references, recorded in reference-builds.md
  pinned-verification/ # Recovered solc 0.8.30 inputs that verify the pinned-init-code contracts on Etherscan
  cuts/              # Diamond cut files per network
  market-config/     # The Sepolia rehearsal market's parameters: our test loan token and feeds, the oracle, the market, its liquidity
  lib/               # Solidity the scripts share: the network table, the pinned Ethereum init code, the type allocations, the config decode structs
  scripts/           # Forge deploy scripts (.s.sol), bash wrappers, TS helpers - no tests;
                     #   signer-preflight.sh is sourced by every wrapper that broadcasts, and
                     #   deploy-output-preflight.sh by every wrapper that tees a run to the recorder
  utils/             # Deployment utility scripts - no tests; both are tested from test/tooling/
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
- Comments describe the code as it is, and why. History — what a line replaced, how a flaw was found — belongs in the commit message. A test may name the failure it rules out, in the present conditional.
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
  cannot show an early return that was never taken when it shares its line with the condition.

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
  - `test/invariants/`: stateful invariant campaigns, bounded and with a fixed seed. The smoke test establishes
    handler reachability; it does not prove which paths the random campaign reaches. Targeted fuzz sequences in
    `LoanFeeInvariants.t.sol` require rare fee transitions across randomized inputs, asserting action counts and
    all invariants at intermediate states. Do not require every rare outcome in each ordinary invariant run.
  - `test/fuzz/`: property tests, each stated as the spec's formula computed independently of the contract.
  - `test/integration/`: suites against contracts we did not write — real deployed ones on a pinned mainnet
    fork, or canonical ones deployed locally, including LayerZero's own composer and OFT contracts. Several
    reach outside the repository and several are `--skip`ped by `pnpm coverage`; which, what each needs and
    why is [`test/README.md`](./test/README.md). A fork suite skips itself unless its network is configured,
    so an offline run is inert rather than failing, and a `REQUIRE_*` variable turns that skip into a failure
    where CI must not let a check go unmade.
  - `test/tooling/`: the deployment tooling's own tests, in TypeScript and shell rather than Solidity, run by
    `pnpm test:tooling` rather than by forge, which ignores them. They sit here rather than beside the scripts so
    that `deployment/` holds only what an operator runs, and they are held to the tooling's lint rules, not the
    looser ones the shared config applies to `test/**/*.ts`.
  - `test/utils/`: fixtures, handlers and harnesses shared by the suites. Mocks live in `contracts/mock/`. Both are
    excluded from the coverage figure. `LoanForkFixture` is `LoanRemoteFixture` with the loan market's real
    contracts behind it (canonical Morpho Blue, the live FXRP/RLUSD market, its oracle and adaptive rate model,
    the real tokens); only the delivery rail stays mocked.
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

How each tool decides what it does is [`deployment/README.md`](./deployment/README.md); the ordered
release sequence is [`deployment/RUNBOOK.md`](./deployment/RUNBOOK.md).

Three rules bind what you may write.

**No deploy script writes the deployment record.** A script prints a `DEPLOYED:` line, the wrapper
tees it, and the record is written only after forge exits — because `forge script` simulates the
whole run before broadcasting, and a filesystem write is not EVM state, so a record written from
inside a script survives the failure of the run that computed it. Never add one. See
[Nothing is recorded until the chain has it](./deployment/README.md#nothing-is-recorded-until-the-chain-has-it).

The facets that inline the `PersonalAccounts` or `Subaccounts`
address derivation bake the frozen `PROXY_CREATION_CODE` constants into their runtime bytecode, so
editing one of those constants is a cross-chain coordination event: predicted addresses for
not-yet-deployed accounts of that kind shift and must be recomputed after such a cut.

Never decide what a cut must redeploy from the source import graph — internal libraries, interfaces,
compiler settings and embedded creation code all change facet bytecode. Run `pnpm check_cut
<network> [cut-file-name]` before executing any cut.

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
`IIrm.sol`, `IOracle.sol` and `contracts/smartAccounts/library/MorphoMath.sol`), pinned to upstream v1.0.0 by
`test/unit/smartAccounts/MorphoConformance.t.sol` (selectors, return schemas, the live market id, share-math and
compounding vectors). Do not add a Morpho import anywhere.

### Proxy storage layouts

Proxies keep their storage across upgrades, so every implementation in a proxy's chain-local
lineage must preserve that proxy's layout: append fields, never insert, reorder or retype. The
OpenZeppelin upgrade-safety validator gates this, locally and in CI (`upgrade-build-info` +
`validate-upgrade`):

```bash
pnpm build:upgrade-info && pnpm validate-upgrade
```

All six live lineages run with `--requireReference` against a frozen build; which directory each uses
and what it matches is [`deployment/reference-builds.md`](./deployment/reference-builds.md), and the
two expected validator findings, how the lineage check decides and what to freeze at a first
deployment are in [`deployment/README.md`](./deployment/README.md). Before re-laying a layout, check
the lineage is still empty with `pnpm check_lineage_fresh <network> [subaccounts|personal-accounts]`.

The rule the account bases follow — controller at slot 0 in every lineage, `xrplOwner` at slot 1 in
every Personal Account lineage, every other base field in an ERC-7201 namespace — stays pinned by
`test/unit/smartAccounts/AccountStorageLayout.t.sol`, which pins the cross-lineage layout rule the
validator does not compare (it checks each lineage only against its own reference).

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

## The changelog

`CHANGELOG.md` describes the release, so **every entry is the delta against `main`** — what someone upgrading from
the last release gets — never the delta against an earlier commit of the branch it is written on. A branch that
adds something and then reworks it carries one entry describing what finally landed, not two describing the
journey; a branch that changes something it introduced since the last release edits its own entry rather than
adding a second. A change that leaves the released behavior untouched has no entry at all.

Keep the entries one line each, and leave out what a reader of the release does not act on: tests, refactors with
no behavioral change, and deployment tooling beyond a line naming it.
