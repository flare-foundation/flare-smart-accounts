# Composer architecture

[`FAssetRedeemComposer`](../../../contracts/composer/implementation/FAssetRedeemComposer.sol) is a single UUPS-upgradeable contract that does two jobs at once:

1. **`ILayerZeroComposer`** — accepts `lzCompose` callbacks from the trusted LayerZero endpoint.
2. **`IBeacon`** — exposes `implementation()` so per-redeemer `BeaconProxy`s read the current redeemer-account logic from it.

Everything else — the trust list, the fee schedule, the redeemer-account map — sits on the composer's own ERC-1967 storage.

## Proxy shape

```text
                            ┌── ERC-1967 proxy ─────────────────────────────┐
                            │ FAssetRedeemComposerProxy (constructor calls  │
                            │ initialize on the implementation via          │
   LayerZero ─► lzCompose ─►│ delegatecall)                                 │
   endpoint                 │ ▼                                             │
                            │ FAssetRedeemComposer (UUPS)                   │
                            │   • endpoint, trustedSourceOApp               │
                            │   • assetManager, fAsset, stableCoin, wNat    │
                            │   • redeemerAccountImplementation             │
                            │   • composerFeeRecipient, default + per-srcEid│
                            │   • defaultExecutor                           │
                            │   • redeemerToRedeemerAccount mapping         │
                            │   • OwnableWithTimelock state                 │
                            └───────────────────────────────────────────────┘
                                          │
                  ┌───────────────────────┴───────────────────────┐
                  │                                               │
                  ▼                                               ▼
              CREATE2 deploy of                          IBeacon.implementation()
              FAssetRedeemerAccountProxy
              (BeaconProxy, beacon = composer)
                  │
                  ▼
              FAssetRedeemerAccount (per redeemer)
                  • composer, owner
                  • set allowances on init
                  • redeemFAsset (composer-only)
                  • redemptionPaymentDefault (owner-only)
                  • xrpRedemptionPaymentDefault (owner-only)
```

[`FAssetRedeemComposerProxy`](../../../contracts/composer/proxy/FAssetRedeemComposerProxy.sol) is an `ERC1967Proxy` that forwards its constructor args to `FAssetRedeemComposer.initialize(...)`. Once deployed, it is upgraded only via UUPS — `FAssetRedeemComposer.upgradeToAndCall(newImpl, data)` is `onlyOwnerWithTimelock`.

[`FAssetRedeemerAccountProxy`](../../../contracts/composer/proxy/FAssetRedeemerAccountProxy.sol) is a `BeaconProxy`. Its beacon is the composer's proxy address. So `composer.implementation()` returns the current redeemer-account logic; every redeemer account reads through it. Upgrading every redeemer account at once is one timelocked `setRedeemerAccountImplementation` call.

## Trust list

`lzCompose` checks two layers of authorization on every call:

```solidity
require(msg.sender == endpoint, OnlyEndpoint());
require(_from == trustedSourceOApp, InvalidSourceOApp(_from));
```

- `endpoint` is the LayerZero endpoint on Flare. Set at init; not changeable post-deploy.
- `trustedSourceOApp` is the source-chain OFT adapter address that's allowed to send compose messages. Set at init; not changeable post-deploy.

Neither field has a setter. Replacing them is a UUPS upgrade.

## Initialization

```solidity
function initialize(
    address _initialOwner,
    address _endpoint,
    address _trustedSourceOApp,
    IAssetManager _assetManager,
    IERC20 _stableCoin,
    IERC20 _wNat,
    address _composerFeeRecipient,
    uint256 _defaultComposerFeePPM,
    address payable _defaultExecutor,
    address _redeemerAccountImplementation
) external initializer;
```

Every argument is sanity-checked:
- The owner, endpoint, trusted source OApp, composer fee recipient, and default executor must be non-zero.
- The asset manager, stable coin, wNat, fAsset (derived from the asset manager), and redeemer-account implementation must be contracts (`address.code.length > 0`).
- `defaultComposerFeePPM < 1_000_000` (PPM = parts-per-million, so this caps the fee strictly below 100%).

`fAsset = _assetManager.fAsset()` — the composer reads its fAsset target from the asset manager rather than taking it as an argument, so the two can never disagree.

## Mutable configuration

| Setter | Access | What it changes |
|--------|--------|-----------------|
| `setDefaultComposerFee(uint256)` | `onlyOwnerWithTimelock` | `defaultComposerFeePPM`. Capped < 1_000_000. |
| `setComposerFees(uint32[], uint256[])` | `onlyOwnerWithTimelock` | Per-srcEid PPM overrides. Stored as `feePPM + 1` so 0 means "unset". |
| `removeComposerFees(uint32[])` | `onlyOwnerWithTimelock` | Drop per-srcEid overrides. Reverts on unset. |
| `setComposerFeeRecipient(address)` | `onlyOwnerWithTimelock` | Where composer-fee fAsset transfers go. Non-zero. |
| `setRedeemerAccountImplementation(address)` | `onlyOwnerWithTimelock` | Beacon implementation for redeemer accounts. Must be a contract. |
| `setDefaultExecutor(address payable)` | `onlyOwnerWithTimelock` | Executor used when a compose message doesn't specify one. Non-zero. |
| `upgradeToAndCall(address, bytes)` | `onlyOwnerWithTimelock` | UUPS upgrade (overridden to compose with the timelock). |
| `setTimelockDuration(uint256)` | `onlyOwnerWithTimelock` (inherited) | Capped at 7 days. |

Owner-level mutation that is **not** timelocked: `transferOwnership` (from OpenZeppelin's `Ownable`) and `cancelTimelockedCall` (mirroring the diamond's behavior).

## Per-redeemer accounts

When `lzCompose` decodes a `RedeemComposeMessage` for a redeemer the composer hasn't seen before:

```solidity
bytes memory bytecode = abi.encodePacked(
    type(FAssetRedeemerAccountProxy).creationCode,
    abi.encode(address(this), _redeemer)
);
_redeemerAccount = Create2.deploy(0, bytes32(0), bytecode);
redeemerToRedeemerAccount[_redeemer] = _redeemerAccount;
emit RedeemerAccountCreated(_redeemer, _redeemerAccount);
IIFAssetRedeemerAccount(_redeemerAccount).setMaxAllowances(fAsset, stableCoin, wNat);
```

`salt = bytes32(0)`. Deployer = the composer itself (no singleton factory, unlike Smart Accounts). The redeemer-account address is therefore deterministic per `(composer-address, redeemer)` pair: `keccak256(0xff || composerAddress || 0 || keccak256(initcode))[12:]`.

Unlike Smart Accounts' frozen `PROXY_CREATION_CODE`, the composer uses live `type(FAssetRedeemerAccountProxy).creationCode`. Cross-chain address parity is not a property the composer needs — the redeemer interacts only with the chain the composer is deployed on.

Right after deployment, the composer calls `setMaxAllowances(fAsset, stableCoin, wNat)` on the new account. Inside the account this does three `forceApprove(owner, type(uint256).max)` calls — see [Redeemer accounts](./RedeemerAccounts.md).

## Read-side aggregates

`IFAssetRedeemComposer` exposes a handful of view aggregates for off-chain consumption:

| Function | Returns |
|----------|---------|
| `getRedeemerAccountAddress(redeemer)` | Stored address if registered, otherwise the CREATE2 prediction. |
| `isRedeemerAccount(address)` | `(true, owner)` if the address is a deployed redeemer account whose registered redeemer maps back to it. Spoof-resistant via the round-trip check. |
| `getBalances(account)` | `(fAsset, stableCoin, wNat)` token balances for `account` — works for any address, not just redeemer accounts. |
| `getComposerFeePPM(srcEid)` | Effective fee in PPM for a given source endpoint (override if set, default otherwise). |
| `implementation()` | Current redeemer-account logic (IBeacon). |

## Governance

Owner gating uses [`OwnableWithTimelock`](../../../contracts/utils/implementation/OwnableWithTimelock.sol) — semantically identical to the diamond's `TimelockFacet`. See [SmartAccounts/Timelock](../SmartAccounts/Timelock.md) for the timelock pattern; only the storage slot (`erc7201:utils.OwnableWithTimelock.State`) and the owner-check source differ.

There is **no** pause mechanism on the composer. The two emergency knobs are:

1. **UUPS upgrade** to a no-op implementation (timelocked).
2. **Off-chain shutdown** by the LayerZero endpoint / OFT operator — once the source side stops sending compose messages, the composer is idle by construction.

A `cancelTimelockedCall` plus a re-record can be used to alter a pending change without waiting through the original delay.
