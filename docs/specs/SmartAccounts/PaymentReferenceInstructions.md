# Payment-reference instructions

The **proof-based** instruction flow turns an XRPL Payment into a Flare-side action. The user sends a Payment to one of the protocol's XRPL provider wallets with a 32-byte payment reference encoding the instruction. A relayer requests the FDC payment attestation, submits it to the diamond, and the encoded action executes.

The entry points live in [`InstructionsFacet`](../../../contracts/smartAccounts/facets/InstructionsFacet.sol). All three methods are `notPaused` (see [Pause](./Pause.md)).

## 32-byte payment reference layout

Byte 0 is the instruction ID, packed as `high-nibble = instructionType`, `low-nibble = instructionCommand`. Byte 1 is a wallet identifier (passed through to the AssetManager when relevant). Bytes 2–11 hold an unsigned 80-bit `value`. Bytes 12–13 hold an `agentVaultId`, bytes 14–15 a `vaultId`, and the last 20 bytes (12–31) overlap with the recipient address slot used by the FXRP transfer instruction.

See [`PaymentReferenceParser`](../../../contracts/smartAccounts/library/PaymentReferenceParser.sol) for the bit-level decoders.

```text
 byte:  0    1                              11 12  13 14  15                                 31
       +--+--+------------------------------+------+------+-----------------------------------+
       |id|wt|         value (uint80)       | agt  | vlt  | (unused for non-transfer shapes)  |
       +--+--+------------------------------+------+------+-----------------------------------+
                                                  └──────── for FXRP transfer (id=0x01):
                                                            bytes 12–31 = recipient address (20)
```

The high nibble of byte 0 partitions the instruction space:

| `instructionType` | Namespace | Vault type |
|-------------------|-----------|------------|
| `0x0` | FXRP raw | — |
| `0x1` | Firelight vault | `VaultType.Firelight` |
| `0x2` | Upshift vault | `VaultType.Upshift` |

Within each namespace, the low nibble selects the command. The full table:

| ID | Type / Command | Action | Value field | Other fields |
|----|----------------|--------|-------------|--------------|
| `0x00` | FXRP / collateral reservation | `reserveCollateral` (proof not required) | lots | bytes 12–13 = agent vault id |
| `0x01` | FXRP / transfer | `executeInstruction` → FXRP transfer | amount (drops) | bytes 12–31 = recipient (20 bytes) |
| `0x02` | FXRP / redeem | `executeInstruction` → FXRP redeem | lots | — |
| `0x10` | Firelight / mint+deposit | `reserveCollateral`, then `executeDepositAfterMinting` | lots | bytes 12–13 = agent vault id, bytes 14–15 = deposit vault id |
| `0x11` | Firelight / deposit | `executeInstruction` → vault deposit | assets (drops) | bytes 14–15 = deposit vault id |
| `0x12` | Firelight / redeem | `executeInstruction` → vault redeem | shares (drops) | bytes 14–15 = withdraw vault id |
| `0x13` | Firelight / claim withdraw | `executeInstruction` → claim withdrawal | period | bytes 14–15 = withdraw vault id |
| `0x20` | Upshift / mint+deposit | `reserveCollateral`, then `executeDepositAfterMinting` | lots | bytes 12–13 = agent vault id, bytes 14–15 = deposit vault id |
| `0x21` | Upshift / deposit | `executeInstruction` → vault deposit | assets (drops) | bytes 14–15 = deposit vault id |
| `0x22` | Upshift / request redeem | `executeInstruction` → request redeem | shares (drops) | bytes 14–15 = withdraw vault id |
| `0x23` | Upshift / claim | `executeInstruction` → claim | date `yyyymmdd` | bytes 14–15 = withdraw vault id |

Every value field is required to be non-zero — `PaymentReferenceParser.getValue` reverts with `ValueZero()` otherwise. `getAgentVaultId` and `getVaultId` reject zero too. `getAddress` rejects `address(0)`.

## Three entry points

### 1. `reserveCollateral(xrplAddress, paymentReference, transactionId)`

Used for instruction IDs ending in `0x?0` — collateral reservation either standalone (`0x00`) or as the first step of a mint+deposit (`0x10`, `0x20`).

Pre-conditions:
- `instructionType <= 2 && instructionCommand == 0` — only the `0x?0` shapes are accepted here.
- `transactionId != bytes32(0)`.

Effects:
1. `PersonalAccounts.getOrCreatePersonalAccount(xrplAddress)` — deploys the PA if needed.
2. `AgentVaults.getAgentVaultAddress(paymentReference)` — resolves the agent.
3. `FXrp.reserveCollateral(personalAccount, agentVault, lots, txId, ref, xrplAddress)` — forwards `msg.value` to the AssetManager via the PA. Emits `IInstructionsFacet.CollateralReserved`.
4. Stores `state.collateralReservationIdToTransactionId[crtId] = transactionId`.

No FDC proof here — collateral reservation is itself an on-chain action that the FAssets system will require a payment proof for later. The XRPL payment that triggered the reservation is *not* the FAssets minting payment; it is a metadata-only request paid out of the user's account into a provider wallet. The same `transactionId` is the proof that the user authorized this reservation.

`msg.value` must cover the AssetManager's collateral reservation fee plus the protocol executor fee. Both come from the relayer, not the user. The default protocol executor is the recipient of `executorFee` wei; configure via [Executors](./Executors.md).

### 2. `executeDepositAfterMinting(crtId, proof, xrplAddress)`

The deferred second half of a `0x10` / `0x20` flow. Run after the FAssets system completes minting on the XRPL side.

Pre-conditions:
- `instructionType ∈ {1, 2} && instructionCommand == 0` — must be a mint+deposit reference.
- `state.collateralReservationIdToTransactionId[crtId] == transactionId` — the reservation must match this XRPL transaction.
- `assetManager.collateralReservationInfo(crtId).status == SUCCESSFUL` — minting completed.
- The FDC `IPayment.Proof` verifies (`PaymentProofs.verifyPayment`).
- `reservationInfo.minter == personalAccount` (computed from `xrplAddress`).
- `lotsToAmount(paymentReferenceValue) == reservationInfo.valueUBA` — what was reserved matches what was minted. (Could shift if the lot size changes between reservation and deposit; the user would then call `deposit` separately.)
- `!state.usedTransactionIds[transactionId]` — not yet executed.

Effects:
1. Marks `usedTransactionIds[transactionId] = true`.
2. Resolves the deposit vault via `Vaults.getVaultAddress(paymentReference)`.
3. `Vault.deposit(personalAccount, vaultType, vault, amount)` — the PA approves and deposits.
4. Emits `IInstructionsFacet.InstructionExecuted`.

Note: the proof-fee check is **skipped** in this path. The collateral-reservation fee already paid covers the protocol's relayer cost, and off-chain logic verifies fee adequacy when the relayer chooses to fulfil the reservation.

### 3. `executeInstruction(proof, xrplAddress)`

Generic dispatch for every command **not** matching `0x?0`. This is the standalone path: the user sends a Payment to a provider wallet, the relayer fetches a proof, the diamond executes.

Pre-conditions:
- `receivedAmount >= getInstructionFee(instructionId)` — the user paid the protocol fee (see [Fees](./Fees.md)).
- The FDC `IPayment.Proof` verifies (`PaymentProofs.verifyPayment`).
- `!state.usedTransactionIds[transactionId]` — not yet executed.

Effects:
1. Marks `usedTransactionIds[transactionId] = true`.
2. `PersonalAccounts.getOrCreatePersonalAccount(xrplAddress)`.
3. `Instructions.executeInstruction(instructionType, instructionCommand, paymentReference, personalAccount)` — dispatches to the primitive (`FXrp.transfer`, `FXrp.redeem`, `Vault.deposit`, `Vault.redeem`, `Vault.claimWithdrawal`, `Vault.requestRedeem`, `Vault.claim`).
4. Emits `IInstructionsFacet.InstructionExecuted`.

The dispatch table in [`Instructions.executeInstruction`](../../../contracts/smartAccounts/library/Instructions.sol) is exhaustive — any combination not listed reverts with `InvalidInstruction(type, command)`.

## Replay protection

Both `executeInstruction` and `executeDepositAfterMinting` (and the memo path's `_distributeFAssets`) write to the same `Instructions.State.usedTransactionIds` mapping. Once an XRPL transaction has driven any on-chain instruction, it cannot drive another — regardless of the path that consumed it.

`reserveCollateral` does **not** mark `usedTransactionIds`; instead, it pins the mapping from `collateralReservationId` to `transactionId`. The matching `executeDepositAfterMinting` later does the marking, so two parallel collateral-reservation requests for the same XRPL transaction would each succeed at the reservation step (idempotency on the AssetManager side handles that) but only the first deposit-after-minting completes.

## Events

`IInstructionsFacet` declares one event per primitive: `CollateralReserved`, `InstructionExecuted`, `FXrpRedeemed`, `FXrpTransferred`, `Approved`, `Deposited`, `Redeemed`, `WithdrawalClaimed`, `RedeemRequested`, `Claimed`. The Personal Account also emits a slimmer version of each event from its own context (`IPersonalAccount`).

The diamond is the recommended event source for indexers: every flow funnels through `InstructionsFacet`, and the diamond-side events carry the XRPL transaction ID, payment reference, and XRPL owner string for cross-referencing back to the source Payment.
