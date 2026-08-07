# Loan Subaccounts

A loan subaccount is a deterministic, restricted staging account owned by a [Personal Account](./PersonalAccounts.md), used to stage loan-related assets (FXRP on the way to or from a cross-chain lending flow). It is not a generic smart wallet: it will expose only a fixed set of loan operations, and anyone may trigger only predefined cleanup actions on it.

Status: scaffolding. The account, its proxy, the per-type implementation registry, and controller-side creation/prediction are in place. Asset-moving methods (sweeps, LayerZero calls) and the instruction dispatch are added in later steps.

## Typed subaccounts

Subaccounts are typed by [`ILoanSubaccountsFacet.SubaccountType`](../../../contracts/userInterfaces/facets/ILoanSubaccountsFacet.sol) (`None` is reserved; `Loan` is the first real type). Each type has its own implementation contract, registered per type in [`LoanSubaccounts.State.typeImplementation`](../../../contracts/smartAccounts/library/LoanSubaccounts.sol) and managed by the timelocked `setLoanSubaccountImplementation`.

## Deployment model

Subaccounts are deployed as [`LoanSubaccountProxy`](../../../contracts/smartAccounts/proxy/LoanSubaccountProxy.sol) — a minimal proxy (OpenZeppelin `Proxy`) rather than a `BeaconProxy`:

```solidity
contract LoanSubaccountProxy is Proxy {
    address private immutable controller;
    ILoanSubaccountsFacet.SubaccountType private immutable subaccountType;

    function _implementation() internal view override returns (address) {
        return ILoanSubaccountsFacet(controller).loanImplementationForType(subaccountType);
    }
}
```

The controller (diamond) is still the beacon in spirit — it answers the implementation lookup and upgrades all subaccounts of a type in one timelocked call — but the proxy asks the type-aware question `loanImplementationForType(type)` instead of the parameterless `IBeacon.implementation()`. The parameterless selector on the diamond is already claimed by [`PersonalAccountsFacet`](../../../contracts/smartAccounts/facets/PersonalAccountsFacet.sol) for Personal Account proxies, and a diamond routes one selector to exactly one facet; the typed variant lets both account families share the diamond as their upgrade authority without touching the PA path.

The proxy's constructor delegate-calls `initialize(controller, parentPersonalAccount, subaccountType)` on the implementation. The implementation contract locks itself in its own constructor, so only proxies can be initialized.

## CREATE2 derivation

Like PAs, subaccounts are deployed via the [EIP-2470 Singleton Factory](https://eips.ethereum.org/EIPS/eip-2470). [`LoanSubaccounts.createLoanSubaccount`](../../../contracts/smartAccounts/library/LoanSubaccounts.sol) builds the init code as:

```solidity
abi.encodePacked(
    type(LoanSubaccountProxy).creationCode,
    abi.encode(address(this) /* diamond */, _parentPersonalAccount, _subaccountType)
)
```

with `salt = bytes32(0)`. The subaccount address is therefore a pure function of `(diamond, parentPersonalAccount, subaccountType)` — per-type and per-account unique, and identical on every chain where the diamond has the same address. No implementation or beacon address enters the derivation, so implementation upgrades never move addresses.

> **Freeze before first use:** the derivation currently uses `type(LoanSubaccountProxy).creationCode`. Before the first production deployment — or the first time a predicted address is handed out — this must be frozen to a hex constant with a pinned-hash test, exactly like [`PersonalAccounts.PROXY_CREATION_CODE`](./PersonalAccounts.md#frozen-proxy_creation_code). Until then, any change to the proxy source shifts all predicted addresses.

## Creation and prediction

- `getLoanSubaccount(xrplOwner, type)` — view; returns the registered subaccount, or the computed address if not yet deployed. Works even before the parent PA exists (the PA address itself is deterministic).
- `createLoanSubaccount(xrplOwner, type)` — permissionless, `notPaused`; creates the subaccount for an **existing** Personal Account (reverts with `PersonalAccountNotDeployed` otherwise). Permissionless creation supports the executor-cleanup path: if assets already landed on the predicted address, anyone can materialize the subaccount to sweep them. Idempotent — repeated calls return the same address.

Created subaccounts are recorded in `LoanSubaccounts.State.loanSubaccounts[parentPersonalAccount][subaccountType]` and announced with `LoanSubaccountCreated`.

## Open design items (decide with the asset-moving methods)

- **Native payability.** The implementation currently has no `receive()`, so plain FLR transfers revert (the proxy's payable fallback delegates to the implementation, which rejects empty calldata). Payability is an implementation-level property — it can be added later via a beacon upgrade with no effect on CREATE2 addresses. Decide as a pair when the sweeps are implemented: either stay non-payable *and* verify the redeem/LayerZero integrations never refund native to the account (a refund against a non-payable account reverts the whole flow), or add `receive()` *plus* a permissionless `sweepNative()` that pushes the balance to the parent Personal Account (fixed destination, consistent with the sweep philosophy). Lean: payable + exit, since external refund behavior (FAssets, LayerZero, bridges) is not under this repo's control.
