# Loan Subaccounts

A loan subaccount is a deterministic, restricted staging account owned by a [Personal Account](./PersonalAccounts.md), used to stage loan-related assets (FXRP on the way to or from a cross-chain lending flow). It is not a generic smart wallet: it will expose only a fixed set of loan operations, and anyone may trigger only predefined cleanup actions on it.

Status: in progress. The account, its proxy, the per-type implementation registry, controller-side creation/prediction, the account abstraction dispatch, both cleanup moves (`sweepRedeem`, `sweepToLoan`), and the recovery methods (`sweepToParent`, `sweepNativeToParent`) are in place. The Flare-side loan instruction (`executeLayerZeroCall`) is in place. The Ethereum-side account has its authenticated compose entry point (`lzCompose` with the borrow and withdraw actions), its governance configuration (`EthereumLoanSettingsFacet`), and its creation route; the permissionless repay/cleanup rails are still to come. A sweep-direction lifecycle was evaluated and rejected (see Cleanup moves), and the relay grace-period fallback is parked (see open items).

## Typed subaccounts

Subaccounts are typed by a raw `uint256` identifier (`0` is reserved and invalid; `1` is the loan type — see the `SUBACCOUNT_TYPE_*` constants in [`ILoanSubaccountsFacet`](../../../contracts/userInterfaces/facets/ILoanSubaccountsFacet.sol)). It is deliberately not a Solidity enum: the proxy creation code — and with it the constructor ABI — is frozen for deterministic CREATE2 addresses (see below), and a compiled enum decoder rejects values outside the range it was compiled with, which would make future types undeployable through the frozen artifact. With a raw integer, a new type needs only a registered implementation. Each type has its own implementation contract, registered per type in [`LoanSubaccounts.State.typeImplementation`](../../../contracts/smartAccounts/library/LoanSubaccounts.sol) and managed by the timelocked `setLoanSubaccountImplementation`.

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
    PROXY_CREATION_CODE, // frozen type(LoanSubaccountProxy).creationCode
    abi.encode(address(this) /* diamond */, _parentPersonalAccount, _subaccountType)
)
```

with `salt = bytes32(0)`. The subaccount address is therefore a pure function of `(diamond, parentPersonalAccount, subaccountType)` — per-type and per-account unique, and identical on every chain where the diamond has the same address. No implementation or beacon address enters the derivation, so implementation upgrades never move addresses.

> **Frozen:** the derivation uses the frozen `LoanSubaccounts.PROXY_CREATION_CODE` hex constant, exactly like [`PersonalAccounts.PROXY_CREATION_CODE`](./PersonalAccounts.md#frozen-proxy_creation_code). Its hash is pinned in `test/LoanSubaccountsLibrary.t.sol`, and two further tests compare it against a fresh compilation of the proxy source (by length, and byte-exact modulo CBOR metadata), so any drift fails CI. Editing the constant or the proxy source is a cross-chain coordination event: all predicted-but-not-deployed subaccount addresses would shift.

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
there is nothing to front-run on this chain (a test covers the five steps in one transaction; the destination side has its own, separately accepted window — see the Ethereum-side section). Only
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
assets just cross over. `executeLayerZeroCall(composeMsg, extraOptions)` is the **loan action**:
it bridges the whole idle FXRP balance to this account's own address on the loan chain with a
**composed call** attached, which the destination-side account executes on arrival (deposit as
collateral, borrow, disburse). Both share one bridging core in the contract, so the guards are
identical by construction: a paused controller blocks it, the governance-pinned settings name
the route, and the OFT's live peer is re-checked against the pinned one on every call. What
differs is authorization and inputs:

- **Restricted to the parent Personal Account** (`onlyParent`): the payload names a loan action
  and, for a borrow, a user-chosen destination for the proceeds, so it must carry the user's
  XRPL signature. This is the instruction-destination rule below, in contract form.
- **The payload (`composeMsg`) is opaque** to this repo. Its schema belongs to the
  destination-side account's `lzCompose` and is pinned down with the Ethereum-side work. It
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
address on the loan chain — which must implement `ILayerZeroComposer` (the Ethereum-side
implementation of this same account). Token credit and compose execution are separate steps in
LayerZero: if `lzCompose` fails, the FXRP is already on the destination account, and the
compose call can be retried permissionlessly through the endpoint.

**Release gates for the Ethereum-side account** (none of this is enforceable from the Flare
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
- **Idle FXRP on the Ethereum account needs an exit.** Plain `sweepToLoan` cleanup delivers
  FXRP with no payload by design, and a failed `lzCompose` leaves credited FXRP behind — the
  Ethereum side must offer cleanup for that state under the same invariant (anyone may move,
  nobody may redirect), because the Flare side cannot instruct on it (`executeLayerZeroCall`
  needs a non-zero Flare-side balance).
- **A real Endpoint/OFT compose-delivery simulation** belongs to the Ethereum-side test suite
  as a regression test; the live-adapter verification recorded here is evidence, not a test.

## Who may choose a destination

Two different rules apply, and the difference is the signature:

- **Instruction destinations are the user's choice.** A borrow names where the RLUSD goes, and the XRPL signature authorizes it. Two forms are supported: an XRPL address reached over Wormhole, or a plain EVM address (typically an exchange deposit address), which the Ethereum-side account transfers to directly. The EVM address is not validated — it is the user's money and the user's choice, the same way the XRPL target is already allowed to be an arbitrary account. The destination kind and the address travel inside the `executeLayerZeroCall` payload, which this repo treats as opaque; the payload format needs a destination-kind tag, to be pinned down when the LayerZero schema is frozen. Both forms will be supported, but the first version implements only the EVM/ERC-20 form — Wormhole has not provided specs yet, so the XRPL form is reserved by the destination-kind tag and added later.
- **Cleanup destinations are never the caller's choice.** Sweeps are permissionless and carry no signature, so their destination must be derived on-chain from `parentPersonalAccount` — never from caller-supplied data. Anyone may move stranded assets; nobody may redirect them.

Caveats specific to the EVM disbursement option, for the front end rather than the contracts: RLUSD is a regulated stablecoin and can freeze or blacklist addresses, so a transfer can revert and turn a borrow into a stuck disbursement; some exchange deposit addresses are not credited when the sender is a contract, or need a tag an ERC-20 transfer cannot carry; and a wrong address is unrecoverable, since nothing is checked.

## The Ethereum-side account

The same frozen proxy bytecode and the same derivation give the subaccount one address on every
chain, and the per-type implementation registry is what makes that useful: each chain's diamond
registers its **own** implementation for the loan type. Flare registers
[`LoanSubaccount`](../../../contracts/smartAccounts/implementation/LoanSubaccount.sol) (FAssets
redemption, the forward bridge, the parent-driven relays); Ethereum registers
[`EthereumLoanSubaccount`](../../../contracts/smartAccounts/implementation/EthereumLoanSubaccount.sol).
The implementation never enters the CREATE2 derivation, so the registration choice cannot move
the address (a test pins this).

The defining difference on Ethereum: **there are no parent-driven methods.** The parent Personal
Account exists only on Flare — on Ethereum its address has no code — so `onlyParent` methods could
never be called. Every authorized action instead arrives as an authenticated LayerZero compose
payload sent by this same account on Flare (`executeLayerZeroCall`), and everything else is
permissionless movement along fixed rails, the same invariant as everywhere: anyone may move
the assets, nobody may redirect them.

The account's configuration lives in
[`EthereumLoanSettingsFacet`](../../../contracts/smartAccounts/facets/EthereumLoanSettingsFacet.sol),
cut **only on the Ethereum-side diamond**: the LayerZero endpoint (the only allowed `lzCompose`
caller), the FXRP OFT on this chain (the only allowed compose sender, and the vehicle for the
bridge-back sweep), the pinned origin route back to Flare (`originEid`/`originPeer`), and the
Morpho contract with its market (`loanToken` = RLUSD, `collateralToken` = FXRP). The timelocked
`setEthereumLoanSettings` validates the OFT exactly as the Flare-side `setLoanBridgeSettings`
does — it must wrap the market's collateral token, share its decimals, report the canonical
`oftVersion`, and its live peer for the origin endpoint must equal the pinned one — and
all-zero settings clear the configuration, disabling the loan module until reconfigured.

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
never sends any, and the account has no native exit yet. The executor and extra data are
untrusted and ignored. A failing delivery reverts and stays retriable through the endpoint;
the credited FXRP is already on the account either way.

**The payload, version 1** — `abi.encode(uint8 version, uint8 action, bytes actionData)`. Every
action carries `(bytes32 operationId, uint64 deadline, bytes32 expectedMarketId, …)`:

- **Operation ids make retries safe**: a user retrying a stalled instruction produces a new
  LayerZero packet, and distinct deliveries of the same intent must not double-execute. An
  already-consumed id completes the delivery without effect (`LoanActionSkipped`). Ids are
  consumed only on execution, so a skipped intent can retry under the same id. Ids must be
  non-zero and globally unique per subaccount across action types; a retry keeps its economic
  fields and refreshes only the deadline.
- **Deadlines expire stale intent**: an old queued action completes without effect instead of
  creating debt long after the user signed it.
- **The market id binds the action to the market it was signed for**
  (`keccak256(abi.encode(marketParams))`, Morpho's canonical id): a settings change between
  signing and delivery **reverts** the delivery instead of reinterpreting — deliberately not a
  skip, since a mismatch is temporary and a permissionless delivery during the window must not
  consume the packet. The delivery stays retriable until its deadline expires.
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

**Creation route.** `createEthereumLoanSubaccount(xrplOwner, type)` on the settings facet is
the Ethereum counterpart of `createLoanSubaccount` — permissionless and idempotent, but the
parent Personal Account resolves to its **computed** address (PAs exist only on Flare, and the
PA derivation is chain-independent), so it materializes exactly the account the Flare side
predicts. Because the facet is cut only on the Ethereum-side diamond, the relaxed route exists
only where it is needed.

Still to come, against the release gates above: the permissionless repay rail (with debt
clamping), the deposit rail for idle FXRP, the bridge-back sweep, and the native exit.

## Deployment

- **Fresh deployments** (`pnpm deploy_contracts` → `DeploySmartAccounts`): the loan module is
  part of the standard cut — `LoanSubaccountsFacet` is deployed with the other smart-accounts
  facets, a `LoanSubaccount` implementation is deployed alongside the Personal Account
  implementation, and type `1` is registered with `setLoanSubaccountImplementation` before
  `setTimelockDuration`, while the timelock is still zero.
- **Existing deployments** (flare, songbird, coston2): the facet needs no dedicated deploy
  step — naming `LoanSubaccountsFacet` in a cut plan
  (`deployment/cuts/<network>/cuts-<date>.json`, verified with `pnpm check_cut`, executed with
  `pnpm diamond_cut`) deploys it from the artifact as part of the cut flow. The implementation
  is deployed with `pnpm deploy_loan_subaccount_implementation <network>` and registered by
  governance with the timelocked
  `setLoanSubaccountImplementation(SUBACCOUNT_TYPE_LOAN, <address>)`.
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
  before relying on an Ethereum deployment. The Ethereum cut installs `LoanSubaccountsFacet`,
  `TimelockFacet`, `PauseFacet`, and `EthereumLoanSettingsFacet` through the standard cut flow
  (the cut plan under `deployment/cuts/ethereum/` is authored at cut time;
  `deployment/deploys/ethereum.json` is seeded with the pinned contracts), and the
  implementation ships with `pnpm deploy_ethereum_loan_subaccount_implementation`. There is
  deliberately no `deployment/chain-config/ethereum.json`: the generic full-deploy script must
  not run against Ethereum — operators go through the pinned bootstrap and the scripts above.

  **Before the first Ethereum cut, still to be built and rehearsed:**

  - a minimal Ethereum-side init contract for the cut: `MasterAccountControllerInit` is
    Flare-specific and is skipped, so ERC-165 interface flags (and nothing else) must be set
    explicitly;
  - post-cut verification: loupe/selector layout, owner, and ERC-165 answers checked against
    the expected Ethereum facet set (the bootstrap itself already verifies init-code hashes,
    CREATE2 addresses, and runtime code against the pinned Flare fixtures, in CI and at
    deploy time);
  - a signed ownership-control rehearsal from the historical owner EOA before anything
    depends on the deployment;
  - the real Endpoint/OFT compose-delivery integration harness (also a step-6 release gate).
- **`setLoanBridgeSettings` comes last, and only once the loan-chain side exists.** Its
  validation reads the OFT's live peer for the destination endpoint, so it cannot be configured
  before the destination route is wired; until then the forward moves revert with
  `LoanBridgeNotConfigured` while creation, the backward sweep, the relays, and recovery
  already work. The Ethereum-side account (same diamond address, same derivation) must be
  deployed before the forward moves are enabled, since bridged FXRP lands on the subaccount's
  own address there.

## Open design items (decide with the asset-moving methods)

- **Stuck RLUSD on the Ethereum side has only one move: repay.** RLUSD arriving there is indistinguishable between an inbound repayment and a borrow whose outbound leg failed, and a borrow may name an arbitrary destination, so a permissionless "send onward" would let anyone redirect a repayment to a third party. Repay is safe under every interpretation, since its target is the account's own position. The cost is that a failed disbursement silently unwinds the loan the user asked for. A bounded retry is possible if the account records the pending disbursement (amount plus destination) at borrow time, so the retry is driven by stored state rather than calldata; that is likely the same state needed to prevent double borrows when a LayerZero message stalls. Product decision, to settle before the Ethereum-side work.
- **TODO, parked: grace-period public fallback for the default relays.** `onlyParent` relays are unreachable during a pause (see above), so a pause held across FDC's attestation window combined with an unavailable executor recreates the executor dependency. The designed fix: relays stay parent-only until the request's `lastUnderlyingTimestamp` (read per-request from `redemptionRequestInfo`, no stored clock) is a grace period past, then open to anyone — by then the executor has demonstrably failed and the timing right has lapsed, so a fee-burning public call is acceptable. Implemented and tested, then parked; **must be decided before the first production deployment**, rather than left to incident-time executor availability.
- ~~Native payability~~ — resolved: the account has `receive()` and `sweepNativeToParent()`, since external refund behavior (FAssets, LayerZero, bridges) is not under this repo's control.
