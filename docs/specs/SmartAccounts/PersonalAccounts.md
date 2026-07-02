# Personal Accounts

Each XRPL address is paired with one [`PersonalAccount`](../../../contracts/smartAccounts/implementation/PersonalAccount.sol) on Flare. The PA holds the user's FXRP, vault shares, and native FLR. Every state-changing entry point is `onlyController` — only the [`MasterAccountController`](../../../contracts/smartAccounts/implementation/MasterAccountController.sol) diamond can call it. The XRPL signature on a Payment transaction (verified via FDC) or on a direct-mint memo is the sole authorization for actions on the PA.

## Deployment model

Personal Accounts are deployed as [`PersonalAccountProxy`](../../../contracts/smartAccounts/proxy/PersonalAccountProxy.sol) — a vanilla OpenZeppelin `BeaconProxy`:

```solidity
contract PersonalAccountProxy is BeaconProxy {
    constructor(address _controller, string memory _xrplOwner)
        BeaconProxy(_controller, abi.encodeWithSelector(
            INITIALIZE_SELECTOR, _controller, _xrplOwner))
    {}
}
```

The beacon is the diamond itself. [`PersonalAccountsFacet.implementation()`](../../../contracts/smartAccounts/facets/PersonalAccountsFacet.sol) returns the current PA logic contract, read from `PersonalAccounts.State.personalAccountImplementation`. Upgrading every Personal Account on the network is therefore a single timelocked call to `setPersonalAccountImplementation`.

The proxy's constructor delegate-calls `initialize(controller, xrplOwner)` on the implementation through the beacon. After that, `controllerAddress` is non-zero and `initialize` reverts on any further call.

## CREATE2 derivation

PAs are deployed via the [EIP-2470 Singleton Factory](https://eips.ethereum.org/EIPS/eip-2470) at `0xce0042B868300000d44A59004Da54A005ffdcf9f`. [`PersonalAccounts.createPersonalAccount`](../../../contracts/smartAccounts/library/PersonalAccounts.sol) builds the init code as:

```solidity
abi.encodePacked(
    PROXY_CREATION_CODE,
    abi.encode(address(this) /* diamond */, _xrplOwner)
)
```

The CREATE2 inputs are:
- `deployer` = the Singleton Factory.
- `salt` = `bytes32(0)`.
- `initCodeHash` = `keccak256(PROXY_CREATION_CODE || abi.encode(controller, xrplOwner))`.

So a given XRPL owner string maps to the **same EVM address on every chain** the protocol is deployed to, provided the diamond address and `PROXY_CREATION_CODE` are the same.

`getOrCreatePersonalAccount(xrplOwner)` returns the existing PA if one is recorded, otherwise computes the deterministic address, deploys the proxy via the singleton factory if no contract is yet at that address, and records the mapping. It is idempotent — repeated calls with the same `xrplOwner` return the same address.

`computePersonalAccountAddress(xrplOwner)` is the pure view variant, used by `PersonalAccountsFacet.getPersonalAccount` and `ReaderFacet.isSmartAccount` to predict the address before deployment.

## Frozen `PROXY_CREATION_CODE`

The CREATE2 input on the proxy side is **not** `type(PersonalAccountProxy).creationCode`. It is a hex-literal constant in [`PersonalAccounts.PROXY_CREATION_CODE`](../../../contracts/smartAccounts/library/PersonalAccounts.sol) equal to that creation code as compiled at commit `2abb115` (the source commit used for the live Flare deployment on 2026-02-13).

`type(...).creationCode` is resolved at compile time and includes the trailing CBOR metadata IPFS hash. That IPFS hash is recomputed from the entire compilation context of `PersonalAccountProxy` — its source, its imports' sources, compiler settings. Any drift there (even a comment edit in a transitively-imported file) shifts the CREATE2 address of every future PA.

Freezing the constant makes the derivation purely a function of `(controller, xrplOwner)`, immune to project drift. The hash is pinned in [`test/PersonalAccountsLibrary.t.sol`](../../../test/PersonalAccountsLibrary.t.sol):

```text
EXPECTED_PROXY_CREATION_CODE_HASH = 0x309250c8635e70dc667c1239a7bb73386e767b7084e9328b70de2c1f505b9b4a
```

That test contract holds three checks:

1. `testProxyCreationCodeLengthMatchesFreshCompilation` — the frozen constant and the live `PersonalAccountProxy` creation code must have the same length.
2. `testProxyCreationCodeMatchesFreshCompilationModuloMetadata` — after stripping the trailing CBOR metadata, the functional bytes must match.
3. `testProxyCreationCodeHashFrozen` — `keccak256(PROXY_CREATION_CODE)` must equal the pinned hash.

Editing the constant is a **cross-chain coordination event**: every PA that has been *predicted but not yet deployed* will move to a new address. The first two tests are excluded from coverage runs (coverage disables `via_ir`, which changes the bytes); the third is the load-bearing pin and runs everywhere.

The frozen constant also keeps `diamondCut` redeployment decisions stable. Facets that inline `PersonalAccounts` address-derivation logic — `PersonalAccountsFacet`, `InstructionsFacet`, `ReaderFacet`, and `MemoInstructionsFacet` — bake `PROXY_CREATION_CODE` into their runtime bytecode. Because it is a constant, those bytes do not drift across rebuilds, so `pnpm check_cut` flags these facets for redeployment only when their own logic actually changed, not because of unrelated metadata churn in `PersonalAccountProxy` or its imports. The embedded bytes shift only if the constant itself is edited (the guarded cross-chain event above); `check_cut` detects that specific case and reports it as a redeploy. See the deployment notes in `AGENTS.md` for the full workflow.

## PersonalAccount surface

[`IPersonalAccount`](../../../contracts/userInterfaces/IPersonalAccount.sol) is the public interface. The internal [`IIPersonalAccount`](../../../contracts/smartAccounts/interface/IIPersonalAccount.sol) extends it with the controller-only methods.

### Public views

| Function | Returns |
|----------|---------|
| `xrplOwner()` | XRPL address string this PA is bound to. |
| `controllerAddress()` | Diamond address (also the beacon). |
| `implementation()` | Reads `IBeacon(controllerAddress).implementation()` — i.e., the diamond's PA logic pointer. |

### Account abstraction entry point

```solidity
function executeUserOp(IPersonalAccount.Call[] calldata _calls) external payable;
```

A multi-call. Each `Call { target, value, data }` is executed sequentially; the whole transaction reverts with `CallFailed(index, returnData)` on the first failure. `nonReentrant` via `ReentrancyGuardTransient` (EIP-1153, Cancun-only). `onlyController` — invoked from the memo flow's `MemoInstructions.execute` after sender and nonce checks. The diamond is the controller, so a UserOp-driven `executeUserOp` call passes the `onlyController` check.

### Controller-only primitives

All `onlyController nonReentrant`, all emit events on `IPersonalAccount`:

- `reserveCollateral(agentVault, lots, executor, executorFee)` — `IAssetManager.reserveCollateral`. Pre-flight checks: agent `NORMAL`, `msg.value >= collateralReservationFee + executorFee`.
- `transferFXrp(to, amount)` — `SafeERC20.safeTransfer` on the FXRP token returned by the AssetManager.
- `redeemFXrp(lots, executor, executorFee)` — `IAssetManager.redeem` with the PA's `xrplOwner` as the redemption target.
- `deposit(vaultType, vault, assets)` — `safeApprove` the FXRP allowance then call the appropriate `deposit` shape:
  - Firelight (ERC-4626): `IIVault(vault).deposit(_assets, address(this))`.
  - Upshift: `IIVault(vault).deposit(address(fxrp), _assets, address(this))`.
- `redeem(vault, shares)` — Firelight `IIVault.redeem(_shares, address(this), address(this))`.
- `claimWithdraw(vault, period)` — Firelight `IIVault.claimWithdraw(_period)`.
- `requestRedeem(vault, shares)` — Upshift `IIVault.requestRedeem` after a `forceApprove` on the vault's LP token.
- `claim(vault, year, month, day)` — Upshift `IIVault.claim` for a specific date.

### Receivers

PAs can hold any ERC-721 / ERC-1155 / ERC-1363 token because they inherit `ERC721Holder`, `ERC1155Holder`, and implement `IERC1363Receiver.onTransferReceived`. `receive() external payable` lets them hold native FLR.

`supportsInterface` covers `IERC721Receiver`, `IERC1363Receiver`, and `IERC1155Receiver` (the latter through `ERC1155Holder`).

## Lifecycle and locking

The implementation contract is locked at construction:

```solidity
constructor() {
    // ensure the implementation contract itself cannot be initialized/used
    controllerAddress = EMPTY_ADDRESS;  // 0x…1111 sentinel
}
```

`initialize(...)` reverts unless `controllerAddress == address(0)`, so it can run exactly once — practically, that's the BeaconProxy constructor's delegate-call. After init:

- `controllerAddress` is set to the diamond.
- `xrplOwner` is set to the XRPL address string.

Neither can be changed afterwards. Storage upgrades happen by pointing the beacon at a new implementation, not by touching individual PAs.

## isSmartAccount check

[`ReaderFacet.isSmartAccount(address)`](../../../contracts/smartAccounts/facets/ReaderFacet.sol) validates a Flare address as a PA by:

1. Confirming there is code at the address.
2. Calling `IPersonalAccount(address).xrplOwner()` and getting a non-empty string.
3. Recomputing `PersonalAccounts.computePersonalAccountAddress(owner)` from that string and verifying it equals the input address.

The third step closes a spoofing window where an arbitrary contract could return any XRPL owner string. It also lets the function answer truthfully for predicted-but-not-yet-deployed PAs (it returns `(false, "")` for those — there is no code yet, so step 1 fails — while `getBalances(string)` and `getPersonalAccount(string)` use the same prediction internally).
