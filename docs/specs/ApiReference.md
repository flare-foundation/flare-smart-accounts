# API reference

Pointer index from each module to its public interfaces. All user-facing types and events are defined under [`contracts/userInterfaces/`](../../contracts/userInterfaces/). Internal facet/library interfaces under [`contracts/smartAccounts/interface/`](../../contracts/smartAccounts/interface/) use the `II*` prefix and are not part of the integrator API.

## Smart Accounts

### Aggregate

- [`IMasterAccountController`](../../contracts/userInterfaces/IMasterAccountController.sol) — union of every facet interface plus the standard `IDiamondCut`, `IDiamondLoupe`, `IERC165`, `IERC173`. Use this when typing a reference to the deployed diamond. The union spans chains, so it is a superset: each chain's diamond cuts a subset (`IComposeTransportFacet` and `ILoanMarketsFacet` are cut only on the loan-chain diamond — Ethereum, at launch), and uncut selectors revert.
- [`IPersonalAccount`](../../contracts/userInterfaces/IPersonalAccount.sol) — public ABI of a deployed Personal Account proxy (the `xrplOwner()`, `controllerAddress()`, `implementation()` views, the `executeUserOp` entry point, the self-called `sendCrossChainUserOp` and the subaccount-only `redeemFromSubaccount`, plus all the events and errors).
- [`ILoanSubaccount`](../../contracts/userInterfaces/ILoanSubaccount.sol) — Flare loan-subaccount ABI: the parent-signed loan instructions (`borrow`/`depositCollateral`/`withdraw`), the permissionless redemption sweep, the authenticated redeem-home compose, and the views, events and errors.
- [`ILoanSubaccountRemote`](../../contracts/userInterfaces/ILoanSubaccountRemote.sol) — remote ABI of the same proxy (Ethereum, at launch): the authenticated loan actions and payload constants; the permissionless `repay`/`depositIdleFxrp`/`checkpointFee` rails; the parent-only signed exit `sweepToOrigin`; the fee state view, events and errors.
- [`IComposeReceiverAccountBase`](../../contracts/userInterfaces/IComposeReceiverAccountBase.sol) — the shared authenticated `lzCompose` and replay surface of the three compose receivers (the loan-chain subaccount and Personal Account, and the Flare loan subaccount as the receiver of its own bridge-back): the entry point, the payload version and skip-reason constants, the authentication/replay errors, and the `usedOperations` and `controllerAddress` views. `ILoanSubaccountRemote`, `IPersonalAccountRemote` and `ILoanSubaccount` extend it and expose their other rails.
- [`IPersonalAccountRemote`](../../contracts/userInterfaces/IPersonalAccountRemote.sol) — remote Personal Account ABI (the compose-driven twin of the Flare PA at the same address, on the loan chain at launch): signed call-batch execution and the identity views; no permissionless rails.

### Per-facet

| Interface | Facet | Subject |
|-----------|-------|---------|
| [`IInstructionsFacet`](../../contracts/userInterfaces/facets/IInstructionsFacet.sol) | [`InstructionsFacet`](../../contracts/smartAccounts/facets/InstructionsFacet.sol) | Proof-based instruction flow: `reserveCollateral`, `executeDepositAfterMinting`, `executeInstruction`, plus events emitted on every primitive. |
| [`IMemoInstructionsFacet`](../../contracts/userInterfaces/facets/IMemoInstructionsFacet.sol) | [`MemoInstructionsFacet`](../../contracts/smartAccounts/facets/MemoInstructionsFacet.sol) | Direct-minting `handleMintedFAssets` entry, view accessors (`getNonce`, `getExecutor`, `isTransactionIdUsed`), every memo-opcode event. |
| [`IPersonalAccountsFacet`](../../contracts/userInterfaces/facets/IPersonalAccountsFacet.sol) | [`PersonalAccountsFacet`](../../contracts/smartAccounts/facets/PersonalAccountsFacet.sol) | `createPersonalAccount(xrplOwner)` (permissionless, pause-gated), `getPersonalAccount(xrplOwner)`, beacon `implementation()`, `PersonalAccountCreated` and `PersonalAccountImplementationSet` events. Extends `IBeacon`. |
| [`IComposeTransportFacet`](../../contracts/userInterfaces/facets/IComposeTransportFacet.sol) | [`ComposeTransportFacet`](../../contracts/smartAccounts/facets/ComposeTransportFacet.sol) | The compose transport of a remote diamond (endpoint, OFT, pinned origin route), one per diamond and shared by every compose receiver on it; cut only on remote diamonds (Ethereum, at launch): `getComposeTransport()`. The timelocked `setComposeTransport(transport)` and the immediate `clearComposeTransport()` are declared on the internal `IIComposeTransportFacet`. |
| [`ILoanMarketsFacet`](../../contracts/userInterfaces/facets/ILoanMarketsFacet.sol) | [`LoanMarketsFacet`](../../contracts/smartAccounts/facets/LoanMarketsFacet.sol) | Loan configuration of the remote loan subaccounts, cut only on the loan-chain diamond: `getLoanMarket(type)`, `isLoanBorrowingDisabled(type)`, `getLoanFeeTerms(type)`. The timelocked setters (write-once `registerLoanMarket`, `disableLoanBorrowing`/`enableLoanBorrowing`, and the fee terms as one unit — `setLoanFeeTerms`, whose first call is the activation) are declared on the internal `IILoanMarketsFacet`. |
| [`ISubaccountsFacet`](../../contracts/userInterfaces/facets/ISubaccountsFacet.sol) | [`SubaccountsFacet`](../../contracts/smartAccounts/facets/SubaccountsFacet.sol) | Subaccounts (type-generic): `createSubaccount(xrplOwner, type)`, `getSubaccount(xrplOwner, type)`, `implementationForType(type)`. The timelocked `setSubaccountImplementation` is declared on the internal `IISubaccountsFacet`. |
| [`ILoanBridgeSettingsFacet`](../../contracts/userInterfaces/facets/ILoanBridgeSettingsFacet.sol) | [`LoanBridgeSettingsFacet`](../../contracts/smartAccounts/facets/LoanBridgeSettingsFacet.sol) | Flare-only loan bridge configuration: `getLoanBridgeSettings()`. The timelocked `setLoanBridgeSettings` is declared on the internal `IILoanBridgeSettingsFacet`. |
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
