# Smart Accounts Architecture

Smart Accounts is a single EIP-2535 diamond proxy. One address on Flare — [`MasterAccountController`](../../../contracts/smartAccounts/implementation/MasterAccountController.sol) — internally routes every state-changing call to one of 15 facets via `delegatecall`. State lives in ERC-7201 namespaced storage so facets can be added, replaced, or removed without storage collisions.

This page describes the on-chain layout: how the diamond is constructed, how facets and libraries split responsibilities, the storage model, and where Personal Accounts plug in.

## The diamond pattern

[`Diamond`](../../../contracts/diamond/implementation/Diamond.sol) is the standard EIP-2535 implementation. Its `fallback()` looks up the facet for `msg.sig` and `delegatecall`s into it:

```solidity
fallback() external payable {
    LibDiamond.DiamondStorage storage ds;
    bytes32 position = LibDiamond.DIAMOND_STORAGE_POSITION;
    assembly { ds.slot := position }
    address facet = ds.facetAddressAndSelectorPosition[msg.sig].facetAddress;
    if (facet == address(0)) revert FunctionNotFound(msg.sig);
    assembly {
        calldatacopy(0, 0, calldatasize())
        let result := delegatecall(gas(), facet, 0, calldatasize(), 0, 0)
        returndatacopy(0, 0, returndatasize())
        switch result case 0 { revert(0, returndatasize()) } default { return(0, returndatasize()) }
    }
}
```

`MasterAccountController` extends `Diamond` directly:

```solidity
contract MasterAccountController is Diamond {
    constructor(IDiamondCut.FacetCut[] memory _diamondCut, DiamondArgs memory _args)
        Diamond(_diamondCut, _args)
    {}
}
```

[`LibDiamond`](../../../contracts/diamond/libraries/LibDiamond.sol) — namespaced at `smartAccounts.LibDiamond.DiamondStorage` — holds:
- `mapping(bytes4 => FacetAddressAndSelectorPosition)` from selector to facet address + position index.
- `bytes4[] selectors` — flat list of every registered selector.
- `mapping(bytes4 => bool) supportedInterfaces` — ERC-165 declarations.
- `address contractOwner` — the diamond owner.

Loupe introspection is exposed by [`DiamondLoupeFacet`](../../../contracts/diamond/facets/DiamondLoupeFacet.sol) (`facets`, `facetFunctionSelectors`, `facetAddresses`, `facetAddress`). Ownership transfer goes through [`OwnershipFacet`](../../../contracts/diamond/facets/OwnershipFacet.sol).

The diamond is initialized by [`MasterAccountControllerInit`](../../../contracts/smartAccounts/facets/MasterAccountControllerInit.sol) — a non-facet contract whose `init(...)` is `delegatecall`-invoked once during the diamond's first `diamondCut`. It:

- Registers the ERC-165 interfaces (`IERC165`, `IDiamondCut`, `IDiamondLoupe`, `IERC173`).
- Sets the default protocol executor and its wei fee.
- Sets the FDC source ID and the payment-proof validity duration.
- Sets the default instruction fee.
- Sets the Personal Account beacon implementation.

## Facets

Fifteen facets are deployed. The first column links to the user-facing interface (`I*.sol`); the second to the on-chain facet contract; the third describes what it does.

| Interface | Facet | Library | Subject |
|-----------|-------|---------|---------|
| [`IInstructionsFacet`](../../../contracts/userInterfaces/facets/IInstructionsFacet.sol) | [`InstructionsFacet`](../../../contracts/smartAccounts/facets/InstructionsFacet.sol) | `Instructions`, `FXrp`, `Vault`, `Vaults`, `AgentVaults`, `InstructionFees`, `PaymentProofs`, `PaymentReferenceParser`, `PersonalAccounts`, `Pause` | Proof-based instruction execution. Entry points: `reserveCollateral`, `executeDepositAfterMinting`, `executeInstruction`, `getTransactionIdForCollateralReservation`. |
| [`IMemoInstructionsFacet`](../../../contracts/userInterfaces/facets/IMemoInstructionsFacet.sol) | [`MemoInstructionsFacet`](../../../contracts/smartAccounts/facets/MemoInstructionsFacet.sol) | `MemoInstructions`, `Instructions`, `PersonalAccounts`, `Pause` | Direct-minting callback `handleMintedFAssets`. Dispatches the seven memo opcodes. View accessors `getNonce`, `getExecutor`, `isTransactionIdUsed`. |
| [`IPersonalAccountsFacet`](../../../contracts/userInterfaces/facets/IPersonalAccountsFacet.sol) | [`PersonalAccountsFacet`](../../../contracts/smartAccounts/facets/PersonalAccountsFacet.sol) | `PersonalAccounts` | Beacon `implementation()` for PA proxies, `setPersonalAccountImplementation` (timelocked), `getPersonalAccount(xrplOwner)`. |
| [`IReaderFacet`](../../../contracts/userInterfaces/facets/IReaderFacet.sol) | [`ReaderFacet`](../../../contracts/smartAccounts/facets/ReaderFacet.sol) | `Vaults`, `AgentVaults`, `PersonalAccounts` | Aggregated reads — full balance snapshot, vault and agent-vault enumeration, `isSmartAccount` verification. |
| [`IVaultsFacet`](../../../contracts/userInterfaces/facets/IVaultsFacet.sol) | [`VaultsFacet`](../../../contracts/smartAccounts/facets/VaultsFacet.sol) | `Vaults` | Firelight / Upshift vault registry. `addVaults` (timelocked), `getVaults`. `VaultType` enum lives here. |
| [`IAgentVaultsFacet`](../../../contracts/userInterfaces/facets/IAgentVaultsFacet.sol) | [`AgentVaultsFacet`](../../../contracts/smartAccounts/facets/AgentVaultsFacet.sol) | `AgentVaults` | FAssets agent-vault registry. `addAgentVaults` / `removeAgentVaults` (both timelocked, with `agentInfo.status == NORMAL` precheck on add), `getAgentVaults`. |
| [`IExecutorsFacet`](../../../contracts/userInterfaces/facets/IExecutorsFacet.sol) | [`ExecutorsFacet`](../../../contracts/smartAccounts/facets/ExecutorsFacet.sol) | `Executors` | Default protocol executor — `setExecutor` (`onlyOwner`, no timelock so it can be rotated quickly), `setExecutorFee` (timelocked), `getExecutorInfo`. |
| [`IInstructionFeesFacet`](../../../contracts/userInterfaces/facets/IInstructionFeesFacet.sol) | [`InstructionFeesFacet`](../../../contracts/smartAccounts/facets/InstructionFeesFacet.sol) | `InstructionFees` | Per-instruction-ID fee schedule. `setDefaultInstructionFee`, `setInstructionFees`, `removeInstructionFees`, `getDefaultInstructionFee`, `getInstructionFee`. |
| [`IPauseFacet`](../../../contracts/userInterfaces/facets/IPauseFacet.sol) | [`PauseFacet`](../../../contracts/smartAccounts/facets/PauseFacet.sol) | `Pause` | Pauser / unpauser roles. `pause()`, `unpause()`, role management (`addPausers` / `removePausers` / `addUnpausers` / `removeUnpausers`, all timelocked). |
| [`IPaymentProofsFacet`](../../../contracts/userInterfaces/facets/IPaymentProofsFacet.sol) | [`PaymentProofsFacet`](../../../contracts/smartAccounts/facets/PaymentProofsFacet.sol) | `PaymentProofs` | FDC source ID and proof-validity duration. `setPaymentProofValidityDuration` (timelocked), `getSourceId`, `getPaymentProofValidityDurationSeconds`. |
| [`IXrplProviderWalletsFacet`](../../../contracts/userInterfaces/facets/IXrplProviderWalletsFacet.sol) | [`XrplProviderWalletsFacet`](../../../contracts/smartAccounts/facets/XrplProviderWalletsFacet.sol) | `XrplProviderWallets` | XRPL receiver-wallet allowlist used by proof verification. `addXrplProviderWallets`, `removeXrplProviderWallets`, `getXrplProviderWallets`. |
| [`ITimelockFacet`](../../../contracts/userInterfaces/facets/ITimelockFacet.sol) | [`TimelockFacet`](../../../contracts/smartAccounts/facets/TimelockFacet.sol) | `Timelock` | Timelock lifecycle. `setTimelockDuration` (timelocked), `executeTimelockedCall`, `cancelTimelockedCall`, `getTimelockDurationSeconds`, `getExecuteTimelockedCallTimestamp`. Maximum duration 7 days. |
| `IDiamondCut` | [`DiamondCutFacet`](../../../contracts/smartAccounts/facets/DiamondCutFacet.sol) | `LibDiamond` | The `diamondCut(...)` entry point. Always `onlyOwnerWithTimelock`. |
| `IDiamondLoupe` | [`DiamondLoupeFacet`](../../../contracts/diamond/facets/DiamondLoupeFacet.sol) | `LibDiamond` | EIP-2535 introspection. |
| `IERC173` | [`OwnershipFacet`](../../../contracts/diamond/facets/OwnershipFacet.sol) | `LibDiamond` | `owner()`, `transferOwnership(newOwner)`. |

[`MasterAccountControllerInit`](../../../contracts/smartAccounts/facets/MasterAccountControllerInit.sol) is **not** a facet — it has no selectors registered on the diamond. Its `init(...)` is invoked only at deployment / migration time via the `_init`/`_calldata` arguments of `diamondCut`.

## Libraries

Thirteen libraries hold the actual business logic. Most own a single ERC-7201 storage slot.

| Library | Storage slot | Purpose |
|---------|--------------|---------|
| [`Instructions`](../../../contracts/smartAccounts/library/Instructions.sol) | `smartAccounts.Instructions.State` | `usedTransactionIds`, `collateralReservationIdToTransactionId`. Dispatches the 7 proof-based instruction shapes. |
| [`MemoInstructions`](../../../contracts/smartAccounts/library/MemoInstructions.sol) | `smartAccounts.MemoInstructions.State` | `nonces`, `ignoreMemo`, `executor`, `replacementFee`. Implements the 7 memo opcodes. |
| [`PersonalAccounts`](../../../contracts/smartAccounts/library/PersonalAccounts.sol) | `smartAccounts.PersonalAccounts.State` | PA implementation pointer, XRPL → PA mapping, CREATE2 deployment. Holds the frozen `PROXY_CREATION_CODE`. |
| [`PaymentProofs`](../../../contracts/smartAccounts/library/PaymentProofs.sol) | `smartAccounts.PaymentProofs.State` | FDC source ID, proof validity duration. `verifyPayment` calls `IFdcVerification.verifyPayment`. |
| [`XrplProviderWallets`](../../../contracts/smartAccounts/library/XrplProviderWallets.sol) | `smartAccounts.XrplProviderWallets.State` | XRPL receiver-wallet allowlist (string array + hash → 1-based index mapping). |
| [`Vaults`](../../../contracts/smartAccounts/library/Vaults.sol) | `smartAccounts.Vaults.State` | Vault registry: id → `VaultInfo {address, type}`, address → id, id list. |
| [`AgentVaults`](../../../contracts/smartAccounts/library/AgentVaults.sol) | `smartAccounts.AgentVaults.State` | Agent-vault registry: id → address, address → id, id list. |
| [`Executors`](../../../contracts/smartAccounts/library/Executors.sol) | `smartAccounts.Executors.State` | Default protocol executor + fee. |
| [`InstructionFees`](../../../contracts/smartAccounts/library/InstructionFees.sol) | `smartAccounts.InstructionFees.State` | Default fee + per-instruction-ID fee (1-based to distinguish unset from zero). |
| [`Pause`](../../../contracts/smartAccounts/library/Pause.sol) | `smartAccounts.Pause.State` | `paused` flag plus pauser / unpauser `EnumerableSet.AddressSet`s. |
| [`Timelock`](../../../contracts/smartAccounts/library/Timelock.sol) | `smartAccounts.Timelock.State` | `executing` re-entry flag, `timelockDurationSeconds`, `timelockedCalls` map. |
| [`FXrp`](../../../contracts/smartAccounts/library/FXrp.sol) | *(stateless)* | `reserveCollateral` / `transfer` / `redeem` wrappers around `IIPersonalAccount` + event emission. `lotsToAmount` view. |
| [`Vault`](../../../contracts/smartAccounts/library/Vault.sol) | *(stateless)* | Vault primitives (`deposit`, `redeem`, `claimWithdrawal`, `requestRedeem`, `claim`) wrapping `IIPersonalAccount` + event emission. Date helper for the Upshift `claim` shape. |
| [`PaymentReferenceParser`](../../../contracts/smartAccounts/library/PaymentReferenceParser.sol) | *(stateless)* | Pure decoders for the 32-byte payment reference: instruction ID/type/command, value, agent-vault ID, vault ID, address. |

`LibDiamond` ([`contracts/diamond/libraries/LibDiamond.sol`](../../../contracts/diamond/libraries/LibDiamond.sol), slot `smartAccounts.LibDiamond.DiamondStorage`) holds the selector map and the `diamondCut` implementation.

## How libraries call each other

Libraries are not `delegatecall`-isolated like facets — they are linked at compile time and inline into whichever facet imports them. So `InstructionsFacet` can compose `PaymentProofs.verifyPayment`, `Instructions.executeInstruction`, and `Vault.deposit` in one transaction, all operating on different namespaced slots of the same diamond.

The dependency graph is shallow:

```
Pause       ─┐
PaymentProofs┤
XrplProviderWallets ←── PaymentProofs
PersonalAccounts ←── (most facets)
Vaults / AgentVaults ←── Instructions, Reader
Executors ←── FXrp ←── Instructions
InstructionFees ←── Instructions
MemoInstructions ←── MemoInstructionsFacet
Timelock ←── (every onlyOwnerWithTimelock facet)
```

## Facet base and access control

[`FacetBase`](../../../contracts/smartAccounts/facets/FacetBase.sol) — every state-changing facet except `MasterAccountControllerInit`, `DiamondLoupeFacet`, and `OwnershipFacet` extends `FacetBase`. It provides two modifiers:

```solidity
modifier onlyOwnerWithTimelock {
    if (Timelock.timeToExecute()) { Timelock.beforeExecute(); _; }
    else                          { Timelock.recordTimelockedCall(msg.data); }
}

modifier onlyOwner { Timelock.checkOnlyOwner(); _; }
```

`onlyOwner` is `LibDiamond.enforceIsContractOwner()`. `onlyOwnerWithTimelock` either records the call (storing `keccak256(msg.data) → block.timestamp + duration`) or executes it (when invoked from `TimelockFacet.executeTimelockedCall`, which sets a transient `executing` flag; or when the configured duration is zero, allowing direct execution).

## Personal Accounts and the beacon

The diamond is both the **controller** (only it can call mutating functions on a Personal Account) and the **beacon** (its `implementation()` selector returns the PA logic contract). The same address fills two roles to keep the per-PA bytecode minimal — `PersonalAccountProxy` is a vanilla OpenZeppelin `BeaconProxy`.

Personal Accounts hold their own balances (FXRP, vault shares, native FLR) and never share storage with the diamond. The connection is one-way: facets call `personalAccount.xxx()` over a normal external call (not delegatecall).

See [Personal Accounts](./PersonalAccounts.md) for CREATE2 derivation and the frozen bytecode rationale.

## Reading the live diamond

Standard EIP-2535 introspection works on `MasterAccountController`:

- `facets()` — full list of `(facetAddress, selectors[])`.
- `facetFunctionSelectors(facet)` — which selectors a given facet exposes.
- `facetAddresses()` — every distinct facet address.
- `facetAddress(selector)` — which facet handles a given selector.

After every governance `diamondCut`, the answer changes; the loupe is the source of truth for what's currently deployed. The deployment scripts under [`deployment/cuts/`](../../../deployment/cuts/) record the cuts performed against each network's diamond, but the on-chain loupe always supersedes those files.
