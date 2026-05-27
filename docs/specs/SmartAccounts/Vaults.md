# Vaults

Smart Accounts integrates with two third-party FAssets-compatible yield vault families — **Firelight** and **Upshift** — and with the FAssets system's own **agent vaults** (for collateral reservation). All three registries live in dedicated libraries and are exposed through their facets.

## Agent vaults

FAssets agents pool collateral and quote minting; Smart Accounts users mint by picking an agent. To keep XRPL payment references compact, agents are registered by a numeric `agentVaultId` (the on-chain agent vault address is too big to fit).

State in [`AgentVaults`](../../../contracts/smartAccounts/library/AgentVaults.sol):

```solidity
struct State {
    mapping(uint256 agentVaultId => address agentVaultAddress);
    mapping(address agentVaultAddress => uint256 agentVaultId);
    uint256[] agentVaultIds;
}
```

Bidirectional + an enumeration list. Both directions are mandatory (`agentVaultIdToAgentVaultAddress` lookup at parse time, `agentVaultAddressToAgentVaultId` for the enumeration / duplicate checks).

[`AgentVaultsFacet`](../../../contracts/smartAccounts/facets/AgentVaultsFacet.sol):

- `addAgentVaults(ids[], addresses[])` — `onlyOwnerWithTimelock`. Rejects zero IDs, duplicates, zero addresses, and any agent whose FAssets `AgentInfo.status != NORMAL`.
- `removeAgentVaults(ids[])` — `onlyOwnerWithTimelock`. Removes by id with swap-and-pop on `agentVaultIds`.
- `getAgentVaults()` — returns ids and matching addresses.

The id is encoded in bytes 12–13 of the XRPL payment reference for any instruction that needs collateral reservation (`0x00`, `0x10`, `0x20`). `PaymentReferenceParser.getAgentVaultId` reverts with `InvalidAgentVault(0)` if zero; `AgentVaults.getAgentVaultAddress` reverts with `InvalidAgentVault(id)` if unregistered.

## Firelight and Upshift vaults

These are user-facing yield vaults. Their interface is bridged via [`IIVault`](../../../contracts/smartAccounts/interface/IIVault.sol) — a union of the two shapes:

| Operation | Firelight | Upshift |
|-----------|-----------|---------|
| Deposit | `deposit(uint256 assets, address receiver) → uint256 shares` (ERC-4626) | `deposit(address assetIn, uint256 amountIn, address receiver) → uint256 shares` |
| Redeem | `redeem(uint256 shares, address receiver, address owner) → uint256 assets` (ERC-4626) | *(use request + claim)* |
| Claim withdrawal | `claimWithdraw(uint256 period) → uint256 assets` | — |
| Request redeem | — | `requestRedeem(uint256 shares, address receiver) → (claimableEpoch, year, month, day)` |
| Claim | — | `claim(uint256 year, uint256 month, uint256 day, address receiver) → (shares, assetsAfterFee)` |
| Shares accounting | The vault is itself the ERC-20 share token. | Shares live in a separate LP token, `lpTokenAddress()`. |
| Preview redemption | `convertToAssets(shares)` (standard ERC-4626) | `previewRedemption(shares, isInstant) → (assetsAmount, assetsAfterFee)` |

The vault type is pinned at registration. State in [`Vaults`](../../../contracts/smartAccounts/library/Vaults.sol):

```solidity
struct VaultInfo {
    address vaultAddress;
    IVaultsFacet.VaultType vaultType;  // None=0, Firelight=1, Upshift=2
}

struct State {
    mapping(uint256 vaultId => VaultInfo);
    mapping(address vaultAddress => uint256 vaultId);
    uint256[] vaultIds;
}
```

[`VaultsFacet`](../../../contracts/smartAccounts/facets/VaultsFacet.sol):

- `addVaults(ids[], addresses[], types[])` — `onlyOwnerWithTimelock`. Rejects zero IDs/addresses, duplicates, `VaultType.None`, length mismatches. **There is no `removeVaults`** — vaults can be added but not removed. Replacing a vault means assigning a new id; the old id stays unreachable from new XRPL payments only if off-chain tooling stops emitting it.
- `getVaults()` — returns ids, addresses, types in parallel arrays.

The id is encoded in bytes 14–15 of the XRPL payment reference. `Vaults.getVaultAddress` additionally checks that the encoded `instructionType` (high nibble of byte 0) matches the registered `vaultType` — `InvalidInstructionType(type, expectedVaultType)` otherwise. This prevents a Firelight vault from being driven by an Upshift command.

## Instruction routing

Mapping XRPL payment-reference IDs to vault primitives:

| Reference ID | Vault type | Primitive |
|--------------|------------|-----------|
| `0x10` | Firelight | reserve collateral + later `Vault.deposit(Firelight)` (via `executeDepositAfterMinting`) |
| `0x11` | Firelight | `Vault.deposit(Firelight)` |
| `0x12` | Firelight | `Vault.redeem` |
| `0x13` | Firelight | `Vault.claimWithdrawal(period)` |
| `0x20` | Upshift | reserve collateral + later `Vault.deposit(Upshift)` |
| `0x21` | Upshift | `Vault.deposit(Upshift)` |
| `0x22` | Upshift | `Vault.requestRedeem` |
| `0x23` | Upshift | `Vault.claim(date)` — date encoded as `yyyymmdd` |

Each primitive in [`Vault`](../../../contracts/smartAccounts/library/Vault.sol) forwards to the matching `IIPersonalAccount` method and emits a vault-namespaced event from the diamond plus a slimmer one from the PA itself.

## PersonalAccount-side mechanics

[`PersonalAccount`](../../../contracts/smartAccounts/implementation/PersonalAccount.sol) is the actual ERC-20 / vault-shares holder. The two important details:

- **Approvals.** `deposit` does `fxrp.approve(_vault, _assets)` then calls the vault. `requestRedeem` does `IERC20(lpToken).forceApprove(_vault, _shares)`. Both emit `Approved` events for off-chain visibility.
- **Receiver address.** Every redeem / claim asks the vault to send funds back to `address(this)` — i.e., the PA itself. The user moves funds out of the PA via the FXRP `transfer` instruction (`0x01`) or via a UserOp.

## Reader-side aggregation

[`ReaderFacet.getBalances(address|xrplOwner)`](../../../contracts/smartAccounts/facets/ReaderFacet.sol) enumerates every registered vault and reports:

- For Firelight: `shares = IERC20(vault).balanceOf(account)`, `assets = IERC4626(vault).convertToAssets(shares)`.
- For Upshift: `shares = IERC20(lpToken).balanceOf(account)`, `assets, _ = IIVault.previewRedemption(shares, false)`.

`ReaderFacet.vaults()` and `ReaderFacet.agentVaults()` expose the underlying registries as struct arrays for off-chain consumption.

## Why two vault shapes coexist

The protocol is not opinionated about which vault family a user picks. The shape difference is real (Upshift's date-based claim makes its redeem flow async; Firelight's ERC-4626 redeem is synchronous), and the XRPL payment reference encodes the choice at the per-payment level. The same Personal Account can hold shares of multiple vaults of either type.

`VaultType.None` exists as the zero value of the enum to make "unset" detectable without a separate boolean. It is never a valid registered type — `VaultsFacet.addVaults` rejects it with `InvalidVaultType(None)`.
