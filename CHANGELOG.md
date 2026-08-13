# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
  - Loan subaccounts — deterministic, restricted staging accounts under each Personal Account for the loan-origination flow. Design and rationale: `docs/specs/SmartAccounts/LoanSubaccounts.md`.
    - `LoanSubaccount` + `LoanSubaccountProxy`: the controller acts as a type-aware beacon (`loanImplementationForType`, timelocked `setLoanSubaccountImplementation`). The subaccount type is a raw `uint256` (`0` reserved, `1` = loan), so future types stay deployable through frozen artifacts.
    - Creation and prediction (`createLoanSubaccount(xrplOwner, type)` — permissionless and idempotent, `getLoanSubaccount`): CREATE2 via the EIP-2470 singleton factory, so a subaccount has the same address on every chain. The proxy creation code is frozen to a PA-style constant with a pinned-hash test (`test/LoanSubaccountsLibrary.t.sol`), so predicted addresses are stable across rebuilds.
    - No new memo opcode: restricted methods are `onlyParent` and are reached through the existing `0xFF`/`0xFE` account abstraction path.
    - Cleanup moves, permissionless with fixed destinations: `sweepRedeem()` (whole balance to the parent's XRPL owner via FAssets `redeemAmount`) and `sweepToLoan()` (bridge to this account's own cross-chain address; reverts while the controller is paused). Timelocked `setLoanBridgeSettings`, validated against the FXRP token, its decimals, the OFT's live peer (pinned, clean-padded), and the canonical `oftVersion`; every sweep re-checks the live peer.
    - Recovery to the parent Personal Account: `sweepToParent(token)` and `sweepNativeToParent()`, plus `receive()`; FXRP is recoverable only below the FAssets minimum redemption amount (the exact complement of `sweepRedeem`).
    - Redemption payment default relays (`redemptionPaymentDefault`, `xrpRedemptionPaymentDefault`), restricted to the parent Personal Account.
    - `executeLayerZeroCall(amount, composeMsg, extraOptions)` — the parent-driven loan instruction: bridges exactly the signed amount of FXRP (zero = message-only instruction) to this account's own address on the loan chain with an opaque composed payload and caller-supplied type-3 execution options.
    - `EthereumLoanSubaccount` — the Ethereum-side implementation behind the same frozen proxy and address (per-chain registration through the type registry); no parent-driven methods, since Personal Accounts exist only on Flare. Loan actions arrive through `lzCompose`, authenticated down to the packet GUID recomputed from the pinned origin peer; payload v1 carries an operation id (consumed only on execution), a deadline, and the Morpho market id it was signed for. `ACTION_BORROW` supplies exactly the authenticated bridged amount and disburses to a clean EVM address; `ACTION_WITHDRAW` returns collateral to the account itself.
    - `EthereumLoanSettingsFacet` — Ethereum-only governance configuration (LayerZero endpoint, FXRP OFT, pinned origin route, Morpho market; validated like the Flare-side bridge settings, cleared by an all-zero struct) and the creation route `createEthereumLoanSubaccount(xrplOwner, type)`, which resolves the parent Personal Account to its computed address.
  - `@layerzerolabs-oapp-evm` dependency, for LayerZero's canonical `IOFT` interface.
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

