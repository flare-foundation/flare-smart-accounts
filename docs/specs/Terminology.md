# Terminology

Roles and concepts referenced across the spec.

## Roles

**XRPL owner** — a string XRPL account address (e.g. `r…`). The protocol's only identity for a user. The XRPL signature on a `Payment` transaction is the sole authorization for actions on the corresponding `PersonalAccount`. Multiple smart-account behaviors key off `keccak256(bytes(xrplOwner))`.

**Personal Account (PA)** — the per-XRPL-address [`PersonalAccount`](../../contracts/smartAccounts/implementation/PersonalAccount.sol) contract on Flare, deployed as a [`PersonalAccountProxy`](../../contracts/smartAccounts/proxy/PersonalAccountProxy.sol). Holds the user's FXRP and vault shares. Mutating entry points are `onlyController` — only the diamond can drive them.

**Controller** — the [`MasterAccountController`](../../contracts/smartAccounts/implementation/MasterAccountController.sol) diamond. Acts both as the orchestrator that drives Personal Accounts and as the OpenZeppelin `IBeacon` whose `implementation()` returns the current Personal Account logic (`PersonalAccountsFacet.implementation()`).

**Executor** — an address paid in fAsset (and/or wei) to relay state changes on behalf of users. Three distinct executor concepts exist:

- *Default protocol executor* — set via `ExecutorsFacet.setExecutor`, paid in wei from `Executors.State.executorFee`, used when `InstructionsFacet` reserves collateral or redeems FXRP.
- *Personal-Account-pinned executor* — set by the user via the memo `0xD0` opcode and cleared via `0xD1`. When set, only this executor may call `handleMintedFAssets` for that PA (except for `0xD0`/`0xD1` themselves, which bypass the check to prevent lock-out).
- *Direct-minting executor* — `msg.sender` of the AssetManager's direct-mint call. Paid in fAsset out of the minted amount.

**Pauser / Unpauser** — two separate role sets in [`Pause.State`](../../contracts/smartAccounts/library/Pause.sol), managed by `onlyOwnerWithTimelock`. Pausers can call `pause()` immediately (no timelock); unpausers can call `unpause()`. The sets are independent (an address can be in one, the other, both, or neither); splitting the roles lets an emergency responder freeze state without necessarily granting them the ability to re-open it.

**Owner** — the diamond's `LibDiamond.contractOwner` (for Smart Accounts) or the OpenZeppelin `Ownable` owner (for the composer). The role guarded by `onlyOwner` and `onlyOwnerWithTimelock`. Transferable via `OwnershipFacet.transferOwnership` (Smart Accounts) or `Ownable.transferOwnership` (composer).

**Composer** — the [`FAssetRedeemComposer`](../../contracts/composer/implementation/FAssetRedeemComposer.sol). Trusted by every `FAssetRedeemerAccount` (composer-only `redeemFAsset` and `setMaxAllowances`).

**Redeemer** — an EVM address that originated a cross-chain redeem on the source chain. Each redeemer's flare-side state is isolated in their `FAssetRedeemerAccount`.

## Identifiers

**Transaction ID** — XRPL transaction hash (32 bytes), supplied by the FDC attestation as `_proof.data.requestBody.transactionId` or by the AssetManager as `_transactionId`. Indexed in [`Instructions.usedTransactionIds`](../../contracts/smartAccounts/library/Instructions.sol) for replay protection across both flows.

**Collateral Reservation ID (CRT ID)** — `uint256` returned by the FAssets `AssetManager.reserveCollateral`. The smart-account `InstructionsFacet` maps it back to the originating XRPL transaction ID in `Instructions.State.collateralReservationIdToTransactionId`, so the deferred `executeDepositAfterMinting` can prove the deposit belongs to the right minter.

**Instruction ID** — a single byte (`uint8`) split into two nibbles: high 4 bits = **instruction type**, low 4 bits = **instruction command**. Packed as byte 0 of the 32-byte XRPL payment reference. See [SmartAccounts/PaymentReferenceInstructions](./SmartAccounts/PaymentReferenceInstructions.md) for the full layout.

**Source ID** — `bytes32` constant identifying the underlying chain for FDC payment proofs (e.g. `bytes32("testXRP")` on test, `bytes32("XRP")` on production). Configured at diamond init and stored in [`PaymentProofs.State.sourceId`](../../contracts/smartAccounts/library/PaymentProofs.sol).

**LayerZero GUID** — the LayerZero message identifier. The composer emits it in every redeem/fail event; replay protection at the endpoint level guarantees a given GUID is delivered to `lzCompose` at most once.

**Source endpoint ID (srcEid)** — `uint32`, the LayerZero source chain identifier. The composer can attach a per-srcEid PPM fee override; otherwise it uses `defaultComposerFeePPM`.

## Concepts

**Diamond (EIP-2535)** — proxy pattern that delegates `msg.sig` to one of multiple facets. Selector ↔ facet mapping lives in `LibDiamond.diamondStorage`; the diamond's `fallback()` does the dispatch.

**ERC-7201 namespaced storage** — each library declares a storage struct at slot `keccak256(abi.encode(uint256(keccak256(name)) - 1)) & ~bytes32(uint256(0xff))`. Lets multiple facets share state via a library without storage-layout collisions, and lets facets be replaced without losing state.

**Singleton Factory ([EIP-2470](https://eips.ethereum.org/EIPS/eip-2470))** — the universal CREATE2 deployer at `0xce0042B868300000d44A59004Da54A005ffdcf9f`. Smart Accounts deploys `PersonalAccountProxy` through it so PA addresses are deterministic across chains: `address = keccak256(0xff || singletonFactory || salt || keccak256(initcode))[12:]`.

**Beacon proxy** — OpenZeppelin's `BeaconProxy`, where the implementation address is read from a separate beacon contract. The diamond is the beacon for Personal Accounts; the composer is the beacon for redeemer accounts. Replacing the implementation upgrades every proxy at once.

**Timelock** — owner-only operations are recorded as `keccak256(msg.data) → execution-allowed-after timestamp`. Once the delay has elapsed, **anyone** can call `executeTimelockedCall(encodedCall)`. Implemented twice with identical semantics: `TimelockFacet` for the diamond, `OwnableWithTimelock` for the composer. Maximum duration: 7 days.

**`onlyOwnerWithTimelock`** — modifier that either records a timelocked call (when not currently executing and `timelockDurationSeconds > 0`) or executes immediately (when the timelock is zero, or when re-entered from `executeTimelockedCall`). Always checks `_checkOwner()` on the recording side.

**Replay set** — `Instructions.State.usedTransactionIds`: a `mapping(bytes32 => bool)` toggled to `true` the first time a transaction ID is seen on either the payment-proof flow or the direct-minting flow.

**Nonce** — `MemoInstructions.State.nonces[personalAccount]`: a counter increasing only on successful memo UserOp execution. The user can bump it via `0xE1` to retire stuck txs.

**PackedUserOperation** — the [ERC-4337](https://eips.ethereum.org/EIPS/eip-4337) calldata shape. Only `sender`, `nonce`, and `callData` are honored by `MemoInstructions.execute`; the other fields are present for ABI compatibility but ignored.

**FAsset / FXRP** — Flare's wrapped representations of underlying-chain assets. FXRP wraps XRP; minting and redeeming are gated by the FAssets `AssetManager`. See `flare-periphery`'s [`IAssetManager`](https://github.com/flare-foundation/flare-periphery-package).

**Agent vault** — an off-protocol FAssets agent whose vault address is registered with `AgentVaultsFacet.addAgentVaults`. Mints from a smart account pick one by its `agentVaultId` packed in the payment reference (bytes 12–13).

**Vault (Firelight / Upshift)** — third-party ERC-4626-shaped vaults registered with `VaultsFacet.addVaults`. `Firelight` follows the ERC-4626 mint/redeem shape; `Upshift` uses a separate LP token plus `requestRedeem` / `claim` (date-keyed). Their identifiers (`vaultId`, bytes 14–15 of the payment reference) and types (`VaultType.None | Firelight | Upshift`) are pinned at registration time.

**XRPL provider wallet** — an XRPL address controlled by the protocol that users pay *into* to send proof-based instructions. Verified by hash in [`PaymentProofs.verifyPayment`](../../contracts/smartAccounts/library/PaymentProofs.sol) against [`XrplProviderWallets.State.xrplProviderWalletHashes`](../../contracts/smartAccounts/library/XrplProviderWallets.sol). Operators can rotate or remove wallets via `XrplProviderWalletsFacet`.

**Instruction fee** — a XRP-denominated minimum on the *received* amount in a payment-proof instruction (`receivedAmount >= instructionFee`). Configured globally (`defaultInstructionFee`) and per-instruction-ID (`InstructionFees.State.instructionFees[instructionId]`, 1-based so 0 means "use default"). Direct-minting has its own executor-fee model; see [SmartAccounts/Fees](./SmartAccounts/Fees.md).

**Compose message** — the LayerZero payload delivered by the source-chain OFT adapter. The composer extracts `srcEid`, `amountLD`, and the encoded [`RedeemComposeMessage`](../../contracts/userInterfaces/IFAssetRedeemComposer.sol).

**Destination tag** — XRPL `DestinationTag`. The composer can call `redeemWithTag` instead of `redeemAmount` to embed it in the redemption payment (XRP only; `IAssetManager.redeemWithTagSupported()` must be true).
