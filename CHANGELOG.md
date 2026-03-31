# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).


## [Unreleased]

### Added
  - Memo instructions system via `mintedFAssets()` entry point on `InstructionsFacet`.
    - 0xFF: Execute UserOp (ERC-4337 `PackedUserOperation`).
    - 0xE0: Ignore memo (recovery for malformed memo, bad callData).
    - 0xE1: Increase nonce (recovery for nonce too low).
    - 0xE2: Replace fee (recovery for fee too low).
    - 0xD0: Set PA executor.
    - 0xD1: Remove PA executor.
  - `MemoInstructions` library with ERC-7201 namespaced storage.
  - `executeUserOp(Call[])` on `PersonalAccount` — generic multi-call for account abstraction.
  - `PauseFacet` with separate pauser/unpauser roles (`EnumerableSet.AddressSet`), `onlyOwnerWithTimelock` on role management.
  - `PersonalAccountReaderFacet` — read-only facet for balance aggregation, vault/agent vault listing, and `isSmartAccount` check.
  - Token receiver support on `PersonalAccount`: `ERC721Holder`, `ERC1155Holder`, `IERC1363Receiver`.
  - `receive() external payable` on `PersonalAccount`.
  - `previewRedemption` to `IIVault` (Upshift vault interface).
  - FAsset Redeem Composer module: cross-chain f-asset redemption via LayerZero compose pattern.
    - `FAssetRedeemComposer` (UUPS upgradeable, `ILayerZeroComposer`, per-source PPM fees, timelocked config).
    - `FAssetRedeemerAccount` (per-redeemer BeaconProxy via CREATE2, redemption with destination tag support).
    - `FAssetRedeemComposerProxy` (ERC1967) and `FAssetRedeemerAccountProxy` (BeaconProxy).
  - `OwnableWithTimelock` utility for timelocked owner operations (max 7 days).

### Changed
  - `InstructionsFacet` extended to support both legacy and memo-based instruction paths.
  - `ReentrancyGuard` → `ReentrancyGuardTransient` (EIP-1153) on `PersonalAccount`.
  - Vault type from `uint8` to `VaultType` enum (`None`, `Firelight`, `Upshift`) in `IVaultsFacet`.
  - Migrated from yarn to pnpm.
  - Updated dependencies: Flare Periphery to 0.1.44-alpha.3, added LayerZero V2 (OFT 4.0.1, Protocol 3.0.159), removed Uniswap V3.

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

