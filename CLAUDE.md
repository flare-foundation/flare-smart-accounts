# Flare Smart Accounts

## Project Overview

Solidity smart contracts implementing Flare Smart Accounts — a Diamond proxy (EIP-2535) system that manages PersonalAccounts linked to XRPL addresses. Supports FAsset minting/redeeming, vault deposits, and Account Abstraction via IXRPPayment proofs.

## Tech Stack

- **Solidity** ^0.8.27, compiled with solc 0.8.30
- **Foundry** (forge) for build, test, coverage
- **EVM target:** Cancun (EIP-1153 transient storage supported)
- **Optimizer:** enabled, 200 runs, via_ir = true

## Commands

- `forge build` — compile contracts
- `forge test` — run all tests
- `forge test -vvv --match-test testName` — run specific test with traces
- `yarn coverage` — coverage report (lcov + genhtml)
- `yarn lint` — solhint on contracts, tests, deployment
- `forge fmt` — format Solidity files (run before lint)

**After every change, run these checks before considering work complete:**
1. `yarn lint` — ensure no lint errors (warnings are acceptable)
2. `forge build` — ensure compilation succeeds
3. `yarn coverage` — ensure all tests pass and coverage report generates

## Project Structure

```
contracts/
  smartAccounts/
    facets/          # Diamond facets (InstructionsFacet, VaultsFacet, etc.)
    implementation/  # MasterAccountController, PersonalAccount
    interface/       # Internal interfaces (II* prefix)
    library/         # Core logic libraries (MemoInstructions, Instructions, Pause, etc.)
    proxy/           # PersonalAccountProxy (beacon proxy)
  userInterfaces/    # Public interfaces (I* prefix)
    facets/          # Public facet interfaces
  diamond/           # Diamond proxy infrastructure
  mock/              # Test mocks
test/                # Forge tests
deployment/          # Deploy scripts
audit/               # Security audit reports
```

## Code Conventions

### Solidity Style
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
- `onlyController` modifier on PersonalAccount functions (controller = Diamond)
- `onlyOwner` / `onlyOwnerWithTimelock` on admin facet functions

### Commits
- Short commit messages, no co-authored-by lines

### Testing
- Tests in `test/` using forge-std `Test`
- Test contract naming: `ContractNameTest`
- Test function naming: `testFeatureName` for success, `testFeatureNameRevertReason` for reverts

## Architecture Notes

- **Diamond pattern**: MasterAccountController is the Diamond. Facets are added/replaced via DiamondCut with timelock.
- **PersonalAccount**: Beacon proxy deployed per XRPL address via CREATE2. Controller is the Diamond.
- **Instruction flow**: XRPL payment → FDC proof → InstructionsFacet → library routing → PersonalAccount execution
- **Instruction paths**: Legacy via `IPayment.Proof` (`standardPaymentReference`), memo-based via `mintedFAssets()` (direct minting with XRPL memo data)
- **Memo instructions**: 0xFF (execute UserOp), 0xE0 (ignore memo), 0xE1 (increase nonce), 0xE2 (replace fee), 0xD0 (set executor), 0xD1 (remove executor)
- **Transaction ID tracking**: `usedTransactionIds` in `Instructions.State` — shared by both legacy and memo paths
- **Nonce-on-success**: Memo instruction nonce only increments on successful execution (XRPL txns are irreversible, proofs must be retryable)
- **Pausing**: `PauseFacet` with separate pauser/unpauser roles. `notPaused` modifier on InstructionsFacet state-modifying functions
