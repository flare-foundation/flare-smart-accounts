# Architecture

This document describes how the two modules in this repo are wired together on chain. Module-specific pages assume this view as background.

## Two modules, one repo

```
                    XRPL Payment ──► FDC IPayment.Proof
                          │                  │
                          │                  ▼
                          │       MasterAccountController (diamond)
                          │       ├─ InstructionsFacet (proof-based)
                          │       ├─ MemoInstructionsFacet (direct-mint)
                          │       └─ ReaderFacet, VaultsFacet, PauseFacet, …
                          │                  │
                          │                  ▼
                          │           PersonalAccount  (BeaconProxy, per XRPL addr)
                          │                  │
                          ▼                  ▼
                       AssetManager (FXRP) ◄─┘
                          ▲
                          │ redeemAmount / redeemWithTag
                          │
                FAssetRedeemerAccount (BeaconProxy, per redeemer EVM addr)
                          ▲
                          │ lzCompose(...)
                FAssetRedeemComposer (UUPS proxy) ◄── LayerZero endpoint
```

The two modules share:

- The Solidity toolchain (`^0.8.27`, solc `0.8.30`, optimizer 200, `via_ir`, Cancun).
- The [`OwnableWithTimelock`](../../contracts/utils/implementation/OwnableWithTimelock.sol) governance utility — timelocked owner operations with `executeTimelockedCall`, identical semantics in [`TimelockFacet`](../../contracts/smartAccounts/facets/TimelockFacet.sol) and `OwnableWithTimelock`.
- The FAsset and FDC interfaces from `flare-periphery`.

They do **not** share state, addresses, or upgrade paths.

## Smart Accounts module

### Diamond proxy ([EIP-2535](https://eips.ethereum.org/EIPS/eip-2535))

[`MasterAccountController`](../../contracts/smartAccounts/implementation/MasterAccountController.sol) extends the generic [`Diamond`](../../contracts/diamond/implementation/Diamond.sol). Its `fallback()` looks up the facet for `msg.sig` from `LibDiamond.diamondStorage().facetAddressAndSelectorPosition` and `delegatecall`s into it:

```solidity
address facet = ds.facetAddressAndSelectorPosition[msg.sig].facetAddress;
if (facet == address(0)) revert FunctionNotFound(msg.sig);
assembly {
    calldatacopy(0, 0, calldatasize())
    let result := delegatecall(gas(), facet, 0, calldatasize(), 0, 0)
    returndatacopy(0, 0, returndatasize())
    switch result case 0 { revert(0, returndatasize()) } default { return(0, returndatasize()) }
}
```

[`LibDiamond`](../../contracts/diamond/libraries/LibDiamond.sol) holds the selector mapping and the `diamondCut` implementation. The standard loupe interface is exposed by [`DiamondLoupeFacet`](../../contracts/diamond/facets/DiamondLoupeFacet.sol). Cuts are gated by [`DiamondCutFacet`](../../contracts/smartAccounts/facets/DiamondCutFacet.sol), whose `diamondCut` is `onlyOwnerWithTimelock` (see [Timelock](./SmartAccounts/Timelock.md)).

Initial state is installed by [`MasterAccountControllerInit`](../../contracts/smartAccounts/facets/MasterAccountControllerInit.sol), `delegatecall`-invoked once during the first `diamondCut`. It registers ERC-165 interfaces, sets the executor/fee, the FDC source ID and payment-proof validity duration, the default instruction fee, and the Personal Account beacon implementation.

The full facet list is documented in [SmartAccounts/Architecture](./SmartAccounts/Architecture.md).

### ERC-7201 namespaced storage

Each library declares its storage struct at a deterministic, collision-free slot:

```solidity
bytes32 internal constant STATE_POSITION = keccak256(
    abi.encode(uint256(keccak256("smartAccounts.<LibName>.State")) - 1)
) & ~bytes32(uint256(0xff));

function getState() internal pure returns (State storage _state) {
    bytes32 position = STATE_POSITION;
    assembly { _state.slot := position }
}
```

The `& ~0xff` mask is the [ERC-7201](https://eips.ethereum.org/EIPS/eip-7201) convention. Slots derive from the library's name (`"smartAccounts.Instructions.State"`, `"smartAccounts.PersonalAccounts.State"`, …) so libraries cannot collide. Replacing a facet that uses `Instructions` with a new version still calling `Instructions.getState()` reads the same storage; state persists across cuts.

Even the diamond's own ownership / selector map lives in an ERC-7201 namespace: `LibDiamond.DIAMOND_STORAGE_POSITION` is keyed off `"smartAccounts.LibDiamond.DiamondStorage"`.

### Personal Accounts (per-user beacon proxies)

Each XRPL address gets a [`PersonalAccount`](../../contracts/smartAccounts/implementation/PersonalAccount.sol) deployed as a [`PersonalAccountProxy`](../../contracts/smartAccounts/proxy/PersonalAccountProxy.sol) — an OpenZeppelin `BeaconProxy` whose beacon is the diamond itself. The diamond's [`PersonalAccountsFacet.implementation()`](../../contracts/smartAccounts/facets/PersonalAccountsFacet.sol) returns the current Personal Account implementation. Upgrading every Personal Account is therefore one timelocked call to `setPersonalAccountImplementation`.

Personal Accounts are deployed via the [EIP-2470 Singleton Factory](https://eips.ethereum.org/EIPS/eip-2470) at `0xce0042B868300000d44A59004Da54A005ffdcf9f`. CREATE2 derivation uses a **frozen** copy of `type(PersonalAccountProxy).creationCode` in [`PersonalAccounts.PROXY_CREATION_CODE`](../../contracts/smartAccounts/library/PersonalAccounts.sol). The hash of that constant is pinned in [`test/PersonalAccountsLibrary.t.sol`](../../test/PersonalAccountsLibrary.t.sol):

```text
EXPECTED_PROXY_CREATION_CODE_HASH = 0x309250c8635e70dc667c1239a7bb73386e767b7084e9328b70de2c1f505b9b4a
```

Freezing the bytecode (not relying on `type(...).creationCode`) makes the CREATE2 input invariant across rebuilds. The proxy's constructor args are `abi.encode(address(this), _xrplOwner)`, so the derivation also depends on the diamond address: the same XRPL owner string maps to the same EVM address on every chain the protocol deploys to **provided both the frozen `PROXY_CREATION_CODE` constant and the diamond address are the same across those chains**. Editing the constant — or deploying the diamond at a different address — is a cross-chain coordination event; the test exists to catch accidental drift in the bytecode half of that pair.

Every state-changing method on `PersonalAccount` is guarded by `onlyController`, where the controller is the diamond. All cross-account flow therefore goes through the diamond, even though Personal Accounts hold their own balances.

### Instruction flow

Two facets route instructions to a Personal Account:

- **Payment-proof flow** — [`InstructionsFacet`](../../contracts/smartAccounts/facets/InstructionsFacet.sol):
  - `reserveCollateral(xrplAddress, paymentReference, transactionId)` — opens a collateral reservation for FXRP minting; later `executeDepositAfterMinting(crtId, proof, xrplAddress)` deposits the minted FXRP into the vault encoded in the payment reference.
  - `executeInstruction(proof, xrplAddress)` — verifies an FDC `IPayment.Proof`, parses the 32-byte payment reference, and routes to the correct primitive (transfer, redeem, deposit, request-redeem, claim, claim-withdraw).
- **Direct-minting flow** — [`MemoInstructionsFacet.handleMintedFAssets`](../../contracts/smartAccounts/facets/MemoInstructionsFacet.sol): called by the FAssets `AssetManager` when FXRP is minted directly to the diamond. The XRPL memo selects the action — memo opcodes are documented in [SmartAccounts/MemoInstructions](./SmartAccounts/MemoInstructions.md).

Both share the `usedTransactionIds` mapping in [`Instructions.State`](../../contracts/smartAccounts/library/Instructions.sol). A given XRPL transaction ID can drive at most one instruction across either path.

The memo-instruction nonce in [`MemoInstructions.State.nonces`](../../contracts/smartAccounts/library/MemoInstructions.sol) only increments on **successful** execution. XRPL transactions are irreversible, so failed UserOps must remain retryable until off-chain tooling cleans them up via the `0xE0` ignore-memo opcode.

### Facets, libraries, interfaces

The on-chain code separates into three layers:

- **Facets** ([`contracts/smartAccounts/facets/`](../../contracts/smartAccounts/facets/)) — thin entry points. Each declares the external selectors that should dispatch to it and contains minimal logic: argument validation, access checks, calls into the corresponding library.
- **Libraries** ([`contracts/smartAccounts/library/`](../../contracts/smartAccounts/library/)) — business logic and namespaced storage.
- **Interfaces** — split between two trees:
  - [`contracts/userInterfaces/`](../../contracts/userInterfaces/) — public ABI surface, prefix `I`. Consumers and integrators import these.
  - [`contracts/smartAccounts/interface/`](../../contracts/smartAccounts/interface/) — internal interfaces, prefix `II`. Used between facets and libraries; not part of the public API.

`MasterAccountController`'s public surface is the union of all facet user-interfaces, aggregated in [`IMasterAccountController`](../../contracts/userInterfaces/IMasterAccountController.sol):

```solidity
interface IMasterAccountController is
    IDiamondCut, IDiamondLoupe, IERC165, IERC173,
    IAgentVaultsFacet, IExecutorsFacet, IInstructionFeesFacet,
    IInstructionsFacet, IMemoInstructionsFacet, IPauseFacet,
    IPaymentProofsFacet, IPersonalAccountsFacet, IReaderFacet,
    ITimelockFacet, IVaultsFacet, IXrplProviderWalletsFacet
{}
```

## FAsset Redeem Composer module

The composer is a single UUPS-upgradeable contract deployed behind [`FAssetRedeemComposerProxy`](../../contracts/composer/proxy/FAssetRedeemComposerProxy.sol) (an `ERC1967Proxy`). It is also a **beacon** for per-redeemer accounts: when an unknown redeemer's `lzCompose` arrives, the composer CREATE2-deploys a [`FAssetRedeemerAccountProxy`](../../contracts/composer/proxy/FAssetRedeemerAccountProxy.sol) (an OpenZeppelin `BeaconProxy` pointing at the composer for its `implementation()`).

Two interfaces guard access:

- `onlyComposer` — the redeemer account accepts redemption and allowance-prime calls only from the composer.
- `onlyOwner` — the redeemer account accepts `redemptionPaymentDefault` only from the EVM address that owns it.

The composer is administered by [`OwnableWithTimelock`](../../contracts/utils/implementation/OwnableWithTimelock.sol). UUPS upgrades go through `upgradeToAndCall`, which is `onlyOwnerWithTimelock`.

See [Composer Architecture](./Composer/Architecture.md) for the message flow and fee model.

## Governance: `OwnableWithTimelock` and `TimelockFacet`

Both modules timelock state-changing owner operations. Two implementations exist with the **same semantics**:

| Where | Contract | Storage slot |
|-------|----------|--------------|
| Smart Accounts diamond | [`TimelockFacet`](../../contracts/smartAccounts/facets/TimelockFacet.sol) + [`Timelock` lib](../../contracts/smartAccounts/library/Timelock.sol) | `erc7201:smartAccounts.Timelock.State` |
| Composer | [`OwnableWithTimelock`](../../contracts/utils/implementation/OwnableWithTimelock.sol) | `erc7201:utils.OwnableWithTimelock.State` |

Both expose `setTimelockDuration` (clamped to 7 days), `executeTimelockedCall`, `cancelTimelockedCall`, and a `getExecuteTimelockedCallTimestamp` view.

The pattern: an `onlyOwnerWithTimelock` modifier either *records* the call (when timelock > 0 and not currently executing) by storing `keccak256(msg.data) → block.timestamp + duration`, or *executes immediately* (when timelock == 0, or when the call comes from `executeTimelockedCall`, which sets a transient `executing` flag and re-enters). Anyone can call `executeTimelockedCall` once the delay has passed — the timelock controls *when* but not *who*.

The Smart Accounts pause role split (`pauser` vs. `unpauser`, in [`Pause` lib](../../contracts/smartAccounts/library/Pause.sol)) sits on top of this: both role sets are managed by `onlyOwnerWithTimelock`, but `pause()` / `unpause()` themselves only check the role and skip the timelock so an attacker-detected incident can be stopped immediately.

## Replay protection

Smart Accounts uses two independent replay sets:

| Set | Where | Keyed by | Used by |
|-----|-------|----------|---------|
| `usedTransactionIds` | [`Instructions.State`](../../contracts/smartAccounts/library/Instructions.sol) | XRPL `bytes32 transactionId` | Both `InstructionsFacet` and `MemoInstructionsFacet` |
| `nonces` | [`MemoInstructions.State`](../../contracts/smartAccounts/library/MemoInstructions.sol) | Per Personal Account | Memo-instruction UserOps (`0xFF` / `0xFE`) |

The shared `usedTransactionIds` set means one XRPL transaction can never drive two on-chain instructions, regardless of the path it took.

The composer relies on LayerZero's GUID-based replay protection at the endpoint; it does not maintain its own replay set.
