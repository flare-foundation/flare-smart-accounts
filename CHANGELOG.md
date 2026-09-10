# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
  - Loan subaccounts — deterministic, restricted staging accounts under each Personal Account for the loan-origination flow. Design: `docs/specs/SmartAccounts/LoanSubaccounts.md`.
    - `LoanSubaccount` + `SubaccountProxy`; the controller is a type-aware beacon (`implementationForType`, timelocked `setSubaccountImplementation`). The type is a raw `uint256` (`0` reserved, `1` = loan).
    - `createSubaccount(xrplOwner, type)` (permissionless, idempotent) and `getSubaccount`: CREATE2 via the EIP-2470 singleton factory — the same address on every chain, creatable before the Personal Account exists. Frozen proxy creation code with a pinned-hash test.
    - Restricted methods are `onlyParent`, reached through the existing `0xFF`/`0xFE` account abstraction path; no new memo opcode.
    - One permissionless direction per account: on Flare, `sweepRedeem()` (pushes FXRP to the parent, which redeems it through the subaccount-only `PersonalAccount.redeemFromSubaccount(amount)`); forward moves are signed. Non-FXRP strays have no rail and strand (accepted; see the spec).
    - `BridgeRoutesFacet` — the Flare-side, type-generic routing to the remote chains, all timelocked: `setFxrpOft` (validated against the FXRP token, its decimals and `oftVersion`; a rotation re-validates every registered route), `setBridgeRoute(eid, peer)` (one pinned peer per remote chain, validated against the adapter's live peer; a zero peer clears the route) and `setSubaccountTypeRoute(type, eid)` (the remote chain a bridging subaccount type lives on, **write-once** — the type is that identity and its instructions carry no destination, so a second chain is a second type; `setSubaccountTypeRouteSuspended(type, bool)` is the reversible per-type stop and `getSubaccountTypeRoutePin` still reports the pin). Every send re-checks the live peer; a new remote chain is a deployment plus governance.
    - `borrow(...)` (its payload reserves a `minComposeValue` delivery floor, which the EVM destination kind must leave zero), `depositCollateral(amount, options)` (no operation id or deadline) and `withdraw(...)` — typed parent-driven loan instructions; the compose payload is built on-chain and validated before any fee is paid. The withdraw is atomic: it carries two option blobs plus a signed delivery-value floor (`WithdrawOptions`) and prepays the return leg as compose value.
    - `cancel(operationId, options)` — a message-only loan instruction that consumes an operation id on the loan chain, so the borrow or withdraw packet carrying it can never execute; the two packets race, so the loan chain's `LoanActionCancelled` is what confirms it.
    - `MorphoLoanSubaccountRemote` — the loan-chain-side implementation behind the same proxy and address: authenticated, replay-protected `lzCompose` (borrow, deposit, atomic withdraw — withdraws and bridges home in one execution, its delivery gated by the signed value floor) plus the permissionless rails `repay` (closing the position pushes the loan-token surplus to the parent) and `depositIdleFxrp` (idle FXRP's one route, into the position; the signed withdraw brings it home). No native rail; a withdraw delivery's compose value is spent or forwarded in the same call.
    - `EthereumControllerInit` — the loan-chain cut's init: the four ERC-165 flags and nothing else (`MasterAccountControllerInit` is Flare-specific and is skipped there).
    - `ComposeTransportFacet` — the remote diamond's compose transport (endpoint, OFT, pinned origin route), one per diamond: timelocked `setComposeTransport(transport)`, immediate owner-only `clearComposeTransport()`.
    - `MorphoLoanMarketsFacet` — one write-once Morpho market per subaccount type (must exist on Morpho; tokens and oracle must carry code) with a per-type borrow kill-switch; each type's Flare fee terms (`feeFloor`/`feeSpread` WAD rates capped at 100%, non-zero `feeRecipient`) are set as one unit by the timelocked `setLoanFeeTerms` after registration; the first set is the activation — borrowing reverts until then.
    - `MorphoMath` (MIT) — the market-id, virtual-share and interest-compounding arithmetic shared by the accounts and the Morpho mock; the Morpho mirror (`IMorpho` with its `Market` struct, `IIrm`, `IOracle`) and math are pinned to Morpho Blue v1.0.0 by `MorphoConformance.t.sol` (the GPL-licensed upstream is deliberately not a dependency).
    - The loan read surface on `MorphoLoanSubaccountRemote`: `getLoanPosition()` (debt projected the way Morpho's accrual will bring it, the fee's running period priced, price, value, LLTV, required cover, Morpho's health factor, the liquidation price), `getLoanLimits(additionalCollateral)` (the cover's exact borrow and withdraw bounds, the pool's liquidity separately), `previewRepay(additionalLoanToken)` (the expected allocation of a repayment, oracle-free), `previewWithdraw(amount)` (the gate's verdict and the smallest top-up that reopens a refused exit) and `previewBorrow(amount, additionalCollateral)` (the gate's verdict with the share-rounded post-borrow debt) — all computed by the code the actions enforce (`LoanMath`); quotes for the observed block.
    - The Flare fee accrual engine on `MorphoLoanSubaccountRemote`: checkpoint accounting — `max(feeFloor, market interest + feeSpread)` per elapsed period at snapshotted terms, WAD-precision carry — with the permissionless pause-exempt `checkpointFee()`, the `getLoanFeeState()` view, and collection inside `repay` (a partial payment split pro rata between debt and fee, the fee's share paid first best-effort and staying in the payment when it cannot leave — `LoanFeeDeferred`; a covering balance closes the debt, attempts the whole collectible, reserves what it cannot pay, then pushes the surplus).
    - The cover gate on `withdraw` and `borrow`: the collateral left in the position after the action, at the market oracle's price, must cover `1.155 / LLTV` of the live debt plus twice the collectible fee (1.5x at the launch market's 77% LLTV, so the gate implies Morpho's health check; 3x the fee debt-free; a fresh position borrows at most two thirds of its collateral value) — refused otherwise (`InsufficientRemainingCollateral(requiredCover, remainingValue)`, retriable) until repaid through `repay` or a smaller amount is signed; nothing is ever taken from the collateral; sub-unit dust on a debt-free position is forgiven at the exit (`LoanFeeRemainderForgiven`).
    - `PersonalAccountRemote` — the compose-driven remote implementation of the Personal Account at the same address, behind the same beacon; one action: execute the signed batch of calls (the loan-chain `executeUserOp`); accepts native. The Flare `PersonalAccount` gains the self-called `sendCrossChainUserOp(destinationEid, ...)`, allowlisted by the bridge routes.
    - `ComposeReceiverAccountBase` — the shared `lzCompose` authentication core of the compose receivers on both chains (operation-id replay protection for the signed actions); the Flare subaccount redeems its own bridge-back on arrival, capped at the packet's amount and until a stamped deadline.
    - The account bases, each written once and dictated by the frozen proxies: `ControlledAccountBase` (the controller — `IControlledAccount`, the root every account interface extends), `SubaccountBase` (parent, type, `initialize`, `onlyParent`, the type-aware beacon lookup, on both chains — `ISubaccount`), `PersonalAccountBase` (XRPL owner, `initialize`, the beacon lookup, for the Flare and the remote Personal Account — `IPersonalAccountBase`) and, on Flare, `BridgingSubaccountBase` (the forward move over the type's route, `sweepRedeem`, the redeem-home compose — `IBridgingSubaccount`, which `ILoanSubaccount` extends). Storage rule: slot 0 `controllerAddress` and slot 1 `xrplOwner` linear (the production Personal Account layout), every other base field namespaced; pinned by `test/unit/smartAccounts/AccountStorageLayout.t.sol`. `IPersonalAccount` now inherits its controller and initializer members from `IControlledAccount` and `IPersonalAccountBase` (the moved declarations keep their signatures; Solidity-qualified references move to the declaring interface, e.g. `IControlledAccount.AlreadyInitialized`), and the Flare Personal Account emits the new `PersonalAccountInitialized`.
  - `@layerzerolabs-oapp-evm` dependency (canonical `IOFT` interface).

### Changed
  - `PersonalAccountsFacet` gains the permissionless, pause-gated `createPersonalAccount(xrplOwner)` (facet replacement on existing deployments); the `PersonalAccounts` library returns `address`.
  - `removeUnpausers` is immediate (`onlyOwner`) instead of timelocked; pauser removal stays timelocked. A removal queued before the facet cut cannot execute afterward: cancel it and remove directly.
  - `OwnableWithTimelock`: `transferOwnership` is timelocked like every other guarded owner call, `renounceOwnership()` reverts with `RenounceDisabled`, and queueing a timelocked call with value reverts with `TimelockValueNotAllowed`.
  - Deployment and CI tooling: the OpenZeppelin upgrade-safety validator over the proxy lineages, a lineage freshness check, a diamond surface verifier before and after a cut, an implementation registration check, and spellcheck (see `deployment/README.md`).

## [[v2.0.0](https://github.com/flare-foundation/flare-smart-accounts/releases/tag/v2.0.0)] - 2026-07-07

### Added
  - `MemoInstructionsFacet` — new facet dedicated to memo-based instructions via the `mintedFAssets()` direct-minting entry point.
    - 0xFF: Execute UserOp (ERC-4337 `PackedUserOperation`).
    - 0xE0: Ignore memo (recovery for malformed memo, bad callData).
    - 0xE1: Increase nonce (recovery for nonce too low).
    - 0xE2: Replace fee (recovery for fee too low).
    - 0xD0: Set PA executor.
    - 0xD1: Remove PA executor.
  - `MemoInstructions` library with ERC-7201 namespaced storage.
  - `executeUserOp(Call[])` on `PersonalAccount` — generic multi-call for account abstraction.
  - `PauseFacet` with separate pauser/unpauser roles (`EnumerableSet.AddressSet`), `onlyOwnerWithTimelock` on role management.
  - `ReaderFacet` — read-only facet for balance aggregation, vault/agent vault listing, and `isSmartAccount` check.
  - Token receiver support on `PersonalAccount`: `ERC721Holder`, `ERC1155Holder`, `IERC1363Receiver`.
  - `receive() external payable` on `PersonalAccount`.
  - `previewRedemption` to `IIVault` (Upshift vault interface).
  - FAsset Redeem Composer module: cross-chain f-asset redemption via LayerZero compose pattern.
    - `FAssetRedeemComposer` (UUPS upgradeable, `ILayerZeroComposer`, per-source PPM fees, timelocked config).
    - `FAssetRedeemerAccount` (per-redeemer BeaconProxy via CREATE2, redemption with destination tag support).
    - `FAssetRedeemComposerProxy` (ERC1967) and `FAssetRedeemerAccountProxy` (BeaconProxy).
  - `OwnableWithTimelock` utility for timelocked owner operations (max 7 days).
  - 0xFE memo opcode — Execute UserOp with data. The 42-byte memo carries only `[0xFE][walletId][fee][keccak256(_data)]`; the encoded `PackedUserOperation` arrives via the AssetManager-forwarded `_data` parameter. Lifts the XRPL memo size constraint at the cost of executor-side coordination.

### Changed
  - Renamed `mintedFAssets()` to `handleMintedFAssets()` to reflect that it's a post-mint callback, not an action.
  - Added a `bytes _data` parameter to `handleMintedFAssets()` for memo opcodes that need inputs not contained in the XRPL memo.
  - `InvalidInstructionType` error now carries the actual vault type alongside the instruction type, so the revert data identifies both sides of the mismatch.
  - `InstructionsFacet` split: legacy payment-proof flow stays in `InstructionsFacet`, memo/direct-minting flow moved to new `MemoInstructionsFacet`. Both share `Instructions.State.usedTransactionIds` for cross-path replay protection.
  - `ReentrancyGuard` → `ReentrancyGuardTransient` (EIP-1153) on `PersonalAccount`.
  - Vault type from `uint8` to `VaultType` enum (`None`, `Firelight`, `Upshift`) in `IVaultsFacet`.
  - Migrated from yarn to pnpm.
  - Updated dependencies: Flare Periphery to 0.1.44-alpha.6, added LayerZero V2 (OFT 4.0.1, Protocol 3.0.159), removed Uniswap V3.

### Removed
  - Swap functionality: `SwapFacet`, `Swap`, `UniswapV3`, `ISwapFacet`, `IISwapFacet`, `MockUniswapV3Router`.
  - `executeSwap` from `PersonalAccount`.


## [[v1.0.0](https://github.com/flare-foundation/flare-smart-accounts/releases/tag/v1.0.0)] - 2025-02-24

### Added
  - Initial release of the project.
  - Diamond proxy (EIP-2535) MasterAccountController with timelocked governance.
  - XRPL-linked personal accounts (BeaconProxy + CREATE2).
  - XRPL payment proof verification.
  - Instruction system: FXRP minting/transfer/redemption, Firelight and Upshift vault operations.
  - Uniswap V3 swap integration.

