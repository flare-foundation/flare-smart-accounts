# FAsset Redeem Composer

A LayerZero compose handler that lets the holder of an OFT-wrapped FAsset on another chain redeem it through Flare in one bridge-and-compose action. Each redeemer EVM address gets a deterministic per-redeemer account on Flare, isolating one user's redemption flow from another's.

The contracts live under [`contracts/composer/`](../../../contracts/composer/). The entry point is [`FAssetRedeemComposer`](../../../contracts/composer/implementation/FAssetRedeemComposer.sol).

## Documents

- [Architecture](./Architecture.md) — the composer, redeemer accounts, beacon-and-UUPS proxy layout, governance
- [Redeem flow](./RedeemFlow.md) — `lzCompose` step by step, success and failure paths
- [Redeemer accounts](./RedeemerAccounts.md) — per-redeemer beacon proxies, allowance priming, payment-default entry
- [Fees](./Fees.md) — default and per-srcEid composer fees, executor fee enforcement

## Key contracts and code layout

```text
contracts/composer/
├── implementation/
│   ├── FAssetRedeemComposer.sol        # UUPS, ILayerZeroComposer, IBeacon, OwnableWithTimelock
│   └── FAssetRedeemerAccount.sol       # per-redeemer account, composer-only + owner-only
├── interface/
│   └── IIFAssetRedeemerAccount.sol     # internal — used between composer and account
└── proxy/
    ├── FAssetRedeemComposerProxy.sol   # ERC1967, calls initialize on deploy
    └── FAssetRedeemerAccountProxy.sol  # BeaconProxy (composer is the beacon), calls initialize
```

Public interfaces:
- [`IFAssetRedeemComposer`](../../../contracts/userInterfaces/IFAssetRedeemComposer.sol) — composer ABI, the `RedeemComposeMessage` struct, every event and error.
- [`IFAssetRedeemerAccount`](../../../contracts/userInterfaces/IFAssetRedeemerAccount.sol) — owner-callable payment-default entry points on the redeemer account.

Both extend a shared base: [`IOwnableWithTimelock`](../../../contracts/userInterfaces/IOwnableWithTimelock.sol) — the timelock pattern used identically here and in the Smart Accounts [`TimelockFacet`](../../../contracts/smartAccounts/facets/TimelockFacet.sol).

## Independence from Smart Accounts

The composer module shares **no on-chain state** with the Smart Accounts module. It has its own:
- proxy admin (a separate ERC-1967 storage slot),
- timelock storage (`erc7201:utils.OwnableWithTimelock.State`),
- beacon implementation pointer (`redeemerAccountImplementation`),
- fee schedule (`defaultComposerFeePPM` + per-srcEid override),
- own redeemer-account registry.

The two modules are deployed in the same repo because they share governance patterns and depend on the same upstream FAssets `IAssetManager`. They could be split into separate repos without code changes other than imports.
