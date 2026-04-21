# Flare Smart Accounts - Agents Guide

This document provides essential information for AI agents working on the `flare-smart-accounts` repository.

## 1. Build, Lint, and Test Commands

### Build

- **Compile Contracts:** `forge build`

### Test

- **Run All Tests:** `forge test`
- **Run Specific Contract Tests:** `forge test --match-contract <ContractName>` (e.g., `forge test --match-contract PersonalAccountTest`)
- **Run Specific Test Function:** `forge test --match-test <testName>` (e.g., `forge test --match-test testReserveCollateral`)
- **Run with Verbosity:** Append `-v`, `-vv`, `-vvv`, `-vvvv`, or `-vvvvv` for increasing detail (logs, traces).
- **Generate Coverage:** `pnpm coverage`

### Lint & Format

- **Lint Solidity (all):** `pnpm lint-sol` (contracts, tests, deployment)
- **Lint Contracts (Solidity):** `pnpm lint-sol-contracts`
- **Lint Tests (Solidity):** `pnpm lint-sol-test`
- **Lint Deployment (Solidity):** `pnpm lint-sol-deployment`
- **Lint TypeScript:** `pnpm lint:check` (fix: `pnpm lint:fix`)
- **Check Formatting:** `pnpm format:check` (fix: `pnpm format:fix`)

### Deployment

- **Deploy Contracts:** `pnpm deploy_contracts <network> <fullDeploy>`
  - Example: `pnpm deploy_contracts coston2 true`
  - Note: `<fullDeploy>` is a boolean (`true`/`false`). `false` skips initialization (useful for diamond facets).
- **Deploy PA Implementation:** `pnpm deploy_personal_account_implementation <network>`
- **Execute Diamond Cut:** `pnpm diamond_cut <network> <cut-file-name>`
- **Verify Contracts:** `pnpm verify_contracts <network>`
- **Supported networks:** `coston2`, `coston`, `flare`, `songbird`, `scdev` (plus `-staging` variants).

## 2. Code Style & Conventions

### Solidity (`contracts/`)

- **Version:** `^0.8.27` (compiled with solc 0.8.30, EVM target: `cancun`).
- **Formatting:** Prettier + `prettier-plugin-solidity` (`pnpm format:check`).
- **Imports:** Use **named imports** explicitly.
  - Example: `import {ContractRegistry} from "flare-periphery/src/flare/ContractRegistry.sol";`
- **Interfaces:** Prefix with `I` (public) or `II` (internal, between facets and libraries).
  - Public: `contracts/userInterfaces/`
  - Internal: `contracts/smartAccounts/interface/`
- **Naming:**
  - Contracts/Libraries: `PascalCase`
  - Functions/Variables: `camelCase`, function parameters prefixed with `_`
  - Constants: `UPPER_CASE_WITH_UNDERSCORES`
- **Error Handling:**
  - Use **custom errors** instead of string messages (gas efficiency).
  - Example: `require(msg.sender == controllerAddress, OnlyController());`
- **Documentation:** Use **NatSpec** (`/// @notice`, `/// @dev`) for all public interfaces and complex logic.
- **Safety:**
  - Use `ReentrancyGuardTransient` (EIP-1153) for state-changing external calls.
  - Use `SafeERC20` for token transfers.
- **Storage:** ERC-7201 namespaced storage for libraries.
  - Slot: `keccak256(abi.encode(uint256(keccak256("smartAccounts.LibName.State")) - 1)) & ~bytes32(uint256(0xff))`

### Testing (`test/`)

- **Framework:** Foundry (`forge-std`).
- **File Naming:** `<ContractName>.t.sol`.
- **Contract Naming:** `<ContractName>Test` inheriting from `Test`.
- **Setup:** Initialize state in `function setUp() public`.
- **Mocking:** extensively use `vm.mockCall`, `vm.prank`, `vm.deal`, etc.
- **Assertions:** Use `assertEq`, `assertTrue`, `vm.expectRevert`, `vm.expectEmit`.

### TypeScript (`scripts/`, `deployment/`)

- **Linter:** ESLint (`pnpm lint:check`).
- **Config:** `tsconfig.json` targets `es2024`, `module: Node20`, strict mode + `verbatimModuleSyntax`, `noUncheckedIndexedAccess`, `exactOptionalPropertyTypes`, `noEmit: true`.
- **Runtime:** TS files run directly via `tsx` (no build step).
- **Imports:** Use ES modules syntax (`import ... from ...`).

## 3. Project Structure

- `contracts/`: Smart contract source code.
  - `smartAccounts/`: Core logic (implementations, facets, libraries, proxies).
  - `composer/`: FAsset redeem composer (cross-chain redemption via LayerZero).
  - `userInterfaces/`: Public interfaces (`I` prefix).
  - `utils/`: Shared helpers (e.g. `OwnableWithTimelock`).
  - `diamond/`: EIP-2535 diamond proxy infrastructure.
  - `mock/`: Test mocks.
- `test/`: Foundry test files.
- `deployment/`: Deployment scripts (`.s.sol`, `.sh`, `.ts`) and configs (`chain-config/`, `deploys/`, `cuts/`).
- `scripts/`: Utility scripts (selectors, slither, etc.).
- `audit/`: Security audit reports.
