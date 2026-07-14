<p align="left">
  <a href="https://flare.network/" target="blank"><img src="https://content.flare.network/Flare-2.svg" width="300" alt="Flare Logo" /></a>
</p>

# Flare Smart Accounts (FSA)

The Flare Smart Accounts is an account abstraction that allows XRPL users to perform actions on the Flare chain without owning any FLR token. Each XRPL address is assigned a unique smart account on the Flare chain, which only it can control. They do so through Payment transactions on the XRPL. The Flare Smart Accounts are especially useful as a way of interacting with the FAssets workflow.

This repository also contains the **FAsset Redeem Composer** — a LayerZero-based module for initiating FAsset redemptions from other chains. It lives alongside FSA but is deployed independently.

## Specification docs

Protocol-level specs for both modules live under [`docs/specs/`](./docs/specs/index.md). They describe the on-chain behavior and link back to the source files that are the source of truth:

- [Introduction](./docs/specs/Introduction.md) and [Architecture](./docs/specs/Architecture.md) — what the repo contains, how it fits together.
- [Smart Accounts](./docs/specs/SmartAccounts/index.md) — diamond, personal accounts, payment-reference and memo instruction flows, vaults, executors, fees, pause, timelock.
- [FAsset Redeem Composer](./docs/specs/Composer/index.md) — LayerZero compose flow, per-redeemer accounts, composer and executor fees.
- [API reference](./docs/specs/ApiReference.md) — pointer index from each module to its public `userInterfaces/I*.sol`.

## Development and contribution

If you want to use Flare Smart Accounts in your project, start on [developer hub - Flare Smart Accounts](https://dev.flare.network/smart-accounts/overview/).

You can also reach out to us on [discord](https://discord.com/invite/flarenetwork).

If you're interested in contributing, please see [CONTRIBUTING.md](./CONTRIBUTING.md).

## Security

If you have found a possible vulnerability please see [SECURITY.md](./SECURITY.md).