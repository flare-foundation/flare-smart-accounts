# Loan Subaccounts

A loan subaccount is a deterministic, restricted staging account owned by a [Personal Account](./PersonalAccounts.md), used to stage loan-related assets (FXRP on the way to or from a cross-chain lending flow). It is not a generic smart wallet: it will expose only a fixed set of loan operations, and anyone may trigger only predefined cleanup actions on it.

Status: in progress. The account, its proxy, the per-type implementation registry, controller-side creation/prediction, the account abstraction dispatch, both cleanup moves (`sweepRedeem`, `sweepToLoan`), and the recovery method (`sweepToParent`) are in place; the account is also the compose receiver of its own loan-chain twin's bridge-back, redeeming on arrival. The Flare-side loan instructions (`borrow`, `depositCollateral`, `withdraw`) are in place. The loan-chain-side account (Ethereum, at launch) is functionally complete: the authenticated compose entry point (`lzCompose` with the borrow, deposit, sweep-deposit and withdraw actions), the per-type market binding and governance configuration (`LoanChainSettingsFacet`), the creation route, and the permissionless rails (`repay`, `depositIdleFxrp`, `sweepToOrigin`, recovery). Redemption is the parent Personal Account's (`redeemFromSubaccount`; the subaccount pushes), so the subaccount carries no redemption-default relays. A sweep-direction lifecycle was evaluated and rejected (see Cleanup moves).

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
- `createSubaccount(xrplOwner, type)` — permissionless, `notPaused`; the parent Personal Account resolves to the registered account when one exists, and to its computed address otherwise — the same fallback `getSubaccount` uses, so creation works before the Personal Account exists (and on chains where PAs never exist at all). Permissionless creation supports the executor-cleanup path: if assets already landed on the predicted address, anyone can materialize the subaccount to sweep them — without waiting for the parent. A subaccount created before its PA is only **partly** inert: `onlyParent` methods have no possible caller and `sweepRedeem` at or above the minimum reverts calling the codeless parent, while `sweepToLoan` (which never reads the parent) works normally, and `sweepToParent` — and `sweepRedeem` below the minimum, which never calls parent code — park assets at the future PA address — the same owner's deterministic address, whose later CREATE2 deployment a pre-existing balance does not block. The PA then deploys at exactly the recorded parent, owning whatever was parked. One qualification: this holds for a valid owner string — the route accepts any string, but a Personal Account cannot be created for an empty one, so an empty-owner subaccount is permanent caller-funded junk with no custody or collision impact. It is also what a user operation calls before invoking a method on the subaccount. Idempotent — repeated calls return the same address.

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

Calling a subaccount that is not deployed yet would **silently succeed** — a call to an address with no code returns success, so `executeUserOp` would not revert. The instruction does nothing, except that any native value it carried is transferred to the codeless address and strands there — the subaccount has no native exit (accepted; see the open items). User operations must therefore create the subaccount first. `createSubaccount` is permissionless and idempotent, so it can be the first call of every such operation:

```text
executeUserOp([
  { target: controller,  data: createSubaccount(xrplOwner, Loan) },
  { target: subaccount,  data: <restricted method> }
])
```

## Cleanup moves

Assets can strand at the subaccount whenever a cross-chain flow breaks part-way. Both directions out are permissionless, so an executor — or anyone — can clear them:

- **`sweepRedeem()`** — the backward move. Pushes idle FXRP to the parent Personal Account and has the parent redeem it to its XRPL owner in the same call, through `PersonalAccount.redeemFromSubaccount(amount)`: callable only by the account's own subaccounts (the controller's prediction for the owner and the caller's type must be the caller), it **pulls exactly the pushed amount and redeems exactly that**, so the parent's own balance is never part of a subaccount-initiated redemption. It takes **no parameters**: the destination is the parent (fixed at deployment, part of the address), the executor comes from the controller, and `msg.value` travels whole as its fee (FAssets records it in whole gwei). `msg.value` must cover the controller's **configured executor fee** — the fee is the price of the permissionless rail, so forcing the backward direction is never gas-only (see the accepted risk below). The fee policy lives at this entry: `redeemFromSubaccount` itself forwards whatever it receives, so an authenticated route can later send less or nothing (the executor stays appointed, unpaid). Reverts with `NothingToRedeem` rather than no-op, so a caller's value is returned instead of being trapped on the account.

  The parent is the **recorded redeemer**. That is the point of the relocation: every redemption outcome — a partial fill, a payment-default payout, a refund — lands on the parent, where `executeUserOp` already handles anything, including triggering the payment default directly on the asset manager. The subaccount keeps no redemption-request or default state and no relay methods; `sweepRedeem` is its one redemption method. The parent calls `redeemAmount` (the UBA-based entry point on `IRedeemExtended`, which the asset manager implements) with the **whole pushed balance**, rather than `redeem`, which only accepts whole lots — a cleanup method that redeemed whole lots would strand the remainder. FAssets may still redeem less than requested when redemption tickets run out; the remainder stays on the parent, under the user's control. A balance below the FAssets minimum redemption amount is pushed to the parent **unredeemed** instead (FAssets would reject it): `redeemedAmount` is zero, the value goes to the parent's float as well (`NativeSweptToParent`), and `TokenSweptToParent` is emitted — the rail never fails on amount, costs the configured fee either way, and "whatever FAssets does not redeem stays on the parent" covers dust and partial fills alike. The parent's redemption runs in its **own reentrancy-guard domain**: the legitimate user-driven path (`executeUserOp` → `sweepRedeem` → `redeemFromSubaccount`) re-enters the parent while its shared guard is held, and the method touches none of the state that guard protects. The nesting is bounded: the method pulls before it redeems and writes no account state, so a redemption reached from beneath any guarded method (no dependency does that today) cannot touch the parent's pre-existing FXRP, and a nested redemption is refused by the guard. The same logic runs when FXRP comes home from the loan chain: the twin's `sweepToOrigin` attaches the `ACTION_REDEEM_HOME` compose (its only field a deadline, the sender's block time plus `REDEEM_HOME_TTL`), this account authenticates it exactly as the loan-chain accounts authenticate theirs (the shared base, with the transport read from the bridge settings — the adapter, its endpoint, the loan chain's EID, the pinned peer) and redeems **at most the packet's authenticated amount** on arrival (`min(balance, amountLD)`; the rest of the balance stays for the public rails — FXRP is fungible, so the cap bounds how much one compose can move, not which units), with the compose value as the executor fee. Zero is allowed there: the packet already cost its sender the LayerZero fee. Past its deadline the packet skips terminally (nothing redeemed, the balance left untouched for the public rails, value to the parent's float), so a packet cannot outlive its delivery window as a standing instruction over later funds. In both the dust branch and the skip, value goes to the parent — never to `msg.sender`, which on that path is the endpoint.
- **`sweepToLoan(extraOptions)`** — the forward move. Bridges idle FXRP onward to the loan chain over LayerZero, to be deposited as collateral on arrival. Its only parameter is the LayerZero execution options (the destination gas); the caller chooses nothing else, for the same reason: the destination is **this account's own address**, which is identical on every chain because it is CREATE2-derived from inputs that do not vary by chain, and the destination chain and OFT come from governance-set controller settings (`setLoanBridgeSettings`, timelocked). So a permissionless caller has nothing to point at. `msg.value` must cover the LayerZero messaging fee; the exact quoted fee is forwarded and any excess is returned to the caller rather than left on an account with no native exit.

  The FXRP OFT is a lock/unlock adapter (`approvalRequired() == true`), so the sweep approves it for the exact amount and resets the allowance to zero afterwards. It reverts while the controller is paused: the forward sweep is the incident-containment surface (an OFT or route compromise is stopped by pausers immediately, without waiting out the timelock), while `sweepRedeem` stays available during a pause so assets can always exit toward the user. `setLoanBridgeSettings` validates that the OFT wraps the FXRP token, shares its decimals, and that its live peer for the destination endpoint equals the **pinned expected peer** exactly — existence alone would accept a wrong route — so misconfiguration fails at the timelocked call, not in the field; explicit zeros clear the settings, which disables the forward sweep until reconfigured. Every `sweepToLoan` re-checks the OFT's live peer against the pinned one before locking FXRP, so a peer mutation on the OFT after configuration fails sweeps closed instead of routing to an unknown remote OApp. It carries the **deposit compose** (`ACTION_DEPOSIT_SWEEP`): on arrival the loan-chain twin supplies exactly the bridged amount as collateral — no debt, no destination, no operation id, because nobody signed it and it must express no choice. Replay safety is the endpoint's: EndpointV2 executes a compose at most once per packet and a failed one stays retriable; the action itself is additive — each packet supplies only its own credited amount. The caller supplies the destination `lzReceive` and `lzCompose` gas in `extraOptions`. If the compose fails, the credit sits idle on the loan-chain account for `depositIdleFxrp`, the fallback rail. FXRP and the OFT both use 6 decimals, so nothing is lost to shared-decimal dust and `minAmountLD` equals the full amount.

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

The same openness is an **accepted risk** against the loan instruction: a stranded balance awaiting a parent-signed `borrow` can be swept
out from under it, aborting the requested loan action. Two bounds keep this accepted rather
than fixed. First, the **primary loan flow is atomic and immune on the Flare leg**: one `handleMintedFAssets`
transaction mints the FXRP, funds the Personal Account, creates the subaccount, transfers, and
bridges with the payload — the subaccount balance never exists outside that transaction, so
there is nothing to front-run on this chain (a test covers the five steps in one transaction; the destination side has its own, separately accepted window — see the loan-chain-side section). Only
*retry-after-strand* is exposed: FXRP already sitting on the subaccount while the user signs a
fresh instruction. Second, in that window the funds can only be pushed to the user's own
addresses. The griefing asymmetry is real, though — the attacker pays the configured executor
fee (backward: to the FAssets executor, or below the minimum to the user's own PA) or the
messaging fee (forward), while `sweepRedeem` imposes a re-mint round trip whose cost is
proportional to the balance — so this is accepted, not solved; revisit (the direction lifecycle
is the known remedy) if such griefing is ever observed in practice. Neither direction is ever
gas-only: `sweepToParent` rejects FXRP, and `sweepRedeem` requires the fee even when it only
pushes dust. One bounded residual is accepted: a redeem-home packet whose credit a public rail
already moved stays retriable for its TTL and can then redeem at most its own amount out of
funds that arrive later, for destination gas alone — bounded in amount (its own credit) and
time (`REDEEM_HOME_TTL`), custody unchanged (the user's own redemption).

### Recovery to the parent Personal Account

Not everything that can land on a subaccount is FXRP: a token sent here by mistake has no
other exit, so one permissionless thin mover pushes it to the parent Personal Account, which
accepts any asset and is fully under the user's control:

- **`sweepToParent(token)`** — recovers a token balance. The caller chooses only *which* asset,
  never where it goes. FXRP is **rejected** (`ProtectedToken`): the loan asset moves only on
  its own rails, and executors run `sweepRedeem` — a free push must not front-run it. A residual
  below the FAssets minimum goes home through `sweepRedeem` itself (pushed unredeemed).

It stays available while the controller is paused: the parent is the safest possible
destination, and an incident should not trap assets.

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

The forward moves come in two shapes. `sweepToLoan` is cleanup: permissionless, with a fixed
argument-free deposit compose — the assets cross over and become collateral. The **loan
instructions** are `borrow(collateralAmount, borrowAmount, destinationKind, destination,
operationId, deadline, extraOptions)`, `depositCollateral(amount, operationId, deadline,
extraOptions)` and `withdraw(amount, operationId, deadline, extraOptions)`: typed methods that
build the compose payload
**on-chain** and bridge it to this account's own address on the loan chain, where the
loan-chain twin executes it on arrival (supply as collateral, borrow, disburse; deposit
collateral only; withdraw collateral). The payload is not passed in: what the user signs is
structured and type-checked, a malformed payload cannot reach the bridge, and the arguments
are validated here — before any bridge fee is paid — for everything the loan chain would
reject on delivery (`InvalidLoanInstruction`: zero operation id, deadline already passed, a
zero borrow, deposit or withdrawal amount, a disbursement destination that is not a clean
non-zero EVM address other than this account). The loan chain re-validates on delivery. The
three are separate instructions with separate actions — a borrow always increases debt
(`borrowAmount` non-zero), `depositCollateral` never does — so each carries exactly the
fields it needs and its own pause rule (a deposit is the defensive move; see the loan-chain
section).
`borrow`'s collateral amount is explicit rather than the whole balance: what travels becomes
the authenticated collateral figure on the destination (the OFT's `amountLD`), so the user
signs exactly what is collateralized, and idle residue — donations, strands from skipped
deliveries — stays behind for the cleanup rails. A **zero collateral amount is a
message-only send** (verified against the live adapter): a borrow against existing
collateral, or a withdraw, which never carries tokens. Only the cleanup sweep keeps
whole-balance semantics, because sweeping everything is what cleanup means. All four share
one bridging core in the contract, so the guards are identical by construction: a paused
controller blocks it, the governance-pinned settings name the route, and the OFT's live peer
is re-checked against the pinned one on every call. What differs is authorization and inputs:

- **Restricted to the parent Personal Account** (`onlyParent`): the instruction names a loan
  action and, for a borrow, a user-chosen destination for the proceeds, so it must carry the
  user's XRPL signature. This is the instruction-destination rule below, in contract form.
- **The payload schema is shared with the loan-chain account**, not opaque: the constants
  (`PAYLOAD_VERSION_1`, `ACTION_BORROW`, `ACTION_DEPOSIT_COLLATERAL`, `ACTION_DEPOSIT_SWEEP`,
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
  (forward, into the account's own position) and `sweepToOrigin(options)` (backward, to the
  account's own Flare address, redeemed on arrival) are the two rails, under the same invariant (anyone may move,
  nobody may redirect).
- **A real Endpoint/OFT compose-delivery simulation** belongs to the loan-chain-side test suite
  as a regression test; the live-adapter verification recorded here is evidence, not a test.
  Still open for the wire hop (a real `EndpointV2` and the OFT's `lzReceive → sendCompose`),
  and it must cover all the actions (borrow, deposit, sweep deposit, withdraw, mirror execute) — the mirror case with a
  native drop into the real beacon proxy followed by a value-carrying batch, since unit tests fund
  the mirror with `vm.deal` and never exercise the executor's gas-limited drop. Covered
  locally: a sender→codec→receiver test runs the bytes the Flare senders hand to `send` through
  the canonical `OFTComposeMsgCodec` wrapper into the real loan-chain receivers.

## Who may choose a destination

Two different rules apply, and the difference is the signature:

- **Instruction destinations are the user's choice.** A borrow names where the RLUSD goes, and the XRPL signature authorizes it. Version 1 implements only the EVM/ERC-20 form (typically an exchange deposit address), paid by a direct transfer; the XRPL-over-Wormhole form is reserved by the payload's destination-kind tag and added when Wormhole provides specs. The EVM address is checked for shape only — clean zero-padded, non-zero, and not the subaccount itself (the proceeds could only repay the new debt); the parent Personal Account, the user's own compose-driven account on the loan chain, is a valid target — beyond that it is the user's money and the user's choice, the same way the XRPL target is already allowed to be an arbitrary account.
- **Cleanup destinations are never the caller's choice.** Sweeps and recovery are permissionless and carry no signature, so their destination must be derived on-chain — the account's own position, its own address on the other chain, or `parentPersonalAccount` — never from caller-supplied data. Anyone may move stranded assets; nobody may redirect them.

Caveats specific to the EVM disbursement option, for the front end rather than the contracts: RLUSD is a regulated stablecoin and can freeze or blacklist addresses, so a transfer can revert and turn a borrow into a stuck disbursement; some exchange deposit addresses are not credited when the sender is a contract, or need a tag an ERC-20 transfer cannot carry; and a wrong address is unrecoverable, since nothing is checked.

## The loan-chain-side account

The same frozen proxy bytecode and the same derivation give the subaccount one address on every
chain, and the per-type implementation registry is what makes that useful: each chain's diamond
registers its **own** implementation for the loan type. Flare registers
[`LoanSubaccount`](../../../contracts/smartAccounts/implementation/LoanSubaccount.sol) (FAssets
redemption pushed to the parent, the forward bridge, recovery to the parent); the loan chain (Ethereum, at
launch) registers
[`LoanSubaccountRemote`](../../../contracts/smartAccounts/implementation/LoanSubaccountRemote.sol).
The implementation never enters the CREATE2 derivation, so the registration choice cannot move
the address (a test pins this).

The defining difference on the loan chain: **there are no parent-driven methods.** The parent
Personal Account has no local key on the loan chain — instructions exist only on Flare, and
its loan-chain presence is the compose-driven mirror described below — so
`onlyParent` methods could
never be called. Every authorized action instead arrives as an authenticated LayerZero compose
payload sent by this same account on Flare (`borrow`, `depositCollateral`, `withdraw`, and the
forward sweep's fixed deposit compose), and everything else is
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
recovery to the parent keep working. And the **per-type market binding**: the timelocked
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
signed action carries `(bytes32 operationId, uint64 deadline, …)`; the unsigned sweep deposit
carries nothing, its replay safety being the endpoint's at-most-once compose delivery. The
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

`ACTION_BORROW` supplies **exactly the authenticated bridged amount** (the codec's `amountLD`,
never the idle balance, which can commingle donations and unrelated transfers) as collateral,
if any, and borrows `borrowAmount` (non-zero) against the account's own position, paying the
destination — EVM kind only, clean zero-padded address, Wormhole kind reserved. It is a debt
increase: pause-gated and subject to the per-type borrow switch. `ACTION_DEPOSIT_COLLATERAL`
supplies exactly the authenticated bridged amount (non-zero) as collateral and changes no
debt — the defensive action: while the controller is paused it executes only when the position
carries live debt. `ACTION_DEPOSIT_SWEEP` is the same deposit without a signature behind it — the
compose of the permissionless Flare `sweepToLoan`: argument-free, no operation id (each packet
carries its own credit), same pause rule. For all of these, if the credited tokens were moved before delivery (the accepted
race above), the action fails closed with `InsufficientComposeBalance` — a cap rather than
provenance, since every balance on the account is the user's own, but it stops a signed action
from absorbing more than its own credit. `ACTION_WITHDRAW` withdraws collateral from the
account's own position **to the account itself**, where only the fixed rails can move it;
Morpho enforces position health.

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
(repayment, deposits, withdrawals, and recovery are never gated by the switch). Clearing the
transport zeroes the LayerZero surface for **all** loan types — composed actions and the
bridge-back sweep wait until governance reconfigures it; with a live timelock that wait is
real, which is why the clear is the nuclear incident lever. Market bindings, `repay`,
defensive idle deposits, and recovery to the parent persist through both levers. The global
pause blocks debt increases, withdrawals, debt-free deposits and the bridge-back (recovery to
the parent is inward and stays open; the mirror's signed user operations are what the pause
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

**The permissionless rails** — fixed destinations, no caller discretion, mirroring the
Flare-side invariant:

- **`repay()`** pushes the whole idle loan-token balance into the account's one position,
  clamped to the live debt: interest is accrued first, a balance below the debt repays by
  assets, a balance covering it repays by **exact borrow shares** (Morpho's canonical
  rounded-up conversion with virtual offsets), closing the position without the over-repay
  revert. The documented user flow overfunds repayments to cover in-flight interest, so the
  clamp is what makes that flow work; the surplus stays for `recoverToken`. Available
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
- **`sweepToOrigin(extraOptions)`** bridges the whole idle FXRP balance back to this account's
  own Flare address (the OFT's own `token()` is the authoritative FXRP identity), with the
  redeem-home compose (a deadline, this block time plus `REDEEM_HOME_TTL`, and nothing else):
  the Flare twin redeems at most this amount on arrival (see Cleanup moves).
  The caller supplies the Flare-side gas in the options and may attach compose value, which
  becomes the redemption's executor fee. Exactly the quoted fee is spent and only the call's own
  excess refunded — pre-existing native never subsidizes a caller. Pause-gated: every exit from
  this chain rides the OFT itself. Live peer re-checked against the pinned one.
- **Recovery** goes to the **parent Personal Account** — the user's own compose-driven account
  on this chain (see below) — a fixed destination baked in at creation, nothing to configure
  and nothing to rotate. `recoverToken(token)` is the one rail: the market's collateral token
  is rejected (it moves only on its own rails); the market's loan token is recoverable only
  while **the position carries no debt** — read live from Morpho, so an external liquidation
  (which zeroes debt without the account observing it) frees the surplus immediately; any
  other token moves freely. It is **not pause-gated**: subaccount to its own parent is inward
  consolidation, not an exit — the parent's signed user operation outward is what the pause stops.
  There is no native rail on this account: no `receive()` (no protocol flow sends native
  here — the bridge rails refund their caller and compose value is rejected — so a plain send
  reverts at the sender) and no native exit. Native can still land without a call:
  pre-deployment funding of the predicted address, a caller-requested LayerZero native drop,
  or a force-send; such a balance strands until a beacon upgrade adds a rail — accepted, since
  nobody in the protocol causes it. Containment note: a pause does not contain a compromise of the
  compose-authentication root itself (endpoint, OFT, pinned peer) — for that incident,
  clearing the transport is the containment, since it disables `lzCompose` entirely.

## The remote Personal Account

Users are XRPL-only, and their signatures become on-chain authority only on Flare — so on
the loan chain the user's Personal Account address exists (the PA proxy derivation is frozen
and chain-independent) but historically carried no code, and anything sent to it was
stranded. The **remote Personal Account**
([`PersonalAccountRemote`](../../../contracts/smartAccounts/implementation/PersonalAccountRemote.sol))
closes that: a per-chain implementation registered behind the same controller-as-beacon that
serves the Flare PAs, materialized at the same CREATE2 address through the frozen PA proxy.
It is the compose-driven mirror of the user's Flare account — no local owner, no
controller-driven methods (instructions exist only on Flare); every authorized action arrives
as an authenticated LayerZero compose message sent by this same account on Flare, exactly the
subaccount's self-to-self trick applied to the PA family.

**Naming.** Four words, one axis each. *Loan* is the business use and stays only on what exists
for the loan — `LoanSubaccount`, `LoanSubaccountRemote`, the settings facets. *Remote* is
location, seen from Flare (the protocol's home): `PersonalAccountRemote` and
`LoanSubaccountRemote` are the same addresses on the other chain. *Compose* is the mechanism:
`ComposeReceiverAccountBase` is the ingress every compose receiver shares — and only that
ingress; the subaccounts also have parent-driven and public rails outside it. *CrossChain* is
the operation the Flare sender performs: `sendCrossChainUserOp` sends a user operation to
another chain and executes nothing itself. "Cross-chain" is general in name only for now — the
sender rides the loan bridge's FXRP OFT and a remote PA exists only on the loan chain; a
multi-destination PA would need per-destination routes.

**The shared base.** The authentication checklist (endpoint-only caller, configured FXRP OFT
as sender, origin chain, `composeFrom` equal to the account's own address, GUID recomputed
from the pinned origin peer) is identical for the mirror PA, the loan-chain subaccount and the
Flare subaccount (as the receiver of its own bridge-back, its transport derived from the bridge
settings), as is the operation-id replay protection with the skip semantics that the signed
actions use (the unsigned Flare action carries no id and relies on the endpoint's at-most-once
compose delivery), and they live once in
[`ComposeReceiverAccountBase`](../../../contracts/smartAccounts/implementation/ComposeReceiverAccountBase.sol)
(public surface: [`IComposeReceiverAccountBase`](../../../contracts/userInterfaces/IComposeReceiverAccountBase.sol)).
Derived accounts define only their action set, their transport source, whether compose value is
accepted (only the Flare receiver, which spends it in the same call) and their identity.
Deliberately one implementation:
this block is the security root of every account with no local owner.

**The action set is one action: execute.** The mirror does what the Flare account does —
run the batch of calls the user signed — with the authenticated compose in the role the
controller plays on Flare. The blast-radius claim follows: a compromised compose root has the
**full on-chain authority of the mirror address** — balances, approvals, external positions
and any role granted to it — the same class as a controller compromise on Flare, but no
authority over the loan subaccount beyond its permissionless fixed rails (it has no
parent-driven methods on this chain, so collateral and debt stay behind its own compose
authentication). Callbacks into the mirror's compose entry (`lzCompose`) meet the active
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
- **No permissionless rail at all.** No protocol flow ever routes FXRP to the mirror: Flare's
  instructions are message-only, bridged collateral lands on the loan subaccount, and
  subaccount recovery brings only non-collateral tokens (the subaccount rejects FXRP in
  `recoverToken`). What lands here is borrow proceeds the user directed here, recovered
  loan-token surplus, and external strays — and the user's next batch moves or uses them.
- **Native is accepted** (`receive()`) and leaves the same way, as a value-carrying call. The
  purpose is funding: a bridge call (proceeds to XRPL through Wormhole, say) wants a native
  fee, and the LayerZero executor **native-drop option** in `extraOptions` delivers native to
  the mirror with the same message that carries the batch — which needs `receive()`. Compose
  *value* stays rejected (`NonZeroComposeValue`; the drop is a separate transfer, and a
  mistaken delivery must stay retriable). A value call exceeding the balance fails with
  `CallFailed` and is retriable after funding. The implementation contract itself, never
  initialized, rejects native (`NotInitialized`) — nothing could ever move it out of there. No
  NFT/1155 holders in v1 (a safe-transfer in without the receiver hooks would revert at the
  sender; add them the day a flow needs them — the batch can already move them out).

**The Flare-side sender.** `PersonalAccount.sendCrossChainUserOp(calls, operationId,
deadline, extraOptions)` — the one instruction: builds the execute envelope on-chain (a
malformed envelope cannot reach the bridge), validates the envelope before any fee is paid
(`InvalidCrossChainUserOp`: zero id, passed deadline, empty batch — the batch itself is
not interpreted; the wallet owns the correctness of targets and amounts, as it does for
`executeUserOp`), and sends a message-only compose (amount zero) over the configured FXRP OFT
to its own address — the validated path: configured bridge settings, live peer re-checked
against the pinned one, exact quoted fee, pause-gated. It is callable **only by the account
itself**, which makes it reachable exclusively through an `executeUserOp` multicall — the XRPL
signature covers every target, value and calldata end-to-end. The fee value rides from the
account's own native balance through the multicall, and any excess simply remains on the
account. `extraOptions` must carry the `lzCompose` gas the batch needs and, when the batch
sends more native than the mirror holds, a native drop. No typed helpers by decision: the common transfer is a one-call batch a
wallet builds like any other, and one sender never grows a helper per use case.

**Creation.** `createPersonalAccountRemote(xrplOwner)` on the loan-chain settings facet —
permissionless and idempotent, the PA analog of the generic `createSubaccount`: the
instruction machinery that creates PAs lazily on Flare does not exist here, so creation is an
explicit route. It requires the registered remote PA implementation (the frozen
BeaconProxy resolves it at construction) and registers the account, so `getPersonalAccount`
answers with it afterwards. An empty owner cannot be created (the implementation rejects it),
so no mirror can exist for an impossible owner. The route sits on the loan-chain settings
facet only because that facet is the loan chain's configuration surface today; the account is
not loan-specific, and the deferred facet split moves creation to a generic
`createPersonalAccount` on `PersonalAccountsFacet` (or a dedicated remote-account creation
facet), not into a transport facet.

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
  both implementations ship with `pnpm deploy_remote_account_implementations ethereum`. There is
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
    `LoanSubaccountRemote` and `PersonalAccountRemote` artifacts (runtime hashes verified
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
    are the storage prefix of **all three** lineages — loan-chain subaccounts, mirror PAs and Flare
    subaccounts (the Flare subaccount adopted the same layout when it became a compose receiver, safe
    only pre-deployment) — so a base-field
    insertion or reorder would corrupt every account of all three kinds at once; and before the
    first deployment of an implementation with a re-laid layout on ANY network of that lineage,
    verify on chain that no proxy of the lineage exists there yet; base state is
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
  - the real Endpoint/OFT compose-delivery integration harness for every action, in both
    directions (also a step-6 release gate; the local sender→codec→receiver tests run each
    sender's bytes — borrow, deposit, sweep deposit, withdraw, mirror execute, and the
    loan-chain redeem-home — through the canonical codec into the real receivers, everything but
    the wire hop; non-zero compose value is covered by the Flare receiver tests, and the
    wire-level `lzReceive → sendCompose → lzCompose` path with delivered compose value, zero and
    non-zero, is exactly what the harness must add).
- **`setLoanBridgeSettings` comes last, and only once the loan-chain side exists.** Its
  validation reads the OFT's live peer for the destination endpoint, so it cannot be configured
  before the destination route is wired; until then the forward moves revert with
  `LoanBridgeNotConfigured` while creation, the backward sweep and recovery already work. The loan-chain-side account (same diamond address, same derivation) must be
  deployed before the forward moves are enabled, since bridged FXRP lands on the subaccount's
  own address there.

## Open design items (decide with the asset-moving methods)

- ~~Stuck RLUSD on the loan-chain side~~ — resolved: while the account's position has debt, the balance is repayment material (`repay` is its only move); once the position is closed, the surplus leaves through `recoverToken` to the parent Personal Account (the user's own loan-chain account). Same-id replay is prevented by the operation ids (two separately authorized ids can each borrow).
- **TODO, parked: atomic withdraw-and-bridge action.** If guaranteed withdrawal completion is ever required, the clean contract-level fix for the withdraw/redeposit ordering race (see the rails) is a single composed action that withdraws collateral and bridges it back in one execution. It is not free: it needs compose value (rejected today by `NonZeroComposeValue`, which exists to keep mistaken deliveries retriable), fee quoting inside the compose, and refund semantics for a permissionless deliverer. Decide if withdrawal-completion guarantees become a product requirement; until then, executor-side bundling of delivery with `sweepToOrigin` is the operational mitigation.
- **TODO, in design: the Flare fee.** An interest-spread model (checkpoint accounting over the account's Morpho debt) was accepted by product and is in design review; it is kept out of this spec until the design settles, then documented here.
- **TODO, deferred: split `LoanChainSettingsFacet`** into the general compose transport (the transport setter and getter) and the loan markets (write-once markets, borrow switch), with the compose-driven PA creation moving to a generic `createPersonalAccount` on `PersonalAccountsFacet` (or a dedicated creation facet). `ILoanChainSettingsFacet.Transport` and `LoanBridgeSettingsFacet` keep their names until then — the latter still configures the actual FXRP loan route. If the split gives the settings a new storage namespace it is a hard pre-first-cut task: after the first cut it would need a migration or a permanent legacy slot.
- ~~Grace-period public fallback for the default relays~~ — resolved by removing the relays: the parent Personal Account is the redeemer and defaults directly on the asset manager through `executeUserOp` (still `notPaused`; the appointed executor's direct path is the pause-time trigger, as before). The planned one-click-withdrawal subaccount type dissolves the same way, into a Personal Account multicall — do not build it.
- ~~Native payability~~ — resolved the other way: no `receive()` and no native exit on the Flare subaccount (no protocol flow leaves native on it — the bridge refunds its caller, redemption outcomes land on the parent, and the compose value of its own bridge-back is forwarded within the same call); native landing without a call (pre-deployment funding of the predicted address, a force-send) strands — accepted; a beacon upgrade can add an exit if it ever matters.
