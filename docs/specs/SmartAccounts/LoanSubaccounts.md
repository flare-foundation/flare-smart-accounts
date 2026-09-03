# Loan Subaccounts

A loan subaccount is a deterministic, restricted staging account owned by a [Personal Account](./PersonalAccounts.md), used to stage loan-related assets (FXRP on the way to or from a cross-chain lending flow). It is not a generic smart wallet: it will expose only a fixed set of loan operations, and anyone may trigger only predefined cleanup actions on it.

Status: the contract surface described here is implemented — the account and its proxy, the per-type implementation registry, creation and prediction, the account abstraction dispatch, the Flare-side loan instructions, the loan-chain-side account with its compose entry point, market binding, permissionless rails and signed exit, and the Flare fee. Two behaviors are worth naming up front: each account has exactly one permissionless direction (on Flare, `sweepRedeem` home — forward moves are signed), and redemption belongs to the parent Personal Account, so the subaccount carries no redemption-default relays. Production activation remains gated by the **Deployment** checklist.

## Typed subaccounts

Subaccounts are typed by a raw `uint256` identifier (`0` is reserved and invalid; `1` is the loan type — see the `SUBACCOUNT_TYPE_*` constants in [`ISubaccountsFacet`](../../../contracts/userInterfaces/facets/ISubaccountsFacet.sol)). It is deliberately not a Solidity enum: the proxy creation code — and with it the constructor ABI — is frozen for deterministic CREATE2 addresses (see below), and a compiled enum decoder rejects values outside the range it was compiled with, which would make future types undeployable through the frozen artifact. With a raw integer, a new type needs only a registered implementation. Each type has its own implementation contract, registered per type in [`Subaccounts.State.typeImplementation`](../../../contracts/smartAccounts/library/Subaccounts.sol) and managed by the timelocked `setSubaccountImplementation`.

## Deployment model

Subaccounts are deployed as [`SubaccountProxy`](../../../contracts/smartAccounts/proxy/SubaccountProxy.sol) — a minimal proxy (OpenZeppelin `Proxy`) rather than a `BeaconProxy`:

```solidity
contract SubaccountProxy is Proxy {
    address private immutable controller;
    uint256 private immutable subaccountType;

    function _implementation() internal view override returns (address) {
        return ISubaccountsFacet(controller).implementationForType(subaccountType);
    }
}
```

The controller (diamond) is still the beacon in spirit — it answers the implementation lookup and upgrades all subaccounts of a type in one timelocked call — but the proxy asks the type-aware question `implementationForType(type)` instead of the parameterless `IBeacon.implementation()`. The parameterless selector on the diamond is already claimed by [`PersonalAccountsFacet`](../../../contracts/smartAccounts/facets/PersonalAccountsFacet.sol) for Personal Account proxies, and a diamond routes one selector to exactly one facet; the typed variant lets both account families share the diamond as their upgrade authority without touching the PA path.

The proxy's constructor delegate-calls `initialize(controller, parentPersonalAccount, subaccountType)` on the implementation. The implementation contract locks itself in its own constructor, so only proxies can be initialized.

One standing assumption is recorded here: OpenZeppelin's `Proxy._delegate` does not check that the implementation has code, so a type whose implementation became codeless would make every proxy call succeed silently (and accept native). It is unreachable today — `setSubaccountImplementation` requires code at the address, the constructor's `initialize` delegate-call reverts on a codeless implementation (`AddressEmptyCode`), and post-Dencun code cannot disappear — but any future registration path that skipped the code check would reopen it.

## CREATE2 derivation

Like PAs, subaccounts are deployed via the [EIP-2470 Singleton Factory](https://eips.ethereum.org/EIPS/eip-2470). [`Subaccounts.createSubaccount`](../../../contracts/smartAccounts/library/Subaccounts.sol) builds the init code as:

```solidity
abi.encodePacked(
    PROXY_CREATION_CODE, // frozen type(SubaccountProxy).creationCode
    abi.encode(address(this) /* diamond */, _parentPersonalAccount, _subaccountType)
)
```

with `salt = bytes32(0)`. The subaccount address is therefore a pure function of `(diamond, parentPersonalAccount, subaccountType)` — per-type and per-account unique, and identical on every chain where the diamond has the same address. No implementation or beacon address enters the derivation, so implementation upgrades never move addresses.

> **Frozen:** the derivation uses the frozen `Subaccounts.PROXY_CREATION_CODE` hex constant, exactly like [`PersonalAccounts.PROXY_CREATION_CODE`](./PersonalAccounts.md#frozen-proxy_creation_code). Its hash is pinned in `test/SubaccountsLibrary.t.sol`, and two further tests compare it against a fresh compilation of the proxy source (by length, and byte-exact modulo CBOR metadata), so any drift fails CI. Editing the constant or the proxy source is a cross-chain coordination event: all predicted-but-not-deployed subaccount addresses would shift. Re-frozen twice pre-deployment: 2026-08-21, when the beacon query was renamed to `implementationForType`, and 2026-08-26, when the proxy contract was renamed to `SubaccountProxy` (the generic deployment vehicle had kept its loan-era name); no subaccount address had shipped either time, so nothing moved on chain.

## Creation and prediction

- `getSubaccount(xrplOwner, type)` — view; returns the registered subaccount, or the computed address if not yet deployed. Works even before the parent PA exists (the PA address itself is deterministic).
- `createSubaccount(xrplOwner, type)` — permissionless, `notPaused` and idempotent. The parent Personal Account resolves to the registered account when one exists and to its computed address otherwise — the same fallback `getSubaccount` uses — so creation works before the Personal Account exists, and on chains where PAs never exist at all. That is what supports the executor-cleanup path: if assets already landed on the predicted address, anyone can materialize the subaccount to sweep them without waiting for the parent. A subaccount created before its PA is only **partly** inert: `onlyParent` methods have no possible caller, and `sweepRedeem` at or above the FAssets minimum reverts because it calls the codeless parent, while below the minimum — the branch that never calls parent code — it parks the FXRP at the future PA address, whose later CREATE2 deployment a pre-existing balance does not block. Anyone can materialize the parent through the permissionless `createPersonalAccount`, and it deploys at exactly the recorded address, owning whatever was parked. One qualification: this holds for a valid owner string — the route accepts any string, but a Personal Account cannot be created for an empty one, so an empty-owner subaccount is permanent caller-funded junk with no custody or collision impact.

Unlike Personal Accounts, which are created lazily as a side effect of an instruction reaching the diamond (`getOrCreatePersonalAccount` inside the instruction entry points) or explicitly through the permissionless `createPersonalAccount`, a loan subaccount always needs an explicit create: its methods are called **directly** — by the parent Personal Account or by an executor — so there is no diamond hop in that path to create it lazily.

Created subaccounts are recorded in `Subaccounts.State.subaccounts[parentPersonalAccount][subaccountType]` and announced with `SubaccountCreated`.

## Reaching a subaccount's restricted methods

Restricted subaccount methods carry `onlyParent` — the caller must be the parent Personal Account, which is fixed at deployment and is part of the subaccount's address.

They are reached through the existing account abstraction path, with no dedicated instruction type: an XRPL-signed memo (`0xFF`/`0xFE`) carries a `PackedUserOperation` whose `callData` is a `PersonalAccount.executeUserOp` multicall, and one of those calls targets the subaccount.

```text
XRPL memo → MemoInstructionsFacet.handleMintedFAssets → MemoInstructions.execute
          → PersonalAccount.executeUserOp   (onlyController)
          → LoanSubaccount.<method>         (onlyParent)
```

The subaccount type does not need encoding in the instruction: the address already commits to `(parentPersonalAccount, subaccountType)`, so *which* subaccount is called is *which* type is meant. Adding subaccount methods or types therefore needs no controller change, no new memo opcode, and no diamond cut. The controller still enforces pause, nonce, replay protection, executor, and fee on the way in, because that all happens in `handleMintedFAssets` before the user operation runs.

Calling a subaccount that is not deployed yet would **silently succeed** — a call to an address with no code returns success, so `executeUserOp` would not revert. The instruction does nothing, except that any native value it carried is transferred to the codeless address and strands there — the subaccount has no native exit (accepted; see **No token recovery rail**). User operations must therefore create the subaccount first. `createSubaccount` is permissionless and idempotent, so it can be the first call of every such operation:

```text
executeUserOp([
  { target: controller,  data: createSubaccount(xrplOwner, Loan) },
  { target: subaccount,  data: <restricted method> }
])
```

## Cleanup moves

Assets can strand at the subaccount whenever a cross-chain flow breaks part-way. By policy,
every account has **one permissionless direction**: an arrival has exactly one free meaning,
and everything else is a user-signed action. On this account the free direction is home —
FXRP on the Flare subaccount means redemption:

- **`sweepRedeem()`** — the backward move, in five parts:
  - It moves all idle FXRP to the parent and calls `PersonalAccount.redeemFromSubaccount(amount)`, which the parent accepts only from its own deterministic subaccounts (the controller's prediction for the owner and the caller's type must be the caller). The parent **pulls exactly the pushed amount and redeems exactly that**, so its own balance is never part of a subaccount-initiated redemption.
  - It takes **no parameters**: the destination is the parent (fixed at deployment, part of the address), the executor comes from the controller, and `msg.value` travels whole as the fee (FAssets records it in whole gwei). Public callers must cover the controller's **configured executor fee** — the price of the permissionless rail, so forcing the backward direction is never gas-only (see the accepted risk below) — while `redeemFromSubaccount` itself forwards whatever it receives, leaving an authenticated route free to send less or nothing (the executor stays appointed, unpaid). An empty balance reverts with `NothingToRedeem` rather than no-op, so a caller's value is returned instead of being trapped.
  - The parent calls `redeemAmount` (the UBA-based entry point on `IRedeemExtended`) with the **whole pushed balance** rather than `redeem`, which only accepts whole lots and would strand the remainder. A balance below the FAssets minimum is pushed to the parent **unredeemed** instead (FAssets would reject it): `redeemedAmount` is zero, the value joins the parent's float (`NativeSweptToParent`), and `TokenSweptToParent` is emitted — the rail never fails on amount and costs the configured fee either way.
  - The parent's redemption runs in its **own reentrancy-guard domain**, because the legitimate path (`executeUserOp` → `sweepRedeem` → `redeemFromSubaccount`) re-enters the parent while its shared guard is held. The nesting is bounded: the method pulls before it redeems and writes no account state, so a redemption reached from beneath any guarded method (no dependency does that today) cannot touch the parent's pre-existing FXRP, and a nested redemption is refused by the guard.
  - The same core runs when FXRP comes home from the loan chain: the twin's `sweepToOrigin` attaches the `ACTION_REDEEM_HOME` compose (its only field a deadline, the sender's block time plus `REDEEM_HOME_TTL`), this account authenticates it exactly as the loan-chain accounts authenticate theirs (the shared base, with the transport read from the bridge settings) and redeems **at most the packet's authenticated amount** on arrival (`min(balance, amountLD)`; the rest stays for the public rail — FXRP is fungible, so the cap bounds how much one compose can move, not which units), with the compose value as the executor fee. Zero is allowed there: the packet already cost its sender the LayerZero fee. Past its deadline the packet skips terminally (nothing redeemed, the balance left for the public rail, value to the parent's float), so a packet cannot outlive its delivery window as a standing instruction over later funds. In both the dust branch and the skip, value goes to the parent — never to `msg.sender`, which on that path is the endpoint.

  The parent is the **recorded redeemer**. That is the point of the relocation: every redemption outcome — a partial fill, a payment-default payout, a refund — lands on the parent, where `executeUserOp` already handles anything, including triggering the payment default directly on the asset manager. The subaccount keeps no redemption-request or default state and no relay methods; `sweepRedeem` is its one redemption method.

The forward direction — moving staged or stranded Flare-side FXRP onward into the position —
is the **signed** `depositCollateral`, which bridges from this account's own balance, so no
transfer call is needed. The Flare account therefore has one permissionless direction
(`sweepRedeem` home) and requires the user's signature for forward movement, which deletes the
sweep-direction race on this chain outright. The invariant that matters is unchanged: anyone
may move the assets toward the user, nobody may redirect them.

> **Integration note:** this intentionally differs from the handoff design. Forward recovery
> requires a user signature; executors must not assume a permissionless forward bridge.

The remaining openness is an **accepted risk** against the loan instruction: a stranded balance
awaiting a parent-signed `borrow` can be redeemed out from under it, aborting the requested loan
action. Only *retry-after-strand* is exposed — the primary flow is atomic on the Flare leg: one
`handleMintedFAssets` transaction mints the FXRP, funds the Personal Account, creates the
subaccount, transfers and bridges with the payload, so the subaccount balance never exists
outside that transaction and there is nothing to front-run on this chain (a test covers the five
steps in one transaction; the destination side has its own, separately accepted window — see the
loan-chain-side section). In the retry window the permissionless `sweepRedeem` can preempt a
signed borrow, but it sends the funds only through the user's own redemption path and costs the
configured executor fee, while the user bears the repeat mint-and-bridge cost. This griefing is
accepted, not solved; revisit if it is ever observed in practice. No other method moves FXRP off
this account. One further residual is bounded and accepted: a redeem-home packet whose credit a
public rail already moved stays retriable for its TTL and can then redeem at most its own amount
out of funds that arrive later, for destination gas alone — bounded in amount (its own credit)
and time (`REDEEM_HOME_TTL`), with custody unchanged (the user's own redemption).

### No token recovery rail

There is deliberately no recovery method for non-FXRP tokens: no protocol flow ever delivers
one here (RLUSD lives on the loan chain, redemption outcomes land on the parent, the bridge
refunds its caller), so the only sources are out-of-protocol — a mistaken send, airdrop dust.
Such a balance strands until a beacon upgrade adds a rail, the same treatment as native and
for the same reason: nobody in the protocol causes it, and every method the account does have
exists for an asset the protocol actually routes here. The remote subaccount has no generic
recovery either; both assets the protocol routes there have their own rails — FXRP through
`depositIdleFxrp`/`sweepToOrigin`, and the loan-token surplus of a closed position through
`repay` itself, which pushes it to the parent (best-effort: a push the token refuses is
retried by any later `repay`).

**No native rail.** There is no `receive()` and no native exit, and no protocol flow leaves
native on the subaccount: the bridge refunds its caller, redemption outcomes land on the parent,
and the one protocol-delivered native — the compose value of its own twin's bridge-back — is
forwarded whole within the same call (a revert unwinds it). A plain send reverts at the sender.
Native can still land without a call: sent with an instruction to the predicted address before
the subaccount existed, or force-sent. Such a balance strands — accepted, since nobody in the
protocol causes it; a beacon upgrade can add an exit if it ever matters. The same policy as the
loan-chain subaccount.

When the agent does not pay the underlying XRP for a redemption, someone must trigger the
**redemption payment default**, which seizes the agent's locked collateral and pays it to the
redeemer. FAssets permits that only from the recorded redeemer, the appointed executor, or the
agent owner. The recorded redeemer is the **parent Personal Account**, so the user triggers the
default directly on the asset manager through `executeUserOp` — no relay on the subaccount, and
the payout (vault collateral and/or pool WNat) lands on the parent. The parties able to default
are exactly the three FAssets intends: the user (through the parent account), the appointed
executor (directly), and the agent (directly). Two operational notes carry over:

- **A user-triggered default forfeits the executor fee funded at sweep time**: the asset manager pays it only
  when the executor is its immediate caller. The executor calling directly is the cheap path;
  the user's own call is the fallback that removes the executor as a single point of failure.
- **The user's path is unreachable while the controller is paused**: the parent only acts
  through the instruction pipeline, which is `notPaused`. The appointed executor's direct path
  is unaffected by our pause, so defaults keep their normal operational trigger during an
  incident. Operationally: unpause promptly, and keep executor monitoring alive during
  incidents.

Integration note: the XRP proof's `proofOwner` must be requested as zero or **the parent
Personal Account's address** — the asset manager sees the parent as the caller, not the
subaccount the FXRP came from.

## The loan instructions: `borrow`, `depositCollateral` and `withdraw`

The forward moves are the **loan
instructions**: `borrow(collateralAmount, borrowAmount, destinationKind, destination,
operationId, deadline, extraOptions)`, `depositCollateral(amount, operationId, deadline,
extraOptions)` and `withdraw(amount, operationId, deadline, options)`: typed methods that
build the compose payload
**on-chain** and bridge it to this account's own address on the loan chain, where the
loan-chain twin executes it on arrival (supply as collateral, borrow, disburse; deposit
collateral only; the atomic withdrawal — withdraw collateral and bridge it back here in the
same execution, redeemed on arrival). The payload is not passed in: what the user signs is
structured and type-checked, a malformed payload cannot reach the bridge, and the arguments
are validated here — before any bridge fee is paid — for the static argument shapes the loan
chain would reject on delivery (`InvalidLoanInstruction`: zero operation id, deadline already
passed, a zero borrow, deposit or withdrawal amount, a disbursement destination that is not a
clean non-zero EVM address other than this account, a zero withdraw delivery-value floor).
Remote-state rejections — unconfigured fee terms, the pause, the borrow switch, balances,
quotes, Morpho itself — surface only on delivery; the loan chain also re-validates the shapes
there.

The withdraw is the one instruction with a second leg, so it takes
`WithdrawOptions` — `{destinationOptions, returnOptions, minComposeValue}`. The first
blob funds the loan-chain delivery and, as compose value, prepays the return send; the second
configures the Flare compose (the redeem-home gas and, optionally, the redemption's executor fee
as compose value). The **signed delivery-value floor** stops an underfunded permissionless
delivery from consuming the packet — LayerZero does not authenticate the delivered value, so
without it anyone could execute the packet with less than the prepaid headroom, or terminal-skip
an expiring one with zero, and the prepaid value would never reach the user; the loan chain
refuses any delivery below the floor, which stays retriable. The wallet must keep the two
consistent: because the floor is checked before the expiry skip, a compose value bought below
the signed floor makes a packet that reverts on every delivery, even after its deadline, and
never finalizes — no funds are at risk (the value was never delivered) and a same-id reissue
executes normally, but the orphan stays in the endpoint's queue until someone delivers it with
value of their own. Quote the return leg first
(`quoteSend` on the loan chain is a view), put that fee plus headroom into `destinationOptions`
as compose value and the same number into `minComposeValue`, then quote and send the first
message; the excess lands on the remote Personal Account — the user's own account — so generous
headroom is not lost (the LayerZero delivery itself may still cost more). Both blobs are signed
end-to-end: invalid `returnOptions` are frozen into the packet and park that withdrawal until a
fresh instruction reissued with the **same operation id**, so the parked packet terminal-skips as
a duplicate instead of surviving as a second live withdrawal. That residual is the accepted cost
of not making the return route a governance setting, which could not carry the per-transaction
redemption fee and would go stale for every in-flight withdrawal at once; the redemption fee
bought inside `returnOptions` stays best-effort on the second leg, since the Flare redeem-home
accepts zero value by design — the executor goes unpaid, never a custody change.

The three are separate instructions with separate actions — a borrow always increases debt
(`borrowAmount` non-zero), `depositCollateral` never does — so each carries exactly the
fields it needs and its own pause rule (a deposit is the defensive move; see the loan-chain
section).
`borrow`'s collateral amount is explicit rather than the whole balance: what travels becomes
the authenticated collateral figure on the destination (the OFT's `amountLD`), so the user
signs exactly what is collateralized, and idle residue — donations, strands from skipped
deliveries — stays behind for the cleanup moves. A **zero collateral amount is a
message-only send** (verified against the live adapter): a borrow against existing
collateral, or a withdraw, which never carries tokens. Only the cleanup moves keep
whole-balance semantics, because sweeping everything is what cleanup means. All three
instructions share one bridging core in the contract, so the guards are identical by
construction: a paused
controller blocks it, the governance-pinned settings name the route, and the OFT's live peer
is re-checked against the pinned one on every call. What differs is authorization and inputs:

- **Restricted to the parent Personal Account** (`onlyParent`): the instruction names a loan
  action and, for a borrow, a user-chosen destination for the proceeds, so it must carry the
  user's XRPL signature. This is the instruction-destination rule below, in contract form.
- **The payload schema is shared with the loan-chain account**, not opaque: the constants
  (`PAYLOAD_VERSION_1`, `ACTION_BORROW`, `ACTION_DEPOSIT_COLLATERAL`,
  `ACTION_WITHDRAW`, `DESTINATION_KIND_*`) are imported
  from the loan-chain interfaces, so the tags cannot drift apart. The per-action tuple layouts
  are duplicated by construction (the sender encodes, the receiver decodes) and are held equal
  by tests: byte-equality of every sender payload against an independently built one, and a
  sender→codec→receiver test that executes the bytes the Flare senders hand to `send` on the
  real loan-chain receivers.
- **The execution options (`extraOptions`) are caller-supplied.** The FXRP OFT adapter enforces
  options only for plain sends (`SEND`, 100k destination gas). For composed sends
  (`SEND_AND_CALL`) its enforced options are empty — which does not block the send (verified
  against the live adapter) but leaves the caller responsible for the complete options:
  destination `lzReceive` gas plus `lzCompose` gas. The options must be **type-3**: once the
  adapter's owner enforces msgType-2 options, LayerZero's `combineOptions` prepends them to the
  caller's and *rejects* non-type-3 caller options outright, and the combined enforced gas
  raises the quoted fee (unboundedly in principle — the quote is taken before sending, so a
  raised fee fails the instruction rather than draining anything).
- The quoted messaging fee is forwarded and any excess `msg.value` returns to the caller (the
  parent).

Destination-side mechanics: the compose receiver is the token recipient — this account's own
address on the loan chain — which must implement `ILayerZeroComposer` (the loan-chain-side
implementation of this same account). Token credit and compose execution are separate steps in
LayerZero: if `lzCompose` fails, the FXRP is already on the destination account, and the
compose call can be retried permissionlessly through the endpoint.

**Release gates for the loan-chain-side account** (none of this is enforceable from the Flare
side):

- **`lzCompose` must authenticate the composed payload.** Anyone holding FXRP can call the
  public OFT directly, name another user's subaccount as recipient, and attach an arbitrary
  borrow/disbursement payload. The canonical OFT encoding records the *source-side caller* as
  `composeFrom` (`OFTMsgCodec.encode`), so the receiver must verify **all** of: `msg.sender`
  is the LayerZero `EndpointV2`, `_from` is the pinned FXRP OFT, the source EID is Flare, and
  `composeFrom == address(this)` — only the account itself calls `send` on the Flare side, and
  it has the same address on both chains, so the check is self-referential. The credited
  amount must be read from the codec (`amountLD`), never from the payload; the executor and
  any extra data are untrusted. A payload failing these checks must not execute: the
  delivery reverts (retriable through the endpoint) and the attached tokens stay on the
  account.
- **Idle FXRP on the loan-chain account needs an exit** — satisfied: `depositIdleFxrp()`
  (forward, into the account's own position, permissionless) and the parent-signed
  `sweepToOrigin(options)` (backward, to the
  account's own Flare address, redeemed on arrival) are the two rails; neither carries a
  destination — both are fixed on-chain, so nobody may redirect.
- **A real Endpoint/OFT compose-delivery simulation** belongs to the loan-chain-side test suite
  as a regression test; the live-adapter verification recorded here is evidence, not a test.
  Still open for the wire hop (a real `EndpointV2` and the OFT's `lzReceive → sendCompose`),
  and it must cover all the actions (borrow, deposit, the atomic withdraw with its return leg, remote-PA execute) — the remote-PA case with a
  native drop into the real beacon proxy followed by a value-carrying batch, since unit tests fund
  the remote PA with `vm.deal` and never exercise the executor's gas-limited drop. Covered
  locally: a sender→codec→receiver test runs the bytes the Flare senders hand to `send` through
  the canonical `OFTComposeMsgCodec` wrapper into the real loan-chain receivers.

## Who may choose a destination

Two different rules apply, and the difference is the signature:

- **Instruction destinations are the user's choice.** A borrow names where the RLUSD goes, and the XRPL signature authorizes it. Version 1 implements only the EVM/ERC-20 form (typically an exchange deposit address), paid by a direct transfer; the XRPL-over-Wormhole form is reserved by the payload's destination-kind tag and added when Wormhole provides specs. The EVM address is checked for shape only — clean zero-padded, non-zero, and not the subaccount itself (the proceeds could only repay the new debt); the parent Personal Account, the user's own compose-driven account on the loan chain, is a valid target — beyond that it is the user's money and the user's choice, the same way the XRPL target is already allowed to be an arbitrary account.
- **Cleanup destinations are never the caller's choice.** The cleanup moves and the surplus push — permissionless (`sweepRedeem`, `depositIdleFxrp`, `repay`) or parent-signed (`sweepToOrigin`, `payLoanFee`) — carry no destination input: it is derived on-chain — the account's own position, its own address on the other chain, `parentPersonalAccount`, or (for the fee leg of `repay` and for `payLoanFee`) the governance-set fee recipient — never from caller-supplied data. Whoever may move the assets the protocol routes, nobody may redirect them (a stray token has no rail at all and strands).

Caveats specific to the EVM disbursement option, for the front end rather than the contracts: RLUSD is a regulated stablecoin and can freeze or blacklist addresses, so a transfer can revert and turn a borrow into a stuck disbursement; some exchange deposit addresses are not credited when the sender is a contract, or need a tag an ERC-20 transfer cannot carry; and a wrong address is unrecoverable, since nothing is checked.

## The loan-chain-side account

The same frozen proxy bytecode and the same derivation give the subaccount one address on every
chain, and the per-type implementation registry is what makes that useful: each chain's diamond
registers its **own** implementation for the loan type. Flare registers
[`LoanSubaccount`](../../../contracts/smartAccounts/implementation/LoanSubaccount.sol) (FAssets
redemption pushed to the parent, the forward bridge); the loan chain (Ethereum, at
launch) registers
[`LoanSubaccountRemote`](../../../contracts/smartAccounts/implementation/LoanSubaccountRemote.sol).
The implementation never enters the CREATE2 derivation, so the registration choice cannot move
the address (a test pins this).

The defining difference on the loan chain: **almost nothing is parent-driven.** The parent
Personal Account has no local key on the loan chain — instructions exist only on Flare, and
its loan-chain presence is the compose-driven remote Personal Account described below. Every authorized action
arrives as an authenticated LayerZero compose payload sent by this same account on Flare
(`borrow`, `depositCollateral`, `withdraw`), with two exceptions: the subaccount's
`onlyParent` methods, the signed exit `sweepToOrigin` and the signed fee payment `payLoanFee`,
whose only permitted caller is the remote Personal Account — reachable only through the user's
cross-chain user operation, and able only to send idle FXRP to this account's own fixed Flare
address, or the parent's own RLUSD to the fee recipient up to what is owed and the signed cap.
Everything else is permissionless movement along fixed rails, the same invariant as
everywhere: anyone may move the assets toward the user, nobody may redirect them (the one
fixed destination that is not the user's own is the governance-set fee recipient of the
Flare fee's collection legs — still never a caller's choice).

The account's configuration lives in two facets, both cut **only on the remote diamond**
(Ethereum, at launch):

- **The compose transport**
  ([`ComposeTransportFacet`](../../../contracts/smartAccounts/facets/ComposeTransportFacet.sol)),
  one per diamond and shared by every compose receiver on it — the remote Personal Account as
  much as every loan type. Its tuple: the LayerZero endpoint (the only allowed `lzCompose`
  caller), the OFT on this chain (the only allowed compose sender, the authoritative identity of
  the bridged token, and the vehicle for the bridge-back sweep), and the pinned origin route back
  to Flare (`originEid`/`originPeer`). The timelocked `setComposeTransport(transport)` validates
  the OFT the way the Flare-side `setFxrpOft` does — canonical `oftVersion`, decimals
  shared with its own token, live peer equal to the pinned one — plus, on this side, that the
  endpoint has code and is the OFT's own (the Flare validator instead requires the OFT to wrap
  FXRP itself, and its receiver reads the endpoint live from the OFT) — and never clears, since
  an all-zero struct fails validation. Clearing is its own call,
  `clearComposeTransport()`, **immediate and owner-only**: a containment lever behind a timelock
  is not one. It disables the transport-dependent surface (composed actions on every receiver and
  the bridge-back sweep) until a new transport is set, while repayment with its best-effort
  surplus push, defensive idle deposits, account creation and the market bindings keep working.
- **The incident runbook** for a compromised endpoint, OFT or peer: **pause → cancel queued
  transport sets → clear → rotate**. Two things the clear does *not* do shape it. It does not
  cancel queued `setComposeTransport` calls — the timelock keys them by calldata hash and lets
  anyone execute a matured one, so a set queued before the clear would restore the route; cancel
  them with `cancelTimelockedCall` first. And it does not retire compose packets already queued
  at the endpoint, so a delivery that reverts against a cleared transport stays retriable. The
  replacement transport must **rotate the compromised identity**: the exact compromised
  endpoint/OFT/peer tuple is never restored, because packets forged under it would pass
  authentication again the moment it is. The accepted cost is an owner-held availability lever
  stronger than the pause — the clear also stops `sweepToOrigin` — documented as the nuclear
  action, with the owner trusted for liveness. The Flare-side clears (a zero peer in
  `setBridgeRoute`, a zero adapter in `setFxrpOft`) stay timelocked while this one is immediate;
  the asymmetry is acceptable because on Flare the pause already gates every outbound move and
  the inbound redeem-home is harmless in direction.
- **The loan markets**
  ([`LoanMarketsFacet`](../../../contracts/smartAccounts/facets/LoanMarketsFacet.sol)), the
  per-type binding: the timelocked `registerLoanMarket(type, market)` binds a subaccount type to
  one Morpho contract and market, **write-once** (see below). `collateralToken` must be the
  transport OFT's token — enforced, so the transport is configured first — while the loan token
  is RLUSD by governance policy per registration, not an on-chain check. The first registration
  permanently pins the collateral token on the transport: every later transport must wrap it
  (rotating to a different OFT adapter for the same token stays possible), so a transport
  replacement can never strand the write-once bindings, and the pin survives a clear.

### Multiple remote chains

The topology is one origin (Flare) and any number of remote chains, described in the same units
on both sides. Each remote diamond stores **one compose transport** with one origin — Flare — so
a remote chain is self-contained. Flare stores, on the type-generic `BridgeRoutesFacet`: the one
FXRP OFT adapter (`setFxrpOft`), **one pinned peer per remote chain** (`setBridgeRoute(eid,
peer)`, the *route*), and **the remote chain each bridging subaccount type lives on**
(`setSubaccountTypeRoute(type, eid)`, **write-once**). A subaccount type is therefore a
(chain, product) pair — the loan type on Ethereum, a second Morpho pool on Base as its own
type — while a Flare-local type (a vault subaccount) is simply never pointed at a route. The pin
is write-once because a type's instructions carry no destination of their own: the Flare
subaccount resolves the type's chain when the signed instruction executes, so re-pointing a live
type would send an already-signed borrow, deposit or withdraw to another chain, strand the
positions on the old one, and let the same operation ids run again on the new chain, whose
replay state is independent. Re-pinning the same route is a no-op (a
retried timelocked call is harmless); a different one reverts (`SubaccountTypeRoutePinned`). A
second chain is a second type. Stopping one pinned type is a separate, reversible lever —
`setSubaccountTypeRouteSuspended(type, true)` makes it read as unroutable, so its forward moves
and its bridge-back authentication fail closed exactly as an unconfigured route does, while
`getSubaccountTypeRoutePin` still shows where its positions live. The Personal Account's cross-chain
user operation names its `destinationEid` explicitly, and the route registry is its allowlist
(`UnknownBridgeRoute`). Every send re-checks the adapter's live peer for its destination against
the pinned one, and an adapter rotation (`setFxrpOft`) re-validates every registered route
against the new adapter's peers, so a route can never silently die in the field.

Adding a remote chain is a deployment of existing bytecode plus governance, with nothing changing
in what users sign or what clients build: bootstrap the diamond there from the pinned init code,
cut the remote facet set, `setComposeTransport`, register the pool under a new type (the same
`LoanSubaccountRemote` if it is Morpho; a new implementation otherwise), `setLoanFeeTerms`; then
on Flare `setSubaccountImplementation(type, <the Flare LoanSubaccount>)`, `setBridgeRoute` and
`setSubaccountTypeRoute` — the route last, once the remote side exists. Clearing a route (zero
peer) fails every type pointed at it and every user operation naming it closed until it is set
again, with the type pins kept; suspending one type stops only that type.

Deliberately not built: **multiple accepted origins on a remote transport** (a remote Personal
Account relaying a Flare-signed batch onward to a second remote chain). The base authenticates
exactly one origin today. The extension is additive when it is ever wanted — append an
`acceptedOrigins` mapping to the transport namespace, make the origin check a membership test
with the peer chosen by the packet's `srcEid`, keep `originEid` as the distinguished home the
fixed rails send to, and re-deploy the remote implementations behind the beacons — none of which
changes an instruction a user signs; it widens the remote authentication root, so it is a
decision to take on its own, with its own review.

One race is accepted on this side: LayerZero credits the bridged tokens and executes the
composed action in two separate steps, so a signed bridge-back sweep delivered in that window
would bounce newly credited FXRP to the user's own Flare address before its composed action
executes; the action then cannot execute and the loan is retried. Since the exit is
parent-signed, only the user's own instruction can do this — a self-inflicted ordering
mistake, not an attack surface — and nothing is redirected. Also noted for later: the pause is a single global switch today; separate pause
domains for the Morpho actions and the bridge would give cleaner containment if one ever needs
stopping without the other.

**The compose entry point.** `lzCompose` authenticates a message down to the LayerZero packet
header before acting on it: the caller must be the configured endpoint, `_from` the configured
FXRP OFT, the source EID the pinned origin chain, `composeFrom` this account's own address —
and, because the compose wrapper alone does not commit to the source OApp, the delivered GUID
must equal the one recomputed from the pinned origin peer
(`GUID.generate(nonce, srcEid, originPeer, dstEid, fxrpOft)`). The endpoint computes the real
GUID from the true packet header, so even an OFT whose peer is temporarily swapped to a
malicious OApp cannot forge a message that passes: this closes the change-send-restore attack
against accumulated positions. Compose value is rejected (`NonZeroComposeValue`) for every
action that does not spend it within the same call — rejecting keeps a mistaken delivery
retriable without value; the atomic withdraw is the one loan-chain action that opts in (the
value is its return leg's fee), behind its signed delivery-value floor. The executor and extra data are
untrusted and ignored. A failing delivery reverts and stays retriable through the endpoint;
the credited FXRP is already on the account either way.

**The payload, version 1** — `abi.encode(uint8 version, uint8 action, bytes actionData)`. Every
inbound action here is signed and carries `(bytes32 operationId, uint64 deadline, …)` — a
uniform envelope, since the one-direction policy removed the unsigned sweep deposit. The
market is not a payload field:
the account operates on exactly one market — the one its type is bound to — so the subaccount
address itself commits to the pool:

- **Operation ids make retries safe**: a user retrying a stalled instruction produces a new
  LayerZero packet, and distinct deliveries of the same intent must not double-execute. An
  already-consumed id completes the delivery without effect (`LoanActionSkipped`). An expired
  skip leaves the id unconsumed, so the same intent can retry under it (expiry is cured by
  refreshing the deadline, a non-economic field); a duplicate id was consumed by its first
  execution. Ids must be non-zero and globally unique per subaccount across
  action types; retrying clients must reuse an expired id only for the same intent with a
  fresh deadline (a convention, not contract-enforced). The terminal gates run before the
  borrow switch and the market lookup, so a duplicate or expired packet finalizes even on a
  sunset pool or an unregistered market.
- **Deadlines expire stale intent**: an old queued action completes without effect instead of
  creating debt long after the user signed it.
- **A debt increase respects the per-type borrow switch** and reverts with
  `BorrowingDisabled` while it is set (deliberately not a skip, since the switch is
  temporary-by-policy and a permissionless delivery must not consume the packet; it stays
  retriable until the deadline expires). Collateral deposits, withdrawals, and repayment are
  never gated by the switch, so a sunset pool's positions stay defensible and can always exit
  (while paused, a deposit executes only when the position carries live debt). A message-only
  action delivered with tokens attached executes normally; the credit simply stays idle on
  the account for the fixed rails.
- Skipped deliveries leave their bridged FXRP on the account for the fixed rails.

- **`ACTION_BORROW`** supplies **exactly the authenticated bridged amount** (the codec's
  `amountLD`, never the idle balance, which can commingle donations and unrelated transfers) as
  collateral, if any, and borrows `borrowAmount` (non-zero) against the account's own position,
  paying the destination — EVM kind only, clean zero-padded address, Wormhole kind reserved. As a
  debt increase it is pause-gated, subject to the per-type borrow switch, and gated on the fee:
  unconfigured fee terms revert retriably (`FeeTermsNotConfigured`), the loan is priced at the
  type's terms current at delivery (see the front-end requirement under The Flare fee), and the
  fee checkpoint runs before the borrow with the principal re-syncing after it.
- **`ACTION_DEPOSIT_COLLATERAL`** supplies exactly the authenticated bridged amount (non-zero) as
  collateral and changes no debt — the defensive action: while the controller is paused it
  executes only when the position carries live debt.
- For both of those, if the credited tokens were moved before delivery (the accepted race
  above), the action fails closed with `InsufficientComposeBalance` — a cap rather than
  provenance, since every balance on the account is the user's own, but it stops a signed action
  from absorbing more than its own credit.
- **`ACTION_WITHDRAW`** is the atomic withdrawal: it withdraws collateral from the account's own
  position and bridges it back to the account's own Flare address **in the same
  execution**, with the redeem-home compose — no idle window between the two, so the redeposit
  race cannot touch a withdrawal. It is also an exit-gate event for the Flare fee: after the
  pause gate it checkpoints and applies the secured-claim rule to the post-withdrawal remainder —
  a withdrawal that would leave the fee under-secured is refused (`OutstandingLoanFee`,
  retriable) until the fee is paid in loan tokens through `repay` or `payLoanFee`; nothing is ever taken from the
  collateral (see The Flare fee; most mid-loan withdrawals pass untouched). It is the one action
  that accepts compose value, spent in the same call: the value pays the return send's LayerZero
  fee, quoted live against the signed `returnOptions` from the payload, with the excess to the
  parent remote Personal Account and too little value for the quote reverting the delivery —
  retriable, since fee quotes drift both ways. Before any consuming branch — execution and
  terminal skip alike — the delivery must carry at least the signed `minComposeValue`
  (`InsufficientDeliveryValue`, retriable), which is what stops a below-value front-run from
  consuming the packet with the prepaid value undelivered; a terminally skipped withdraw
  delivered at or above the floor forwards its value to the parent, since nothing may strand on
  an account with no native rail. Morpho enforces position health.

**Creation route.** The same generic `createSubaccount(xrplOwner, type)` serves this chain —
there is no separate loan-chain creation function. The parent Personal Account resolves the
way `getSubaccount` already predicts it: the registered account when one exists, its
**computed** address otherwise (the PA derivation is frozen and chain-independent, so the two
can never diverge). On this chain the parent is the compose-driven remote Personal Account
(see below): the registered branch runs once the remote PA has been created, the computed one
before — either way the subaccount materializes at exactly the address the Flare side
predicts, whether or not the remote PA exists yet.

**One market per account, bound by the type.** Positions must outlive every configuration
decision, so the market an account operates on is not mutable state at all: the timelocked
`registerLoanMarket(type, market)` binds a subaccount type to one Morpho contract and
market, **write-once** — registering a different market for the same type reverts, and a new
pool is a new subaccount type (same implementation, one registry call per chain, its own
deterministic addresses). Since the account's address commits to its type and the type
commits to its market, *where the money is* is *which pool it is on*: payloads carry no
market field, `repay` takes no argument, and debt state is read live from Morpho
(`position()`, plus the market totals where shares must convert) — no debt decision is
cached, so an external liquidation is visible to the very next call
with no synchronization step. (The Flare fee keeps its own checkpoint bookkeeping — principal,
clock, terms snapshot — but that prices elapsed periods and gates exits; it never answers a
Morpho debt question, and it marks itself to the live debt at every checkpoint.) Market registration validates that the market exists on the Morpho
contract, both tokens carry code, and the collateral token is exactly the transport OFT's
token; the first registration also pins the collateral token for every later transport and —
transitively — every later market (see the configuration section). The loan token is
deliberately not pinned: RLUSD is governance policy per registration, not an on-chain
invariant. Registration policy: **only canonical immutable Morpho Blue deployments of the v1.0.0
implementation this mirror is pinned to** — any other implementation needs the conformance
verification below repeated before it may be registered. This is a pre-registration governance
trust assumption enforced by review at the timelocked call — the contract itself checks only
code-presence and market existence. The Morpho surface the account
compiles against — the `IMorpho` and `IOracle` mirrors and the `MorphoMath` id and share
arithmetic — is our own MIT code: the upstream `morpho-blue` files are GPL-2.0-or-later and
deliberately not a dependency. It was verified once against v1.0.0 (commit `55d2d99`, 2026-09-03:
the canonical selectors, the `position`/`market`/`price` return schemas, the live FXRP/RLUSD
market id, `SharesMathLib` vectors) and is pinned by
`test/MorphoConformance.t.sol`; Morpho Blue is immutable, so the target never moves. It matters because the
binding is permanent and the account's debt checks must be able to read its live position: a
Morpho that could later change behavior or start reverting would block that account's
debt-gated paths (borrowing, defensive deposits, repayment and its surplus push) — inherent to where the
position lives. Immutability reduces that availability risk; it is not containment — it does
not protect against a vulnerability in the immutable code itself, a malicious clone, or a
compromised market oracle or interest model.

**Sunsetting a pool.** The timelocked per-type `disableLoanBorrowing` stops new
debt increases on a type (`enableLoanBorrowing` reverses it) — the routine migration
lever: register the next pool as a new type, disable borrowing on the old one, and the old
accounts remain fully exit-capable forever
(repayment with its surplus push, deposits, and withdrawals are never gated by the switch). Clearing the
transport (immediate, owner-only) zeroes the LayerZero surface for **all** compose receivers —
composed actions and the bridge-back sweep wait until governance sets a new transport through
the timelock; that wait is real, which is why the clear is the nuclear incident lever and not a
routine one. Market bindings, `repay`
(with its surplus push), and defensive idle deposits persist through both levers. The global
pause blocks debt increases, withdrawals, debt-free deposits and the bridge-back (the surplus
push to the parent is inward and stays open; the remote PA's signed user operations are what the
pause stops) — while **repayment and defensive collateral deposits stay available**: a composed
deposit or an idle-rail deposit executes during a pause exactly when the position carries
live debt, so an endangered position can still be defended, while a debt-free deposit is new
exposure and waits out the pause like everything else. Accepted consequence: the global pause
is **not a full Morpho quarantine**. While any borrow shares exist — real debt or dust —
anyone can time a defensive deposit of the account's whole idle FXRP balance into its
market's Morpho during a pause, and permissionless repayment (also deliberately pause-exempt)
likewise moves the account's idle loan-token balance into that Morpho. Neither rail can
redirect funds, create debt, or pick a destination, but a compromised Morpho would receive
both. There is no on-chain Morpho-**action** quarantine: the registration policy above lowers
the odds of ever binding a Morpho that turns hostile or unreadable, but it is a trust
assumption, not a containment control. Separate pause domains would be the actual containment
improvement and remain future work.

**The rails** — fixed destinations, no caller discretion. By the one-direction policy, each
permissionless arrival has exactly one free meaning (RLUSD repays, FXRP deposits); the exit is
a user-signed action:

- **`repay()`** pushes the whole idle loan-token balance into the account's one position,
  clamped to the live debt: with live debt, interest is accrued first, a balance below the
  debt repays by assets, a balance covering it repays by **exact borrow shares** (Morpho's
  canonical rounded-up conversion with virtual offsets), closing the position without the
  over-repay revert. The documented user flow overfunds repayments to cover in-flight
  interest, so the clamp is what makes that flow work. Once the debt is zero — closed by this
  call, or already zero (a full external liquidation, tokens arriving after the close; accrual
  is skipped then, so a reverting IRM cannot trap the balance) — the balance beyond the fee
  reservation is the user's surplus and is pushed to the parent Personal Account in the same
  call. `repay` is also a Flare-fee collection point: it checkpoints before the Morpho
  repayment, re-syncs the principal after it, then pays the collectible fee to the recipient
  best-effort and reserves any still-outstanding collectible before pushing surplus (see The
  Flare fee; while paused the fee payment is held — the reservation and the surplus push
  still run, and the Morpho repayment stays pause-exempt).
  **Best-effort**: a push the token refuses (RLUSD can freeze addresses) never rolls back the
  repayment that just succeeded — the surplus stays on the now debt-free account
  (`LoanSurplusRetained`) and any later `repay` retries it, so loan tokens rest on a
  debt-free account only until a push succeeds. Available while paused — repaying moves the
  position toward safety, and the surplus push is inward consolidation to the user's own
  account.
- **`checkpointFee()`** runs a bare fee checkpoint — permissionless and pause-exempt, the
  measurement ping of the fee model (with the `getLoanFeeState()` view beside it); it moves
  no assets (see The Flare fee).
- **`depositIdleFxrp()`** supplies the whole idle FXRP balance as collateral into the
  account's one position — the executor's retry rail for FXRP that arrived without a
  successful composed action. Defending an indebted position survives a pause, like
  repayment; a debt-free deposit is new exposure and pause-gated. Debt is read live from
  Morpho on every check — nothing is cached, so an external liquidation is visible to the
  very next call. One race remains for **residue**: this gas-only rail can front-run the signed
  exit and lock the credit as the user's own collateral (the signed batch then reverts
  `NothingToSweep` and stays retriable; a signed withdrawal gets the funds back out). It can
  never touch a withdrawal — the withdraw action bridges its amount home in the same
  execution, with no idle window. Funds are never redirected — the impact is delay and a
  repeat cost.
- **`sweepToOrigin(extraOptions)`** — the signed exit — bridges the whole idle FXRP balance
  back to this account's own Flare address (the OFT's own `token()` is the authoritative FXRP
  identity), with the redeem-home compose (a deadline, this block time plus `REDEEM_HOME_TTL`,
  and nothing else): the Flare twin redeems at most this amount on arrival (see Cleanup
  moves). It is a fee exit gate: a collectible Flare fee left under-secured by the position's
  collateral blocks the sweep (`OutstandingLoanFee` — settle through `repay` or `payLoanFee`, then sweep);
  with no fee principal and nothing collectible the check is storage-only, keeping the rail
  Morpho- and oracle-free (see The Flare fee).
  **Restricted to the parent** — the remote Personal Account — so it is reached only
  through a user-signed cross-chain user operation, whose batch supplies `msg.value` from the
  remote PA's own native balance (funded by a native drop in the same instruction if needed; withdraw
  headroom accumulates there too). The accepted policy cost: while the Flare side is paused or
  its route unconfigured, the exit waits — custody is unaffected, and the call works again
  after (pauses are expected to be rare and short). It stays the **Morpho-independent**
  exit whenever the account carries no fee principal and nothing collectible — never
  borrowed, or fully synced closed — so a broken market cannot trap idle credit there; a
  live fee principal checkpoints first and a collectible fee reads the position
  (the dead-Morpho residual is accepted; see The Flare fee). The batch supplies the Flare-side gas in the
  options and may attach compose value, which becomes the redemption's executor fee. Exactly
  the quoted fee is spent and only the call's own excess refunded — to the remote PA — and
  pre-existing native never subsidizes the caller. Pause-gated on this chain (every exit rides
  the OFT itself). Live peer re-checked against the pinned one.
- **There is no generic recovery rail.** Loan-token surplus is the one thing that needs an
  exit, and it is folded into `repay` (above): debt is read live from Morpho, so a full
  external liquidation or another complete external close — which zeroes debt without the
  account observing it — frees the balance for
  the very next `repay` call, which collects and reserves any outstanding fee first and
  pushes the rest to the parent Personal Account (the
  user's own compose-driven account on this chain, a fixed destination baked in at creation;
  best-effort — a refused push stays here for the next `repay` to retry).
  Any other stray token strands until a beacon upgrade adds a rail — accepted, exactly as on
  the Flare subaccount: no protocol flow delivers one here, and every token the protocol does
  route here has its own rail.
  There is no native rail on this account: no `receive()` (the only protocol-delivered native
  is a withdraw delivery's compose value, spent or forwarded to the parent within the same
  call — a plain send reverts at the sender) and no native exit. Native can still land without a call:
  pre-deployment funding of the predicted address, a caller-requested LayerZero native drop,
  or a force-send; such a balance strands until a beacon upgrade adds a rail — accepted, since
  nobody in the protocol causes it. Containment note: a pause does not contain a compromise of the
  compose-authentication root itself (endpoint, OFT, pinned peer) — for that incident,
  clearing the transport (immediate, owner-only; queued transport sets cancelled first) is the
  containment, since it disables `lzCompose` entirely — and the compromised tuple is then
  rotated, never restored, because a cleared transport does not retire compose packets already
  queued at the endpoint (see the configuration section).

## The Flare fee

Flare charges a spread over the market's interest, with a floor: the user's effective rate is
**max(feeFloor, Morpho rate + feeSpread)**, measured checkpoint-to-checkpoint (the examples
below use floor 7%, spread 1%). An origination fee was explicitly rejected — the user must
not start with less than they borrowed. Defensive rails stay free: the fee never gates
`depositIdleFxrp` or the Morpho repayment itself.

Three product decisions shape everything below:

1. **The fee is a junior claim.** Liquidation can pay collateral out past the exit gate; the
   expected write-off is accepted credit risk. No "unconditionally enforced" promise anywhere.
2. **The promise is per-checkpoint measurement:** the user pays
   `max(floor, market interest + spread)` *as measured between checkpoints*. Permissionless
   checkpoints are a legitimate refinement of the measurement, not a broken promise.
3. **Rates stay mutable**, timelocked, with a settle-around operational runbook and a
   per-account terms snapshot as the safety net (below).

### Terms and their lifecycle

Per subaccount type, in [`LoanMarkets`](../../../contracts/smartAccounts/library/LoanMarkets.sol):
`feeFloor` and `feeSpread` (annual WAD rates, `1e18 = 100%`, each **enforced ≤ `1e18`** at set
time, so no snapshotted rate can overflow the accrual math — a bad snapshot could not be
repaired by changing the global terms, since the account computes at its stored terms first)
and a non-zero `feeRecipient`, set **as one unit** by the timelocked
`setLoanFeeTerms(type, terms)` after market registration — the same one-call shape as
`setComposeTransport`. The recipient is the permanent **activation
marker**: borrowing reverts (`FeeTermsNotConfigured`, retriably, never consuming the packet)
until the terms are set, and the setter never accepts a zero recipient, so the marker cannot
return to unconfigured. That on-chain gate is what closes the fee-free window — without it,
borrowing is enabled at registration and an early borrower would snapshot zero terms, pricing
their whole first period at zero when the real rate later arrives. Terms are deliberately
separate from registration rather than atomic with it: governance controls the values and
deployment runs with the timelock at zero, so the activation gate achieves the same guarantee
with a cleaner API — and because activation is a single call, there is no ordering for the
timelock's permissionless execution to get wrong. Zero rates are a legal, deliberate "fee off"
once the recipient is set. Later calls change the rates or rotate the collector, always
restating all three fields (rotating the collector changes where the fee goes, not what anyone
owes).

A rate change follows a **runbook, part of the design**: subaccounts are enumerable off-chain
from creation events, and the timelock gives notice. Three steps: (1) checkpoint every
account with live fee state, settling the old period at the old terms; (2) execute the queued
change; (3) checkpoint every account again, so each adopts the new terms from that moment.
This is best-effort, not an exact global boundary — and the direction matters: a missed
account keeps accruing at its old snapshotted rate, which favors the user after an increase
but overcharges a dormant user after a *decrease* until someone pings (the permissionless
ping and the executor's post-change pass are the mitigation).

The safety net for a missed account: each account **snapshots the terms it accrues under** at
every checkpoint. A checkpoint prices the elapsed interval at the *stored* terms, then adopts
the current ones. No retroactive-repricing lever exists in either direction.

**Consent to the terms is a front-end requirement, not a payload field.** A borrow is priced
at the type's terms current when it executes on the loan chain, and a borrow executes minutes
after signing under normal conditions — at most until its deadline. A signed rate bound in the
payload was built and then removed (2026-09-02): a terms change is timelocked and publicly
queued, so it is never a surprise, and after it lands every open position moves to the new
terms at its next checkpoint anyway (decision 3), so the bound only ever protected the first
period of a borrow that straddled the change. Two integration requirements replace it, in the
same spirit as the withdraw wallet invariant above: the front end must **warn (or refuse) while
a `setLoanFeeTerms` for the type is pending in the timelock queue**, and must **sign borrow
deadlines under one hour**, so a delayed packet cannot execute past that warning. A borrow
that straddles a change without those safeguards opens at the new terms from its first
second — the same position every existing borrower reaches at their next checkpoint; nobody's
funds are at stake, only the chance to reconsider.

### Checkpoint accounting

Neither Morpho's rate history nor a principal/interest split is readable on-chain (Morpho
stores only borrow shares and market totals), so the fee is computed from checkpoints. Per
account: `principal` — the canonical Morpho debt as of the last checkpoint (token base
units); `flareDebtX18` — the accrued, uncollected fee at WAD precision (token base units ×
`1e18`); `lastCheckpoint`; the snapshotted `floor`/`spread`. The **collectible** fee is
`flareDebtX18 / 1e18` rounded down — whole base units; every transfer and every gate works on
the collectible, and the fractional remainder stays in the accumulator.

A checkpoint runs **before** every debt-touching action and on a permissionless ping.
**Every checkpoint — including `principal == 0` and `T == 0` — ends by re-baselining:**
`lastCheckpoint := now` and the snapshot adopts the current terms. Beyond the re-baseline,
the degenerate cases are exactly:

- `principal == 0`: skip Morpho entirely — nothing to measure, floor on zero principal
  accrues zero. (Without the re-baseline, a first borrow or a re-borrow after a full close
  would accrue its first period under zero or stale terms, the same bug class as the closed
  registration window.)
- `principal != 0 && T == 0`: skip the accrual and the fee calculation (a zero interval owes
  zero), but **still raw-read the canonical debt and set `principal := D`** — a zero-time
  checkpoint that skipped the read would preserve a stale base: front-run checkpoint at `t`,
  external repayment, second checkpoint in the same block → `T == 0` observes nothing and
  the next period is charged on the pre-repayment principal. The raw read needs no
  `accrueInterest`: any interest it misses shows up as market interest `I` at the next
  measuring checkpoint, which the fee formula already credits.
- `T > 0`: the normal measuring checkpoint below.

The measurement is **shares-first**, so it never adds Morpho liveness where none is needed:

- If a raw position read shows zero borrow shares (externally repaid or liquidated to zero):
  settle with `D = 0`, `I = 0` — no `accrueInterest`, no IRM.
- Only with live borrow shares: `Morpho.accrueInterest` — explicit, so a following Morpho
  action cannot capitalize interest the checkpoint never saw — then read the canonical
  rounded-up live debt `D`.

Then, at the **stored** terms, with `T = now − lastCheckpoint` and `YEAR = 365 days`:

```text
I                 = max(0, D − principal)                    // token base units, clamped
interestX18       = I · 1e18
floorComponentX18 = mulDiv(principal · floor,  T, YEAR)
spreadComponentX18= mulDiv(principal · spread, T, YEAR)
feeDeltaX18       = max(floorComponentX18, interestX18 + spreadComponentX18) − interestX18
flareDebtX18     += feeDeltaX18                              // never negative by construction
principal        := D
lastCheckpoint   := now; snapshot := current terms
```

The clamp means a debt decrease the account did not itself cause (an external repayment, a
liquidation) counts as zero interest, never negative.

**Every successful debt-changing action then re-synchronizes after itself**: perform the
Morpho borrow or repayment, re-read the canonical rounded-up debt, `principal := D_after`
(`lastCheckpoint` stays at now). The post-action value is read from Morpho, never adjusted by
the requested amount — borrow shares and rounding are load-bearing. Without this the formal
algorithm breaks both ways: a first borrow would leave `principal = 0` and the next
checkpoint would classify the whole borrowed amount as market interest (a free first period),
and a repayment would keep charging the old base.

Scope of "debt-touching": `borrow` and `repay` (checkpoint before, sync after). A pure
collateral top-up (`depositCollateral`, `depositIdleFxrp`) changes no debt and runs no
transition. Terminal guards (duplicate, expired) run **before** any
checkpoint; a reverted action rolls its checkpoint back atomically. Settling before the
action is load-bearing: a borrow first raises `D`, and an unsettled period would count the
borrowed amount as market interest, eroding the floor. Re-capitalizing makes the fee compound
at event granularity, and marking `principal` to the live debt means external events reduce
the fee base **going forward** — only the elapsed period is charged on the old base.

**Arithmetic:** annual WAD rates over a fixed 365-day year, full-precision `mulDiv` as above.
The charged amount is the collectible (rounds **down**); the fractional remainder stays in
`flareDebtX18`. Each `mulDiv` by `YEAR` truncates below one X18 unit, so partitioning a
period can lose up to one X18 accumulator unit — under `1e-18` of a token base unit — per
checkpoint: an accepted, economically negligible bound, not exact-to-the-wei accounting.
Within that bound, splitting never mints dust (no per-interval round-up) and never materially
discards revenue. No per-checkpoint minimum fee — that would be an unbounded griefing
primitive. `principal` and the collectible are denominated in the market's **loan token base
units**; registration policy requires a token with conventional transfer semantics — no
fee-on-transfer, no rebasing (RLUSD at launch).

### Collection

The fee is denominated in the **loan token** and collects at two points, both loan-token and
both fixed-destination: inside `repay`, and through the parent-signed `payLoanFee`; the exits
never collect — they only refuse while the fee is under-secured (the exit gate below). The
collection:

- **`repay()`**, in this exact order: checkpoint → Morpho repayment (position safety) →
  canonical post-sync → fee attempt: pay `min(collectible, remaining balance)` to the fee
  recipient, best-effort — a transfer the token refuses never rolls back the Morpho
  repayment, and while paused the payment is held, while the reservation and the surplus push
  below still run (the Morpho repayment and the checkpoint stay pause-exempt) → recompute the
  balance and the still-outstanding
  collectible → **reserve** `min(outstanding collectible, remaining balance)` on the
  subaccount (`LoanFeeReserved`) → push only the balance beyond the reservation to the
  parent as surplus. A later `repay` retries collection from the reserved tokens without
  another user top-up; a shortfall beyond them still needs new funds. `flareDebtX18` is
  reduced only by `1e18 ×` the amount actually transferred.
- **`payLoanFee(maxAmount)`** — `onlyParent`, so reached only through the user's signed
  cross-chain batch on the remote Personal Account (approve the subaccount for the amount, then
  call), in this order: pause gate (like `repay`'s fee leg: money leaving the user's accounts
  toward the collector waits out an incident) → checkpoint → transfer `min(maxAmount,
  collectible)` from the parent's own RLUSD straight to the fee recipient by `transferFrom` →
  reduce `flareDebtX18` → forgive debt-free dust. The fee alone, never the debt, and the signed
  `maxAmount` is the cap — the user authorizes an exact ceiling in the same signature that
  moves the money, so a wrong computation can refuse but never overcharge. Nothing lands on
  the subaccount, so subaccount RLUSD keeps its one meaning (repay). An under-approved,
  underfunded or frozen parent, a frozen recipient, or nothing collectible reverts the whole
  batch, retriable. The canonical batch is `approve(X)` → `payLoanFee(X)` → `approve(0)`: the
  clamp can leave a remainder, and an allowance to the upgradeable subaccount is spending
  authority — harmless under this implementation, not something to leave standing.

Closing the loan through the rails therefore costs the live Morpho debt plus the collectible,
from the same RLUSD balance in one `repay`; paying the fee alone, with the loan kept open, is
`payLoanFee`.

### The exit gate

The gate is what makes dodging the repay-side fee pointless — Morpho's `repay` is
permissionless, so anyone can extinguish the debt directly, but the collateral leaves only
through the account's rails (with the liquidation exception, accepted as decision 1). Both
exits are parent-signed, and both gate on the collectible — **as a secured claim**: the
collateral remaining in the position IS the fee's security, so an exit is refused when it
would strip that security.

- **The security rule:** an exit passes uncollected when the collateral remaining after it,
  valued at the market oracle's price, covers `FEE_SECURITY_FACTOR × collectible`
  (factor 3 — headroom for the fee's growth until the next gate event and for price drift;
  deliberately NOT liquidation-proof, which would need ~5× and is already accepted as the
  junior-claim risk). The factor is a gross threshold on the remaining collateral, not equity
  net of Morpho's senior debt: at Morpho's LLTV boundary the equity behind the fee can be well
  under the fee itself. Mid-loan partial withdrawals therefore carry no fee friction while the
  remainder clears the threshold; only the exit that would leave the fee under-secured must
  first be settled through `repay` or `payLoanFee`. When `collectible`
  is zero the rule needs no oracle and no position read. A zero or dead oracle values the
  security at nothing, so the exit is refused — the escape is settling through `repay` or `payLoanFee`, after
  which the retried delivery passes with nothing collectible, oracle-free. (A live-debt
  withdrawal is blocked by Morpho's own oracle-dependent health check anyway — `payLoanFee`
  clears the fee gate there but not Morpho's check, so the debt must be closed — and the
  refused case is effectively the debt-free one, where the fee is static and exactly
  settleable.)
- **`withdraw` (the atomic bridge-home)**, in this exact order: the hard argument checks
  (zero amount, zero id) → the delivery-value floor → duplicate/expired skip → pause gate →
  checkpoint →
  the security rule on the post-withdrawal remainder — secured passes, under-secured reverts
  `OutstandingLoanFee` (retriable) → consume the operation id → withdraw and bridge.
  Settlement is deliberately not part of the withdraw: the fee is paid in loan tokens through
  `repay` (subaccount RLUSD means repay, the free direction) or `payLoanFee` (the fee alone,
  from the parent, parent-signed), after which the same parked packet passes; no price ever
  moves funds at an exit.
- **`sweepToOrigin`**: the same security rule, over the position's full current collateral
  (the sweep moves idle FXRP, not the position). With zero `principal` and nothing
  collectible the gate is storage-only — no Morpho read, no oracle — so the stuck-FXRP exit
  keeps its independence when borrowing was never used or is fully synced closed; a live
  `principal` checkpoints first (a Morpho position read, plus the IRM while shares live —
  the dead-Morpho residual below), and with `collectible > 0` and a live position securing
  it, the sweep passes uncollected. Under-secured blocks (`OutstandingLoanFee`): no atomic
  collection here — settle through `repay` (send RLUSD to the subaccount, the free
  direction) or `payLoanFee` (the fee alone, from the parent), then sweep.
- **Final-exit forgiveness:** when a gate passes with `principal == 0` and a sub-unit
  fractional remainder still in `flareDebtX18`, the remainder is cleared with
  `LoanFeeRemainderForgiven` — it can never be transferred (ERC-20 moves whole base units)
  and never grows again, so a raw-zero gate would park both exits forever over less than one
  base unit.

Consequence to respect in review: an over-accrual bug is not self-limiting — it parks the
exit until settled — so the accrual logic carries money-path review weight.

**Settlement is loan-token only.** No exit converts the fee: an under-secured withdraw or sweep
refuses (`OutstandingLoanFee`), the user pays the fee in RLUSD — to the subaccount, where `repay`
collects it after any live debt, or from the parent through `payLoanFee`, the fee alone — and
the retried packet passes. An FXRP settlement mode
— the fee deducted from the withdrawn collateral at the market oracle's price under a signed cap
— was built and removed (2026-09-02): it only ever served users who had closed outside the rails
or underfunded `repay`, and it was the one place a price moved funds. Removing it takes the
oracle out of every money path (it survives only in the gate's comparison, where a wrong price
can refuse an exit but never take from it), drops a payload field, four errors and an event, and
leaves the collector holding RLUSD only. `sweepToOrigin` stays oracle- and Morpho-free when the
account carries no fee principal and nothing collectible.

**The overlap (Morpho allows, the gate refuses) and the fee-only payment.** A partial `repay`
sends everything to Morpho, so under `repay` alone the fee is only ever paid at full close and
grows relative to a shrinking debt. Once the collectible `F` exceeds `D / (LLTV ×
FEE_SECURITY_FACTOR)` of the live debt `D` (about 43% at LLTV 0.77 and factor 3), a band of
remainders `D / LLTV ≤ V < FEE_SECURITY_FACTOR × F` passes Morpho's health check but fails the
gate — and subaccount RLUSD cannot reach the fee while debt remains, so a fee-sized top-up
there only shrinks the debt. `payLoanFee` is the way through it: the user pays the fee alone
from the remote Personal Account's own RLUSD, in one signed batch, and keeps the loan open. The
factor stays 3 (lowering it only makes the band rarer — the threshold moves to ~65% of debt at
2 — while cutting the debt-free recovery headroom from a 67% to a 50% price fall). Pinned by
`testHealthyLiveDebtExitCanNeedTheDebtClosedBeforeTheFee` (the `repay`-only path) and
`testPayLoanFeeFromParentUnblocksTheOverlapWithoutClosingTheDebt`. Front-end requirements, in
the spirit of the wallet invariant: detect the band for the requested remainder `V`; offer the
three ways out — pay the fee alone from the PA (`approve` + `payLoanFee` + `approve(0)`, with
`maxAmount` a little above the quoted collectible since it accrues by the minute; the clamp
makes the excess safe and the final reset leaves no allowance standing), withdraw less, or
close through `repay` (which needs `D + max(0, F − V /
FEE_SECURITY_FACTOR)`, debt first); warn that RLUSD sent to the subaccount goes to debt before
fee; and say that the refused packet stays unconsumed and retriable. The design path, for the
record: a withdraw-time settlement pulled from the parent (a signed cap field in the withdraw
payload, the subaccount reaching into the PA) was built and rejected twice, in FXRP and in
RLUSD; the parent-driven `payLoanFee` keeps the withdraw schema, gets the cap for free as the
signed amount, and keeps authority in the direction that already existed (parent → subaccount).

**Dead-Morpho residual (accepted):** with live borrow shares and a permanently reverting
Morpho/IRM, the gate's checkpoint cannot run and idle FXRP behind `sweepToOrigin` waits —
but collateral inside a dead Morpho is lost anyway, and the shares-first rule already frees
every debt-free account. No standing governance write-off power; if the case ever
materializes, the implementation behind the beacon can be upgraded — the escape hatch the
architecture already has.

### External repayment is a donation

The clamp makes repaying outside the rails pointless as fee avoidance: the elapsed period
still owes `max(floor·P·T − I, spread·P·T)`, computed as if the extinguished interest had not
been observed. A third-party donor never leaves the user worse off — but part of the gift
leaks to Flare (reducing observed `I` raises the floor-bound fee by the same amount, up to
the floor). A user repaying their own debt directly on Morpho is their own donor and pays
that leak; the documented flow is the rails.

### Permissionless ping

Anyone may trigger a bare checkpoint (`checkpointFee()`); it stays standalone, permissionless
and pause-exempt — it is also what a liquidated user needs. **Under unchanged terms and
non-decreasing debt**, splitting a period typically increases the total fee and never decreases
it by more than the accepted truncation bound above — one X18 accumulator unit, under `1e-18` of
a base unit, per checkpoint — so pinging cannot be used against Flare in any economically
meaningful way; a ping after an external repayment correctly *lowers* the future fee base —
that is the prospective policy working, not an exception to it. The fee is therefore
**path-dependent**: finer partitions approach the continuous integral of
`max(floor, instantaneous rate + spread)` and can exceed the whole-period-average reading.
That is the promise (decision 2): the FE advertises the per-checkpoint measurement, not an
average. No minimum checkpoint interval — it bounds nothing (permissionless `repay` also
checkpoints) and delays liquidation relief.

### Liquidation and the fee

A Morpho liquidation transfers seized collateral **directly to the liquidator** — around the
gate. The claim survives up to the liquidation residue: a boundary liquidation leaves
collateral in the position (at LLTV 77% with a ~7% bonus, roughly a fifth of the debt value),
which still exits only through the rails; only a deep liquidation — a price gap, a position
left unhealthy — strips everything and extinguishes the claim in practice. Decision 1 accepts
this: the fee is junior to Morpho debt and the liquidation incentive, self-liquidation is a
bounded-value dodge (gas, sniping risk, only the deep case escapes fully), and the expected
write-off is priced, not prevented. With every withdrawal gated, liquidation is the *only*
value exit around the gate: a secured withdrawal or sweep also passes uncollected, but
deliberately, leaving the claim covered by the remaining position — only liquidation can
strip the claim's security and make it unrecoverable.

Accounting stays **prospective-only**: the contract cannot learn when a liquidation happened,
so a ping stops the floor's clock from ping time, never retroactively — the FE surfaces "I
was liquidated → ping now" and the executor pings on observed liquidations. A
"debt-and-collateral-both-dropped" detection heuristic was **rejected**: interest can mask a
partial liquidation, an external repayment plus a signed withdrawal produces the same deltas,
and a self-liquidator deserves no forgiveness. No automatic write-off: an unpaid claim on an
emptied account simply stays outstanding.

### Storage, activation and ABI

Fee state is the remote implementation's own linear state, starting right after the one
linear base field (slot 0, `controllerAddress`; every other base field is namespaced — see the
storage rule below), append-only; the frozen proxy and CREATE2 addresses are untouched. The loan chain is not
deployed, so the fee **ships before the first live position** — no lazy-migration semantics
needed. The fee touches **three coordinated surfaces**, and activation verifies the
reviewed version of every one before any route opens: the remote `LoanSubaccountRemote`
(accrual, gates, collection), the Flare `LoanSubaccount` (the extended borrow/withdraw
payload encoders), and `LoanMarketsFacet` (the timelocked terms setter and the activation
marker). Activation order, distinguishing the two chains: on the remote diamond, the compose
transport first (market registration already requires it), then the verified remote
implementation, then `registerLoanMarket`, then `setLoanFeeTerms` (the activation; borrowing
reverts until it executes, so the market is registered but inert across the gap — verify all
three fields before opening any route); on Flare, the
verified sender implementation, and the forward route (`setBridgeRoute` for the chain,
`setSubaccountTypeRoute` for the type) enabled **last**, as the deployment gates already require. Borrowing is impossible without
configured terms at every point in that order. Missing fee configuration never makes the
pause-exempt repayment rail unusable (an unconfigured type cannot have debt to repay; zero
terms accrue zero, and debt presupposes the borrow gate passed).

**The frozen V1 wire schemas (exact types and ordering):**

- Borrow action data, unchanged from before the fee: `abi.encode(bytes32 operationId,
  uint64 deadline, uint8 destinationKind, bytes32 destination, uint256 borrowAmount)`.
- Withdraw action data, unchanged from before the fee: `abi.encode(bytes32 operationId,
  uint64 deadline, uint256 amount, uint256 minComposeValue, bytes returnOptions)`.
- Deposit-collateral action data, unchanged: `abi.encode(bytes32 operationId,
  uint64 deadline)`.
- `WithdrawOptions` (Flare, signed): `{bytes destinationOptions; bytes returnOptions;
  uint256 minComposeValue;}`.
- Skip reasons: 1 = duplicate, 2 = expired (3, the retired signed-terms skip, is never
  reused).
- Sender/receiver byte-equivalence tests pin the tuples.

### Worked example

(floor 7%, spread 1%.) Borrow 1000 on 1.1.2026 (post-sync `principal` = 1000). On 1.1.2027
Morpho says 1060 (`I` = 60, 6%): owed = max(70, 70) = 70, fee debt 10; the user borrows
another 1000 → post-sync `principal` = 2060. On 1.1.2028 Morpho says 2100 (`I` = 40, ~2%):
owed = max(144.2, 60.6) ≈ 144, fee ≈ 104, fee debt ≈ 114, `principal` = 2100 — closing
through the rails now costs 2100 + 114. On 1.1.2029 Morpho says 2000 (someone repaid
100+interest externally; `I` clamps to 0): owed = max(147, 21) = 147, fee debt ≈ 261,
`principal` = 2000. If the rest is also repaid externally, **a year later** (1.1.2030) the
next checkpoint charges max(140, 20) = 140 on the old base, marks `principal` to 0, and
accrual stops; fee debt ≈ 401 waits at the exit gate, payable in RLUSD through `repay` or `payLoanFee`.

## The remote Personal Account

Users are XRPL-only, and their signatures become on-chain authority only on Flare — so on
the loan chain the user's Personal Account address exists (the PA proxy derivation is frozen
and chain-independent) but historically carried no code, and anything sent to it was
stranded. The **remote Personal Account**
([`PersonalAccountRemote`](../../../contracts/smartAccounts/implementation/PersonalAccountRemote.sol))
closes that: a per-chain implementation registered behind the same controller-as-beacon that
serves the Flare PAs, materialized at the same CREATE2 address through the frozen PA proxy.
It is the compose-driven twin of the user's Flare account — no local owner, no
controller-driven methods (instructions exist only on Flare); every authorized action arrives
as an authenticated LayerZero compose message sent by this same account on Flare, exactly the
subaccount's self-to-self trick applied to the PA family.

**Naming.** Four words, one axis each. *Loan* is business-specific and stays only on what
exists for the loan (`LoanSubaccount`, `LoanSubaccountRemote`, the settings facets); *Remote*
is location seen from Flare, the non-Flare implementation at the same address
(`PersonalAccountRemote`, `LoanSubaccountRemote`); *Compose* is the ingress authentication
mechanism (`ComposeReceiverAccountBase` — and only that ingress, since the subaccounts also
have parent-driven and public rails); *Bridging* is the Flare-side surface every type that
bridges FXRP to its remote twin shares (`BridgingSubaccountBase`); *CrossChain* is the Flare-side send
(`sendCrossChainUserOp`, which sends a user operation to another chain and executes nothing
itself). "Cross-chain" is general in name only while one configured destination exists: the
sender rides the loan bridge's FXRP OFT and a remote PA exists only on the loan chain, so a
multi-destination PA would need per-destination routes.

**The shared base.** The authentication checklist (endpoint-only caller, configured FXRP OFT
as sender, origin chain, `composeFrom` equal to the account's own address, GUID recomputed
from the pinned origin peer) is identical for the remote PA, the loan-chain subaccount and the
Flare subaccount (as the receiver of its own bridge-back, its transport derived from the bridge
settings — with one accepted trust extension: that receiver reads its authenticating endpoint
live from the governance-set OFT rather than pinning it; the canonical `OFTAdapter`'s endpoint
is immutable, a compromised OFT could already move the locked FXRP, and the only action
forgeable here redeems the account's own FXRP to its owner's XRPL address), as is the
operation-id replay protection with the skip semantics that the signed
actions use (the unsigned Flare action carries no id and relies on the endpoint's at-most-once
compose delivery), and they live once in
[`ComposeReceiverAccountBase`](../../../contracts/smartAccounts/implementation/ComposeReceiverAccountBase.sol)
(public surface: [`IComposeReceiverAccountBase`](../../../contracts/userInterfaces/IComposeReceiverAccountBase.sol)).
Derived accounts define only their action set, their transport source, whether compose value is
accepted (per action; the Flare redeem-on-arrival and the loan-chain atomic withdraw, each
spending or forwarding it in the same call) and their identity.
Deliberately one implementation:
this block is the security root of every account with no local owner.

**The account bases.** Above the compose ingress, the identity every account shares is
written once as well, in a small hierarchy the frozen proxies dictate:
[`ControlledAccountBase`](../../../contracts/smartAccounts/implementation/ControlledAccountBase.sol)
(the controller, set once — the root of every account;
[`IControlledAccount`](../../../contracts/userInterfaces/IControlledAccount.sol) is the one
declaration of `controllerAddress()` every account interface extends);
[`SubaccountBase`](../../../contracts/smartAccounts/implementation/SubaccountBase.sol) (what the
frozen `SubaccountProxy` dictates for every subaccount type on every chain: the parent and the
type, `initialize(controller, parent, type)`, `onlyParent`, the type-aware beacon lookup —
[`ISubaccount`](../../../contracts/userInterfaces/ISubaccount.sol));
[`PersonalAccountBase`](../../../contracts/smartAccounts/implementation/PersonalAccountBase.sol)
(what the frozen `PersonalAccountProxy` dictates for both Personal Account implementations: the
XRPL owner, `initialize(controller, xrplOwner)`, the beacon lookup —
[`IPersonalAccountBase`](../../../contracts/userInterfaces/IPersonalAccountBase.sol)); and, on
Flare only,
[`BridgingSubaccountBase`](../../../contracts/smartAccounts/implementation/BridgingSubaccountBase.sol)
(what every subaccount type that bridges FXRP to its own remote address shares: the forward-move
core over its type's route, the permissionless `sweepRedeem`, the redeem-home compose —
[`IBridgingSubaccount`](../../../contracts/userInterfaces/IBridgingSubaccount.sol)). The four
implementations then hold only what is theirs: `PersonalAccount` its controller-driven methods,
`PersonalAccountRemote` the signed batch execution, `LoanSubaccount` the three typed loan
instruction encoders, `LoanSubaccountRemote` the Morpho actions and the fee engine. A Flare-local
subaccount type (a vault subaccount) would extend `SubaccountBase` alone; a new bridging type,
`BridgingSubaccountBase`. The storage rule the bases follow is in the pre-first-cut invariants.

**The action set is one action: execute.** The remote PA does what the Flare account does —
run the batch of calls the user signed — with the authenticated compose in the role the
controller plays on Flare. The blast-radius claim follows: a compromised compose root has the
**full on-chain authority of the remote PA's address** — balances, approvals, external positions
and any role granted to it — the same class as a controller compromise on Flare, but over
the loan subaccount it holds exactly two narrow authorities: the parent-only `sweepToOrigin`,
able only to send idle FXRP to the subaccount's own fixed Flare address, and the parent-only
`payLoanFee`, able only to move the remote PA's own RLUSD to the governance-set fee recipient up
to the collectible and the signed cap — never to redirect funds or touch Morpho collateral or debt,
which stay behind the subaccount's own compose authentication. Callbacks into the remote PA's compose entry (`lzCompose`) meet the active
reentrancy guard; `receive()` and the views stay callable and are benign.

- `PA_ACTION_EXECUTE(opId, deadline, Call[] calls)` — the signed batch, `Call {target,
  value, data}` field-identical to the Flare `IPersonalAccount.Call`. Hard checks revert
  (zero id, empty batch); duplicate/expired deliveries skip; then the pause gate, the id is
  consumed and the calls run in order, **all or nothing for calls that revert**: a reverting
  call fails the whole delivery with `CallFailed(index, returnData)`, the id stays unconsumed
  and the packet stays retriable at the endpoint (expiry alone changes nothing there — once
  the deadline has passed, the next delivery attempt terminal-skips it). Return data is
  **not interpreted**, exactly as in the Flare `executeUserOp`: a callee that reports failure
  by returning `false` instead of reverting (some ERC-20s), or a codeless target, counts as a
  successful call and consumes the id — the wallet must know the callee's success convention
  (a test pins this). A plain native send is `Call(recipient, amount, "")`; an ERC-20 transfer
  targets the token with `transfer(...)` calldata. Pause-gated — signed traffic stops during an
  incident, since a transport compromise is exactly what an incident looks like; the packet
  re-delivers after unpausing. Nothing is validated about targets (the signature is the
  authority, as on Flare); the wallet owns the batch's correctness.
- **No permissionless rail at all.** No protocol flow ever routes FXRP to the remote PA: Flare's
  instructions are message-only, bridged collateral lands on the loan subaccount, and
  the subaccount's only outward push is its closed-position loan-token surplus (folded into
  `repay`). What lands here is borrow proceeds the user directed here, that surplus, and
  external strays — and the user's next batch moves or uses them.
- **Native is accepted** (`receive()`) and leaves the same way, as a value-carrying call. The
  purpose is funding: a bridge call (proceeds to XRPL through Wormhole, say) wants a native
  fee, and the LayerZero executor **native-drop option** in `extraOptions` delivers native to
  the remote PA with the same message that carries the batch — which needs `receive()`. Compose
  *value* stays rejected (`NonZeroComposeValue`; the drop is a separate transfer, and a
  mistaken delivery must stay retriable). A value call exceeding the balance fails with
  `CallFailed` and is retriable after funding. The implementation contract itself, never
  initialized, rejects native (`NotInitialized`) — nothing could ever move it out of there. No
  NFT/1155 holders in v1 (a safe-transfer in without the receiver hooks would revert at the
  sender; add them the day a flow needs them — the batch can already move them out).

**The Flare-side sender.** `PersonalAccount.sendCrossChainUserOp(destinationEid, calls, operationId,
deadline, extraOptions)` — the one instruction: builds the execute envelope on-chain (a
malformed envelope cannot reach the bridge), validates the envelope before any fee is paid
(`InvalidCrossChainUserOp`: zero id, passed deadline, empty batch — the batch itself is
not interpreted; the wallet owns the correctness of targets and amounts, as it does for
`executeUserOp`), and sends a message-only compose (amount zero) over the FXRP OFT adapter to
its own address on the chain `destinationEid` names — the validated path: a registered bridge
route for that endpoint (the route registry is the allowlist of chains; `UnknownBridgeRoute`
otherwise), live peer re-checked against the pinned one, exact quoted fee, pause-gated. It is callable **only by the account
itself**, which makes it reachable exclusively through an `executeUserOp` multicall — the XRPL
signature covers every target, value and calldata end-to-end. The fee value rides from the
account's own native balance through the multicall, and any excess simply remains on the
account. `extraOptions` must carry the `lzCompose` gas the batch needs and, when the batch
sends more native than the remote PA holds, a native drop. No typed helpers by decision: the common transfer is a one-call batch a
wallet builds like any other, and one sender never grows a helper per use case.

**Creation.** `createPersonalAccount(xrplOwner)` on the `PersonalAccountsFacet` — the generic,
permissionless, idempotent, pause-gated route, cut on every chain, the PA analog of
`createSubaccount`: on Flare the instruction machinery creates PAs lazily and the explicit route
lets anyone materialize one earlier (an executor completing a loan subaccount's `sweepRedeem`
needs the parent to exist); here, where no instruction machinery exists, it is the only route.
The caller gains nothing: the frozen derivation commits to the owner and the controller, and the
created account obeys only its Flare twin's authenticated compose. It requires the registered
remote PA implementation (the frozen BeaconProxy resolves it at construction) and registers the
account, so `getPersonalAccount` answers with it afterwards. An empty owner cannot be created
(the implementation rejects it), so no remote PA can exist for an impossible owner. The
`PersonalAccounts` library behind it is account-type-agnostic — it deploys and records a
deterministic proxy and returns a plain `address`; the Flare facets cast to `IIPersonalAccount`
where they need Flare behavior, since the code behind the proxy here is not a Flare Personal
Account.

## Deployment

### Flare-side deployments

- **Fresh deployments** (`pnpm deploy_contracts` → `DeploySmartAccounts`): the loan module is
  part of the standard cut — `SubaccountsFacet` and `BridgeRoutesFacet` are deployed with the other smart-accounts
  facets, a `LoanSubaccount` implementation is deployed alongside the Personal Account
  implementation, and type `1` is registered with `setSubaccountImplementation` before
  `setTimelockDuration`, while the timelock is still zero.
- **Existing deployments** (flare, songbird, coston2): the facet needs no dedicated deploy
  step — naming `SubaccountsFacet`, `BridgeRoutesFacet` and the replaced `PersonalAccountsFacet`
  (it gains `createPersonalAccount`) in a cut plan
  (`deployment/cuts/<network>/cuts-<date>.json`, verified with `pnpm check_cut`, executed with
  `pnpm diamond_cut`) deploys it from the artifact as part of the cut flow. The implementation
  is deployed with `pnpm deploy_loan_subaccount_implementation <network>` (Flare-family
  networks only — the script refuses Ethereum) and registered by
  governance with the timelocked
  `setSubaccountImplementation(SUBACCOUNT_TYPE_LOAN, <address>)`.

### Ethereum bootstrap

Rebuilding today's sources does **not** reproduce the production diamond address — source
drift changes the base facets' bytecode, their CREATE2 addresses, the diamond's constructor
arguments, and with them its address. The historical init code of
the diamond and its three base facets is therefore pinned as raw bytes under
`deployment/pinned-init-code/` (recovered from the Flare creation transactions and verified:
its CREATE2 derivation reproduces the live addresses exactly; `test/PinnedInitCode.t.sol`
asserts the hashes, the derivation, and a golden xrplOwner → Personal Account → subaccount
address vector in CI). `pnpm deploy_ethereum_controller` reproduces all four contracts on
Ethereum at the production addresses — permissionless, since CREATE2 through the EIP-2470
factory is sender-independent. **The follow-up facet cut is not permissionless**: the fresh
diamond is owned by the historical `DiamondArgs.owner` EOA
(`0x7801A7e1FD6a99d1a74DC0a59622b3b7dc4049bA`) — confirm that key is still controlled
before relying on an Ethereum deployment. The Ethereum cut installs `SubaccountsFacet`,
`TimelockFacet`, `PauseFacet`, `PersonalAccountsFacet` (the PA beacon and creation surface for the
remote Personal Accounts), `ComposeTransportFacet` and `LoanMarketsFacet` through the standard cut flow
(the cut plan under `deployment/cuts/ethereum/` is authored at cut time;
`deployment/deploys/ethereum.json` is written by the bootstrap when it runs — the record exists
only once the contracts do, and the cut planner refuses to plan without it), and both
implementations ship with `pnpm deploy_remote_account_implementations ethereum` (the script
refuses the Flare-family chain ids: a remote implementation recorded on Flare would look like a
legitimate artifact and, registered there, corrupt every Personal Account's storage). There is
deliberately no `deployment/chain-config/ethereum.json`: the generic full-deploy script must
not run against Ethereum — operators go through the pinned bootstrap and the scripts above.

### Pre-first-cut invariants

One ordering constraint is absolute: the pool-per-type settings scheme redefined payload
version 1 relative to the earlier route-registry draft, which is safe **only** while no
loan-chain settings facet has ever been cut, no old-V1 packet is queued or in flight anywhere
in LayerZero, and no client or tooling holds prebuilt old-schema payloads — all true today:
nothing has been deployed to Ethereum, so `deployment/deploys/ethereum.json` does not exist
yet. The same condition
covers every later in-place V1 change, most recently the withdraw action's `actionData`
gaining `minComposeValue` and `returnOptions` (the fee's signed bounds — borrow rate maxima and
a withdraw FXRP cap — were added and removed again inside the same pre-cut window), and the
removal of the sweep-deposit action (id 4 retired, never reused; ids 1–3 unchanged). An environment that had
shipped the old scheme would need a new payload version instead. The settings storage namespaces
are fresh — `smartAccounts.ComposeTransport.State` and `smartAccounts.LoanMarkets.State` —
and splitting the earlier single settings namespace is itself a pre-first-cut-only move under
the same condition: after a first cut it would need a migration or a permanent legacy slot. The
storage-lineage gate below is the third member of this family.

### Release checklist

**Before the first Ethereum cut, still to be built and rehearsed:**

- **implementation registration as a verified gate**: `setSubaccountImplementation(1, …)`
  and `setPersonalAccountImplementation(…)` must register exactly the reviewed
  `LoanSubaccountRemote` and `PersonalAccountRemote` artifacts (runtime hashes verified
  before the timelocked calls, `implementationForType(1)` and the PA beacon's
  `implementation()` asserted after them), and this must complete before any account is
  advertised, funded, or the cross-chain route is enabled. The setters check only that
  code exists; a wrong but `initialize`-compatible registration would let permissionless
  creation materialize frozen proxies with the wrong storage layout, and initialization
  cannot be replayed;
- **the chain-local storage-lineage gate**: every implementation in a proxy's chain-local
  upgrade lineage must preserve that proxy's storage layout (cross-chain layouts may
  differ — the chains share only the address — but a chain's lineage may not). The account
  bases follow one **storage rule**, forced by the production Flare Personal Account (slot 0
  `controllerAddress`, slot 1 `xrplOwner`, live behind thousands of proxies): the controller
  is slot 0, linear, in every lineage (`ControlledAccountBase`), `xrplOwner` is slot 1, linear,
  in every Personal Account lineage (`PersonalAccountBase`), and **every other base field is
  namespaced** (ERC-7201: `smartAccounts.ComposeReceiverAccountBase.State` for the consumed
  operation ids, `smartAccounts.SubaccountBase.State` for the parent and the type), so a base can
  gain fields without shifting any derived lineage's own linear state, which starts right after
  the linear base fields. `test/AccountStorageLayout.t.sol` pins the rule. Adopting it moved
  the not-yet-deployed lineages' fields (the remote subaccount's fee state from slot 4 to
  slot 1, the remote PA's `xrplOwner` to slot 1, `usedOperations` into its namespace) — safe
  only because no subaccount or remote Personal Account proxy exists yet; before the first
  deployment of any of those implementations on ANY network, verify on chain that no proxy of
  the lineage exists there. The Flare Personal Account's layout is unchanged by construction;

- a minimal Ethereum-side init contract for the cut: `MasterAccountControllerInit` is
  Flare-specific and is skipped, so ERC-165 interface flags (and nothing else) must be set
  explicitly;
- post-cut verification: loupe/selector layout, owner, and ERC-165 answers checked against
  the expected Ethereum facet set (the bootstrap itself already verifies init-code hashes,
  CREATE2 addresses, and runtime code against the pinned Flare fixtures, in CI and at
  deploy time);
- a signed ownership-control rehearsal from the historical owner EOA before anything
  depends on the deployment;
- a pre-cut verification that the fresh diamond still has the pinned initial owner and the
  exact base selector mapping (the cut checker already recognizes the pinned base facets as
  intentional reuse, verified against the Flare runtime hashes, instead of proposing to
  replace them with current-source builds);
- per-action `lzCompose` gas profiling against the real Morpho, oracle and token contracts
  — the test fixture's option values are illustrative headroom for the mock path, not
  production configuration;
- **the canonical-Morpho premise of the fee's exit gate**: with live borrow shares,
  canonical Morpho's `withdrawCollateral` accrues interest and oracle-checks position
  health, so a dead oracle blocks live-debt withdrawals at Morpho itself — which is why
  the gate's dead-oracle parked case is effectively the debt-free one, settleable through
  `repay` or `payLoanFee` (see The Flare fee). `MockMorpho` models this check behind a switch (the fee
  fixtures run over-leveraged with it off; dedicated tests run with it on), so the
  interplay is pinned at the unit level; what remains is verifying the premise against the
  canonical Morpho source and the real market in the integration harness before launch;
- **fee terms configured before any route opens**: `registerLoanMarket`, then the one
  `setLoanFeeTerms` call (the activation — borrowing reverts until it executes); verify all
  three fields before enabling the forward route;
- **the Ethereum FXRP OFT's decimals**: `token().decimals()` must equal its `sharedDecimals()`
  (6) on the loan chain — the no-dust argument (`minAmountLD == amountLD`) rests on it on both
  chains; `setComposeTransport` fails closed otherwise, so confirm the representation before
  the transport is queued;
- **FAssets' zero-fee executor**: the zero-value redeem-home passes the controller's executor to
  `redeemAmount` with zero value; verify against the deployed asset manager that a named
  executor with a zero fee is accepted (the vendored interfaces do not say) — if it is not,
  every zero-value bridge-back would terminal-skip after its TTL and fall back to the
  fee-paying public rail;
- **operator chain checks**: the implementation deploy scripts refuse the wrong chain family
  (a remote implementation registered on Flare would corrupt every Personal Account's storage),
  and every deploy and cut flow — the `check_cut` preview included — verifies that the RPC's
  chain id matches the named network before acting, so a mis-set `<NETWORK>_RPC_URL` fails
  instead of retargeting the flow;
- **the fee-activation runbook rehearsed** once on a testnet diamond with a non-zero timelock;
- **the real Endpoint/OFT compose-delivery integration harness** for every action, in both
  directions (the local sender→codec→receiver tests run each
  sender's bytes — borrow, deposit, the atomic withdraw with its real return
  send, remote-PA execute, and the loan-chain redeem-home — through the canonical codec into the
  real receivers, everything but the wire hop; non-zero compose value is covered by the
  receiver tests on both chains (the Flare redeem-home and the loan-chain withdraw), and the
  wire-level `lzReceive → sendCompose → lzCompose` path with delivered compose value, zero and
  non-zero, is exactly what the harness must add).
- **Each route is enabled last, and only once its remote side exists.** `setBridgeRoute`
  reads the adapter's live peer for the destination endpoint, so it cannot be set before the
  adapter's peer is wired; until the type is pointed at a live route its forward moves revert
  with `BridgeRouteNotConfigured` (a cross-chain user operation naming the chain with
  `UnknownBridgeRoute`) while creation and the backward sweep already work. The remote account
  (same diamond address, same derivation) must be deployed before the forward moves are
  enabled, since bridged FXRP lands on the subaccount's own address there.

## Design decisions, resolved

The asset-moving decisions below were taken with the methods they concern; each is
incorporated in the sections above, and the note here records what was decided and what was
deliberately not built.

- ~~Stuck RLUSD on the loan-chain side~~ — resolved: while the account's position has debt, the balance is repayment material (`repay` is its only move); once the position is closed — by `repay` itself or by a full external liquidation — the same `repay` call pushes the surplus to the parent Personal Account (the user's own loan-chain account), best-effort: a push the token refuses stays on the account for a later `repay` to retry, never rolling back the repayment. No generic `recoverToken`: stray tokens strand, as on the Flare side. Same-id replay is prevented by the operation ids (two separately authorized ids can each borrow).
- ~~Atomic withdraw-and-bridge action~~ — resolved, built as `ACTION_WITHDRAW` itself: the withdraw compose withdraws the collateral and bridges it home in the same execution (the withdraw/redeposit race is closed for withdrawals; it survives only for residue). Compose value is accepted for this one action and spent in the same call — the return leg's fee, prepaid from Flare as message-1 compose value, quoted against the signed `returnOptions`, excess to the parent; every delivery must carry the signed `minComposeValue` floor (delivery is permissionless, the value unauthenticated — below the floor nothing consumes the packet), and a short delivery reverts and stays retriable. Two accepted residuals: bad signed `returnOptions` park that withdrawal until a fresh instruction reusing the same operation id (the parked packet then terminal-skips as a duplicate), and the redeem-home packet residual above applies to the return leg as to any bridge-back — including its best-effort redemption fee.
- ~~The Flare fee~~ — resolved, designed and built: checkpoint accounting of `max(feeFloor, market interest + feeSpread)` over the account's Morpho debt, per-type timelocked terms behind a recipient activation marker, collection in `repay` (debt first) and through the parent-signed `payLoanFee` (the fee alone, from the remote PA's own RLUSD, the signed amount as cap), with the exits gated as a secured claim (an under-secured withdraw or sweep is refused until the fee is paid). The gate's basis is gross collateral at factor 3: an equity basis would widen the Morpho-allows/gate-refuses band about fourfold, and a lower factor would trade recovery headroom for a rarer band; `payLoanFee` is the fee-only way through that band (see The exit gate). See The Flare fee.
- ~~Split `LoanChainSettingsFacet`~~ — resolved: `ComposeTransportFacet` (the general compose transport, timelocked set, immediate owner-only clear with a cancel-then-rotate runbook) and `LoanMarketsFacet` (write-once markets, borrow switch); creation moved to the generic `createPersonalAccount` on `PersonalAccountsFacet`.
- ~~`LoanBridgeSettingsFacet`, one global destination~~ — resolved: the Flare end became the type-generic `BridgeRoutesFacet` — one FXRP adapter (`setFxrpOft`, re-validating every route on rotation), one pinned peer per remote chain (`setBridgeRoute`), and the chain each bridging subaccount type lives on (`setSubaccountTypeRoute`, write-once — the type IS that identity, and its instructions carry no destination; `setSubaccountTypeRouteSuspended` is the reversible per-type stop); the Personal Account's `sendCrossChainUserOp` names its `destinationEid`, allowlisted by the registry. A new remote chain is a deployment plus governance. Multiple accepted origins on a remote transport (relay hops) were deliberately left for a later, additive change — see Multiple remote chains.
- ~~Grace-period public fallback for the default relays~~ — resolved by removing the relays: the parent Personal Account is the redeemer and defaults directly on the asset manager through `executeUserOp` (still `notPaused`; the appointed executor's direct path is the pause-time trigger, as before). The planned one-click-withdrawal subaccount type dissolves the same way, into a Personal Account multicall — do not build it.
- ~~Native payability~~ — resolved the other way: no `receive()` and no native exit on the Flare subaccount (no protocol flow leaves native on it — the bridge refunds its caller, redemption outcomes land on the parent, and the compose value of its own bridge-back is forwarded within the same call); native landing without a call (pre-deployment funding of the predicted address, a force-send) strands — accepted; a beacon upgrade can add an exit if it ever matters.
