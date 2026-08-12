# Loan Subaccounts

A loan subaccount is a deterministic, restricted staging account owned by a [Personal Account](./PersonalAccounts.md), used to stage loan-related assets (FXRP on the way to or from a cross-chain lending flow). It is not a generic smart wallet: it will expose only a fixed set of loan operations, and anyone may trigger only predefined cleanup actions on it.

Status: in progress. The account, its proxy, the per-type implementation registry, controller-side creation/prediction, the account abstraction dispatch, both cleanup moves (`sweepRedeem`, `sweepToLoan`), and the recovery methods (`sweepToParent`, `sweepNativeToParent`) are in place. The LayerZero call (`executeLayerZeroCall`) and the sweep-direction lifecycle are still to come.

## Typed subaccounts

Subaccounts are typed by a raw `uint256` identifier (`0` is reserved and invalid; `1` is the loan type — see the `SUBACCOUNT_TYPE_*` constants in [`ILoanSubaccountsFacet`](../../../contracts/userInterfaces/facets/ILoanSubaccountsFacet.sol)). It is deliberately not a Solidity enum: the proxy creation code — and with it the constructor ABI — gets frozen for deterministic CREATE2 addresses (see below; still pending), and a compiled enum decoder rejects values outside the range it was compiled with, which would make future types undeployable through the frozen artifact. With a raw integer, a new type needs only a registered implementation. Each type has its own implementation contract, registered per type in [`LoanSubaccounts.State.typeImplementation`](../../../contracts/smartAccounts/library/LoanSubaccounts.sol) and managed by the timelocked `setLoanSubaccountImplementation`.

## Deployment model

Subaccounts are deployed as [`LoanSubaccountProxy`](../../../contracts/smartAccounts/proxy/LoanSubaccountProxy.sol) — a minimal proxy (OpenZeppelin `Proxy`) rather than a `BeaconProxy`:

```solidity
contract LoanSubaccountProxy is Proxy {
    address private immutable controller;
    uint256 private immutable subaccountType;

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
- `createLoanSubaccount(xrplOwner, type)` — permissionless, `notPaused`; creates the subaccount for an **existing** Personal Account (reverts with `PersonalAccountNotDeployed` otherwise). Permissionless creation supports the executor-cleanup path: if assets already landed on the predicted address, anyone can materialize the subaccount to sweep them. It is also what a user operation calls before invoking a method on the subaccount. Idempotent — repeated calls return the same address.

Unlike Personal Accounts, which are only ever created as a side effect of an instruction reaching the diamond (`getOrCreatePersonalAccount` inside the instruction entry points), a loan subaccount needs an explicit create: its methods are called **directly** — by the parent Personal Account or by an executor — so there is no diamond hop in that path to create it lazily.

Created subaccounts are recorded in `LoanSubaccounts.State.loanSubaccounts[parentPersonalAccount][subaccountType]` and announced with `LoanSubaccountCreated`.

## Reaching a subaccount's restricted methods

Restricted subaccount methods carry `onlyParent` — the caller must be the parent Personal Account, which is fixed at deployment and is part of the subaccount's address.

They are reached through the existing account abstraction path, with no dedicated instruction type: an XRPL-signed memo (`0xFF`/`0xFE`) carries a `PackedUserOperation` whose `callData` is a `PersonalAccount.executeUserOp` multicall, and one of those calls targets the subaccount.

```text
XRPL memo → MemoInstructionsFacet.handleMintedFAssets → MemoInstructions.execute
          → PersonalAccount.executeUserOp   (onlyController)
          → LoanSubaccount.<method>         (onlyParent)
```

The subaccount type does not need encoding in the instruction: the address already commits to `(parentPersonalAccount, subaccountType)`, so *which* subaccount is called is *which* type is meant. Adding subaccount methods or types therefore needs no controller change, no new memo opcode, and no diamond cut. The controller still enforces pause, nonce, replay protection, executor, and fee on the way in, because that all happens in `handleMintedFAssets` before the user operation runs.

Calling a subaccount that is not deployed yet would **silently succeed** — a call to an address with no code returns success, so `executeUserOp` would not revert. The instruction does nothing, except that any native value it carried is transferred to the codeless address, where it sits until the subaccount is created and `sweepNativeToParent` recovers it. User operations must therefore create the subaccount first. `createLoanSubaccount` is permissionless and idempotent, so it can be the first call of every such operation:

```text
executeUserOp([
  { target: controller,  data: createLoanSubaccount(xrplOwner, Loan) },
  { target: subaccount,  data: <restricted method> }
])
```

## Cleanup moves

Assets can strand at the subaccount whenever a cross-chain flow breaks part-way. Both directions out are permissionless, so an executor — or anyone — can clear them:

- **`sweepRedeem()`** — the backward move. Redeems idle FXRP to the parent Personal Account's XRPL owner through FAssets. It takes **no parameters**: the destination is read on-chain from the parent account, the executor and fee come from the controller, and `msg.value` must cover the fee. Reverts with `NothingToRedeem` rather than no-op, so a caller's value is returned instead of being trapped on the account.

  It calls `redeemAmount` (the UBA-based entry point on `IRedeemExtended`, which the asset manager implements) with the **whole balance**, rather than `redeem`, which only accepts whole lots. A cleanup method that redeemed whole lots would strand the remainder — up to one lot short of a full sweep — with no way out, which defeats the purpose. FAssets may still redeem less than requested when redemption tickets run out; the remainder simply stays on the account and can be swept again.
- **`sweepToLoan()`** — the forward move. Bridges idle FXRP onward to the loan chain over LayerZero. It also takes **no parameters**, for the same reason: the destination is **this account's own address**, which is identical on every chain because it is CREATE2-derived from inputs that do not vary by chain, and the destination chain and OFT come from governance-set controller settings (`setLoanBridgeSettings`, timelocked). So a permissionless caller has nothing to point at. `msg.value` must cover the LayerZero messaging fee; the exact quoted fee is forwarded and any excess is returned to the caller rather than left on an account with no native exit.

  The FXRP OFT is a lock/unlock adapter (`approvalRequired() == true`), so the sweep approves it for the exact amount and resets the allowance to zero afterwards. It reverts while the controller is paused: the forward sweep is the incident-containment surface (an OFT or route compromise is stopped by pausers immediately, without waiting out the timelock), while `sweepRedeem` stays available during a pause so assets can always exit toward the user. `setLoanBridgeSettings` validates that the OFT wraps the FXRP token, shares its decimals, and that its live peer for the destination endpoint equals the **pinned expected peer** exactly — existence alone would accept a wrong route — so misconfiguration fails at the timelocked call, not in the field; explicit zeros clear the settings, which disables the forward sweep until reconfigured. Every `sweepToLoan` re-checks the OFT's live peer against the pinned one before locking FXRP, so a peer mutation on the OFT after configuration fails sweeps closed instead of routing to an unknown remote OApp. No compose message is attached: this is cleanup, moving the assets across, and depositing them into the lending protocol is a separate forward move on the destination side. FXRP and the OFT both use 6 decimals, so nothing is lost to shared-decimal dust and `minAmountLD` equals the full amount.

### Recovery to the parent Personal Account

Not everything that can land on a subaccount is FXRP. A FAssets redemption default pays the
redeemer — this account — in vault collateral (a stablecoin) and/or pool WNat; bridges and
redemptions can refund native; an instruction can send value to the predicted address before the
subaccount exists (the account has a `receive()` for native). None of those assets have a bridge
or redeem exit here, so two permissionless recovery methods push them to the parent Personal
Account, which accepts any asset and is fully under the user's control:

- **`sweepToParent(token)`** — recovers a token balance. The caller chooses only *which* asset,
  never where it goes. FXRP is special-cased: only a residual **below** the FAssets minimum
  redemption amount can be recovered this way (the complement of `sweepRedeem`, which requires
  at least the minimum), so recovery cannot become a third direction for the loan asset.
- **`sweepNativeToParent()`** — recovers the native balance.

Both stay available while the controller is paused: the parent is the safest possible
destination, and an incident should not trap assets.

When the agent does not pay the underlying XRP for a redemption, someone must trigger the
**redemption payment default**. FAssets permits that only from the recorded redeemer (this
account), the appointed executor, or the agent owner — so relying on the appointed executor
alone would make it a single point of failure. The account therefore exposes permissionless
relays, `redemptionPaymentDefault` and `xrpRedemptionPaymentDefault` (mirroring
`FAssetRedeemerAccount`): FAssets validates the proof and the request, the relay acts as the
redeemer, and the payout always lands on this account, where `sweepToParent` recovers it.

## Who may choose a destination

Two different rules apply, and the difference is the signature:

- **Instruction destinations are the user's choice.** A borrow names where the RLUSD goes, and the XRPL signature authorizes it. Two forms are supported: an XRPL address reached over Wormhole, or a plain EVM address (typically an exchange deposit address), which the Ethereum-side account transfers to directly. The EVM address is not validated — it is the user's money and the user's choice, the same way the XRPL target is already allowed to be an arbitrary account. The destination kind and the address travel inside the `executeLayerZeroCall` payload, which this repo treats as opaque; the payload format needs a destination-kind tag, to be pinned down when the LayerZero schema is frozen.
- **Cleanup destinations are never the caller's choice.** Sweeps are permissionless and carry no signature, so their destination must be derived on-chain from `parentPersonalAccount` — never from caller-supplied data. Anyone may move stranded assets; nobody may redirect them.

Caveats specific to the EVM disbursement option, for the front end rather than the contracts: RLUSD is a regulated stablecoin and can freeze or blacklist addresses, so a transfer can revert and turn a borrow into a stuck disbursement; some exchange deposit addresses are not credited when the sender is a contract, or need a tag an ERC-20 transfer cannot carry; and a wrong address is unrecoverable, since nothing is checked.

## Open design items (decide with the asset-moving methods)

- **Stuck RLUSD on the Ethereum side has only one move: repay.** RLUSD arriving there is indistinguishable between an inbound repayment and a borrow whose outbound leg failed, and a borrow may name an arbitrary destination, so a permissionless "send onward" would let anyone redirect a repayment to a third party. Repay is safe under every interpretation, since its target is the account's own position. The cost is that a failed disbursement silently unwinds the loan the user asked for. A bounded retry is possible if the account records the pending disbursement (amount plus destination) at borrow time, so the retry is driven by stored state rather than calldata; that is likely the same state needed to prevent double borrows when a LayerZero message stalls. Product decision, to settle before the Ethereum-side work.
- ~~Native payability~~ — resolved: the account has `receive()` and `sweepNativeToParent()`, since external refund behavior (FAssets, LayerZero, bridges) is not under this repo's control.
