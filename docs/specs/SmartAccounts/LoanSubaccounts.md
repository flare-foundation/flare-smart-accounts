# Loan Subaccounts

A loan subaccount is a deterministic, restricted staging account owned by a [Personal Account](./PersonalAccounts.md), used to stage loan-related assets (FXRP on the way to or from a cross-chain lending flow). It is not a generic smart wallet: it will expose only a fixed set of loan operations, and anyone may trigger only predefined cleanup actions on it.

Status: in progress. The account, its proxy, the per-type implementation registry, controller-side creation/prediction, the account abstraction dispatch, both cleanup moves (`sweepRedeem`, `sweepToLoan`), and the recovery methods (`sweepToParent`, `sweepNativeToParent`) are in place. The Flare-side loan instruction (`executeLayerZeroCall`) is in place. The loan-chain-side account (Ethereum, at launch) is functionally complete: the authenticated compose entry point (`lzCompose` with the borrow, withdraw, and set-recovery actions), the per-type market binding and governance configuration (`LoanChainSettingsFacet`), the creation route, and the permissionless rails (`repay`, `depositIdleFxrp`, `sweepToOrigin`, recovery). A sweep-direction lifecycle was evaluated and rejected (see Cleanup moves), and the relay grace-period fallback is parked (see open items).

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
- `createSubaccount(xrplOwner, type)` — permissionless, `notPaused`; the parent Personal Account resolves to the registered account when one exists, and to its computed address otherwise — the same fallback `getSubaccount` uses, so creation works before the Personal Account exists (and on chains where PAs never exist at all). Permissionless creation supports the executor-cleanup path: if assets already landed on the predicted address, anyone can materialize the subaccount to sweep them — without waiting for the parent. A subaccount created before its PA is only **partly** inert: `onlyParent` methods have no possible caller and `sweepRedeem` reverts reading the XRPL owner from the codeless parent, while `sweepToLoan` (which never reads the parent) works normally, and `sweepToParent`/`sweepNativeToParent` park assets at the future PA address — the same owner's deterministic address, whose later CREATE2 deployment a pre-existing balance does not block. The PA then deploys at exactly the recorded parent, owning whatever was parked. One qualification: this holds for a valid owner string — the route accepts any string, but a Personal Account cannot be created for an empty one, so an empty-owner subaccount is permanent caller-funded junk with no custody or collision impact. It is also what a user operation calls before invoking a method on the subaccount. Idempotent — repeated calls return the same address.

Unlike Personal Accounts, which are only ever created as a side effect of an instruction reaching the diamond (`getOrCreatePersonalAccount` inside the instruction entry points), a loan subaccount needs an explicit create: its methods are called **directly** — by the parent Personal Account or by an executor — so there is no diamond hop in that path to create it lazily.

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

Calling a subaccount that is not deployed yet would **silently succeed** — a call to an address with no code returns success, so `executeUserOp` would not revert. The instruction does nothing, except that any native value it carried is transferred to the codeless address, where it sits until the subaccount is created and `sweepNativeToParent` recovers it. User operations must therefore create the subaccount first. `createSubaccount` is permissionless and idempotent, so it can be the first call of every such operation:

```text
executeUserOp([
  { target: controller,  data: createSubaccount(xrplOwner, Loan) },
  { target: subaccount,  data: <restricted method> }
])
```

## Cleanup moves

Assets can strand at the subaccount whenever a cross-chain flow breaks part-way. Both directions out are permissionless, so an executor — or anyone — can clear them:

- **`sweepRedeem()`** — the backward move. Redeems idle FXRP to the parent Personal Account's XRPL owner through FAssets. It takes **no parameters**: the destination is read on-chain from the parent account, the executor and fee come from the controller, and `msg.value` must cover the fee. Reverts with `NothingToRedeem` rather than no-op, so a caller's value is returned instead of being trapped on the account.

  It calls `redeemAmount` (the UBA-based entry point on `IRedeemExtended`, which the asset manager implements) with the **whole balance**, rather than `redeem`, which only accepts whole lots. A cleanup method that redeemed whole lots would strand the remainder — up to one lot short of a full sweep — with no way out, which defeats the purpose. FAssets may still redeem less than requested when redemption tickets run out; the remainder simply stays on the account and can be swept again.
- **`sweepToLoan()`** — the forward move. Bridges idle FXRP onward to the loan chain over LayerZero. It also takes **no parameters**, for the same reason: the destination is **this account's own address**, which is identical on every chain because it is CREATE2-derived from inputs that do not vary by chain, and the destination chain and OFT come from governance-set controller settings (`setLoanBridgeSettings`, timelocked). So a permissionless caller has nothing to point at. `msg.value` must cover the LayerZero messaging fee; the exact quoted fee is forwarded and any excess is returned to the caller rather than left on an account with no native exit.

  The FXRP OFT is a lock/unlock adapter (`approvalRequired() == true`), so the sweep approves it for the exact amount and resets the allowance to zero afterwards. It reverts while the controller is paused: the forward sweep is the incident-containment surface (an OFT or route compromise is stopped by pausers immediately, without waiting out the timelock), while `sweepRedeem` stays available during a pause so assets can always exit toward the user. `setLoanBridgeSettings` validates that the OFT wraps the FXRP token, shares its decimals, and that its live peer for the destination endpoint equals the **pinned expected peer** exactly — existence alone would accept a wrong route — so misconfiguration fails at the timelocked call, not in the field; explicit zeros clear the settings, which disables the forward sweep until reconfigured. Every `sweepToLoan` re-checks the OFT's live peer against the pinned one before locking FXRP, so a peer mutation on the OFT after configuration fails sweeps closed instead of routing to an unknown remote OApp. No compose message is attached: this is cleanup, moving the assets across, and depositing them into the lending protocol is a separate forward move on the destination side. FXRP and the OFT both use 6 decimals, so nothing is lost to shared-decimal dust and `minAmountLD` equals the full amount.

Which direction to sweep is the **executor's operational decision**, deliberately not enforced
on-chain. A parent-stamped direction lifecycle — so a third party could not front-run the
executor and trigger the opposite direction first — was considered, built, evaluated, and
rejected as a product decision. Both destinations are the user's own — the parent's XRPL
owner backward, this account's own cross-chain address forward — so a front-run cannot lose or
redirect funds; it is linear-cost vandalism, a real fee paid per attempt for no gain. The
lifecycle, in exchange, would have blocked the backward exit for its timeout duration (even
during a pause), delayed legitimate direction changes, and added a standing state machine to
custody code. The invariant that matters holds without it: anyone may move the assets, nobody
may redirect them.

The same openness is an **accepted risk** against the loan instruction: a stranded balance awaiting a parent-signed `executeLayerZeroCall` can be swept
out from under it, aborting the requested loan action. Two bounds keep this accepted rather
than fixed. First, the **primary loan flow is atomic and immune on the Flare leg**: one `handleMintedFAssets`
transaction mints the FXRP, funds the Personal Account, creates the subaccount, transfers, and
bridges with the payload — the subaccount balance never exists outside that transaction, so
there is nothing to front-run on this chain (a test covers the five steps in one transaction; the destination side has its own, separately accepted window — see the loan-chain-side section). Only
*retry-after-strand* is exposed: FXRP already sitting on the subaccount while the user signs a
fresh instruction. Second, in that window the funds can only be pushed to the user's own
addresses. The griefing asymmetry is real, though — the attacker pays a fixed executor or
messaging fee while `sweepRedeem` imposes a re-mint round trip whose cost is proportional to
the balance — so this is accepted, not solved; revisit (the direction lifecycle is the known
remedy) if such griefing is ever observed in practice.

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
**redemption payment default**, which seizes the agent's locked collateral and pays it to the
redeemer. FAssets permits that only from the recorded redeemer (this account), the appointed
executor, or the agent owner — so relying on the appointed executor alone would make it a single
point of failure. The account exposes relays, `redemptionPaymentDefault` and
`xrpRedemptionPaymentDefault`, **restricted to the parent Personal Account** (`onlyParent`, so
the user drives them through an XRPL instruction). They are deliberately not permissionless,
unlike the sweeps: defaulting is not cleanup along fixed rails but a *decision* — after the
payment window expires, the user may prefer waiting for a late XRP payment over taking the
collateral payout — and a public relay would let anyone front-run the appointed executor's own
call, which burns the funded executor fee (FAssets pays it only when the executor is the
immediate caller). With parent-driven relays, the parties able to default are exactly the three
FAssets intends: the user (through the parent account), the appointed executor (directly on the
asset manager), and the agent (directly). The payout always lands on this account, where
`sweepToParent` recovers it.

Two costs of the relay to be aware of:

- **Any relayed default forfeits the funded executor fee** — including a parent-driven one. The
  asset manager pays the fee only when the executor is its *immediate caller*, and through the
  relay the caller is always this account, so the fee funded at `sweepRedeem` time is burned.
  Relaying is the user's fallback, not the cheap path; the executor calling the asset manager
  directly is.
- **The relay is unreachable while the controller is paused**: the parent only acts through the
  instruction pipeline, which is `notPaused`. The appointed executor's direct path is unaffected
  by our pause, so defaults still have their normal operational trigger during an incident — but
  a pause held open across FDC's attestation window, combined with an unavailable executor,
  recreates the executor dependency the relay removes. Operationally: unpause promptly, and keep
  executor monitoring alive during incidents. A grace-period public fallback on the relay (open
  to anyone once a request is old enough) is designed but parked — see the open items.

Integration note: the XRP proof's `proofOwner` must be requested as zero or **this account's
address** — the asset manager sees this account as the caller, not the parent or any relayer.

## The loan instruction: `executeLayerZeroCall`

The forward moves come in two shapes. `sweepToLoan` is cleanup: permissionless, no payload, the
assets just cross over. `executeLayerZeroCall(amount, composeMsg, extraOptions)` is the **loan
action**: it bridges exactly the signed `amount` of FXRP to this account's own address on the
loan chain with a **composed call** attached, which the destination-side account executes on
arrival (deposit as collateral, borrow, disburse). The amount is explicit rather than the whole
balance: what travels becomes the authenticated collateral figure on the destination (the OFT's
`amountLD`), so the user signs exactly what is collateralized, and idle residue — donations,
strands from skipped deliveries — stays behind for the cleanup rails. A **zero amount is a
message-only send** (verified against the live adapter), used by actions that carry no tokens:
withdraw and set-recovery. Only the cleanup sweep keeps whole-balance
semantics, because sweeping everything is what cleanup means. Both share one bridging core in the contract, so the guards are
identical by construction: a paused controller blocks it, the governance-pinned settings name
the route, and the OFT's live peer is re-checked against the pinned one on every call. What
differs is authorization and inputs:

- **Restricted to the parent Personal Account** (`onlyParent`): the payload names a loan action
  and, for a borrow, a user-chosen destination for the proceeds, so it must carry the user's
  XRPL signature. This is the instruction-destination rule below, in contract form.
- **The payload (`composeMsg`) is opaque** to this repo. Its schema belongs to the
  destination-side account's `lzCompose` and is pinned down with the loan-chain-side work. It
  must be non-empty: an empty payload would degrade to a plain transfer, which is
  `sweepToLoan`'s job.
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
  parent), same as the sweeps.

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
  (forward, into the account's own position) and `sweepToOrigin()` (backward, to the
  account's own Flare address) are the two rails, under the same invariant (anyone may move,
  nobody may redirect).
- **A real Endpoint/OFT compose-delivery simulation** belongs to the loan-chain-side test suite
  as a regression test; the live-adapter verification recorded here is evidence, not a test.
  Still open.

## Who may choose a destination

Two different rules apply, and the difference is the signature:

- **Instruction destinations are the user's choice.** A borrow names where the RLUSD goes, and the XRPL signature authorizes it. Version 1 implements only the EVM/ERC-20 form (typically an exchange deposit address), paid by a direct transfer; the XRPL-over-Wormhole form is reserved by the payload's destination-kind tag and added when Wormhole provides specs. The EVM address is checked for shape only — clean zero-padded, non-zero, and neither the subaccount itself nor the parent Personal Account (the two addresses in scope when composing, never valid targets) — beyond that it is the user's money and the user's choice, the same way the XRPL target is already allowed to be an arbitrary account.
- **Cleanup destinations are never the caller's choice.** Sweeps are permissionless and carry no signature, so their destination must be derived on-chain from `parentPersonalAccount` — never from caller-supplied data. Anyone may move stranded assets; nobody may redirect them.

Caveats specific to the EVM disbursement option, for the front end rather than the contracts: RLUSD is a regulated stablecoin and can freeze or blacklist addresses, so a transfer can revert and turn a borrow into a stuck disbursement; some exchange deposit addresses are not credited when the sender is a contract, or need a tag an ERC-20 transfer cannot carry; and a wrong address is unrecoverable, since nothing is checked.

## The loan-chain-side account

The same frozen proxy bytecode and the same derivation give the subaccount one address on every
chain, and the per-type implementation registry is what makes that useful: each chain's diamond
registers its **own** implementation for the loan type. Flare registers
[`LoanSubaccount`](../../../contracts/smartAccounts/implementation/LoanSubaccount.sol) (FAssets
redemption, the forward bridge, the parent-driven relays); the loan chain (Ethereum, at
launch) registers
[`LoanChainSubaccount`](../../../contracts/smartAccounts/implementation/LoanChainSubaccount.sol).
The implementation never enters the CREATE2 derivation, so the registration choice cannot move
the address (a test pins this).

The defining difference on the loan chain: **there are no parent-driven methods.** The parent
Personal Account has no local key on the loan chain — instructions exist only on Flare, and
its loan-chain presence is the compose-driven mirror described below — so
`onlyParent` methods could
never be called. Every authorized action instead arrives as an authenticated LayerZero compose
payload sent by this same account on Flare (`executeLayerZeroCall`), and everything else is
permissionless movement along fixed rails, the same invariant as everywhere: anyone may move
the assets, nobody may redirect them.

The account's configuration lives in
[`LoanChainSettingsFacet`](../../../contracts/smartAccounts/facets/LoanChainSettingsFacet.sol),
cut **only on the loan-chain diamond** (Ethereum, at launch), in two parts. The **global transport**, shared by
every loan type: the LayerZero endpoint (the only allowed `lzCompose` caller), the FXRP OFT on
this chain (the only allowed compose sender, the authoritative FXRP identity, and the vehicle
for the bridge-back sweep), and the pinned origin route back to Flare (`originEid`/`originPeer`).
The timelocked `setLoanChainTransport` validates the OFT exactly as the Flare-side
`setLoanBridgeSettings` does — canonical `oftVersion`, decimals shared with its own token,
wired to the same endpoint, live peer equal to the pinned one — and an all-zero transport
clears it, disabling the transport-dependent surface (composed actions and the bridge-back
sweep) for all loan types until reconfigured — repayment, defensive idle deposits, and
configured recovery keep working. And the **per-type market binding**: the timelocked
`registerLoanChainMarket(type, market)` binds a subaccount type to one Morpho contract and
market (`collateralToken` must be the OFT's token — enforced; the loan token is RLUSD by
governance policy per registration, not an on-chain check), **write-once** — see below. The
first registration permanently pins the collateral token: every later non-zero transport must
wrap it (rotating to a different OFT adapter for the same token stays possible), so a
transport replacement can never strand the write-once bindings; the pin survives a transport
clear. One selected loan chain at a time: the Flare side stores a single global destination
route and this side one global transport, so the deployment serves exactly one loan chain.
Serving several loan chains simultaneously would need the transport bound per subaccount type
(the type would then identify both the chain and the pool) and a per-type destination on the
Flare side — a design change, not a configuration.

One race is accepted on this side, mirroring the Flare-side decision: LayerZero credits the
bridged tokens and executes the composed action in two separate steps, so a permissionless
bridge-back sweep will be able to bounce newly credited FXRP to the user's own Flare address
before its composed action executes; the action then cannot execute and the loan is retried.
As on Flare, the front-runner pays real fees per attempt, gains nothing, and cannot redirect
anything. Also noted for later: the pause is a single global switch today; separate pause
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
against accumulated positions. Compose value is rejected (`NonZeroComposeValue`) — the flow
never sends any, and rejecting keeps a mistaken delivery retriable without value. The executor and extra data are
untrusted and ignored. A failing delivery reverts and stays retriable through the endpoint;
the credited FXRP is already on the account either way.

**The payload, version 1** — `abi.encode(uint8 version, uint8 action, bytes actionData)`. Every
action carries `(bytes32 operationId, uint64 deadline, …)`. The market is not a payload field:
the account operates on exactly one market — the one its type is bound to — so the subaccount
address itself commits to the pool:

- **Operation ids make retries safe**: a user retrying a stalled instruction produces a new
  LayerZero packet, and distinct deliveries of the same intent must not double-execute. An
  already-consumed id completes the delivery without effect (`LoanActionSkipped`). An expired
  skip leaves the id unconsumed, so the same intent can retry under it (expiry is cured by
  refreshing the deadline, a non-economic field); a duplicate id was consumed by its first
  execution; a stale-epoch skip **retires** its id, since staleness cannot be cured without
  changing an economic field. Ids must be non-zero and globally unique per subaccount across
  action types; retrying clients must reuse an expired id only for the same intent with a
  fresh deadline (a convention, not contract-enforced). The terminal gates run before the
  borrow switch and the market lookup, so a duplicate or expired packet finalizes even on a
  sunset pool or an unregistered market.
- **Deadlines expire stale intent**: an old queued action completes without effect instead of
  creating debt long after the user signed it.
- **A debt increase respects the per-type borrow switch** and reverts with
  `BorrowingDisabled` while it is set (deliberately not a skip, since the switch is
  temporary-by-policy and a permissionless delivery must not consume the packet; it stays
  retriable until the deadline expires). Pure collateral top-ups, withdrawals, and repayment
  are never gated by the switch, so a sunset pool's positions stay defensible and can always exit
  (while paused, a top-up executes only when the position carries live debt). A message-only
  action delivered with tokens attached executes normally; the credit simply stays idle on
  the account for the fixed rails.
- Skipped deliveries leave their bridged FXRP on the account for the fixed rails.

`ACTION_BORROW` supplies **exactly the authenticated bridged amount** (the codec's `amountLD`,
never the idle balance, which can commingle donations and unrelated transfers) as collateral,
and for a non-zero `borrowAmount` borrows against the account's own position and pays the
destination — EVM kind only, clean zero-padded address, Wormhole kind reserved. If the credited
tokens were moved before delivery (the accepted race above), the action fails closed with
`InsufficientComposeBalance` — a cap rather than provenance, since every balance on the account
is the user's own, but it stops a signed action from absorbing more than its own credit. `ACTION_WITHDRAW` withdraws
collateral from the account's own position **to the account itself**, where only the fixed
rails can move it; Morpho enforces position health.

**Creation route.** The same generic `createSubaccount(xrplOwner, type)` serves this chain —
there is no separate loan-chain creation function. The parent Personal Account resolves the
way `getSubaccount` already predicts it: the registered account when one exists, its
**computed** address otherwise (the PA derivation is frozen and chain-independent, so the two
can never diverge). On this chain the parent is the compose-driven mirror Personal Account
(see below): the registered branch runs once the mirror has been created, the computed one
before — either way the subaccount materializes at exactly the address the Flare side
predicts, whether or not the mirror exists yet.

**One market per account, bound by the type.** Positions must outlive every configuration
decision, so the market an account operates on is not mutable state at all: the timelocked
`registerLoanChainMarket(type, market)` binds a subaccount type to one Morpho contract and
market, **write-once** — registering a different market for the same type reverts, and a new
pool is a new subaccount type (same implementation, one registry call per chain, its own
deterministic addresses). Since the account's address commits to its type and the type
commits to its market, *where the money is* is *which pool it is on*: payloads carry no
market field, `repay` takes no argument, and every debt question is a single live `position()`
read — nothing is cached, so an external liquidation is visible to the very next call with no
synchronization step. Market registration validates that the market exists on the Morpho
contract, both tokens carry code, and the collateral token is exactly the transport OFT's
token; the first registration also pins the collateral token for every later transport and —
transitively — every later market (see the configuration section). The loan token is
deliberately not pinned: RLUSD is governance policy per registration, not an on-chain
invariant. Registration policy: **only canonical immutable Morpho Blue deployments**. This is a
pre-registration governance trust assumption enforced by review at the timelocked call — the
contract itself checks only code-presence and market existence. It matters because the
binding is permanent and the account's debt checks must be able to read its live position: a
Morpho that could later change behavior or start reverting would block that account's
debt-gated paths (borrowing, defensive deposits, loan-token recovery) — inherent to where the
position lives. Immutability reduces that availability risk; it is not containment — it does
not protect against a vulnerability in the immutable code itself, a malicious clone, or a
compromised market oracle or interest model.

**Sunsetting a pool.** The timelocked per-type `disableLoanChainBorrowing` stops new
debt increases on a type (`enableLoanChainBorrowing` reverses it) — the routine migration
lever: register the next pool as a new type, disable borrowing on the old one, and the old
accounts remain fully exit-capable forever
(repayment, top-ups, withdrawals, and recovery are never gated by the switch). Clearing the
transport zeroes the LayerZero surface for **all** loan types — composed actions and the
bridge-back sweep wait until governance reconfigures it; with a live timelock that wait is
real, which is why the clear is the nuclear incident lever. Market bindings, `repay`,
defensive idle deposits, and configured recovery persist through both levers. The global
pause blocks debt increases, withdrawals, debt-free deposits, the bridge-back and outward
recovery — while **repayment and defensive collateral top-ups stay available**: a composed
top-up or an idle-rail deposit executes during a pause exactly when the position carries
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

**The permissionless rails** — fixed destinations, no caller discretion, mirroring the
Flare-side invariant:

- **`repay()`** pushes the whole idle loan-token balance into the account's one position,
  clamped to the live debt: interest is accrued first, a balance below the debt repays by
  assets, a balance covering it repays by **exact borrow shares** (Morpho's canonical
  rounded-up conversion with virtual offsets), closing the position without the over-repay
  revert. The documented user flow overfunds repayments to cover in-flight interest, so the
  clamp is what makes that flow work; the surplus stays for `recoverLoanToken`. Available
  while paused — repaying moves the position toward safety.
- **`depositIdleFxrp()`** supplies the whole idle FXRP balance as collateral into the
  account's one position — the executor's retry rail for FXRP that arrived without a
  successful composed action. Defending an indebted position survives a pause, like
  repayment; a debt-free deposit is new exposure and pause-gated. Debt is read live from
  Morpho on every check — nothing is cached, so an external liquidation is visible to the
  very next call. The direction race versus `sweepToOrigin` is accepted but carries an
  asymmetry the Flare-side sweeps do not have: redepositing costs the griefer only gas, while
  completing the withdrawal again costs a new signed operation and a repeat bridge fee. A
  permissionless caller can even deliver a queued withdrawal compose and redeposit its FXRP in
  the same transaction; an executor narrows this to a transaction-ordering race by atomically
  bundling delivery with `sweepToOrigin` (compose delivery is permissionless on the endpoint;
  private order flow helps), but cannot close it. Funds are never redirected — the impact is
  delay and the repeat cost.
- **`sweepToOrigin()`** bridges the whole idle FXRP balance back to this account's own Flare
  address (the OFT's own `token()` is the authoritative FXRP identity). Exactly the quoted
  fee is spent and only the call's own excess refunded — pre-existing native never subsidizes
  a caller. Pause-gated: every exit from this chain rides the OFT itself. Live peer re-checked
  against the pinned one.
- **Recovery** goes only to the **authenticated recovery destination**, stored by the
  `ACTION_SET_RECOVERY` compose action (user-signed, like every action). Updates carry a
  strictly increasing epoch, because deliveries are unordered and an older update must not
  overwrite a newer destination — a **stale-epoch skip retires its operation id** (unlike
  expiry, staleness cannot be cured without changing an economic field, so the id has no
  legitimate reuse). The set-recovery action is deliberately **allowed while paused**:
  rotating a compromised destination is configuration toward safety, and it must not have to
  wait for (and race) an unpause while outward recovery is stopped. The flip side: a pause
  does not contain a compromise of the compose-authentication root itself (endpoint, OFT,
  pinned peer) — for that incident, clearing the transport is the containment, since it
  disables `lzCompose` entirely. `recoverToken`
  moves stray assets (the market's tokens are protected and rejected); `recoverLoanToken`
  moves loan-token surplus, but only while **the position carries no debt** — read live from
  Morpho, so an external liquidation (which zeroes debt without the account observing it) is
  visible immediately; `recoverNative`
  moves the native balance (the account has `receive()` for bridge refunds). Outward recovery
  is pause-gated; an unset destination leaves assets waiting.

## The loan-chain Personal Account

Users are XRPL-only, and their signatures become on-chain authority only on Flare — so on
the loan chain the user's Personal Account address exists (the PA proxy derivation is frozen
and chain-independent) but historically carried no code, and anything sent to it was
stranded. The **loan-chain Personal Account**
([`LoanChainPersonalAccount`](../../../contracts/smartAccounts/implementation/LoanChainPersonalAccount.sol))
closes that: a per-chain implementation registered behind the same controller-as-beacon that
serves the Flare PAs, materialized at the same CREATE2 address through the frozen PA proxy.
It is the compose-driven mirror of the user's Flare account — no local owner, no
controller-driven methods (instructions exist only on Flare); every authorized action arrives
as an authenticated LayerZero compose message sent by this same account on Flare, exactly the
subaccount's self-to-self trick applied to the PA family.

**The shared base.** The authentication checklist (endpoint-only caller, configured FXRP OFT
as sender, origin chain, `composeFrom` equal to the account's own address, GUID recomputed
from the pinned origin peer) and the operation-id replay protection with the skip semantics
are identical for the mirror PA and the loan subaccount, and live once in
[`LoanChainAccountBase`](../../../contracts/smartAccounts/implementation/LoanChainAccountBase.sol)
(public surface: [`ILoanChainAccountBase`](../../../contracts/userInterfaces/ILoanChainAccountBase.sol)).
Derived accounts define only their action set and identity. Deliberately one implementation:
this block is the security root of every account with no local owner.

**The action set is minimal and typed.** The exact blast-radius claim: a compromised compose
root can drain the mirror's token balances and invoke an ERC-20-`transfer`-shaped call on a
target of its choosing — a non-standard target could attach other semantics to that
selector — but it gets no arbitrary calldata, no delegatecall, no approval, and no general
execution as the mirror; callbacks into the mirror's public entries meet the active
reentrancy guard.

- `PA_ACTION_TRANSFER_TOKEN(opId, deadline, token, destination, amount)` — the one signed
  action: an exact-amount ERC-20 move to a destination of the user's choice (shape-checked
  only: non-zero, not this account). This replaces any set-then-recover indirection: the
  signature covers the actual move. Pause-gated — outward moves stop during an incident,
  since a transport compromise is exactly what an incident looks like; the packet stays
  queued at the endpoint and re-delivers after unpausing.
- **No permissionless rail at all.** No protocol flow ever routes FXRP to the mirror: Flare's
  instructions are message-only, bridged collateral lands on the loan subaccount, and the
  planned retargeting of subaccount recovery to the parent will bring only non-collateral
  tokens (the subaccount rejects FXRP in `recoverToken`). Today nothing in the protocol sends
  the mirror anything at all; it is the prerequisite for that retargeting.
  FXRP reaching the mirror is therefore always external (a misdirected OFT send or transfer),
  and the signed token transfer is its exit — a permissionless bridge-back was considered and
  dropped: it would have been a public payable OFT-send path, with a race against signed FXRP
  transfers, serving only a case nobody causes.
- No native at all — no `receive()` and no native exit: nothing in the protocol ever pushes
  native at the mirror (its only payable entry is the value-rejecting `lzCompose`), so plain
  native sends revert at the sender. The only way native can
  still land is a force-send; rather than carry an exit for a case nobody causes, the
  implementation's beacon-upgradeability is the answer — an exit is added the day one is
  needed. No NFT/1155 holders in v1 for the same reason (a safe-transfer without a command to
  move it out again would only build a trap).

**The Flare-side sender.** `PersonalAccount.sendCrossChainInstruction(payload, extraOptions)`
sends the command as a message-only compose (amount zero) over the configured FXRP OFT — the
validated path: configured bridge settings, live peer re-checked against the pinned one,
exact quoted fee, pause-gated. It is callable **only by the account itself**, which makes it
reachable exclusively through an `executeUserOp` multicall — the XRPL signature covers the
payload end-to-end. The fee value rides from the account's own native balance through the
multicall, and any excess simply remains on the account. (A raw user-op call to the OFT
remains technically possible as an emergency fallback, with none of these guardrails.)

**Creation.** `createLoanChainPersonalAccount(xrplOwner)` on the loan-chain settings facet —
permissionless and idempotent, the PA analog of the generic `createSubaccount`: the
instruction machinery that creates PAs lazily on Flare does not exist here, so creation is an
explicit route. It requires the registered loan-chain PA implementation (the frozen
BeaconProxy resolves it at construction) and registers the account, so `getPersonalAccount`
answers with it afterwards. An empty owner cannot be created (the implementation rejects it),
so no mirror can exist for an impossible owner.

## Deployment

- **Fresh deployments** (`pnpm deploy_contracts` → `DeploySmartAccounts`): the loan module is
  part of the standard cut — `SubaccountsFacet` and `LoanBridgeSettingsFacet` are deployed with the other smart-accounts
  facets, a `LoanSubaccount` implementation is deployed alongside the Personal Account
  implementation, and type `1` is registered with `setSubaccountImplementation` before
  `setTimelockDuration`, while the timelock is still zero.
- **Existing deployments** (flare, songbird, coston2): the facet needs no dedicated deploy
  step — naming `SubaccountsFacet` and `LoanBridgeSettingsFacet` in a cut plan
  (`deployment/cuts/<network>/cuts-<date>.json`, verified with `pnpm check_cut`, executed with
  `pnpm diamond_cut`) deploys it from the artifact as part of the cut flow. The implementation
  is deployed with `pnpm deploy_loan_subaccount_implementation <network>` and registered by
  governance with the timelocked
  `setSubaccountImplementation(SUBACCOUNT_TYPE_LOAN, <address>)`.
- **Ethereum bootstrap.** Rebuilding today's sources does **not** reproduce the production
  diamond address — source drift changes the base facets' bytecode, their CREATE2 addresses,
  the diamond's constructor arguments, and with them its address. The historical init code of
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
  `TimelockFacet`, `PauseFacet`, `PersonalAccountsFacet` (the PA beacon surface for the
  loan-chain Personal Accounts), and `LoanChainSettingsFacet` through the standard cut flow
  (the cut plan under `deployment/cuts/ethereum/` is authored at cut time;
  `deployment/deploys/ethereum.json` is seeded with the pinned contracts), and the
  implementation ships with `pnpm deploy_loan_chain_subaccount_implementation ethereum`. There is
  deliberately no `deployment/chain-config/ethereum.json`: the generic full-deploy script must
  not run against Ethereum — operators go through the pinned bootstrap and the scripts above.
  One ordering constraint is absolute: the pool-per-type settings scheme redefined payload
  version 1 relative to the earlier route-registry draft, which is safe **only** while no
  loan-chain settings facet has ever been cut, no old-V1 packet is queued or in flight
  anywhere in LayerZero, and no client or tooling holds prebuilt old-schema payloads — all
  true today, `deployment/deploys/ethereum.json` holds only the pinned bootstrap contracts. An
  environment that had shipped the old scheme would need a new payload version instead. (The
  settings storage namespace is no longer shared: the rename to
  `smartAccounts.LoanChainSettings.State` gave it a fresh slot — itself a pre-first-cut-only
  move, covered by the same condition.)

  **Before the first Ethereum cut, still to be built and rehearsed:**

  - **implementation registration as a verified gate**: `setSubaccountImplementation(1, …)`
    and `setPersonalAccountImplementation(…)` must register exactly the reviewed
    `LoanChainSubaccount` and `LoanChainPersonalAccount` artifacts (runtime hashes verified
    before the timelocked calls, `implementationForType(1)` and the PA beacon's
    `implementation()` asserted after them), and this must complete before any account is
    advertised, funded, or the cross-chain route is enabled. The setters check only that
    code exists; a wrong but `initialize`-compatible registration would let permissionless
    creation materialize frozen proxies with the wrong storage layout, and initialization
    cannot be replayed;
  - **the chain-local storage-lineage gate**: every implementation in a proxy's chain-local
    upgrade lineage must preserve that proxy's storage layout (cross-chain layouts may
    differ — the chains share only the address — but a chain's lineage may not). The
    loan-chain subaccount layout was reordered when the shared base was extracted, which is
    safe only because no loan-chain subaccount proxy exists yet; verify that before the first
    cut, and freeze a storage-layout baseline for both loan-chain implementations once the
    first proxy is deployed. The shared base's two fields (`controller`, `usedOperations`)
    are the storage prefix of **both** lineages — subaccounts and mirror PAs — so a base-field
    insertion or reorder would corrupt every account of both kinds at once; base state is
    effectively frozen at those two fields from the first proxy on;

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
  - the real Endpoint/OFT compose-delivery integration harness (also a step-6 release gate).
- **`setLoanBridgeSettings` comes last, and only once the loan-chain side exists.** Its
  validation reads the OFT's live peer for the destination endpoint, so it cannot be configured
  before the destination route is wired; until then the forward moves revert with
  `LoanBridgeNotConfigured` while creation, the backward sweep, the relays, and recovery
  already work. The loan-chain-side account (same diamond address, same derivation) must be
  deployed before the forward moves are enabled, since bridged FXRP lands on the subaccount's
  own address there.

## Open design items (decide with the asset-moving methods)

- ~~Stuck RLUSD on the loan-chain side~~ — resolved: while the account's position has debt, the balance is repayment material (`repay` is its only move); once the position is closed, the surplus leaves through `recoverLoanToken` to the authenticated recovery destination. Same-id replay is prevented by the operation ids (two separately authorized ids can each borrow).
- **TODO, parked: atomic withdraw-and-bridge action.** If guaranteed withdrawal completion is ever required, the clean contract-level fix for the withdraw/redeposit ordering race (see the rails) is a single composed action that withdraws collateral and bridges it back in one execution. It is not free: it needs compose value (rejected today by `NonZeroComposeValue`, which exists to keep mistaken deliveries retriable), fee quoting inside the compose, and refund semantics for a permissionless deliverer. Decide if withdrawal-completion guarantees become a product requirement; until then, executor-side bundling of delivery with `sweepToOrigin` is the operational mitigation.
- **TODO, in design: the Flare fee.** An interest-spread model (checkpoint accounting over the account's Morpho debt) was accepted by product and is in design review; it is kept out of this spec until the design settles, then documented here.
- **TODO, parked: grace-period public fallback for the default relays.** `onlyParent` relays are unreachable during a pause (see above), so a pause held across FDC's attestation window combined with an unavailable executor recreates the executor dependency. The designed fix: relays stay parent-only until the request's `lastUnderlyingTimestamp` (read per-request from `redemptionRequestInfo`, no stored clock) is a grace period past, then open to anyone — by then the executor has demonstrably failed and the timing right has lapsed, so a fee-burning public call is acceptable. Implemented and tested, then parked; **must be decided before the first production deployment**, rather than left to incident-time executor availability.
- ~~Native payability~~ — resolved: the account has `receive()` and `sweepNativeToParent()`, since external refund behavior (FAssets, LayerZero, bridges) is not under this repo's control.
