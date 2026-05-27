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

- Solidity `^0.8.27`, compiled with solc 0.8.30
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
```

### Deployment

```bash
pnpm deploy_contracts <network> <fullDeploy>
pnpm deploy_personal_account_implementation <network>
pnpm diamond_cut <network> <cut-file-name>
pnpm check_facet_redeploys <network> [cut-file-name] [--no-build]
pnpm check_stale_selectors <network> [cut-file-name] [--no-build]
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
```

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
test/                # Foundry tests
deployment/
  chain-config/      # Per-network chain config JSON
  deploys/           # Deployed contract addresses per network
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

- Tests live in `test/` and use `forge-std` `Test`.
- Test files are named `<ContractName>.t.sol`.
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

Facets that inline `PersonalAccounts` creation or address-derivation logic can embed `type(PersonalAccountProxy).creationCode` into their runtime bytecode. If the embedded proxy creation code changes, including its metadata, those facets may be redeployed even when their source files did not change. This keeps on-chain Personal Account address derivation consistent; predicted addresses for not-yet-deployed Personal Accounts should be recomputed after such a cut.

There are two valid ways to prepare the `facets` list:

- For the safest review flow, list all candidate facets and let the script reuse unchanged deployments.
- For a smaller cut file, first run `pnpm check_facet_redeploys <network> [cut-file-name]` and include only facets reported as `REDEPLOY`.

Do not rely only on the source import graph, since internal libraries, interfaces, compiler settings, and embedded creation code can change facet bytecode.

Before executing a cut, run `pnpm check_stale_selectors <network> [cut-file-name]` to find selectors that are live in the diamond but absent from current artifact ABIs. Review selectors reported as `REVIEW`; add only intentionally removed selectors to `deleteSelectorSigs` in the cut JSON, and leave selectors out when they should remain live through an older facet. `deleteSelectorSigs` entries accept either a 4-byte hex selector (e.g. `"0xe8a6eec2"`) or a canonical function signature (e.g. `"mintedFAssets(bytes32,string,uint256,uint256,bytes,address)"`); signatures are hashed to selectors at cut-build time. The checker always compares against all deployed facet artifacts, even when the cut file lists only a minimal facet subset, resolves function signatures on a best-effort basis from local cut data and git history, and prints both live and currently deployed facet addresses when the historical facet can be identified.

## External Dependencies

Dependencies are managed through Soldeer (`foundry.toml [dependencies]`).

- `@openzeppelin-contracts` 5.5.0: standard OpenZeppelin contracts
- `@openzeppelin-contracts-upgradeable` 5.5.0: upgradeable variants used by composer UUPS
- `flare-periphery` 0.1.44-alpha.6: Flare chain contract registry, FDC, and FAsset interfaces
- `@layerzerolabs-oft-evm` 4.0.1: LayerZero OFT used by `FAssetRedeemComposer`
- `@layerzerolabs-lz-evm-protocol-v2` 3.0.159: LayerZero V2 protocol primitives
- `forge-std` 1.10.0: Foundry test utilities

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
