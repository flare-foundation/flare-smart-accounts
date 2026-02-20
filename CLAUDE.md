# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Flare Smart Accounts (FSA) is an account abstraction protocol enabling XRPL users to perform actions on the Flare blockchain without holding FLR tokens. Each XRPL address gets a unique smart account on Flare, controlled exclusively through XRPL Payment transactions.

## Build & Test Commands

```bash
# Setup
yarn                     # install node dependencies
forge soldeer install    # install Solidity dependencies
forge build              # compile contracts

# Testing
forge test               # run all tests
forge test --mc <ContractName>   # run tests for a specific contract (e.g. PersonalAccountTest)
forge test --mt <testName>       # run a specific test function
forge test -vvv          # run with execution traces for failing tests

# Linting & Formatting
yarn lint                # run solhint on contracts, tests, and deployment
yarn lint-contracts      # lint only contracts/
yarn lint-test           # lint only test/
yarn ts-lint             # lint TypeScript files
yarn format              # format all files with Prettier

# Coverage
yarn coverage            # generate HTML coverage report

# Deployment
yarn deploy_contracts <network> <fullDeploy>   # e.g. yarn deploy_contracts coston2 true
yarn diamond_cut <network> <cut-file-name>     # execute a diamond cut upgrade
yarn verify_contracts <network>                # verify contracts on Blockscout
```

## Architecture

### Diamond Proxy Pattern (EIP-2535)

The core system uses the Diamond pattern. `MasterAccountController` is the diamond contract that delegates calls to 13 facets:

- **Facets** (`contracts/smartAccounts/facets/`) — thin entry points that delegate to libraries
- **Libraries** (`contracts/smartAccounts/library/`) — contain the actual business logic
- **Interfaces** — two layers:
  - `contracts/userInterfaces/` — public API interfaces (prefixed `I`)
  - `contracts/smartAccounts/interface/` — internal interfaces (prefixed `II`) used for facet-to-library communication

### Personal Accounts

Each XRPL user gets a `PersonalAccount` deployed as a **beacon proxy** (`PersonalAccountProxy`), where the beacon controller is the `MasterAccountController`. All personal accounts share the same implementation but have isolated storage.

### FAsset Redeem Composer

The `composer/` module handles cross-chain f-asset redemption via LayerZero:
- `FAssetRedeemComposer` — UUPS upgradeable, implements `ILayerZeroComposer`
- `FAssetRedeemerAccount` — per-redeemer deterministic accounts (beacon proxy pattern)

### Key Dependency Flow

```
Facets → Libraries → Core Logic
  ↓
PersonalAccount (beacon proxy) ← MasterAccountController (diamond)
```

## Code Conventions

- **Solidity version**: `^0.8.27` (compiled with 0.8.30, EVM target: cancun, via_ir enabled)
- **Named imports** only: `import {Foo} from "path/to/Foo.sol";`
- **Custom errors** instead of revert strings: `require(condition, CustomError())`
- **NatSpec** on public interfaces
- Use `ReentrancyGuard` for state-changing external calls and `SafeERC20` for token transfers
- Max line length: 119 chars (Solidity), 120 chars (TypeScript)
- Solidity formatting: Prettier with print width 80, tab width 4, double quotes
- Tests: file `<ContractName>.t.sol`, contract `<ContractName>Test`, use `setUp()` for initialization

## Deployment

- **Supported networks**: coston2, coston, flare, songbird, scdev (plus `-staging` variants)
- Chain configs: `deployment/chain-config/<network>.json`
- Deployed addresses: `deployment/deploys/<network>.json`
- Diamond cut files: `deployment/cuts/<network>/`
- Requires `.env` with `<NETWORK>_RPC_URL` and `DEPLOYER_PRIVATE_KEY`

## External Dependencies

Managed via Soldeer (`foundry.toml [dependencies]`):
- OpenZeppelin Contracts 5.5.0 (standard + upgradeable)
- Flare Periphery 0.1.38 (chain contract registry)
- Uniswap V3 (core + periphery)
- LayerZero V2 (OFT + protocol)
- forge-std 1.10.0
