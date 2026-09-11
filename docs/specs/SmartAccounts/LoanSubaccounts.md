# Loan Subaccounts

A loan subaccount is a deterministic, restricted staging account owned by a [Personal Account](./PersonalAccounts.md), used to stage loan-related assets (FXRP on the way to or from a cross-chain lending flow). It is not a generic smart wallet: it will expose only a fixed set of loan operations, and anyone may trigger only predefined cleanup actions on it.

Status: the contract surface described here is implemented — the account and its proxy, the per-type implementation registry, creation and prediction, the account abstraction dispatch, the Flare-side loan instructions, the loan-chain-side account with its compose entry point, market binding and permissionless rails, and the Flare fee. Two behaviors are worth naming up front: each account has exactly one permissionless direction (on Flare, `sweepRedeem` home — forward moves are signed), and redemption belongs to the parent Personal Account, so the subaccount carries no redemption-default relays. Production activation remains gated by the **Deployment** checklist.

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

> **Frozen:** the derivation uses the frozen `Subaccounts.PROXY_CREATION_CODE` hex constant, exactly like [`PersonalAccounts.PROXY_CREATION_CODE`](./PersonalAccounts.md#frozen-proxy_creation_code). Its hash is pinned in `test/unit/smartAccounts/SubaccountsLibrary.t.sol`, and two further tests compare it against a fresh compilation of the proxy source (by length, and byte-exact modulo CBOR metadata), so functional drift fails CI. Metadata drift does not, and is tolerated by design: the CBOR trailer is a hash over the whole compilation context, so a later comment edit in `ISubaccount` or `ISubaccountsFacet` will re-drift it, and that drift is then accepted rather than chased — re-freezing moves addresses, drift does not. Editing the constant is a cross-chain coordination event: all predicted-but-not-deployed subaccount addresses would shift. Editing the proxy source alone moves no address while the constant stands: an edit that changes bytes outside the metadata trailer fails the functional comparison, and that is what forces the choice between reverting the edit and re-freezing, while a comment-only edit moves the trailer alone and fails nothing. Re-frozen three times pre-deployment: 2026-08-21, when the beacon query was renamed to `implementationForType`; 2026-08-26, when the proxy contract was renamed to `SubaccountProxy` (the generic deployment vehicle had kept its loan-era name); and 2026-09-09 onto the release build, so the constant is the byte-exact creation code of the reviewed source rather than of an earlier compilation. `SubaccountsFacet` was cut on no network at any of those moments, so no subaccount existed and no address moved on chain. The third is the last: from here the constant is fixed even as its source's metadata drifts.

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
  - The same core runs when FXRP comes home from the loan chain: the twin's withdraw action attaches the `ACTION_REDEEM_HOME` compose to its return leg (its only field a deadline, the sender's block time plus `REDEEM_HOME_TTL`), this account authenticates it exactly as the loan-chain accounts authenticate theirs (the shared base, with the transport derived from its type's bridge route) and redeems **at most the packet's authenticated amount** on arrival (`min(balance, amountLD)`; the rest stays for the public rail — FXRP is fungible, so the cap bounds how much one compose can move, not which units), with the compose value as the executor fee. Zero is allowed there: the packet already cost its sender the LayerZero fee. Past its deadline the packet skips terminally (nothing redeemed, the balance left for the public rail, value to the parent's float), so a packet cannot outlive its delivery window as a standing instruction over later funds. In both the dust branch and the skip, value goes to the parent — never to `msg.sender`, which on that path is the endpoint.

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
`depositIdleFxrp` into the position, from where the signed withdraw brings it home, and the
loan-token surplus of a closed position through
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

## The loan instructions: `borrow`, `depositCollateral`, `withdraw` and `cancel`

The forward moves are the **loan
instructions**: `borrow(collateralAmount, borrowAmount, destinationKind, destination,
minComposeValue, operationId, deadline, extraOptions)`, `depositCollateral(amount, extraOptions)` and
`withdraw(amount, operationId, deadline, options)` and `cancel(operationId, extraOptions)`: typed methods that
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

The four are separate instructions with separate actions — a borrow always increases debt
(`borrowAmount` non-zero), `depositCollateral` never does — so each carries exactly the
fields it needs and its own pause rule (a deposit is the defensive move, and carries neither an
operation id nor a deadline; see the loan-chain section).
`borrow`'s collateral amount is explicit rather than the whole balance: what travels is what the
user signs (the OFT's `amountLD` authenticates it on the destination), and idle residue on this
side — donations, strands from skipped deliveries — stays behind for the cleanup moves. (On the
loan chain the action then supplies its credit together with whatever is idle there, since that
account's FXRP has one route anyway; see the loan-chain section.) A **zero collateral amount is a
message-only send** (verified against the live adapter): a borrow against existing
collateral, a withdraw, or a cancel, none of which carries tokens. Only the cleanup moves keep
whole-balance semantics, because sweeping everything is what cleanup means. All four
instructions share one bridging core in the contract, so the guards are identical by
construction: a paused
controller blocks it, the type's pinned bridge route names the destination, and the OFT's live peer
is re-checked against the pinned one on every call. What differs is authorization and inputs:

- **Restricted to the parent Personal Account** (`onlyParent`): the instruction names a loan
  action and, for a borrow, a user-chosen destination for the proceeds, so it must carry the
  user's XRPL signature. This is the instruction-destination rule below, in contract form.
- **The payload schema is shared with the loan-chain account**, not opaque: the constants
  (`ACTION_BORROW`, `ACTION_DEPOSIT_COLLATERAL`, `ACTION_WITHDRAW`, `ACTION_CANCEL`,
  `DESTINATION_KIND_*`) live in `ILoanSubaccount`, which both halves import, and
  `PAYLOAD_VERSION_1` in `IComposeReceiverAccountBase` beside the bridging surface, so the tags
  cannot drift apart. They are venue-neutral by design: what each action then does to a position
  is the executing half's own, written out for this pair in `IMorphoLoanSubaccountRemote`. The per-action tuple layouts
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
- **Idle FXRP on the loan-chain account needs an exit** — satisfied by one rail: the
  permissionless `depositIdleFxrp()` moves it into the account's own position, and the signed
  withdraw action brings it home from there. It carries no destination — fixed on-chain, so
  nobody may redirect. (A parent-signed direct bridge-back, `sweepToOrigin`, existed pre-cut
  and was removed. The route rests on current dependencies, not on an invariant: on a
  canonical market `supplyCollateral` has no conditions of its own beyond an existing market,
  a non-zero amount and the collateral token's `transferFrom` — the FXRP token is an
  upgradeable proxy whose implementation today has no pause or blocklist, and a `uint128`
  collateral overflow is out of FXRP's range — and, once deposited, withdrawing waits on the
  position's ordinary conditions (Morpho health, the fee gate, the pause, the oracle, the
  transport), while collateral a position needs can be liquidated. Accepted under the
  beacon-upgrade policy; the second exit only added a signed authority, a race and a special
  case — see the resolved decisions.)
- **A real Endpoint/OFT compose-delivery simulation** belongs to the loan-chain-side test suite
  as a regression test; the live-adapter verification recorded here is evidence, not a test.
  Still open for the wire hop (a real `EndpointV2` and the OFT's `lzReceive → sendCompose`),
  and it must cover all the actions (borrow, deposit, the atomic withdraw with its return leg, cancel, remote-PA execute) — the remote-PA case with a
  native drop into the real beacon proxy followed by a value-carrying batch, since unit tests fund
  the remote PA with `vm.deal` and never exercise the executor's gas-limited drop. Covered
  locally: a sender→codec→receiver test runs the bytes the Flare senders hand to `send` through
  the canonical `OFTComposeMsgCodec` wrapper into the real loan-chain receivers.

## Who may choose a destination

Two different rules apply, and the difference is the signature:

- **Instruction destinations are the user's choice.** A borrow names where the RLUSD goes, and the XRPL signature authorizes it. Version 1 implements only the EVM/ERC-20 form (typically an exchange deposit address), paid by a direct transfer; the XRPL-over-Wormhole form is reserved by the payload's destination-kind tag and added when Wormhole provides specs. The EVM address is checked for shape only — clean zero-padded, non-zero, and not the subaccount itself (the proceeds could only repay the new debt); the parent Personal Account, the user's own compose-driven account on the loan chain, is a valid target — beyond that it is the user's money and the user's choice, the same way the XRPL target is already allowed to be an arbitrary account.
- **Cleanup destinations are never the caller's choice.** The cleanup moves and the surplus push — all permissionless (`sweepRedeem`, `depositIdleFxrp`, `repay`) — carry no destination input: it is derived on-chain — the account's own position, `parentPersonalAccount`, or (for the fee legs of `repay`) the governance-set fee recipient — never from caller-supplied data. Whoever may move the assets the protocol routes, nobody may redirect them (a stray token has no rail at all and strands).

Caveats specific to the EVM disbursement option, for the front end rather than the contracts: RLUSD is a regulated stablecoin and can freeze or blacklist addresses, so a transfer can revert and turn a borrow into a stuck disbursement; some exchange deposit addresses are not credited when the sender is a contract, or need a tag an ERC-20 transfer cannot carry; and a wrong address is unrecoverable, since nothing is checked.

## The loan-chain-side account

The same frozen proxy bytecode and the same derivation give the subaccount one address on every
chain, and the per-type implementation registry is what makes that useful: each chain's diamond
registers its **own** implementation for the loan type. Flare registers
[`LoanSubaccount`](../../../contracts/smartAccounts/implementation/LoanSubaccount.sol) (FAssets
redemption pushed to the parent, the forward bridge); the loan chain (Ethereum, at
launch) registers
[`MorphoLoanSubaccountRemote`](../../../contracts/smartAccounts/implementation/MorphoLoanSubaccountRemote.sol).
The implementation never enters the CREATE2 derivation, so the registration choice cannot move
the address (a test pins this).

The defining difference on the loan chain: **nothing is parent-driven.** The parent
Personal Account has no local key on the loan chain — instructions exist only on Flare, and
its loan-chain presence is the compose-driven remote Personal Account described below. Every authorized action
arrives as an authenticated LayerZero compose payload sent by this same account on Flare
(`borrow`, `depositCollateral`, `withdraw`, `cancel`), with no exception: the subaccount has no
parent-callable method at all (the parent-signed fee payment `payLoanFee` existed pre-cut and
was removed; see the resolved decisions).
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
  the bridged token, and the vehicle for the withdraw's return leg), and the pinned origin route back
  to Flare (`originEid`/`originPeer`). The timelocked `setComposeTransport(transport)` validates
  the OFT the way the Flare-side `setFxrpOft` does — canonical `oftVersion`, decimals
  shared with its own token, live peer equal to the pinned one — plus, on this side, that the
  endpoint has code and is the OFT's own (the Flare validator instead requires the OFT to wrap
  FXRP itself, and its receiver reads the endpoint live from the OFT) — and never clears, since
  an all-zero struct fails validation. Clearing is its own call,
  `clearComposeTransport()`, **immediate and owner-only**: a containment lever behind a timelock
  is not one. It disables the transport-dependent surface (composed actions on every receiver, the
  withdraw's return leg included) until a new transport is set, while repayment with its best-effort
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
  stronger than the pause — documented as the nuclear
  action, with the owner trusted for liveness. The Flare-side clears (a zero peer in
  `setBridgeRoute`, a zero adapter in `setFxrpOft`) stay timelocked while this one is immediate;
  the asymmetry is acceptable because on Flare the pause already gates every outbound move and
  the inbound redeem-home is harmless in direction.
- **The loan markets**
  ([`MorphoLoanMarketsFacet`](../../../contracts/smartAccounts/facets/MorphoLoanMarketsFacet.sol)), the
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
against the new adapter's peers — the **Flare half** of a rotation, which is all Flare can see.
The remote half is not: each remote OFT holds a live peer for Flare, and each remote diamond's
compose transport pins that adapter as its `originPeer` (`setComposeTransport` requires the two
to agree). What a packet from the new adapter meets depends on the phase: while the remote
OFT's live Flare peer still names the old adapter, it fails in `lzReceive`, before any token is
credited; once that peer names the new adapter but the transport's `originPeer` does not yet,
a token-bearing compose is credited and then fails compose authentication (retriable) and a
message-only user operation parks. A rotation is therefore a coordinated runbook, never one
call: **(1) pause the Flare side — the source of new traffic — but not the remote destinations,
which must keep delivering; (2) cancel the conflicting queued setters on both sides; (3) let
the old traffic drain fully through `lzCompose`, return packets included; (4) wire the new
adapter's peers: on every remote chain set the remote OFT's live Flare peer to the new
adapter, and on Flare set the new adapter's own peer for every registered route's endpoint to
that route's stored remote peer (the adapter's owner does this on the OFT); (5) on every
remote chain `setComposeTransport` with `originPeer` = the new adapter; (6) `setFxrpOft` on
Flare; (7) unpause.** Only two of these orderings are enforced by code — the remote transport
validates `originPeer` against its OFT's live Flare peer, and `setFxrpOft` re-validates every
stored route against the new adapter's own peers, so both halves of (4) must precede (5) and
(6) respectively; keeping `setFxrpOft` last, after the remote side is wired, is an operational
rule, not a validation. A seamless rotation would need dual-peer acceptance for the
transition in both the remote OFT's receive path (a standard OFT holds one peer per source
endpoint) and the compose authentication — a separate future extension, distinct from the
multi-origin `acceptedOrigins[srcEid]` design deferred under Multiple remote chains.

> **The adapters are upgradeable proxies, and an upgrade is not a rotation.** Every FXRP OFT
> checked on 2026-09-09 sits behind a proxy — Flare's adapter, its Coston2 counterpart and the
> Ethereum OFT — so the same address can change behavior with no rotation, no runbook and no
> event on our side. `setFxrpOft`'s four reads (`token`, `sharedDecimals`, `oftVersion`, and the
> per-route peers) are true when read and can change afterwards, and re-reading them defends
> nothing: an upgrade can keep all four truthful while forging compose instructions. This is an
> accepted dependency on the upgrade authority. On Flare that authority is
> `0xbe653C54DF337F13Fcb726101388F4a4803049F3`, the same Safe that owns the controller, so it is
> the trust domain the protocol already rests on; the Ethereum OFT's owner is a different party.
>
> Same authority is not the same safeguard, though. The diamond's upgrades and timelocked
> configuration changes currently carry a 3,600-second delay — queued, visible and cancellable —
> while the same Safe upgrading the adapter through its ProxyAdmin takes effect in the transaction.
> (Not every owner call here is delayed: ownership transfer, cancellation and unpauser removal are
> immediate by design.) The delay we do rely on does not extend to the adapter, so the warning
> window there is zero.
>
> What the operator owes is the record — implementation address and code hash, upgrade authority,
> OApp owner and delegate — and treating a change as an incident, which means the incident runbook
> above in full: **pause → cancel queued transport sets → clear → rotate**. Clearing alone is not
> enough; a `setComposeTransport` queued beforehand survives the clear and anyone may execute it
> once it matures.

Adding a remote chain is a deployment of existing bytecode plus governance, with nothing changing
in what users sign or what clients build: bootstrap the diamond there from the pinned init code,
cut the remote facet set, `setComposeTransport`, register the pool under a new type (the same
`MorphoLoanSubaccountRemote` if it is Morpho; a new implementation otherwise), `setLoanFeeTerms`; then
on Flare `setSubaccountImplementation(type, <the Flare LoanSubaccount>)`, `setBridgeRoute` and
`setSubaccountTypeRoute` — the route last, once the remote side exists. Clearing a route (zero
peer) fails every type pointed at it and every user operation naming it closed until it is set
again, with the type pins kept; suspending one type stops only that type. None of these stops
cancels a queued timelocked setter — it survives, matures, and anyone may then execute it and
undo the stop — so the Flare containment runbook is the remote one's: cancel queued conflicting
`setFxrpOft` / `setBridgeRoute` / `setSubaccountTypeRouteSuspended` calls first
(`cancelTimelockedCall`).

Deliberately not built: **multiple accepted origins on a remote transport** (a remote Personal
Account relaying a Flare-signed batch onward to a second remote chain). The base authenticates
exactly one origin today. The extension is additive when it is ever wanted — append an
`acceptedOrigins` mapping to the transport namespace, make the origin check a membership test
with the peer chosen by the packet's `srcEid`, keep `originEid` as the distinguished home the
withdraw's return leg sends to, and re-deploy the remote implementations behind the beacons — none of which
changes an instruction a user signs; it widens the remote authentication root, so it is a
decision to take on its own, with its own review.

One race is accepted on this side: LayerZero credits the bridged tokens and executes the
composed action in two separate steps, and in that window anyone can call the permissionless
`depositIdleFxrp`, which locks the newly credited FXRP into the user's own position. The
composed action then finds less idle balance than it bridged, supplies whatever is idle and
proceeds, the borrow exactly as signed. The borrow is
authorized against the position as it stands at execution, not against the bridged credit
specifically: the credit went into the position, and the user's own signed withdraw or a
liquidation may have moved collateral since — Morpho's health check and the packet's deadline
bound what a delayed borrow can do. Gas-only for the griefer, nothing lost or delayed for the
user, nothing redirected. (Before the sweep's removal the action failed closed instead, since the
credit could also have left the account.) Also noted for later: the pause is a single global switch today; separate pause
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
inbound action here is signed; the borrow and the withdraw carry `(bytes32 operationId, uint64
deadline, …)`, while the deposit carries no action data at all — a re-issued deposit (a new
packet; a delivered compose cannot replay) only adds the user's own collateral, which the permissionless rail can do with the same tokens anyway, and
a late one is harmless, the same reasoning that leaves the Flare redeem-home id-less. The
market is not a payload field:
the account operates on exactly one market — the one its type is bound to — so the subaccount
address itself commits to the pool:

- **Operation ids make retries safe**: a user retrying a stalled instruction produces a new
  LayerZero packet, and distinct deliveries of the same intent must not double-execute. An
  already-consumed id completes the delivery without effect (`LoanActionSkipped`). An expired
  skip leaves the id unconsumed, so the same intent can retry under it (expiry is cured by
  refreshing the deadline, a non-economic field); a duplicate id was consumed by its first
  execution. Both skips are terminal only when a later delivery actually arrives and is valid
  (for a withdraw, carrying its signed value floor) — until then the packet merely sits in the
  endpoint, non-executable once its deadline has passed. Ids must be non-zero and globally unique per subaccount across the actions that
  carry one (borrow and withdraw); retrying clients must reuse an expired id only for the same intent with a
  fresh deadline (a convention, not contract-enforced). Reusing an id is **first-success-wins**,
  not replacement: two packets under one id race, whichever executes first stands and the other
  skips — so an id may be reused to change delivery details (options, deadline) or to re-issue an
  instruction that can never succeed (bad `returnOptions`), never to change the amount or the
  destination of one that might still land. The id is the user's idempotency key across an
  asynchronous hop Flare cannot deduplicate (two valid XRPL transactions are two packets), which is
  why it stays. A stuck packet stops being executable once its deadline has passed (the deadline
  itself is inclusive), and **`cancel(operationId)`** is early finality on top of the ids, built
  on the same key (a cancel keyed by the LayerZero GUID was rejected — it races the packet it
  targets, and the id is what the user already holds). It is message-only and the one action that
  withdraws an authority instead of using one: on arrival it consumes the id and does nothing
  else — no market read, no fee terms, no borrow switch, nothing moved — so on the loan chain it
  is not pause-gated and it carries no deadline of its own. On Flare it travels the ordinary
  instruction path, which the pause closes like every other instruction (the controller's
  instruction facets and the bridge send both check it): a Flare-only pause with the loan chain
  live is the one state in which the user cannot revoke a parked packet; there the loan
  chain's own pause suspends the borrow but cancels nothing, so the order is: pause the loan
  chain, restore Flare when safe, submit and confirm the cancellation while the loan chain stays
  paused, then resume — unpausing it earlier makes the latent packet executable again. That gap is
  **accepted, not scheduled**, and so is the matching proposal to exempt the Flare-side collateral
  deposit: either would take a new authenticated entry point on Flare and a carve-out in the
  bridge's own pause, to buy an availability guarantee a dependency can withdraw anyway — bridging
  fresh collateral starts at FAssets, which has a pause of its own. What a Flare pause does not
  touch is the loan chain, whose rails are local and permissionless: repayment, a deposit of FXRP
  already sitting on the account (with debt outstanding), and the fee checkpoint all stay
  available. So the position can still be defended with RLUSD already on the subaccount, or with
  RLUSD anyone can send there — a third party included — since `repay` needs no signature. Being
  on the loan chain is not enough on its own: RLUSD held by the remote Personal Account moves only
  on a signed instruction from Flare, and a Flare pause stops a new one being sent — though an
  instruction already in flight can still execute, since the loan chain is not the paused side.
  The accepted risk is the position with no reachable funds — Morpho interest keeps accruing and
  it stays liquidatable for as long as the Flare side is closed. Sending it is **not**
  cancellation: the two packets race, an original that lands first executes normally and the
  cancellation then finds the id consumed and finalizes quietly without an event. A client
  therefore resolves a sent cancellation by whichever arrives — `LoanActionCancelled`, or the
  original action's own execution event — and either one ends the instruction's live state.
  Cancelling an id that was never issued simply burns it, which is what makes a re-send
  harmless. The motivating case is a borrow parked by a failed health check after a price
  drop, which any collateral landing — the user's own deposit or the permissionless rail — would
  otherwise make executable again; a deadline cap at the sender was considered for the same
  problem and rejected, since cancellation answers it precisely and a cap would expire
  legitimate packets during an outage. Front-end duties
  that follow: generate and persist one id per logical intent; reconstruct ids and GUIDs from the
  Flare-side events after local state loss; reuse an id only for the same economic intent; show
  an instruction as live until it executes, its deadline passes, or its cancellation is
  confirmed; never mint a fresh id merely because delivery status is uncertain; and once a
  cancellation has been signed for an id, retire that id for good — never reissue under it, since
  the cancellation carries no deadline and a late delivery would burn the renewed instruction. The terminal gates run before the
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

- **`ACTION_BORROW`** supplies **the account's whole idle FXRP balance** (the packet's credit
  and any residue — every FXRP on this account is the user's own and has one route, the
  position) as collateral, if any, and borrows `borrowAmount` (non-zero) against the account's own position,
  paying the destination — EVM kind only, clean zero-padded address, Wormhole kind reserved, and
  with it the payload's `minComposeValue`, which that kind must leave at zero. As a
  debt increase it is pause-gated, subject to the per-type borrow switch, and gated on the fee:
  unconfigured fee terms revert retriably (`FeeTermsNotConfigured`), the loan is priced at the
  type's terms current at delivery (see the front-end requirement under The Flare fee), and the
  fee checkpoint runs before the borrow with the principal re-syncing after it. It is also a
  cover-gate event: the post-borrow position — the supplied credit included — must cover
  `1.155 / LLTV` of the new debt plus twice the collectible fee at the market oracle's price, or
  the delivery reverts retriably (`InsufficientRemainingCollateral`) with nothing supplied or
  disbursed; Morpho's own health check runs inside the borrow and is implied by the gate (see
  The cover gate).
- **`ACTION_DEPOSIT_COLLATERAL`** supplies the account's whole idle FXRP balance (the
  authenticated bridged amount, non-zero, plus any residue) as collateral and changes no debt —
  the defensive action: while the controller is paused it executes only when the position
  carries live debt. It carries no operation id and no deadline, so it never skips: delivered
  late it deposits, delivered twice (two packets, two credits) it deposits twice — the user's
  own collateral each time.
- For both of those, the bridged amount authenticates the packet, it does not cap the supply:
  residue from skipped packets or direct sends rides along instead of waiting for the
  permissionless rail's separate call, and if that rail already put the credit into the position
  before delivery (the accepted race above) the action supplies that much less — down to
  nothing — and proceeds; a borrow is authorized against the aggregate position as it stands at
  execution, not against its bridged credit specifically. The events carry the amount actually
  supplied in the execution. (Pre-cut history: the supply was first capped at the packet's own
  amount and failed closed below it, when the signed sweep could still take a credit elsewhere.)
- **`ACTION_CANCEL`** consumes the operation id it names and does nothing else — no market read,
  no fee terms, no borrow switch, nothing moved — so it needs neither a registered market nor
  activated terms, and is not pause-gated on the loan chain. An id already consumed finalizes it
  quietly; an id never issued is simply burned. It carries no deadline and refuses compose value
  like every action but the withdraw. See the operation-id section for what sending one does and
  does not mean.
- **`ACTION_WITHDRAW`** is the atomic withdrawal: it withdraws collateral from the account's own
  position and bridges it back to the account's own Flare address **in the same
  execution**, with the redeem-home compose — no idle window between the two, so the redeposit
  race cannot touch a withdrawal. It is also a cover-gate event: after the pause gate it
  checkpoints the Flare fee and applies the cover rule to the post-withdrawal remainder — a
  withdrawal that would leave the collateral worth less than `1.155 / LLTV` of the live debt plus
  twice the collectible fee (1.5× at the launch market's 77% LLTV) is refused
  (`InsufficientRemainingCollateral`, retriable) until debt and fee are repaid in loan tokens
  through `repay`, or a smaller amount is signed; nothing is ever taken from the collateral (see
  The cover gate). It is the one action
  that accepts compose value, spent in the same call: the value pays the return send's LayerZero
  fee, quoted live against the signed `returnOptions` from the payload, with the excess to the
  parent remote Personal Account and too little value for the quote reverting the delivery —
  retriable, since fee quotes drift both ways. Before any consuming branch — execution and
  terminal skip alike — the delivery must carry at least the signed `minComposeValue`
  (`InsufficientDeliveryValue`, retriable), which is what stops a below-value front-run from
  consuming the packet with the prepaid value undelivered; a terminally skipped withdraw
  delivered at or above the floor forwards its value to the parent, since nothing may strand on
  an account with no native rail. The gate sits above Morpho's own liquidation line, so Morpho's
  health check never binds on this path.

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
clock, terms snapshot — but that prices elapsed periods and gates the exit; it never answers a
Morpho debt question, and it marks itself to the live debt at every checkpoint.) Market registration validates that the market exists on the Morpho
contract, both tokens and the oracle carry code (Morpho's `createMarket` checks none of them, and
a codeless oracle would escape the cover gate's `try`: the call succeeds with empty return data and
decoding it reverts outside the `catch` — a raw revert instead of the gate's refusal; code presence
at registration is all this checks, the oracle's later behavior is the gate's), and the
collateral token is exactly the transport OFT's
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
`test/unit/smartAccounts/MorphoConformance.t.sol`; Morpho Blue is immutable, so the target never moves. It matters because the
binding is permanent and the account's debt checks must be able to read its live position: a
Morpho that could later change behavior or start reverting would block that account's
debt-gated paths (borrowing, defensive deposits, repayment and its surplus push) — inherent to where the
position lives. Immutability reduces that availability risk; it is not containment — it does
not protect against a vulnerability in the immutable code itself, a malicious clone, or a
compromised market oracle or interest model.

**Sunsetting a pool.** The timelocked per-type `disableLoanBorrowing` stops new
debt increases on a type (`enableLoanBorrowing` reverses it) — the routine migration
lever: register the next pool as a new type, cancel any queued `enableLoanBorrowing` for the old
one first (a matured enable is executable by anyone afterward and would undo the disable), disable
borrowing on it, and the old accounts remain fully exit-capable forever
(repayment with its surplus push, deposits, and withdrawals are never gated by the switch). Clearing the
transport (immediate, owner-only) zeroes the LayerZero surface for **all** compose receivers —
composed actions, the withdraw's return leg included, wait until governance sets a new transport through
the timelock; that wait is real, which is why the clear is the nuclear incident lever and not a
routine one. Market bindings, `repay`
(with its surplus push), and defensive idle deposits persist through both levers. The global
pause blocks debt increases, withdrawals (their return leg included) and debt-free deposits (the
surplus push to the parent is inward and stays open, and `repay`'s fee legs are never held — that
money goes to Flare's own recipient; the remote PA's signed user operations are what the pause
stops) — while **repayment and defensive collateral deposits stay available**: a composed
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

- **`repay()`** pays the account's debt and its Flare fee from the whole idle loan-token
  balance, **pro rata**: it checkpoints first, accrues interest, and reads the live debt `D`
  and the collectible fee `F`. A balance `P` short of `D + F` pays `P × F / (D + F)` (rounded
  down, remainders to the debt) to the fee recipient first and repays Morpho with the rest —
  by **exact borrow shares** when that rest covers the debt, otherwise by assets — so both
  claims shrink in the same proportion; a balance covering `D + F` repays by exact borrow
  shares (Morpho's canonical rounded-up conversion with virtual offsets), closing the position
  without the over-repay revert, attempts the whole collectible from the remainder (reserving
  anything unpaid) and pushes the surplus to the parent Personal Account in the same call. The documented user flow
  quotes `D + F` plus headroom for in-flight interest — the surplus push is what makes
  paying above the quote harmless — and a payment that covers the debt but not the fee
  deliberately leaves a pro-rata sliver of both open rather than closing the debt alone (that
  would hand a debt-first route to anyone sending exactly `D`; the split closes the debt for
  less only when a paid share's round-down leaves exactly `D` — possible within roughly `F / D`
  base units of `D + F` — or when a deferred share leaves the full payment available to cover
  it; Morpho then consumes exactly `D` and the tail handles the remainder). Once the debt is zero — closed by this
  call, or already zero (a full external liquidation, tokens arriving after the close; accrual
  is skipped then, so a reverting IRM cannot trap the balance) — the balance beyond the fee
  reservation is the user's surplus. Every fee payment is best-effort: a transfer the token
  refuses (RLUSD can freeze the recipient) never rolls back the repayment. A partial payment's
  share then stays in the payment and repays debt (`LoanFeeDeferred` — the fee stays owed
  unless the tail below pays it); if that closes the debt, the tail attempts the remainder
  again and reserves what still cannot be paid (`LoanFeeReserved`, see The Flare fee). Nothing
  in `repay` is pause-gated: the Morpho repayment moves the position toward safety, and the
  fee legs move money to Flare's own recipient, where an overcharge would be refundable — the
  pause has nothing to hold there.
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
  very next call. It is also the only way idle FXRP leaves the account — into the position,
  from where the signed withdraw brings it home — so the credit of a composed action can be
  deposited by anyone before that action executes (the accepted race above), which the action
  then simply does not supply twice — and any residue idle at that moment goes in with the
  action, so the rail's separate call is only ever needed when no action is coming. It can never
  touch a withdrawal — the withdraw action bridges its amount home in the same execution, with
  no idle window. Funds are never redirected — the impact is delay and a repeat cost.
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

1. **The fee is a junior claim.** Paid pro rata with the debt on the rails, but liquidation
   can pay collateral out past the cover gate; the expected write-off is accepted credit risk.
   No "unconditionally enforced" promise anywhere.
2. **The promise is per-checkpoint measurement:** the user pays
   `max(floor, market interest + spread)` *as measured between checkpoints*. Permissionless
   checkpoints are a legitimate refinement of the measurement, not a broken promise.
3. **Rates stay mutable**, timelocked, with a settle-around operational runbook and a
   per-account terms snapshot as the safety net (below).

### Terms and their lifecycle

Per subaccount type, in [`MorphoLoanMarkets`](../../../contracts/smartAccounts/library/MorphoLoanMarkets.sol):
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

The fee is denominated in the **loan token** and collects at one point, loan-token and
fixed-destination: inside `repay`; the exit
never collects — it only refuses while the remainder would not cover the position (the cover gate
below). The
collection:

- **`repay()`**, in this exact order: checkpoint → Morpho accrual, the live debt `D` and the
  collectible `F` → with a balance `P < D + F`, the **pro-rata fee share** `P × F / (D + F)`
  (rounded down) is paid to the fee recipient first, best-effort — refused by the token (a
  frozen recipient), it stays in the payment and repays debt (`LoanFeeDeferred`; if that
  closes the debt, the tail below attempts the remainder again and reserves what still cannot
  be paid; what the tail cannot pay either stays owed) — and the rest repays Morpho (by exact shares when it covers the debt, by assets otherwise); with `P ≥ D + F` the Morpho repayment closes
  by exact shares → canonical post-sync → the debt-free tail: pay `min(collectible, remaining
  balance)` to the recipient, best-effort, never rolling back the repayment → **reserve**
  `min(outstanding collectible, remaining balance)` on the subaccount (`LoanFeeReserved`) →
  push only the balance beyond the reservation to the parent as surplus. A later `repay`
  retries collection from the reserved tokens without another user top-up; a shortfall beyond
  them still needs new funds. `flareDebtX18` is reduced only by `1e18 ×` the amount actually
  transferred. The split realizes the fee incrementally on the default route — every partial
  payment carries its share — with no stored reserve: a share the collector cannot receive
  goes to the debt (or, once that is closed, to the reservation), which costs Flare only timing, only during a freeze of
  its own recipient, and nothing a user can trigger. The debt-only route stays available to
  anyone who repays Morpho directly on the account's behalf (a rescuer wanting maximum health
  improvement, say); a debt-only external repayment, a partial liquidation or a third-party
  repayment raises the fee-to-debt ratio, and later `repay` payments then allocate a larger
  share to the fee — an accepted consequence.

Settling both claims through the rails therefore costs the live Morpho debt plus the collectible,
from the same RLUSD balance in one `repay` (rounding or a deferred fee share can close Morpho for
less, leaving fee outstanding). There is no fee-only payment: a top-up to the subaccount is split
pro rata, and a fee left with zero debt is what `repay` pays first.

### The cover gate

The gate is what makes dodging the repay-side fee pointless — Morpho's `repay` is
permissionless, so anyone can extinguish the debt directly, but the collateral leaves only
through the account's rails (with the liquidation exception, accepted as decision 1). Both
signed actions that move the position toward the edge, the withdraw and the borrow, gate on
the whole position: the collateral in the position is the security of the debt and of the fee
behind it, so an action is refused when it would strip that security. Morpho alone would let a
user withdraw, or borrow, to the exact liquidation edge (its `_isHealthy` is the same test for a
withdrawal, a borrow and a liquidation), so the buffer above that edge is the account's own —
and it has to hold on both actions, since a withdraw-only buffer is spent by borrowing loan
tokens against the same collateral.

- **The cover rule:** a withdrawal passes when the collateral remaining after it, and a borrow
  when the collateral of the post-borrow position, valued at the market oracle's price, is worth
  at least

  `requiredCover = (D + FEE_WEIGHT × F) × EXIT_HEADROOM / LLTV`, rounded up,

  for the live Morpho debt `D`, the collectible fee `F` and the market's LLTV read from its
  params — `EXIT_HEADROOM = 1.155e18`, `FEE_WEIGHT = 2`. At the launch market's 77% LLTV this is
  exactly `1.5 × (D + 2F)`: Morpho's liquidation line `D / LLTV` with a 15.5% headroom, the fee
  counted twice as the junior claim it is. The three regimes it fixes: a fresh loan (`F ≈ 0`) is
  gated at `1.5 D` where Morpho would allow `1.3 D`; a debt-free position at `3F`, the fee's own
  cover (deliberately not liquidation-proof — the accepted junior-claim risk); a live loan in
  between. Measured against the real market: a liquidation closing the whole debt at Morpho's
  edge takes `lltv × LIF` of the collateral, about 82.7% at this market's 77% and ~1.0741, so
  roughly 17% is left standing under the fee claim, while a price low enough to exhaust the
  collateral writes the shortfall off as bad debt and leaves the claim unsecured
  (`test/integration/MorphoLoanSubaccountRemoteFork.t.sol`). For `D = 1000`, `F = 70`: Morpho
  allows the collateral down to 1299, the gate keeps 1710; debt repaid, 210. On the borrow side
  the same numbers read as a borrowing limit: a fresh position may borrow up to
  `V × LLTV / 1.155` of its collateral value — two thirds at 77%, where Morpho alone allowed 77%
  — and with the position sitting at the cover nothing more can be borrowed, where without the
  borrow gate another 316.7 could have been. The rule implies Morpho's health check
  (`1.155 × (D + 2F) ≥ D`), so Morpho's own refusal never binds on the withdraw path; on the
  borrow path Morpho's check runs first, inside its `borrow`, and the gate is the binding one
  whenever Morpho passed. With nothing owed (`D = 0`, `F = 0`) the gate reads no oracle. A zero
  or dead oracle values the collateral at nothing, so the action is refused — the escape is
  settling through `repay`, after which a retried withdrawal passes with nothing owed,
  oracle-free (a borrow needs the oracle back: Morpho reads it too).
- **`withdraw` (the atomic bridge-home)**, in this exact order: the hard argument checks
  (zero amount, zero id) → the delivery-value floor → duplicate/expired skip → pause gate →
  checkpoint (with a live fee principal; zero principal has nothing to accrue) →
  the cover rule on the post-withdrawal remainder — covered passes, uncovered reverts
  `InsufficientRemainingCollateral(requiredCover, remainingValue)` (retriable; the two numbers
  let the front end size the repayment) → consume the operation id → withdraw and bridge.
  Settlement is deliberately not part of the withdraw: debt and fee are paid in loan tokens
  through `repay` (subaccount RLUSD means repay, the free direction), after which the same parked
  packet passes; no price ever moves funds at an exit.
- **`borrow`**: after the checkpoint, Morpho's `borrow` (its health check inside) and the
  principal re-sync, the cover rule on the position as it stands — the supplied credit included,
  nothing out. Uncovered reverts `InsufficientRemainingCollateral(requiredCover, remainingValue)`
  before anything is disbursed, and the whole delivery rolls back: the credit stays idle on the
  account and the packet stays retriable (a smaller signed borrow, more collateral, or a
  repayment reopens it).
- **The front end's numbers** come from the read surface below: the required cover, the remaining
  value, the largest amount that passes and the smallest repayment that reopens a refused exit
  are computed on-chain by the code the gate runs.
- **Final-exit forgiveness:** when a gate passes with `principal == 0` and a sub-unit
  fractional remainder still in `flareDebtX18`, the remainder is cleared with
  `LoanFeeRemainderForgiven` — it can never be transferred (ERC-20 moves whole base units)
  and never grows again, so a raw-zero gate would park the exit forever over less than one
  base unit.

Consequence to respect in review: an over-accrual bug is not self-limiting — it parks the
exit until settled — so the accrual logic carries money-path review weight.

### The read surface

Five views on the loan-chain subaccount quote what the actions will do, computed by the same
code the actions enforce: the fee and cover formulas live in one pure library (`LoanMath`), and
the projection of Morpho's debt reproduces Morpho's own accrual (the rate model's `borrowRateView`
compounded over the time since the market's last update, `MorphoMath.wTaylorCompounded`, then
`toAssetsUp` on the accrued totals). `getLoanFeeState()` stays as the stored-state getter. Every
quote is for the observed block; the contract recomputes at delivery, so a packet crossing chains
must be re-checked against a fresh read before it is sent.

- **`getLoanPosition()`** — the position projected to now: collateral in the position and idle
  beside it, idle loan tokens, the live debt, the fee's running period priced at the snapshotted
  terms (`feeDebtX18`; the collectible is its whole units), the oracle price (zero when dead —
  the gate's own treatment, so a zero limit below is explained), the collateral value, the LLTV,
  the cover the gate demands as things stand, Morpho's health factor (`morphoHealthFactor`,
  named for the line it measures — Flare's cover is the stricter one) and the liquidation price
  (`liquidationPrice`: the lowest oracle price at which Morpho still holds the position healthy,
  both of its floor steps included; zero debt-free, the maximum with debt and no collateral).
  Pinned by "the view in block N equals the stored state after a checkpoint in block N", in the
  unit and fuzz suites, and by Morpho passing at the liquidation price and refusing one unit
  below.
- **`getLoanLimits(additionalCollateral)`** — the largest further borrow the cover passes
  (`maxBorrowByCover`) once the idle collateral and the packet's are supplied (Morpho's share
  rounding included: bisection on the exact post-borrow debt), the pool's remaining liquidity
  as a separate figure (Morpho's own bound; the front end sees which one binds), and the largest
  withdrawal the cover passes — the whole collateral when nothing is owed, zero under a dead
  oracle otherwise. Both bounds are exact to the unit within what the cover and the collateral
  allow: a positive bound passes the cover check and one unit more fails it, except that a
  withdrawal bound equal to the whole collateral is capped by the collateral, where Morpho, not
  the cover, refuses the excess; a zero bound means no positive amount is allowed, not that zero
  itself was checked. They are arithmetic quotes, not execution guarantees — the pool's
  liquidity, the pause, the borrow switch and the transport are separate conditions.
- **`previewRepay(additionalLoanToken)`** — `repay`'s allocation of the idle loan tokens plus a
  top-up: the pro-rata fee share of a payment short of both claims, the debt closed by shares or
  repaid by assets with Morpho's rounding, the tail's fee, reservation and surplus, the state
  left behind, and the top-up that closes both claims now. Oracle-free and shares-first, like
  `repay`: a debt-free account's preview reads no rate model, so the fee-only settlement and the
  surplus recovery stay quotable where `repay` stays available. It is the
  **expected** allocation: a fee transfer the collector's token refuses is deferred to the debt
  or reserved at execution, so the fee then stays owed — pinned by a frozen-collector test.
- **`previewBorrow(amount, additionalCollateral)`** — the gate's verdict on a borrow
  (`coverSatisfied`, the required cover of the post-borrow position, the supplied collateral's
  value, the post-borrow debt with Morpho's share rounding, the pool's liquidity beside it) —
  the one number the front end could not cheaply recompute is that debt.
- **`previewWithdraw(amount)`** — the gate's verdict on a withdrawal (`coverSatisfied`, the
  required cover and the remaining value — the two numbers a refusal carries) and, when refused, the
  smallest top-up whose `repay` makes it pass: a binary search over the top-up with the exact
  split simulated, since every unit paid shrinks both claims and closing both always suffices.
  Under a dead oracle that minimum is the closing amount. Exact to the unit ("repay 9.44 to
  withdraw this"), fuzzed against the gate. The cover check only: it does not check that the
  amount exists in the position, which Morpho refuses at execution.

Two dependencies to know. The projecting views call the market's rate model and add its interest
into `uint128` totals as canonical accrual does; a reverting model, or an overflow, reverts them
(it blocks every debt-bearing action too — the dead-Morpho residual), except `previewRepay` on a
debt-free account, which like `repay` never reaches the model. And the views read the market's
IRM address from the registered params: a market registered without one earns no interest, and
the projection says so.

What the views deliberately leave to the client: the pause, the fee-terms activation, the
per-type borrow switch and the transport are read from the controller's existing getters; a
pending terms change is known from the timelock's events, not from a snapshot differing from the
current terms (a snapshot lags every change until the account's next checkpoint); a packet's
consumption from `usedOperations(id)`, its queued, expired or retriable state from the watcher.

**Settlement is loan-token only.** No exit converts the fee: an uncovered withdraw refuses
(`InsufficientRemainingCollateral`), the user pays in RLUSD — to the subaccount, where `repay`
splits it pro rata between the live debt and the fee and attempts the whole collectible on a
payment covering both (reserving what it cannot pay) — and the retried packet passes once the fee
has actually left the account: a collector the token refuses leaves the fee owed and reserved on
the account (`LoanFeeReserved`), still counted by the gate, until a later `repay` retries it. An FXRP
settlement mode — the fee deducted from the withdrawn collateral at the market oracle's price
under a signed cap — was built and removed (2026-09-02): it only ever served users who had closed
outside the rails or underfunded `repay`, and it was the one place a price moved funds. Removing
it takes the oracle out of every money path — it survives only in the gate's comparison — drops a
payload field, four errors and an event, and leaves the collector holding RLUSD only.

That is not the same as the price being harmless, and the scope matters. **Debt-free, with only a
fee outstanding**, the exposure is Flare's claim and nothing else: too low, and the gate refuses an
exit the position could have afforded, which is conservative and retriable; too high, and the
residue clears the three-times bar nominally, then normalizes to less than the fee — an
under-secured exit that has already happened. Nothing else catches that case, because with zero
borrow shares Morpho's health check consults no price at all, so the gate is the only thing
standing there.

**With live debt the price does reach the user**, through Morpho rather than through this contract:
too high and they borrow more than the collateral really supports, with the correction arriving as
a liquidation of that collateral; too low and a sound position becomes liquidatable. That is the
market's own exposure, shared by every borrower on it, and the gate — strictly tighter than
Morpho's check at this market's ratio — narrows it rather than adding to it.

**The fee-only case is accepted, not defended** — the same junior-claim risk the cover already
carries, arriving by another route. What bounds it is that the gate reads the market's own oracle,
so for a debt-bearing position the price risk is Morpho's too and not something this contract can
hold a different opinion about; the part that is ours alone is the debt-free fee claim.

The obstacle to defending it is data, not coherence. A refusal-only check is perfectly sensible in
principle — the gate never liquidates anything, it only permits or refuses, so it could keep
Morpho's valuation and simply decline to act on a price it distrusts. But
[`IOracle`](../../../contracts/smartAccounts/interface/IOracle.sol) exposes `price()` and nothing
else, with no timestamp and no round data, so observing staleness at all means reaching past
Morpho's oracle into the underlying feeds or standing up a second source. What is accepted is the
cost of acquiring that signal, plus the availability a refusal would trade away, weighed against a
junior claim. What follows is operational, not structural: the production oracle's freshness and
manipulation resistance are a launch prerequisite, not a property this contract verifies.

**Stricter than Morpho by design (Morpho allows, the gate refuses).** With live debt the band
`D / LLTV ≤ V < (D + 2F) × 1.155 / LLTV` of remainders passes Morpho's health check but fails
the gate — that is the headroom, not an edge case, and it is widest where the fee is large next
to the debt (after a debt-only Morpho repayment, a partial liquidation, a third party repaying on
the account's behalf; on the rails alone `repay` keeps the fee-to-debt ratio near the accrual
rate). The way through with the loan still open is a top-up to the subaccount, which `repay`
splits pro rata: every payment shrinks both claims, and
`P = (D + 2F − V × LLTV / 1.155) × (D + F) / (D + 2F)` is the payment that brings the remainder `V`
to the line in exact arithmetic — a starting point, not a quote: the split rounds the fee share
down, the debt is re-read from shares after the repayment and the cover rounds up, so the exact
minimum comes from checking the post-repayment state and stepping the payment up until
`ceil((D' + 2F') × 1.155 / LLTV) ≤ V` (for `D = 100`, `F = 7`, `V = 130` in base units the formula
says 26 and 27 is needed; `previewWithdraw` does this on-chain). The
alternative is to withdraw less. Pinned by `testOverlapTopUpOnTheSubaccountPaysTheFeeProRata`,
`testExitGateIsStricterThanMorphoHealth`, `testExitGateFollowsTheMarketLltv` and
`testExitGateValuesTheRemainderRoundedDown`, `testCoverGateIsStricterThanMorphoHealthOnBorrow` and
`testBorrowGateCountsTheFeeAndTheSuppliedCredit`. Front-end requirements, in the spirit of the wallet
invariant: quote the required cover and the remaining value for the requested amount (the
refusal carries both, `previewWithdraw` quotes them beforehand); offer the two ways out — the
top-up `previewWithdraw` returns, or a smaller withdrawal (`getLoanLimits`) — and quote
`previewRepay`'s closing amount plus headroom for in-flight interest to settle both claims through
`repay` (the surplus returns to the PA); say that RLUSD sent to the subaccount is split pro rata
between debt and fee, and that the refused packet stays unconsumed and retriable. The design
path, for the record: the first gate covered the fee alone, at three times the collectible on the
gross remainder, and left a live-debt withdrawal to Morpho's own check — which lets a position
run to its liquidation edge; the position-wide cover replaced it on 2026-09-05 (debt-free it is
the same `3F`). Earlier, a withdraw-time settlement pulled from the parent (a signed cap field in
the withdraw payload, the subaccount reaching into the PA) was built and rejected twice, in FXRP
and in RLUSD; a parent-signed fee-only payment from the remote PA's own RLUSD (`payLoanFee`)
followed and was removed on 2026-09-04 (see the resolved decisions).

**Dead-Morpho residual (accepted):** with a permanently reverting IRM, a position's collateral
is lost anyway, and so is idle FXRP on that account, whose only route home runs through the
position (`depositIdleFxrp`, then the signed withdraw); the shares-first rule still frees the
loan-token balance of every debt-free account, because that path reads the position but never
the IRM. A Morpho that no longer answers at all blocks even that read, and with it every
position-dependent rail and `repay`'s surplus push; with `feePrincipal == 0`, `checkpointFee`
still runs without touching Morpho. No standing governance write-off power; if the case ever
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
write-off is priced, not prevented. With every withdrawal and every borrow gated, liquidation
is the *only* value exit around the gate: a covered withdrawal also passes uncollected, but
deliberately, leaving the claim covered by the remaining position, and a covered borrow leaves
the same cover standing — only liquidation can strip the claim's security and make it
unrecoverable.

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
reviewed version of every one before any route opens: the remote `MorphoLoanSubaccountRemote`
(accrual, gates, collection), the Flare `LoanSubaccount` (the extended borrow/withdraw
payload encoders), and `MorphoLoanMarketsFacet` (the timelocked terms setter and the activation
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

- Borrow action data: `abi.encode(bytes32 operationId, uint64 deadline, uint8 destinationKind,
  bytes32 destination, uint256 borrowAmount, uint256 minComposeValue)`. The floor is **reserved**:
  every kind V1 supports disburses without spending compose value on the loan chain, so
  `DESTINATION_KIND_EVM` requires it to be zero and both sides refuse a non-zero one (the Flare
  sender with `InvalidLoanInstruction` before the bridge fee, the loan chain with
  `UnexpectedDeliveryValueFloor`). It exists so a kind that pays for its own onward delivery —
  the reserved Wormhole-to-XRPL one — can be enabled by upgrading the implementations and setting
  governance parameters, rather than by changing the wire schema. That is a reduction in what a
  later change has to move, not a guarantee that no other signed field will be needed. Its
  meaning, once such a kind exists, is the withdraw's, and it is enforced the same way: checked
  before every branch that finalizes the packet, so an underfunded delivery reverts retriably
  instead of consuming the instruction.
- Withdraw action data, unchanged from before the fee: `abi.encode(bytes32 operationId,
  uint64 deadline, uint256 amount, uint256 minComposeValue, bytes returnOptions)`.
- Deposit-collateral action data: empty (`bytes("")`; the operation id and deadline it once
  carried were dropped pre-cut, 2026-09-04).
- Cancel action data: `abi.encode(bytes32 operationId)`, under `ACTION_CANCEL = 5` (4, the
  retired sweep-to-origin action, is never reused).
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
accrual stops; fee debt ≈ 401 waits at the cover gate, payable in RLUSD through `repay`.

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
exists for the loan (`LoanSubaccount`, `MorphoLoanSubaccountRemote`, `MorphoLoanMarketsFacet`); *Remote*
is location seen from Flare, the non-Flare implementation at the same address
(`PersonalAccountRemote`, `MorphoLoanSubaccountRemote`); *Compose* is the ingress authentication
mechanism (`ComposeReceiverAccountBase` — and only that ingress, since the subaccounts also
have parent-driven and public rails); *Bridging* is the Flare-side surface every type that
bridges FXRP to its remote twin shares (`BridgingSubaccountBase`); *CrossChain* is the Flare-side send
(`sendCrossChainUserOp`, which sends a user operation to another chain and executes nothing
itself). "Cross-chain" is general in fact as well as in name: the sender names its
`destinationEid`, allowlisted by the per-chain route registry (`BridgeRoutesFacet`), and every
remote chain bootstraps the same diamond and remote Personal Account — see Multiple remote
chains.

**The shared base.** The authentication checklist (endpoint-only caller, configured FXRP OFT
as sender, origin chain, `composeFrom` equal to the account's own address, GUID recomputed
from the pinned origin peer) is identical for the remote PA, the loan-chain subaccount and the
Flare subaccount (as the receiver of its own bridge-back, its transport derived from its type's
bridge route — with one accepted trust extension: that receiver reads its authenticating endpoint
live from the governance-set OFT rather than pinning it; the canonical `OFTAdapter`'s endpoint
is immutable, a compromised OFT could already move the locked FXRP, and the only action
forgeable here redeems the account's own FXRP to its owner's XRPL address), as is the
operation-id replay protection with the skip semantics that the signed
actions use (the id-less Flare redeem-home carries no id and relies on the endpoint's
at-most-once compose delivery), and they live once in
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
`PersonalAccountRemote` the signed batch execution, `LoanSubaccount` the four typed loan
instruction encoders, `MorphoLoanSubaccountRemote` the Morpho actions and the fee engine. A Flare-local
subaccount type (a vault subaccount) would extend `SubaccountBase` alone; a new bridging type,
`BridgingSubaccountBase`. The storage rule the bases follow is in the pre-first-cut invariants.

**The action set is one action: execute.** The remote PA does what the Flare account does —
run the batch of calls the user signed — with the authenticated compose in the role the
controller plays on Flare. The blast-radius claim follows: a compromised compose root has the
**full on-chain authority of the remote PA's address** — balances, approvals, external positions
and any role granted to it — the same class as a controller compromise on Flare, but over
the loan subaccount it holds no direct authority at all: the subaccount has no parent-callable
method, so Morpho collateral and debt stay behind the subaccount's own compose authentication. Callbacks into the remote PA's compose entry (`lzCompose`) meet the active
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
  step — naming `SubaccountsFacet`, `BridgeRoutesFacet`, the replaced `PersonalAccountsFacet`
  (it gains `createPersonalAccount`) and the replaced `PauseFacet` (`removeUnpausers` becomes
  immediate; a removal queued before the cut must be cancelled and redone directly — see
  [Pause](./Pause.md#upgrading-to-the-immediate-unpauser-removal)) in a cut plan
  (`deployment/cuts/<network>/cuts-<date>.json`, verified with `pnpm check_cut`, executed with
  `pnpm diamond_cut`) deploys it from the artifact as part of the cut flow. **Two implementations
  must also be deployed and registered, and neither is part of the cut.** The loan subaccount:
  `pnpm deploy_loan_subaccount_implementation <network>` (Flare-family networks only — the script
  refuses Ethereum), registered by governance with the timelocked
  `setSubaccountImplementation(SUBACCOUNT_TYPE_MORPHO_LOAN, <address>)`. And **the home `PersonalAccount`
  itself**: `pnpm deploy_personal_account_implementation <network>`, registered with the timelocked
  `setPersonalAccountImplementation(<address>)`. Replacing `PersonalAccountsFacet` does not change
  the code behind existing Personal Account proxies — the beacon keeps serving whatever
  `PersonalAccounts` records, and only that call moves it — so an existing network that skips the
  second registration has accounts with neither `sendCrossChainUserOp` nor `redeemFromSubaccount`:
  parent-signed remote operations cannot start at all, and a returned redeem-home compose or a
  public `sweepRedeem` at or above the FAssets minimum reverts on the missing selector, recoverable
  only through another timelocked upgrade. The ordered sequence, and the verification each step
  needs before the next, is [`deployment/RUNBOOK.md`](../../../deployment/RUNBOOK.md).

### Ethereum bootstrap

Rebuilding today's sources does **not** reproduce the production diamond address — source
drift changes the base facets' bytecode, their CREATE2 addresses, the diamond's constructor
arguments, and with them its address. The historical init code of
the diamond and its three base facets is therefore pinned as raw bytes under
`deployment/pinned-init-code/` (recovered from the Flare creation transactions and verified:
its CREATE2 derivation reproduces the live addresses exactly; `test/unit/smartAccounts/PinnedInitCode.t.sol`
asserts the hashes, the derivation, and a golden xrplOwner → Personal Account → subaccount
address vector in CI). `pnpm deploy_ethereum_controller <network>` reproduces all four contracts
at the production addresses on a loan chain — Ethereum, or Sepolia, where the same singleton
factory makes the same derivation land the same addresses, which is what allows the bootstrap to
be rehearsed there. It is permissionless, since CREATE2 through the EIP-2470 factory is
sender-independent. **The follow-up facet cut is not permissionless**: the fresh
diamond is owned by the historical `DiamondArgs.owner` EOA
(`0x7801A7e1FD6a99d1a74DC0a59622b3b7dc4049bA`) — confirm that key is still controlled
before relying on an Ethereum deployment. The Ethereum cut installs `SubaccountsFacet`,
`TimelockFacet`, `PauseFacet`, `PersonalAccountsFacet` (the PA beacon and creation surface for the
remote Personal Accounts), `ComposeTransportFacet` and `MorphoLoanMarketsFacet` through the standard cut flow, with
[`EthereumControllerInit`](../../../contracts/smartAccounts/facets/EthereumControllerInit.sol) as the
cut's init: `MasterAccountControllerInit` is Flare-specific and is skipped, so this sets the four
ERC-165 interface flags and nothing else (the executor, payment-proof and instruction-fee settings
belong to facets the Ethereum cut does not carry, and the Personal Account beacon and each type's
implementation are timelocked governance calls made after the cut, never init writes; the cut plan
names it as its `init` block with no arguments — see `deployment/cuts/ethereum/cut-example.json`)
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
covers every later in-place V1 change, most recently the deposit action's `actionData` emptying
(its operation id and deadline dropped), before that the withdraw action's `actionData`
gaining `minComposeValue` and `returnOptions` (the fee's signed bounds — borrow rate maxima and
a withdraw FXRP cap — were added and removed again inside the same pre-cut window), and the
removal of the sweep-deposit action (id 4 retired, never reused; ids 1–3 unchanged). An environment that had
shipped the old scheme would need a new payload version instead. The settings storage namespaces
are fresh — `smartAccounts.ComposeTransport.State` and `smartAccounts.MorphoLoanMarkets.State` on the
loan chain, and on Flare `smartAccounts.BridgeRoutes.State`, which replaced the earlier
`smartAccounts.LoanBridgeSettings.State` outright (never cut, verified 2026-09-03 against the
complete `DiamondCut` history of the controller — 3 cuts on flare, 3 on songbird, 8 on coston2,
read through the explorer log API — none of which ever added the retired facet's
`getLoanBridgeSettings()` or `setLoanBridgeSettings(address,uint32,bytes32)` selectors; no cut
plan under `deployment/cuts/` ever named it either, so nothing was ever configured under the
old namespace and no migration or legacy slot is needed) —
and splitting the earlier single settings namespace is itself a pre-first-cut-only move under
the same condition: after a first cut it would need a migration or a permanent legacy slot. The
storage-lineage gate below is the third member of this family.

### Release checklist

**Before the first Ethereum cut.** Three kinds of item: tooling that is built and is run at the
moment named, work still to be built or rehearsed, and premises that hold in source or on a fork
but must be confirmed against the live contracts, together with the order of activation.

**Built - run at the named moment:**

- pre-cut verification, `pnpm verify_diamond ethereum --pre-cut`: the fresh diamond is pristine -
  the pinned initial owner, exactly the three pinned base facets with their canonical selectors,
  no ERC-165 flag set yet, code hashing to the pins (the cut checker already recognizes the
  pinned base facets as intentional reuse instead of proposing to replace them with
  current-source builds);
- post-cut verification, `pnpm verify_diamond ethereum <cut-file>`: the loupe exposes exactly the
  recorded facets' selectors both ways, every facet's code is its artifact's (modulo metadata),
  the owner is the expected one, the four ERC-165 flags answer true, and the pinned controller
  and base facets match by address and code hash, all read at one block, with the responders of
  `facets()`, `supportsInterface` and `owner()` authenticated from the diamond's own dispatch
  storage and the cut file's deleted selectors checked to have no dispatch entry left - under a
  cut file's `deleteAllOldMethods` the expected facets are the cut's own instead of the record's
  and `deleteSelectorSigs` is ignored, its dispatch-entry check included, exactly as the executor
  ignores it. (The bootstrap itself already verifies init-code hashes, CREATE2 addresses and
  runtime code against the pinned Flare fixtures, in CI and at deploy time; the cut wrapper runs
  the post-cut check itself when it executes the cut.)
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
  the linear base fields. `test/unit/smartAccounts/AccountStorageLayout.t.sol` pins the rule. Adopting it moved
  the not-yet-deployed lineages' fields (the remote subaccount's fee state from slot 4 to
  slot 1, the remote PA's `xrplOwner` to slot 1, `usedOperations` into its namespace) — safe
  only because no subaccount or remote Personal Account proxy exists yet; before the first
  deployment of any of those implementations on ANY network, verify on chain that no proxy of
  the lineage exists there. The Flare Personal Account's layout is unchanged by construction;
  Both halves are tooled: the OpenZeppelin upgrade-safety validator (`pnpm build:upgrade-info &&
  pnpm validate-upgrade`, a CI job) checks the six proxy-backed implementations — the three live ones
  (the Flare Personal Account and the two composer contracts) against a reconstructed v2.0.0
  reference build (`deployment/build-info-v2.0.0/`, reconstructed runtimes matching the deployed code modulo
  generated fields; an incompatible layout change fails by field, a safe append passes), the three
  lineages with no proxy yet without a
  reference until their first deployment freezes one — the namespaces being pinned by the test above;
  and
  `pnpm check_lineage_fresh <network> [subaccounts|personal-accounts]` answers the on-chain half
  where the chain is decisive — a Personal Account proxy needs a non-zero beacon that can never
  return to zero, and a subaccount proxy needs a registered implementation, which only the
  `SubaccountImplementationSet` history can rule out (an RPC serving full-range logs) — and
  otherwise answers from the retained git history of the network's deployment record and cut
  files (a facet any current, historical or example record names may have been installed), on the
  stated assumption that every installation was committed under its canonical facet name before
  execution and remains reachable from the clone's refs, failing closed on
  anything unproven. Verified 2026-09-05: the **subaccount lineage is fresh on flare, songbird,
  coston2 and coston2-staging** (`SubaccountsFacet` is cut on none of them and no version of their
  records ever named it) and Ethereum has no deployment record (the check refuses to infer
  freshness from that; the bootstrap has not run), so the re-laid subaccount layouts are safe; the
  **Personal Account lineage is not fresh** on any of the four (beacons set), and its layout is
  unchanged, as the rule requires and the validator's v2.0.0 reference enforces;
- **operator chain checks**: the implementation deploy scripts refuse the wrong chain family
  (a remote implementation registered on Flare would corrupt every Personal Account's storage),
  and every deploy and cut flow — the `check_cut` preview included — verifies that the RPC's
  chain id matches the named network before acting, so a mis-set `<NETWORK>_RPC_URL` fails
  instead of retargeting the flow;

**Still to be built or rehearsed:**

- **implementation registration as a verified gate**: `setSubaccountImplementation(1, …)`
  and `setPersonalAccountImplementation(…)` must register exactly the reviewed
  `MorphoLoanSubaccountRemote` and `PersonalAccountRemote` artifacts (runtime hashes verified
  before the timelocked calls, `implementationForType(1)` and the PA beacon's
  `implementation()` asserted after them), and this must complete before any account is
  advertised, funded, or the cross-chain route is enabled. The setters check only that
  code exists; a wrong but `initialize`-compatible registration would let permissionless
  creation materialize frozen proxies with the wrong storage layout, and initialization
  cannot be replayed;
- a signed ownership-control rehearsal from the historical owner EOA before anything
  depends on the deployment;
- per-action `lzCompose` gas profiling against the real Morpho, oracle and token contracts
  — the test fixture's option values are illustrative headroom for the mock path, not
  production configuration;
- **the fee-activation runbook rehearsed** once on a testnet diamond with a non-zero timelock;
- **the real Endpoint/OFT compose-delivery integration harness** for every action, in both
  directions. The market half of the integration evidence is in the repository already
  (`test/integration/MorphoLoanSubaccountRemoteFork.t.sol`, above); what this adds is the wire
  hop, which that suite deliberately leaves mocked (the local sender→codec→receiver tests run each
  sender's bytes — borrow, deposit, the atomic withdraw with its real return
  send, remote-PA execute, and the loan-chain redeem-home — through the canonical codec into the
  real receivers, everything but the wire hop; non-zero compose value is covered by the
  receiver tests on both chains (the Flare redeem-home and the loan-chain withdraw), and the
  wire-level `lzReceive → sendCompose → lzCompose` path with delivered compose value, zero and
  non-zero, is exactly what the harness must add).

**To confirm on the live contracts, and the order of activation:**

- **the canonical-Morpho premises of the cover gate**: the gate implies Morpho's health check
  (`1.155 × (D + 2F) ≥ D`, cover rounded up, collateral value rounded down), so on the real
  market Morpho's own refusal must never bind first on a withdrawal, while on a borrow both
  errors are reachable: Morpho's check runs first inside its own `borrow`, so an amount past
  Morpho's line fails with Morpho's error, and the band between our cover and that line passes
  Morpho and is refused by the gate alone (134 RLUSD on collateral worth 200 at LLTV 77%: Morpho
  allows 154, our cover is 201); with live debt a dead oracle is refused by the
  gate itself on a withdrawal (on a borrow Morpho refuses first, and a borrow has no oracle-free
  route back); with `D = 0` and collectible `F = 0` the withdrawal passes the gate oracle-free
  (debt-free with an unpaid fee still reads the oracle), which then
  needs canonical `withdrawCollateral` to skip the oracle too with zero borrow shares
  (`_isHealthy` returns early). `MockMorpho` runs the canonical health check (`_isHealthy` over
  the oracle at the market's LLTV, skipped with zero borrow shares) unless a test switches it
  off: the fuzz, invariant and adversarial suites run with it on; the unit fixture switches it
  off because its fee tests never lean on it (their positions - 1000 RLUSD on 100 FXRP at
  1 FXRP = 20 RLUSD - sit at 50% LTV, inside both lines) and switches it back on in the tests
  that pin the order of refusals: the gate before Morpho on a withdrawal, both errors reachable
  on a borrow, the dead-oracle order on each action, the oracle-free debt-free exit, the LLTV the
  gate follows and the liquidation price. The views' agreement with the actions
  (`getLoanPosition` against a checkpoint in the same block, each preview against its own cover
  check, the exact minimum top-up) is pinned by the fuzz properties, which run with the check on.
  So the interplay is pinned at the unit level, and
  `test/integration/MorphoLoanSubaccountRemoteFork.t.sol` carries it onto the market itself: the
  account, the gate and the five views driven over canonical Morpho Blue and the live FXRP/RLUSD
  market at a pinned block. What that suite pins there: the debt projection equals what canonical
  `accrueInterest` writes at the same timestamp, under the market's own adaptive rate model and
  again after an external borrow moves utilization; the borrow bound, the withdrawal bound and the
  minimum top-up are each exact to the unit at the live price, with a partial repayment leaving the
  position still borrowing; each preview's numbers are the numbers the gate refuses with; the
  market's free liquidity binds where cover does not, and Morpho refuses past its own line and past
  its liquidity with its own errors; the quoted liquidation price is the edge the health factor
  crosses; and with the feed taken away the withdrawal is refused by the gate, a borrow is refused
  by Morpho, while repayment stays oracle-free and the debt-free exit still passes. What it does
  not carry is the wire hop, which is the harness below, and the real feed's own expiry, whose
  timing belongs to the feed;
- **fee terms configured before any route opens**: `registerLoanMarket`, then the one
  `setLoanFeeTerms` call (the activation — borrowing reverts until it executes); verify all
  three fields before enabling the forward route;
- **the Ethereum FXRP OFT's decimals**: `token().decimals()` must equal its `sharedDecimals()`
  (6) on the loan chain — the no-dust argument (`minAmountLD == amountLD`) rests on it on both
  chains; `setComposeTransport` fails closed otherwise, so confirm the representation before
  the transport is queued (read on Ethereum mainnet 2026-09-03: the FXRP token is the OFT
  itself and `decimals() == sharedDecimals() == 6`; the Flare adapter's is still to be read);
- **FAssets' zero-fee executor**: the zero-value redeem-home passes the controller's executor to
  `redeemAmount` with zero value; verify against the deployed asset manager that a named
  executor with a zero fee is accepted (the vendored interfaces do not say; the source rule,
  read 2026-09-03 in the FAssets repository 40 commits past `v1.3.0`, accepts it - the deployed
  asset manager's version is still to be confirmed) — if it is not,
  every zero-value bridge-back would terminal-skip after its TTL and fall back to the
  fee-paying public rail;
- **Each route is enabled last, and only once its remote side exists.** `setBridgeRoute`
  reads the adapter's live peer for the destination endpoint, so it cannot be set before the
  adapter's peer is wired; until the type is pointed at a live route its forward moves revert
  with `BridgeRouteNotConfigured` (a cross-chain user operation naming the chain with
  `UnknownBridgeRoute`) while creation already works. The remote account
  (same diamond address, same derivation) must be deployed before the forward moves are
  enabled, since bridged FXRP lands on the subaccount's own address there.

## Design decisions, resolved

The asset-moving decisions below were taken with the methods they concern; each is
incorporated in the sections above, and the note here records what was decided and what was
deliberately not built.

- ~~Stuck RLUSD on the loan-chain side~~ — resolved: while the account's position has debt, the balance is repayment material (`repay` is its only move); once the position is closed — by `repay` itself or by a full external liquidation — the same `repay` call pushes the surplus to the parent Personal Account (the user's own loan-chain account), best-effort: a push the token refuses stays on the account for a later `repay` to retry, never rolling back the repayment. No generic `recoverToken`: stray tokens strand, as on the Flare side. Same-id replay is prevented by the operation ids (two separately authorized ids can each borrow).
- ~~Atomic withdraw-and-bridge action~~ — resolved, built as `ACTION_WITHDRAW` itself: the withdraw compose withdraws the collateral and bridges it home in the same execution (the withdraw/redeposit race is closed for withdrawals; it survives only for residue). Compose value is accepted for this one action and spent in the same call — the return leg's fee, prepaid from Flare as message-1 compose value, quoted against the signed `returnOptions`, excess to the parent; every delivery must carry the signed `minComposeValue` floor (delivery is permissionless, the value unauthenticated — below the floor nothing consumes the packet), and a short delivery reverts and stays retriable. Two accepted residuals: bad signed `returnOptions` park that withdrawal until a fresh instruction reusing the same operation id (the parked packet then terminal-skips as a duplicate), and the redeem-home packet residual above applies to the return leg as to any bridge-back — including its best-effort redemption fee.
- ~~The Flare fee~~ — resolved, designed and built: checkpoint accounting of `max(feeFloor, market interest + feeSpread)` over the account's Morpho debt, per-type timelocked terms behind a recipient activation marker, collection in `repay` (pro rata with the debt on a partial payment; a payment covering debt plus fee attempts the whole collectible and reserves what it cannot pay), with the withdraw and the borrow gated on the whole position (an action that would leave the collateral worth less than `(D + 2F) × 1.155 / LLTV` is refused until repaid, or a smaller amount is signed). The gate's first form covered the fee alone at three times the collectible and left live-debt withdrawals to Morpho's own edge; the position-wide cover replaced it on 2026-09-05 and was extended to the borrow on 2026-09-06 (see The cover gate). See The Flare fee.
- ~~Debt-first vs pro-rata `repay`~~ — resolved (2026-09-04): pro rata. A partial `repay` pays the fee `P × F / (D + F)` alongside the debt, so the fee is realized incrementally on the default route instead of only at close. Strict — a payment covering the debt but not the fee leaves a sliver of both, bar the rounding edge where the share's round-down leaves Morpho exactly `D` (within roughly `F / D` base units of `D + F`) and the deferred case, where the full payment stays available and may cover `D` (closing the debt alone would hand a debt-first route to anyone sending exactly `D`) — and without a stored reserve: a share the collector cannot receive stays in the payment, repaying debt (`LoanFeeDeferred`), which costs Flare only timing, only during a freeze of its own recipient. direct Morpho repayment stays the debt-only route (`payLoanFee`, then the fee-only payment, was removed later that day). See Collection.
- ~~`sweepToOrigin`~~ — removed (2026-09-04). On a canonical market `supplyCollateral` has no conditions of its own beyond an existing market, a non-zero amount and the collateral token's `transferFrom` (Morpho is immutable with no pause; the Ethereum FXRP token is an upgradeable proxy whose current implementation has no pause or blocklist — a dependency assumption, not an invariant), so idle FXRP on the loan-chain account has its route home through the position: `depositIdleFxrp`, then the signed withdraw, under the position's ordinary conditions (health, the fee gate, the pause, the oracle, the transport; collateral a position needs can be liquidated). The parent-signed direct bridge-back only added a second signed authority over the subaccount, the residue race with the deposit rail, and a Morpho-free special case to document. Residual accepted: idle FXRP on an account whose type has no market yet, or whose Morpho is dead, waits — for the registration, or for the beacon upgrade a dead Morpho needs anyway. The remote subaccount then kept one parent-only method, `payLoanFee`, removed the same day.
- ~~Pause-gating the fee legs~~ — resolved (2026-09-04): not gated. `repay`'s fee legs (and, until its removal the same day, `payLoanFee`) move the user's RLUSD to Flare's own governance-set recipient, at an amount the contract computes or the signature caps, so an overcharge during an incident lands on Flare's address and is refundable — the pause bought little there, while holding the fee made the paused route debt-first and needed its own deferred/reserved cases. Accepted on two stated assumptions: the recipient is governance-set and replaceable (a compromised or wrong recipient would collect the fee shares of the repayments made during one rotation window), and the fee accounting is simple and audited. The pause keeps gating debt increases, withdrawals and debt-free deposits.
- ~~`payLoanFee`~~ — removed (2026-09-04). It was kept for two reasons, both gone: as the escape for an RLUSD-frozen subaccount (false - Ethereum RLUSD checks the spender in `transferFrom`/`approve`, and the subaccount is the spender), and as the fee-only payment that keeps the loan whole, which the team does not want to offer (the fee is presented with the debt as one obligation). Pro-rata `repay` pays the fee on the default route and in full once the debt is closed, and the overlap band is crossed by a pro-rata top-up. With it go the remote subaccount's last parent-only method, the approve/call/approve(0) batch, `NothingCollectible`, and the `_forgiveFeeDust` sub-unit guard that only a partial fee-only payment could reach.
- ~~The deposit's operation id and deadline~~ — dropped (2026-09-04). Both were functionally inert on a deposit: it only adds the user's own collateral, which the permissionless `depositIdleFxrp` can do with the same tokens anyway, so a re-issued deposit is harmless (a new packet; a delivered compose cannot replay), an expired one would only have left the credit for the rail, and the id's retire-a-parked-packet use belongs to borrow and withdraw. They were kept for the uniform envelope and FE correlation (the GUID serves); `depositCollateral(amount, extraOptions)` now sends an empty action payload, `CollateralDeposited` and `CollateralDepositInstructionSent` lost their id. The borrow and the withdraw keep both fields (see the operation-id decision below).
- ~~The operation id on borrow and withdraw, and a cancel action~~ — resolved (2026-09-04): keep the id; a cancel was first deferred, then planned the same day as its own follow-up (`cancel(operationId)` on top of the ids, for early finality — the motivating case is a borrow parked by a failed health check after a price drop, which a rescue deposit large enough to restore health would make executable again). The id is the idempotency key for the two actions with effects to prevent (a re-issued intent under the same id is deduplicated on the remote; Flare cannot tell two valid XRPL transactions apart), with first-success-wins semantics on reuse. Deadlines alone were rejected (an original and a re-issued packet can both execute before expiry), and a GUID-keyed cancel was rejected (it races the packet it targets and drops the double-submit protection). The deposit keeps neither field (see above).
- ~~Split `LoanChainSettingsFacet`~~ — resolved: `ComposeTransportFacet` (the general compose transport, timelocked set, immediate owner-only clear with a cancel-then-rotate runbook) and `MorphoLoanMarketsFacet` (write-once markets, borrow switch); creation moved to the generic `createPersonalAccount` on `PersonalAccountsFacet`.
- ~~`LoanBridgeSettingsFacet`, one global destination~~ — resolved: the Flare end became the type-generic `BridgeRoutesFacet` — one FXRP adapter (`setFxrpOft`, re-validating every route on rotation), one pinned peer per remote chain (`setBridgeRoute`), and the chain each bridging subaccount type lives on (`setSubaccountTypeRoute`, write-once — the type IS that identity, and its instructions carry no destination; `setSubaccountTypeRouteSuspended` is the reversible per-type stop); the Personal Account's `sendCrossChainUserOp` names its `destinationEid`, allowlisted by the registry. A new remote chain is a deployment plus governance. Multiple accepted origins on a remote transport (relay hops) were deliberately left for a later, additive change — see Multiple remote chains.
- ~~Grace-period public fallback for the default relays~~ — resolved by removing the relays: the parent Personal Account is the redeemer and defaults directly on the asset manager through `executeUserOp` (still `notPaused`; the appointed executor's direct path is the pause-time trigger, as before). The planned one-click-withdrawal subaccount type dissolves the same way, into a Personal Account multicall — do not build it.
- ~~Native payability~~ — resolved the other way: no `receive()` and no native exit on the Flare subaccount (no protocol flow leaves native on it — the bridge refunds its caller, redemption outcomes land on the parent, and the compose value of its own bridge-back is forwarded within the same call); native landing without a call (pre-deployment funding of the predicted address, a force-send) strands — accepted; a beacon upgrade can add an exit if it ever matters.
