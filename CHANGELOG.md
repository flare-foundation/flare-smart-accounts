# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
  - Loan subaccounts — deterministic, restricted staging accounts under each Personal Account for the loan-origination flow. Design: `docs/specs/SmartAccounts/LoanSubaccounts.md`.
    - `LoanSubaccount` + `SubaccountProxy`; the controller is a type-aware beacon (`implementationForType`, timelocked `setSubaccountImplementation`). The type is a raw `uint256` (`0` reserved, `1` = loan).
    - `createSubaccount(xrplOwner, type)` (permissionless, idempotent) and `getSubaccount`: CREATE2 via the EIP-2470 singleton factory — the same address on every chain, creatable before the Personal Account exists. Frozen proxy creation code with a pinned-hash test.
    - Restricted methods are `onlyParent`, reached through the existing `0xFF`/`0xFE` account abstraction path; no new memo opcode.
    - One permissionless direction per account: on Flare, `sweepRedeem()` (pushes FXRP to the parent, which redeems it through the subaccount-only `PersonalAccount.redeemFromSubaccount(amount)`); forward moves are signed. Non-FXRP strays have no rail and strand (accepted; see the spec).
    - Timelocked `setLoanBridgeSettings` (FXRP OFT, destination EID, pinned peer), validated against the token, its decimals, the live peer and `oftVersion`.
    - `borrow(...)`, `depositCollateral(...)` and `withdraw(...)` — typed parent-driven loan instructions; the compose payload is built on-chain and validated before any fee is paid. The withdraw is atomic: it carries two option blobs plus a signed delivery-value floor (`WithdrawOptions`) and prepays the return leg as compose value.
    - `LoanSubaccountRemote` — the loan-chain-side implementation behind the same proxy and address: authenticated, replay-protected `lzCompose` (borrow, deposit, atomic withdraw — withdraws and bridges home in one execution, its delivery gated by the signed value floor) plus the permissionless rails `repay` (closing the position pushes the loan-token surplus to the parent) and `depositIdleFxrp`, and the parent-only signed exit `sweepToOrigin(options)` (redeemed on Flare on arrival). No native rail; a withdraw delivery's compose value is spent or forwarded in the same call.
    - `ComposeTransportFacet` — the remote diamond's compose transport (endpoint, OFT, pinned origin route), one per diamond: timelocked `setComposeTransport(transport)`, immediate owner-only `clearComposeTransport()`.
    - `LoanMarketsFacet` — one write-once Morpho market per subaccount type with a per-type borrow kill-switch.
    - `PersonalAccountRemote` — the compose-driven mirror of the Flare Personal Account at the same address, behind the same beacon; one action: execute the signed batch of calls (the loan-chain `executeUserOp`); accepts native. The Flare `PersonalAccount` gains the self-called `sendCrossChainUserOp(...)`.
    - `ComposeReceiverAccountBase` — the shared `lzCompose` authentication core of the compose receivers on both chains (operation-id replay protection for the signed actions); the Flare subaccount redeems its own bridge-back on arrival, capped at the packet's amount and until a stamped deadline.
  - `@layerzerolabs-oapp-evm` dependency (canonical `IOFT` interface).
  - `pnpm spellcheck` (cspell) with an advisory CI job.

### Changed
  - `PersonalAccountsFacet` gains the permissionless, pause-gated `createPersonalAccount(xrplOwner)` (facet replacement on existing deployments); the `PersonalAccounts` library returns `address`.
  - `removeUnpausers` is immediate (`onlyOwner`) instead of timelocked; pauser removal stays timelocked. Mirrors `flare-dvn-contracts`.

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

