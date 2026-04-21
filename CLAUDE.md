# Flare Smart Accounts

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Flare Smart Accounts (FSA) is an account abstraction protocol enabling XRPL users to perform actions on the Flare blockchain without holding FLR tokens. Each XRPL address gets a unique smart account on Flare, controlled exclusively through XRPL Payment transactions.

The system is implemented as a Diamond proxy (EIP-2535) — `MasterAccountController` — that manages per-user `PersonalAccount`s linked to XRPL addresses. It supports FAsset minting/redeeming, vault deposits, and Account Abstraction via `IXRPPayment` proofs.

## Tech Stack

- **Solidity** ^0.8.27, compiled with solc 0.8.30
- **Foundry** (forge) for build, test, coverage
- **EVM target:** Cancun (EIP-1153 transient storage supported)
- **Optimizer:** enabled, 200 runs, `via_ir = true`
- **Package manager:** pnpm

## Commands

```bash
# Setup
pnpm install              # install node dependencies
forge soldeer install     # install Solidity dependencies

# Build & Test
forge build                              # compile contracts
forge test                               # run all tests
forge test --mc <ContractName>           # run tests for a specific contract
forge test --mt <testName>               # run a specific test function
forge test -vvv --match-test <testName>  # run specific test with traces
pnpm coverage                            # coverage report (lcov + genhtml)

# Linting & Formatting
pnpm lint-sol                # solhint on contracts, tests, deployment
pnpm lint-sol-contracts      # lint only contracts/
pnpm lint-sol-test           # lint only test/
pnpm lint:check              # ESLint on TypeScript
pnpm format:check            # Prettier check on TS/JS

# Deployment
pnpm deploy_contracts <network> <fullDeploy>   # e.g. pnpm deploy_contracts coston2 true
pnpm diamond_cut <network> <cut-file-name>     # execute a diamond cut upgrade
pnpm deploy_composer <network>                 # deploy FAsset redeem composer
pnpm verify_contracts <network>                # verify contracts on Blockscout
```

**After every change, run these checks before considering work complete:**
1. `pnpm lint-sol` — ensure no lint errors (warnings are acceptable)
2. `forge build` — ensure compilation succeeds
3. `pnpm coverage` — ensure all tests pass and coverage report generates

## Project Structure

```
contracts/
  smartAccounts/
    facets/          # Diamond facets (InstructionsFacet, VaultsFacet, MemoInstructionsFacet, etc.)
    implementation/  # MasterAccountController, PersonalAccount
    interface/       # Internal interfaces (II* prefix) for facet ↔ library communication
    library/         # Core logic libraries (MemoInstructions, Instructions, Pause, etc.)
    proxy/           # PersonalAccountProxy (beacon proxy)
  composer/
    implementation/  # FAssetRedeemComposer, FAssetRedeemerAccount
    interface/       # Internal composer interfaces
    proxy/           # Composer proxies (UUPS + beacon)
  userInterfaces/    # Public API interfaces (I* prefix)
    facets/          # Public facet interfaces
  diamond/           # Diamond proxy infrastructure (EIP-2535)
  utils/             # Shared helpers (e.g. OwnableWithTimelock)
  mock/              # Test mocks
test/                # Forge tests
deployment/
  chain-config/      # Per-network chain config JSON
  deploys/           # Deployed contract addresses per network
  cuts/              # Diamond cut files per network
  scripts/           # Forge deploy scripts (.s.sol) + bash wrappers
audit/               # Security audit reports
```

## Architecture

### Diamond Proxy Pattern (EIP-2535)

`MasterAccountController` is the Diamond. It delegates to multiple facets (InstructionsFacet, VaultsFacet, AgentVaultsFacet, MemoInstructionsFacet, ReaderFacet, PauseFacet, TimelockFacet, ExecutorsFacet, etc.). Facets are added/replaced via DiamondCut with a timelock.

- **Facets** (`contracts/smartAccounts/facets/`) — thin entry points that delegate to libraries
- **Libraries** (`contracts/smartAccounts/library/`) — contain the actual business logic
- **Interfaces** — two layers:
  - `contracts/userInterfaces/` — public API interfaces (prefixed `I`)
  - `contracts/smartAccounts/interface/` — internal interfaces (prefixed `II`) used for facet-to-library communication

### Personal Accounts

Each XRPL user gets a `PersonalAccount` deployed as a **beacon proxy** (`PersonalAccountProxy`) via CREATE2, where the beacon controller is the `MasterAccountController`. All personal accounts share the same implementation but have isolated storage. `onlyController` restricts mutating entry points to the Diamond.

### FAsset Redeem Composer

The `composer/` module handles cross-chain FAsset redemption via LayerZero:
- `FAssetRedeemComposer` — UUPS upgradeable, implements `ILayerZeroComposer`
- `FAssetRedeemerAccount` — per-redeemer deterministic accounts (beacon proxy pattern)

### Key Dependency Flow

```
Facets → Libraries → Core Logic
  ↓
PersonalAccount (beacon proxy) ← MasterAccountController (diamond)
```

### Instruction Flow

- **Legacy path:** XRPL payment → FDC `IPayment.Proof` (`standardPaymentReference`) → `InstructionsFacet` → library routing → `PersonalAccount` execution
- **Memo path:** `mintedFAssets()` (direct minting with XRPL memo data) → `MemoInstructionsFacet`
- **Memo instruction codes:** `0xFF` execute UserOp, `0xE0` ignore memo, `0xE1` increase nonce, `0xE2` replace fee, `0xD0` set executor, `0xD1` remove executor
- **Transaction ID tracking:** `usedTransactionIds` in `Instructions.State` — shared by both legacy and memo paths
- **Nonce-on-success:** Memo instruction nonce only increments on successful execution (XRPL txns are irreversible, proofs must be retryable)
- **Pausing:** `PauseFacet` with separate pauser/unpauser roles. `notPaused` modifier on `InstructionsFacet` state-modifying functions

## Code Conventions

### Solidity Style

- **Version:** `^0.8.27` (compiled with 0.8.30, EVM target: cancun, `via_ir` enabled)
- **Named imports** only: `import {Foo} from "path/to/Foo.sol";`
- **Custom errors** instead of revert strings: `require(condition, CustomError())`
- **NatSpec** on public interfaces
- Use `ReentrancyGuard` for state-changing external calls and `SafeERC20` for token transfers
- Max line length: 119 chars (Solidity), 120 chars (TypeScript)
- Formatting: Prettier with print width 80, tab width 4, double quotes
- Function parameters: each on its own line, prefixed with `_`
- Visibility/mutability on its own indented line after params
- Opening brace on its own line after visibility
- Example:
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
- ERC-7201 namespaced storage: `keccak256(abi.encode(uint256(keccak256("smartAccounts.LibName.State")) - 1)) & ~bytes32(uint256(0xff))`
- Internal interfaces use `II` prefix (e.g., `IIPersonalAccount`), public interfaces use `I` prefix
- Libraries contain core logic; facets are thin wrappers that call libraries
- `onlyController` modifier on `PersonalAccount` functions (controller = Diamond)
- `onlyOwner` / `onlyOwnerWithTimelock` on admin facet functions

### Testing

- Tests in `test/` using forge-std `Test`
- Test file: `<ContractName>.t.sol`, contract: `<ContractName>Test`, use `setUp()` for initialization
- Test function naming: `testFeatureName` for success, `testFeatureNameRevertReason` for reverts

### Commits

Follow [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/). No co-authored-by lines.

| Type | When to use |
| ---- | ----------- |
| `feat` | Adding new features or functionality |
| `fix` | Fixing a bug |
| `refactor` | Restructuring code without changing behavior |
| `test` | Adding or updating tests |
| `docs` | Documentation changes |
| `chore` | Maintenance tasks (dependencies, tooling, etc.) |
| `ci` | CI/CD pipeline changes |
| `chore(release)` | Creating a release |
| `chore(deploy)` | Updating deploy parameters and scripts |

`fix`, `feat`, and `refactor` modify production/audit-scoped code. `chore` and `test` should not modify audit-scoped files.

## Deployment

- **Supported networks:** coston2, coston, flare, songbird, scdev (plus `-staging` variants)
- Chain configs: `deployment/chain-config/<network>.json`
- Deployed addresses: `deployment/deploys/<network>.json`
- Diamond cut files: `deployment/cuts/<network>/`
- Requires `.env` with `<NETWORK>_RPC_URL` and `DEPLOYER_PRIVATE_KEY`

## External Dependencies

Managed via Soldeer (`foundry.toml [dependencies]`):
- `@openzeppelin-contracts` 5.5.0 — standard OpenZeppelin contracts
- `@openzeppelin-contracts-upgradeable` 5.5.0 — upgradeable variants (used by composer UUPS)
- `flare-periphery` 0.1.44-alpha.6 — Flare chain contract registry, FDC, FAsset interfaces
- `@layerzerolabs-oft-evm` 4.0.1 — LayerZero OFT (used by FAssetRedeemComposer)
- `@layerzerolabs-lz-evm-protocol-v2` 3.0.159 — LayerZero V2 protocol primitives
- `forge-std` 1.10.0 — Foundry test utilities
