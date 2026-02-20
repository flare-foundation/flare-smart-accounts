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
- **Generate Coverage:** `yarn coverage`

### Lint & Format

- **Lint All:** `yarn lint` (runs Solhint and ESLint)
- **Lint Contracts (Solidity):** `yarn lint-contracts`
- **Lint Tests (Solidity):** `yarn lint-test`
- **Lint TypeScript:** `yarn ts-lint`
- **Format Code:** `yarn format` (Prettier)

### Deployment

- **Deploy Contracts:** `yarn deploy_contracts <network> <fullDeploy>`
  - Example: `yarn deploy_contracts coston2 true`
  - Note: `<fullDeploy>` is a boolean (`true`/`false`). `false` skips initialization (useful for diamond facets).

## 2. Code Style & Conventions

### Solidity (`contracts/`)

- **Version:** `^0.8.27` (Use this pragma or match existing files).
- **Formatting:** Follow Prettier settings (`yarn format`).
- **Imports:** Use **named imports** explicitly.
  - Example: `import {ContractRegistry} from "flare-periphery/src/flare/ContractRegistry.sol";`
- **Interfaces:** Prefix with `I` (e.g., `IPersonalAccount`). Place in `contracts/userInterfaces/` or `contracts/smartAccounts/interface/`.
- **Naming:**
  - Contracts/Libraries: `PascalCase`
  - Functions/Variables: `camelCase`
  - Constants: `UPPER_CASE_WITH_UNDERSCORES`
  - Storage Variables: No specific prefix enforcement observed, but avoid shadowing.
- **Error Handling:**
  - Use **custom errors** instead of string messages where possible (gas efficiency).
  - Example: `require(msg.sender == controllerAddress, OnlyController());`
- **Documentation:** Use **NatSpec** (`/// @notice`, `/// @dev`) for all public interfaces and complex logic.
- **Safety:**
  - Use `ReentrancyGuard` for state-changing external calls.
  - Use `SafeERC20` for token transfers.

### Testing (`test/`)

- **Framework:** Foundry (`forge-std`).
- **File Naming:** `<ContractName>.t.sol`.
- **Contract Naming:** `<ContractName>Test` inheriting from `Test`.
- **Setup:** Initialize state in `function setUp() public`.
- **Mocking:** extensively use `vm.mockCall`, `vm.prank`, `vm.deal`, etc.
- **Assertions:** Use `assertEq`, `assertTrue`, `vm.expectRevert`, `vm.expectEmit`.

### TypeScript (`scripts/`, `deployment/`)

- **Linter:** ESLint (`yarn ts-lint`).
- **Config:** `tsconfig.json` targets `es2022`, strict mode enabled.
- **Imports:** Use ES modules syntax (`import ... from ...`).

## 3. Project Structure

- `contracts/`: Smart contract source code.
  - `smartAccounts/`: Core logic (implementations, facets, proxies).
  - `composer/`: Composer contracts.
  - `userInterfaces/`: Public interfaces.
- `test/`: Foundry test files.
- `deployment/`: Deployment scripts and configurations.
- `scripts/`: Utility scripts.
