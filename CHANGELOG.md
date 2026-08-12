# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
  - Loan subaccount scaffolding (step 1): deterministic per-Personal-Account staging accounts for loan flows.
    - `LoanSubaccount` — base implementation with `initialize`, `controllerAddress`, `parentPersonalAccount`, `subaccountType`, and `implementation`. Asset-moving methods are added in later steps.
    - `LoanSubaccountProxy` — minimal proxy that resolves its implementation per `SubaccountType` through the controller (controller-as-beacon); the type is fixed at deployment.
    - `LoanSubaccountsFacet` + `LoanSubaccounts` library — per-`SubaccountType` implementation registry with timelocked `setLoanSubaccountImplementation` and `loanImplementationForType` resolution.
    - `ILoanSubaccount` / `ILoanSubaccountsFacet` public interfaces and the `SubaccountType` enum (`None`, `Loan`).
  - Loan subaccount creation and prediction (step 2):
    - `LoanSubaccounts` library: CREATE2 deployment via the EIP-2470 singleton factory (salt `0`, init code from the diamond, parent Personal Account, and subaccount type), `computeLoanSubaccountAddress`, `getOrCreateLoanSubaccount`, and the per-parent registry with `LoanSubaccountCreated` event.
    - `createLoanSubaccount(xrplOwner, type)` — permissionless, `notPaused`; requires the parent Personal Account to be deployed.
    - `getLoanSubaccount(xrplOwner, type)` — view returning the registered or predicted subaccount address.
    - Spec page `docs/specs/SmartAccounts/LoanSubaccounts.md`. Note: proxy creation code must be frozen (PA-style constant + pinned-hash test) before the first production deployment.
  - Loan subaccount account abstraction dispatch (step 3):
    - `onlyParent` modifier on `LoanSubaccount`: restricted methods are callable only by the parent Personal Account, reached through the existing `0xFF`/`0xFE` memo path via `PersonalAccount.executeUserOp`. No new memo opcode — the subaccount address already commits to the subaccount type.
    - A user operation creates the subaccount with `createLoanSubaccount` as its first call, then calls a method on it: calling a subaccount that is not deployed yet would silently succeed, since a call to an address with no code returns success.
  - `LoanSubaccount.sweepToLoan()` — the forward cleanup move: permissionless, bridges all idle FXRP over LayerZero to this account's own address on the loan chain (identical on every chain by CREATE2 derivation). Takes no parameters; the destination chain and FXRP OFT come from governance-set `setLoanBridgeSettings`, so the caller cannot choose where the assets go. The quoted messaging fee is forwarded and any excess `msg.value` is returned to the caller.
  - `IIOft` — minimal local subset of LayerZero's `IOFT` (`quoteSend`, `send` and their structs), since LayerZero's own interface pulls types from a package that is not a dependency of this project.
  - `LoanSubaccount.sweepRedeem()` — the backward cleanup move: permissionless, redeems all idle FXRP to the parent Personal Account's XRPL owner. Takes no parameters, so neither the destination (read from the parent account) nor the executor (read from the controller) can be chosen by the caller. Uses the UBA-based `redeemAmount` rather than the lot-based `redeem`, so no remainder is left stranded on the account.
  - Spellcheck: `pnpm spellcheck` (cspell over contracts, tests, deployment, and docs) with an advisory `spellcheck` CI job.

### Fixed
  - Misspelled `newWallet` variable name in `MasterAccountControllerTest`.

## [[v2.0.0](https://github.com/flare-foundation/flare-smart-accounts/releases/tag/v2.0.0)] - 2026-07-07

### Added
  - `MemoInstructionsFacet` — new facet dedicated to memo-based instructions via the `mintedFAssets()` direct-minting entry point.
    - 0xFF: Execute UserOp (ERC-4337 `PackedUserOperation`).
    - 0xE0: Ignore memo (recovery for malformed memo, bad callData).
    - 0xE1: Increase nonce (recovery for nonce too low).
    - 0xE2: Replace fee (recovery for fee too low).
    - 0xD0: Set PA executor.
    - 0xD1: Remove PA executor.
  - `MemoInstructions` library with ERC-7201 namespaced storage.
  - `executeUserOp(Call[])` on `PersonalAccount` — generic multi-call for account abstraction.
  - `PauseFacet` with separate pauser/unpauser roles (`EnumerableSet.AddressSet`), `onlyOwnerWithTimelock` on role management.
  - `ReaderFacet` — read-only facet for balance aggregation, vault/agent vault listing, and `isSmartAccount` check.
  - Token receiver support on `PersonalAccount`: `ERC721Holder`, `ERC1155Holder`, `IERC1363Receiver`.
  - `receive() external payable` on `PersonalAccount`.
  - `previewRedemption` to `IIVault` (Upshift vault interface).
  - FAsset Redeem Composer module: cross-chain f-asset redemption via LayerZero compose pattern.
    - `FAssetRedeemComposer` (UUPS upgradeable, `ILayerZeroComposer`, per-source PPM fees, timelocked config).
    - `FAssetRedeemerAccount` (per-redeemer BeaconProxy via CREATE2, redemption with destination tag support).
    - `FAssetRedeemComposerProxy` (ERC1967) and `FAssetRedeemerAccountProxy` (BeaconProxy).
  - `OwnableWithTimelock` utility for timelocked owner operations (max 7 days).
  - 0xFE memo opcode — Execute UserOp with data. The 42-byte memo carries only `[0xFE][walletId][fee][keccak256(_data)]`; the encoded `PackedUserOperation` arrives via the AssetManager-forwarded `_data` parameter. Lifts the XRPL memo size constraint at the cost of executor-side coordination.

### Changed
  - Renamed `mintedFAssets()` to `handleMintedFAssets()` to reflect that it's a post-mint callback, not an action.
  - Added a `bytes _data` parameter to `handleMintedFAssets()` for memo opcodes that need inputs not contained in the XRPL memo.
  - `InvalidInstructionType` error now carries the actual vault type alongside the instruction type, so the revert data identifies both sides of the mismatch.
  - `InstructionsFacet` split: legacy payment-proof flow stays in `InstructionsFacet`, memo/direct-minting flow moved to new `MemoInstructionsFacet`. Both share `Instructions.State.usedTransactionIds` for cross-path replay protection.
  - `ReentrancyGuard` → `ReentrancyGuardTransient` (EIP-1153) on `PersonalAccount`.
  - Vault type from `uint8` to `VaultType` enum (`None`, `Firelight`, `Upshift`) in `IVaultsFacet`.
  - Migrated from yarn to pnpm.
  - Updated dependencies: Flare Periphery to 0.1.44-alpha.6, added LayerZero V2 (OFT 4.0.1, Protocol 3.0.159), removed Uniswap V3.

### Removed
  - Swap functionality: `SwapFacet`, `Swap`, `UniswapV3`, `ISwapFacet`, `IISwapFacet`, `MockUniswapV3Router`.
  - `executeSwap` from `PersonalAccount`.


## [[v1.0.0](https://github.com/flare-foundation/flare-smart-accounts/releases/tag/v1.0.0)] - 2025-02-24

### Added
  - Initial release of the project.
  - Diamond proxy (EIP-2535) MasterAccountController with timelocked governance.
  - XRPL-linked personal accounts (BeaconProxy + CREATE2).
  - XRPL payment proof verification.
  - Instruction system: FXRP minting/transfer/redemption, Firelight and Upshift vault operations.
  - Uniswap V3 swap integration.

