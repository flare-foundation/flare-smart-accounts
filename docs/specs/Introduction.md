# Introduction

This repository hosts two on-chain modules that share Solidity tooling, governance patterns, and FAsset interfaces, but are otherwise independent.

## Smart Accounts

[Smart Accounts](./SmartAccounts/index.md) is an **account-abstraction protocol for XRPL users**. Each XRPL address is assigned a unique smart account on Flare. The user controls that account exclusively by signing XRPL Payment transactions — never by holding FLR or an EVM key. The smart account can mint FAssets, redeem FAssets, transfer FXRP, deposit into vaults, and execute arbitrary `PackedUserOperation` calls (ERC-4337 shaped), all driven by XRPL payments.

The contracts live under [`contracts/smartAccounts/`](../../contracts/smartAccounts/) plus shared diamond infrastructure in [`contracts/diamond/`](../../contracts/diamond/). The entry point on Flare is the [`MasterAccountController`](../../contracts/smartAccounts/implementation/MasterAccountController.sol) diamond. Each user gets a per-XRPL-address [`PersonalAccount`](../../contracts/smartAccounts/implementation/PersonalAccount.sol) deployed as a beacon proxy (the diamond is the beacon).

Two driving flows feed instructions into the diamond:

- **Payment-proof flow.** A relayer fetches an XRPL `IPayment` attestation from the Flare Data Connector (FDC) and submits it to [`InstructionsFacet`](../../contracts/smartAccounts/facets/InstructionsFacet.sol). The 32-byte XRPL `standardPaymentReference` carries the instruction (transfer, redeem, vault deposit, etc.).
- **Direct-minting flow.** The FAssets [`AssetManager`](https://github.com/flare-foundation/fassets) calls [`MemoInstructionsFacet.handleMintedFAssets`](../../contracts/smartAccounts/facets/MemoInstructionsFacet.sol) after FXRP is minted to the diamond. The XRPL memo bytes select what to do with the freshly-minted FAssets — including executing arbitrary `PackedUserOperation`s (memo opcodes `0xFF` / `0xFE`), updating account state (`0xE0`–`0xE2`), or pinning an executor (`0xD0` / `0xD1`).

Both paths share replay protection through a single `usedTransactionIds` set keyed by XRPL transaction ID, so the same XRPL transaction cannot drive two instructions.

## FAsset Redeem Composer

[FAsset Redeem Composer](./Composer/index.md) is an unrelated LayerZero compose handler. It lets a holder of an OFT-wrapped FAsset on another chain redeem it through Flare in a single bridge-and-compose action.

The contracts live under [`contracts/composer/`](../../contracts/composer/). The entry point is [`FAssetRedeemComposer`](../../contracts/composer/implementation/FAssetRedeemComposer.sol) — a UUPS-upgradeable contract that implements `ILayerZeroComposer`. Each redeemer EVM address gets a [`FAssetRedeemerAccount`](../../contracts/composer/implementation/FAssetRedeemerAccount.sol) deployed via CREATE2 as a beacon proxy, isolating one redeemer's funds and approvals from another.

The composer enforces a per-source-endpoint fee in PPM, takes the fee in fAsset out of the bridged amount, calls the AssetManager's `redeemAmount` or `redeemWithTag` for the rest, and returns any unredeemable balance to the redeemer's account (with native value wrapped to wNat on failure).

## What is not in this repo

- **The FAssets system.** The `IAssetManager` interface, the agent vaults, and the FDC payment verifier all live in upstream Flare repositories. Smart Accounts and the composer call into them through the standard interfaces.
- **XRPL itself.** XRPL Payment transactions are produced and signed off-chain. The protocol consumes them only after an FDC attestation, or as a side effect of FAssets direct minting.
- **Off-chain relayers and executors.** The protocol is intentionally driven by external actors (relayers fetch proofs and submit them, executors are paid in fAsset to call `handleMintedFAssets`). Off-chain tooling lives outside the repo.
- **LayerZero infrastructure.** The composer is a compose handler; the LayerZero endpoint and source-side OFT adapter are external.
