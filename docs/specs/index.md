# Flare Smart Accounts

Specification documents for the two on-chain modules in this repository: the **Smart Accounts** protocol and the **FAsset Redeem Composer**.

These docs describe protocol-level behavior and the contracts that implement it. Where a doc cites a contract, the link goes to the actual `.sol` file in this repo, which is the source of truth.

## Reading order

- [Introduction](./Introduction.md) — what this repo contains, how the pieces fit together, who interacts with them
- [Architecture](./Architecture.md) — cross-module layout, the diamond, personal accounts, address derivation, replay protection
- [Terminology](./Terminology.md) — roles and concepts referenced throughout

## Modules

- [Smart Accounts](./SmartAccounts/index.md) — XRPL-controlled accounts on Flare, payment-proof and direct-minting instruction flows, FAsset minting and redemption, vault deposits, account abstraction
- [FAsset Redeem Composer](./Composer/index.md) — LayerZero compose-based cross-chain FAsset redemption with per-redeemer deterministic accounts

## Reference

- [API reference](./ApiReference.md) — pointer index from each module to its public `userInterfaces/I*.sol`
