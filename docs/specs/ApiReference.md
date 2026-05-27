# API reference

Pointer index from each module to its public interfaces. All user-facing types and events are defined under [`contracts/userInterfaces/`](../../contracts/userInterfaces/). Internal facet/library interfaces under [`contracts/smartAccounts/interface/`](../../contracts/smartAccounts/interface/) use the `II*` prefix and are not part of the integrator API.

## Smart Accounts

### Aggregate

- [`IMasterAccountController`](../../contracts/userInterfaces/IMasterAccountController.sol) — union of every facet interface plus the standard `IDiamondCut`, `IDiamondLoupe`, `IERC165`, `IERC173`. Use this when typing a reference to the deployed diamond.
- [`IPersonalAccount`](../../contracts/userInterfaces/IPersonalAccount.sol) — public ABI of a deployed Personal Account proxy (the `xrplOwner()`, `controllerAddress()`, `implementation()` views, `executeUserOp` entry point, plus all the events and errors).

### Per-facet

| Interface | Facet | Subject |
|-----------|-------|---------|
| [`IInstructionsFacet`](../../contracts/userInterfaces/facets/IInstructionsFacet.sol) | [`InstructionsFacet`](../../contracts/smartAccounts/facets/InstructionsFacet.sol) | Proof-based instruction flow: `reserveCollateral`, `executeDepositAfterMinting`, `executeInstruction`, plus events emitted on every primitive. |
| [`IMemoInstructionsFacet`](../../contracts/userInterfaces/facets/IMemoInstructionsFacet.sol) | [`MemoInstructionsFacet`](../../contracts/smartAccounts/facets/MemoInstructionsFacet.sol) | Direct-minting `handleMintedFAssets` entry, view accessors (`getNonce`, `getExecutor`, `isTransactionIdUsed`), every memo-opcode event. |
| [`IPersonalAccountsFacet`](../../contracts/userInterfaces/facets/IPersonalAccountsFacet.sol) | [`PersonalAccountsFacet`](../../contracts/smartAccounts/facets/PersonalAccountsFacet.sol) | `getPersonalAccount(xrplOwner)`, beacon `implementation()`, `PersonalAccountCreated` and `PersonalAccountImplementationSet` events. Extends `IBeacon`. |
| [`IReaderFacet`](../../contracts/userInterfaces/facets/IReaderFacet.sol) | [`ReaderFacet`](../../contracts/smartAccounts/facets/ReaderFacet.sol) | Aggregated reads: `getBalances(address)`, `getBalances(xrplOwner)`, `agentVaults()`, `vaults()`, `isSmartAccount(address)`. |
| [`IVaultsFacet`](../../contracts/userInterfaces/facets/IVaultsFacet.sol) | [`VaultsFacet`](../../contracts/smartAccounts/facets/VaultsFacet.sol) | Vault registry (Firelight / Upshift), `VaultType` enum, `addVaults`, `getVaults`. |
| [`IAgentVaultsFacet`](../../contracts/userInterfaces/facets/IAgentVaultsFacet.sol) | [`AgentVaultsFacet`](../../contracts/smartAccounts/facets/AgentVaultsFacet.sol) | FAssets agent-vault registry: `addAgentVaults`, `removeAgentVaults`, `getAgentVaults`. |
| [`IExecutorsFacet`](../../contracts/userInterfaces/facets/IExecutorsFacet.sol) | [`ExecutorsFacet`](../../contracts/smartAccounts/facets/ExecutorsFacet.sol) | Default proof-flow executor: `setExecutor`, `setExecutorFee` (timelocked), `getExecutorInfo`. |
| [`IInstructionFeesFacet`](../../contracts/userInterfaces/facets/IInstructionFeesFacet.sol) | [`InstructionFeesFacet`](../../contracts/smartAccounts/facets/InstructionFeesFacet.sol) | Proof-flow fees: `setDefaultInstructionFee`, `setInstructionFees` (per ID), `removeInstructionFees`, `getDefaultInstructionFee`, `getInstructionFee`. |
| [`IPauseFacet`](../../contracts/userInterfaces/facets/IPauseFacet.sol) | [`PauseFacet`](../../contracts/smartAccounts/facets/PauseFacet.sol) | Pause state and dual pauser/unpauser role sets: `pause`, `unpause`, `addPausers`, `removePausers`, `addUnpausers`, `removeUnpausers`. |
| [`IPaymentProofsFacet`](../../contracts/userInterfaces/facets/IPaymentProofsFacet.sol) | [`PaymentProofsFacet`](../../contracts/smartAccounts/facets/PaymentProofsFacet.sol) | FDC source ID and proof-validity duration: `getSourceId`, `getPaymentProofValidityDurationSeconds`, `setPaymentProofValidityDuration`. |
| [`IXrplProviderWalletsFacet`](../../contracts/userInterfaces/facets/IXrplProviderWalletsFacet.sol) | [`XrplProviderWalletsFacet`](../../contracts/smartAccounts/facets/XrplProviderWalletsFacet.sol) | Receiver-wallet allowlist for proof-flow payments: `addXrplProviderWallets`, `removeXrplProviderWallets`, `getXrplProviderWallets`. |
| [`ITimelockFacet`](../../contracts/userInterfaces/facets/ITimelockFacet.sol) | [`TimelockFacet`](../../contracts/smartAccounts/facets/TimelockFacet.sol) | Timelocked-call lifecycle: `setTimelockDuration` (timelocked), `executeTimelockedCall`, `cancelTimelockedCall`, `getExecuteTimelockedCallTimestamp`, `getTimelockDurationSeconds`. |

### Diamond infrastructure

- [`IDiamondCut`](../../contracts/diamond/interfaces/IDiamondCut.sol), [`IDiamondLoupe`](../../contracts/diamond/interfaces/IDiamondLoupe.sol), [`IDiamond`](../../contracts/diamond/interfaces/IDiamond.sol), [`IERC173`](../../contracts/diamond/interfaces/IERC173.sol), [`IERC165`](../../contracts/diamond/interfaces/IERC165.sol) — standard EIP-2535 surface.
- [`DiamondLoupeFacet`](../../contracts/diamond/facets/DiamondLoupeFacet.sol) — `facets()`, `facetFunctionSelectors`, `facetAddresses`, `facetAddress`.
- [`OwnershipFacet`](../../contracts/diamond/facets/OwnershipFacet.sol) — `owner()`, `transferOwnership(newOwner)`.

## FAsset Redeem Composer

| Interface | Contract | Subject |
|-----------|----------|---------|
| [`IFAssetRedeemComposer`](../../contracts/userInterfaces/IFAssetRedeemComposer.sol) | [`FAssetRedeemComposer`](../../contracts/composer/implementation/FAssetRedeemComposer.sol) | Compose entry (`lzCompose`), config (per-srcEid fee, executor, beacon implementation), view aggregates (`getRedeemerAccountAddress`, `isRedeemerAccount`, `getBalances`), the `RedeemComposeMessage` struct, all events and errors. Extends `ILayerZeroComposer`, `IBeacon`, and `IOwnableWithTimelock`. |
| [`IFAssetRedeemerAccount`](../../contracts/userInterfaces/IFAssetRedeemerAccount.sol) | [`FAssetRedeemerAccount`](../../contracts/composer/implementation/FAssetRedeemerAccount.sol) | Owner-only payment-default entrypoints (`redemptionPaymentDefault`, `xrpRedemptionPaymentDefault`), `owner()`, `composer()` views. |
| [`IOwnableWithTimelock`](../../contracts/userInterfaces/IOwnableWithTimelock.sol) | [`OwnableWithTimelock`](../../contracts/utils/implementation/OwnableWithTimelock.sol) | Generic timelock surface mirrored in `TimelockFacet` for the diamond. `executeTimelockedCall`, `cancelTimelockedCall`, `setTimelockDuration`, view accessors. |

## Cross-cutting interface notes

- All errors are custom errors (no revert strings). Each interface declares its own errors next to the function or event they cover.
- All events and errors are defined on the public `I*.sol` interfaces, never on the internal `II*.sol` interfaces or the implementations. To filter events from the diamond, use the user-interface ABIs and `MasterAccountController`'s address.
- `IMasterAccountController` does **not** declare any methods of its own. It is a marker interface combining every facet interface plus the EIP-2535 / ERC-173 / ERC-165 standards.
