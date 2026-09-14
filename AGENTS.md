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

- The ordered, verified release sequence — which governance call to make when, and what proves each step landed — is [`deployment/RUNBOOK.md`](./deployment/RUNBOOK.md). The commands below are its building blocks; the runbook is what says in which order to run them and on which networks.
- `<fullDeploy>` is a boolean (`true` or `false`). **Both modes are a full deployment from current source** — `false` only skips the diamond cut, the init and the vault/wallet configuration — so neither is a facet-only mode or for a live network. To add or replace facets on a live network, use a cut file and `pnpm diamond_cut`. Why, and the recorder's guard on the two live entries, are in [`deployment/README.md`](./deployment/README.md).
- Supported networks are the Flare family `coston2`, `coston`, `flare` and `songbird`, with `-staging` variants such as `coston2-staging`, and the loan chains `ethereum` and `sepolia` (its testnet), whose one tracked deployment is the pinned one and which have no staging alias. Sepolia also takes a throwaway deployment for rehearsals (`deploy_remote_controller_throwaway`), recorded in the gitignored `sepolia_mock` record, which only `configure_remote_controller` reads, and only when its target argument says `throwaway`. A chain in neither family is refused by every tool; the rules are in [`deployment/README.md`](./deployment/README.md#networks).
- Deployment requires `.env` with `<NETWORK>_RPC_URL` and `DEPLOYER_PRIVATE_KEY`.
- `configure_remote_controller` is everything the remote controller is configured with after its cut, read from
  `deployment/chain-config/<network>.json`: the sections are `governance` (the pauser and unpauser roles, then
  the timelock duration last), `implementations`, `transport`, `market`, `fees`, `wiring` (the last
  three) and `all`, defaulting to `governance`, and the target is `pinned` or `throwaway` — which
  controller on that chain to configure, named
  rather than assumed, defaulting to `pinned`. `prepare` writes the calls for the owner to submit under `deployment/output-internal/<network>/`
  and prints them, with the `executeTimelockedCall` line beside each one once a duration is in force; `execute`
  submits them and needs the diamond's current owner to sign, so it serves the throwaway flow alone — its own
  read-back sees simulated state, so the wrapper follows a broadcast with a separate `verify` run; `verify`
  reads the chain back. `implementations` is the one section whose two addresses are not in the chain config:
  the remote Personal Account and the type's remote subaccount are deploy outputs, read from the target's own
  deployment record, and a record naming neither leaves the section unready. It is also the one section
  whose calls are FILTERED against the chain: a registration the diamond has already made is skipped with a
  note, because the deploy reuses an implementation whose code has not changed and re-registering the address
  the diamond already serves costs a timelocked call, three signatures and an execution to change nothing.
  `prepare` and `execute` skip the same ones; a registry that cannot be read yet (the facet is not cut) filters
  nothing, and a registry pointing at an address the config does not name is never filtered, since the
  registration is how that disagreement gets resolved. No other section is filtered: re-registering a market is
  refused on chain and a different one is a disagreement a person must see, the transport and the fee terms are
  legitimately re-set to the same values, and the duration is every run's last call. It registers; it does not
  replace `verify_implementation --stage pre`, which is the check that can still refuse a wrong address before
  it is registered. A section named on its own must be complete in the file; a sweep skips an incomplete one
  with a note. Only `execute` takes a signing key: the other two read, and a multisig owner has nothing to sign
  with anyway.
- `describe_calls` names the parameters of the calls `prepare` wrote. It reads the file under
  `deployment/output-internal/<network>/`, makes no chain call and takes no key, and prints one
  `name = value` line per parameter. A STRUCT is one parameter whose value is the bracketed form a
  governance sheet cell and the Safe Transaction Builder both take
  (`_market = ["0xd011...",["0x1B5A...",...,"770000000000000000"]]`), nested to any depth and in
  declaration order. EVERY scalar inside the brackets is quoted, integers included: the builder
  parses them with `JSON.parse` and takes a decimal string for any integer field, while a bare
  integer is read as a double and is exact only to about 9.0e15 in either direction. A top-level
  scalar stays plain, since its own cell is not JSON. `--sheet` emits the pairs tab separated for
  pasting, naming a selector it could not decode rather than leaving the row looking argument-free; `--flat`
  gives one line per leaf, walking arrays with an index (`_cuts[0].facetAddress`), for reading a
  call rather than pasting it. The names come from the compiled ABI, searched internal interfaces
  first because a selector fixes the signature but not the parameter names, so the decode is a
  SECOND SOURCE on what was encoded rather than a restatement of the inputs. The suite needs a
  `forge build`; without artifacts it skips, and `REQUIRE_FORGE_TOOLING` turns that into a failure,
  which is how the Foundry CI job demands it run.
- `deploy_remote_account_implementations` takes a mandatory selection: `all`, or a comma-separated
  list of `personal-account` and `morpho-loan-subaccount`. Names rather than a flag each, so a new
  subaccount type is a new name rather than a moved argument. A preflight
  (`plan-remote-implementations.ts`) compares each named implementation's recorded address against
  the artifact, modulo the runtime's trailing metadata as the cut planner does, and SKIPS one that
  already carries this code — a successful skip, so `all` can deploy one and reuse the rest, and a
  run that deploys nothing leaves the record untouched and never reaches the recorder. Reuse is not
  registration: the plan reports what the diamond's registry holds separately, and where the record
  and the registry name different addresses it says so rather than choosing.
- `transfer_ownership` hands the pinned remote controller to a new owner, and exists for the preflight rather
  than the call: `transferOwnership` is one step, has no acceptance from the new owner, is not timelocked, and a
  wrong address ends that diamond's governance for good. The expected current owner is an argument, compared
  against the chain, so a run pointed at the wrong network stops instead of handing away whatever it found; the
  signing key must be that owner; the zero address, the diamond itself and the current owner are refused, and a
  new owner with no code is called out rather than refused. It serves the deployer-owned handover alone - the
  bootstrap owner signs its own transfer from a wallet, and a throwaway is never handed on - so there is no
  target argument. The broadcast is followed by a separate `verify` run, since the script's own read-back would
  see simulated state.
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
which is what the Foundry-equipped `test-tooling-forge` job does, since the node-only job cannot run it) and the
shell scenarios of the cut wrapper, the configuration wrapper and the market wrapper. They live under `test/` like
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
  build-info-v2.0.0/ # Reconstructed v2.0.0 build of the three live implementations: the upgrade validator's reference
  cuts/              # Diamond cut files per network
  market-config/     # The Sepolia rehearsal market's parameters: our test loan token and feeds, the oracle, the market, its liquidity
  lib/               # Solidity the scripts share: the network table, the pinned Ethereum init code, the type allocations, the config decode structs
  scripts/           # Forge deploy scripts (.s.sol), bash wrappers, TS helpers - no tests
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
  - `test/invariants/`: stateful invariant campaigns, bounded and with a fixed seed; a smoke test pins that every
    handler path executes.
  - `test/fuzz/`: property tests, each stated as the spec's formula computed independently of the contract.
  - `test/integration/`: suites against contracts we did not write — either real deployed ones on a pinned mainnet
    fork, or canonical ones deployed locally. `MorphoLoanSubaccountRemoteCanonicalCompose.t.sol` is the second kind: it
    runs the loan account against LayerZero's own `MessagingComposer` (`contracts/mock/CanonicalComposeEndpoint.sol`
    is that contract verbatim plus an `eid` getter), because the compose queue's rules are relied on rather than
    implemented. Both files are `--skip`ped by `pnpm coverage`: LayerZero's composer does not compile with the
    optimizer disabled, which is how `forge coverage` builds. `test/unit/deployment/DeploySmartAccountsGuards.t.sol`
    and `test/unit/deployment/DeployRemoteControllerThrowaway.t.sol` are skipped for the same class of reason:
    `DeploySmartAccounts` copies a memory array of structs into storage, which only the IR pipeline compiles
    (solc 1834), and `DeployRemoteControllerThrowaway` assembles the controller's constructor arguments, which
    without the IR pipeline is stack-too-deep - so a test importing either cannot build under coverage. Deploy
    scripts are pruned from the figure anyway, so the skips cost nothing. The fork suites skip themselves
    unless the network they need is configured, so an offline run is inert rather than failing;
    `MorphoLoanSubaccountRemoteFork.t.sol` needs `ETHEREUM_RPC_URL` to name an endpoint that serves state at its
    pinned block (an archive read), and runs with
    `ETHEREUM_RPC_URL=<url> forge test --match-path "test/integration/*"`. Most free tiers prune that far back;
    `https://eth-pokt.nodies.app` served it on 2026-09-09, and `cast block <FORK_BLOCK> --rpc-url <url>` plus one
    `eth_call` at that block is the quickest way to test a candidate before running the suite.
    `SepoliaMarketFork.t.sol` needs `SEPOLIA_RPC_URL` - any current Sepolia endpoint, since it forks the latest
    block - and drives the rehearsal market script's phases against Morpho's real oracle factory and Morpho itself.
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

How the tooling works — the cut planner (`check_cut`), the diamond verifier before and after a cut
(`verify_diamond`), the implementation registration check (`verify_implementation`), the recorder's
guard on the live entries and the frozen creation-code rule that keeps cut plans stable — is
[`deployment/README.md`](./deployment/README.md). The ordered release sequence is
[`deployment/RUNBOOK.md`](./deployment/RUNBOOK.md).

Two of its rules bind code changes. The facets that inline the `PersonalAccounts` or `Subaccounts`
address derivation bake the frozen `PROXY_CREATION_CODE` constants into their runtime bytecode, so
editing one of those constants is a cross-chain coordination event: predicted addresses for
not-yet-deployed accounts of that kind shift and must be recomputed after such a cut. And never decide
what a cut must redeploy from the source import graph — internal libraries, interfaces, compiler
settings and embedded creation code all change facet bytecode; run `pnpm check_cut <network>
[cut-file-name]` before executing any cut.

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

The three live implementations — the Flare Personal Account, `FAssetRedeemComposer` and
`FAssetRedeemerAccount` — are checked against the reconstructed v2.0.0 reference in
`deployment/build-info-v2.0.0/`; the remote Personal Account and both loan subaccounts have no proxy
on any network yet and run only the checks that need no reference. Before re-laying one of those
layouts, check the lineage is still empty with `pnpm check_lineage_fresh <network> [subaccounts|personal-accounts]`.
How the reference was reconstructed, what the validator's two expected findings mean (the waived
constructors, the diamond libraries' namespace warnings), how the lineage check decides, and what to
copy at a lineage's first production deployment are in [`deployment/README.md`](./deployment/README.md).
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
